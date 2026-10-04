// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
#include "BusResetCoordinator.hpp"

#ifndef ASFW_HOST_TEST
#include <DriverKit/IOLib.h>
#endif

#include "../Async/Interfaces/IAsyncControllerPort.hpp"
#include "../ConfigROM/ConfigROMStager.hpp"
#include "../ConfigROM/ROMScanner.hpp"
#include "../Hardware/OHCIConstants.hpp"
#include "BusManager.hpp"
#include "../Hardware/HardwareInterface.hpp"
#include "../Hardware/InterruptManager.hpp"
#include "../Logging/Logging.hpp"
#include "SelfIDCapture.hpp"
#include "TopologyManager.hpp"
#include "CSR/TopologyMapService.hpp"

namespace {

void LogBusResetEdgeLatched(uint64_t timestamp) {
    ASFW_LOG_V2(BusReset, "Latched busReset edge @ %llu ns", timestamp);
}

void LogSelfIDCompletionLatched(uint64_t timestamp, bool sticky) {
    if (sticky) {
        ASFW_LOG_V3(BusReset, "Latched selfIDComplete2 @ %llu ns", timestamp);
        return;
    }

    ASFW_LOG_V3(BusReset, "Latched selfIDComplete @ %llu ns", timestamp);
}

void LogDeferredRunAlreadyScheduled(const char* reason) {
    ASFW_LOG_V3(BusReset, "Deferred run already scheduled (%{public}s)",
                (reason != nullptr) ? reason : "unspecified");
}

void LogStateTransition(ASFW::Driver::BusResetCoordinator::State previousState,
                        ASFW::Driver::BusResetCoordinator::State nextState, const char* reason) {
    ASFW_LOG_V2(BusReset, "[FSM] %{public}s -> %{public}s: %{public}s",
                ASFW::Driver::BusResetCoordinator::StateString(previousState),
                ASFW::Driver::BusResetCoordinator::StateString(nextState), reason);
}

} // namespace

namespace ASFW::Driver {

std::atomic<uint32_t> BusResetCoordinator::nextDiagnosticsInstanceId_{1};

BusResetCoordinator::BusResetCoordinator()
    : diagnosticsInstanceId_(nextDiagnosticsInstanceId_.fetch_add(1, std::memory_order_relaxed)) {}
BusResetCoordinator::~BusResetCoordinator() { deferredWorkEpoch_->Retire(); }

bool BusResetCoordinator::RetireDeferredWork() noexcept {
    deferredWorkEpoch_->Retire();
    return deferredWorkEpoch_->Quiesced();
}

bool BusResetCoordinator::Initialize(HardwareInterface* hw, OSSharedPtr<IODispatchQueue> workQueue,
                                     Async::IAsyncControllerPort* asyncSys,
                                     SelfIDCapture* selfIdCapture, ConfigROMStager* configRom,
                                     InterruptManager* interrupts, TopologyManager* topology,
                                     BusManager* busManager, Discovery::ROMScanner* romScanner,
                                     Bus::TopologyMapService* topologyMapService,
                                     Scheduling::ITimerScheduler* timerScheduler) {
    // Initialization/rebinding requires a quiesced owner. Queued work from the
    // prior binding keeps its retired token and cannot enter the new runtime.
    if (!RetireDeferredWork()) {
        ASFW_LOG_ERROR(BusReset, "Cannot rebind coordinator with an active deferred callback");
        return false;
    }
    deferredWorkEpoch_ = std::make_shared<Shared::PostedWorkEpoch>();
    deferredRunScheduled_ = false;
    hardware_ = hw;
    workQueue_ = std::move(workQueue);
    asyncSubsystem_ = asyncSys;
    selfIdCapture_ = selfIdCapture;
    configRomStager_ = configRom;
    interruptManager_ = interrupts;
    topologyManager_ = topology;
    busManager_ = busManager;
    romScanner_ = romScanner;
    topologyMapService_ = topologyMapService;
    timerScheduler_ = timerScheduler;

    state_ = State::Idle;
    selfIdLatch_.Reset();
    pendingBusResetEdge_ = false;
    cycle_ = ResetCycleState{};
    delegateAttemptActive_ = false;
    delegateTarget_ = 0xFF;
    delegateRetryCount_ = 0;
    delegateSuppressed_ = false;
    stopFlushIssued_ = false;

    if (topologyMapService_) {
        topologyMapService_->Invalidate();
    }

    if (hardware_ == nullptr || workQueue_.get() == nullptr || asyncSubsystem_ == nullptr ||
        selfIdCapture_ == nullptr || configRomStager_ == nullptr || interruptManager_ == nullptr ||
        topologyManager_ == nullptr) {
        ASFW_LOG(BusReset, "ERROR: BusResetCoordinator initialized with null dependencies");
        return false;
    }
#ifndef ASFW_HOST_TEST
    if (timerScheduler_ == nullptr) {
        ASFW_LOG_ERROR(BusReset, "Bus reset coordinator requires a nonblocking timer");
        return false;
    }
#endif
    return true;
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
void BusResetCoordinator::OnIrq(uint32_t intEvent, uint64_t timestamp) {
    bool relevant = false;

    if ((intEvent & IntEventBits::kBusReset) != 0U) {
        // Mask the level source before returning to the interrupt dispatcher.
        // Reset only the previous cycle's software evidence, then retain any
        // completion carried by this same snapshot for the deferred FSM.
        MaskBusReset();
        selfIdLatch_.Reset();
        cycle_.timing.lastBusResetEdgeNs = timestamp;
        pendingBusResetEdge_ = true;
        relevant = true;
        ++busResetIrqCount_;
        LogBusResetEdgeLatched(timestamp);
    }

    if ((intEvent & IntEventBits::kSelfIDComplete) != 0U) {
        selfIdLatch_.complete = true;
        selfIdLatch_.completeTimeNs = timestamp;
        relevant = true;
        LogSelfIDCompletionLatched(timestamp, false);
    }

    if ((intEvent & IntEventBits::kSelfIDComplete2) != 0U) {
        selfIdLatch_.stickyComplete = true;
        selfIdLatch_.stickyCompleteTimeNs = timestamp;
        relevant = true;
        LogSelfIDCompletionLatched(timestamp, true);
    }

    if (!relevant || workQueue_.get() == nullptr) {
        return;
    }

    const auto epoch = deferredWorkEpoch_;
    workQueue_->DispatchAsync(^{
      Shared::PostedWorkEpoch::Lease lease(*epoch);
      if (!lease) return;
      RunStateMachine();
    });
}

void BusResetCoordinator::BindCallbacks(TopologyReadyCallback onTopology) {
    topologyCallback_ = std::move(onTopology);
}

BusResetCoordinator::ResetDiagnostics BusResetCoordinator::Diagnostics() const {
    return ResetDiagnostics{
        .driverStartId = diagnosticsInstanceId_,
        .resetEpoch = resetEpoch_,
        .manualResetEpoch = manualResetEpoch_,
        .softwareResetIssuedCount = softwareResetIssuedCount_,
        .busResetIrqCount = busResetIrqCount_,
        .lastAcceptedGeneration = lastAcceptedGeneration_,
        .lastTopologyNodeCount = lastTopologyNodeCount_,
        .readyForDiscoveryFailureBits = readyForDiscoveryFailureBits_,
        .lastRecoveryReasonCode = lastRecoveryReasonCode_,
        .lastResetKind = static_cast<uint8_t>(lastResetKind_),
        .recoveryResetAttempts = manualRecoveryResetAttempts_,
        .discoveryCallbackCount = discoveryCallbackCount_,
    };
}

uint64_t BusResetCoordinator::MonotonicNow() noexcept {
#ifdef ASFW_HOST_TEST
    return ASFW::Testing::HostMonotonicNow();
#else
    static mach_timebase_info_data_t info{};
    if (info.denom == 0) {
        mach_timebase_info(&info);
    }
    const uint64_t ticks = mach_absolute_time();
    return ticks * info.numer / info.denom;
#endif
}

const char* BusResetCoordinator::StateString() const { return StateString(state_); }

const char* BusResetCoordinator::StateString(State state) {
    switch (state) {
    case State::Idle:
        return "Idle";
    case State::Detecting:
        return "Detecting";
    case State::WaitingSelfID:
        return "WaitingSelfID";
    case State::QuiescingAT:
        return "QuiescingAT";
    case State::RestoringConfigROM:
        return "RestoringConfigROM";
    case State::ClearingBusReset:
        return "ClearingBusReset";
    case State::Rearming:
        return "Rearming";
    case State::Complete:
        return "Complete";
    case State::QuiesceFailed:
        return "QuiesceFailed";
    }
    return "Unknown";
}

void BusResetCoordinator::TransitionTo(State newState, const char* reason) {
    if (state_ == newState) {
        return;
    }

    const uint64_t now = MonotonicNow();

    if (newState == State::Detecting) {
        ++metrics_.resetCount;
        firstIrqTime_ = now;
    } else if (newState == State::RestoringConfigROM) {
        busResetClearTime_ = now;
    }

    LogStateTransition(state_, newState, reason);

    state_ = newState;
    stateEntryTime_ = now;
}

void BusResetCoordinator::CompleteCurrentRun() {
    workInProgress_.store(false, std::memory_order_release);
}

void BusResetCoordinator::YieldAndReschedule(uint32_t delayMs, const char* reason) {
    if (workQueue_.get() == nullptr) {
        return;
    }

    bool expected = false;
    if (!deferredRunScheduled_.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        LogDeferredRunAlreadyScheduled(reason);
        return;
    }

    if (!ScheduleDeferred(delayMs, [this] {
        deferredRunScheduled_.store(false, std::memory_order_release);
        RunStateMachine();
    })) {
        deferredRunScheduled_.store(false, std::memory_order_release);
        RecordRecoveryReason("Bus reset timer scheduling failed; recovery blocked");
        TransitionTo(State::QuiesceFailed, "Deferred timer unavailable");
    }
}

bool BusResetCoordinator::ScheduleDeferred(uint32_t delayMs, std::function<void()> work) {
    const auto epoch = deferredWorkEpoch_;
    auto guarded = [epoch, work = std::move(work)] {
        Shared::PostedWorkEpoch::Lease lease(*epoch);
        if (lease) work();
    };
    const uint64_t delayNs = static_cast<uint64_t>(delayMs) * 1'000'000ULL;
    if (timerScheduler_ != nullptr) {
        return timerScheduler_->ScheduleAfter(delayNs, std::move(guarded)) !=
               Scheduling::kInvalidTimerToken;
    }
#ifdef ASFW_HOST_TEST
    // Legacy test rigs use the same deferred virtual-clock semantics. The
    // production initialization rejects a missing injected timer.
    if (workQueue_) {
        workQueue_->DispatchAsyncAfter(delayNs, std::move(guarded));
        return true;
    }
#endif
    return false;
}

bool BusResetCoordinator::G_ATInactive() {
    if (hardware_ == nullptr) {
        return false;
    }

    // OHCI 1.1 §7.2.3.2 requires software to wait until the AT contexts are no
    // longer active before clearing `IntEvent.busReset`.
    auto access = hardware_->TryBeginAccess();
    if (!access) return false;
    const uint32_t atReqControl =
        access.Read(Register32FromOffsetUnchecked(DMAContextHelpers::AsReqTrContextControlSet));
    const uint32_t atRspControl =
        access.Read(Register32FromOffsetUnchecked(DMAContextHelpers::AsRspTrContextControlSet));

    const bool atReqActive = (atReqControl & kContextControlActiveBit) != 0U;
    const bool atRspActive = (atRspControl & kContextControlActiveBit) != 0U;
    return !atReqActive && !atRspActive;
}

bool BusResetCoordinator::HasSelfIDCompletion() const {
    return selfIdLatch_.complete || selfIdLatch_.stickyComplete;
}

bool BusResetCoordinator::CanAttemptSelfIDDecode() const {
    return G_NodeIDValid() && HasSelfIDCompletion();
}

bool BusResetCoordinator::G_NodeIDValid() const {
    if (hardware_ == nullptr) {
        return false;
    }

    auto access = hardware_->TryBeginAccess();
    if (!access) return false;
    const uint32_t nodeId = access.Read(Register32::kNodeID);
    return ((nodeId & 0x80000000U) != 0U) && ((nodeId & 0x3FU) != 63U);
}

bool BusResetCoordinator::G_IsRoot() const {
    if (hardware_ == nullptr) {
        return false;
    }
    // OHCI NodeID.root (bit 30) — set when the PHY reports this controller is root.
    auto access = hardware_->TryBeginAccess();
    return access && (access.Read(Register32::kNodeID) & NodeIDBits::kRoot) != 0U;
}

} // namespace ASFW::Driver
