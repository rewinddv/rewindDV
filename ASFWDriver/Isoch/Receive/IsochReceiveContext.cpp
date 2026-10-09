// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#include "IsochReceiveContext.hpp"
#include "ReceiveStopGate.hpp"
#include "../../Common/TimingUtils.hpp"
#include "../Core/IsochEventGroup.hpp"
#include "../../Hardware/OHCIConstants.hpp"
#include "../../Hardware/RegisterMap.hpp"
#include "../../Diagnostics/Signposts.hpp"

#include <utility>
#include <optional>

namespace ASFW::Isoch {

// ============================================================================
// Factory
// ============================================================================

std::unique_ptr<IsochReceiveContext> IsochReceiveContext::Create(::ASFW::Driver::HardwareInterface* hw,
                                                            std::shared_ptr<::ASFW::Isoch::Memory::IIsochDMAMemory> dmaMemory) {
    auto ctx = std::unique_ptr<IsochReceiveContext>(new (std::nothrow) IsochReceiveContext());
    if (!ctx || !ctx->HasStateLock()) return nullptr;

    ctx->hardware_ = hw;
    ctx->dmaMemory_ = std::move(dmaMemory);

    return ctx;
}

// ============================================================================
// Lifecycle
// ============================================================================

IsochReceiveContext::~IsochReceiveContext() {
    (void)Stop();
}

// ============================================================================
// Configuration
// ============================================================================

IsochReceiveContext::Registers IsochReceiveContext::GetRegisters(uint8_t index) const {
    return Registers{
        .CommandPtr          = static_cast<::ASFW::Driver::Register32>(::DMAContextHelpers::IsoRcvCommandPtr(index)),
        .ContextControlSet   = static_cast<::ASFW::Driver::Register32>(::DMAContextHelpers::IsoRcvContextControlSet(index)),
        .ContextControlClear = static_cast<::ASFW::Driver::Register32>(::DMAContextHelpers::IsoRcvContextControlClear(index)),
        .ContextMatch        = static_cast<::ASFW::Driver::Register32>(::DMAContextHelpers::IsoRcvContextMatch(index)),
    };
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t IsochReceiveContext::Configure(uint8_t channel, uint8_t contextIndex) {
    if (!HasStateLock()) return kIOReturnNoMemory;
    if (!hardware_ || !dmaMemory_) {
        return kIOReturnNotReady;
    }

    if (contextIndex >= 4) {
        return kIOReturnBadArgument;
    }

    contextIndex_ = contextIndex;
    channel_ = channel;
    registers_ = GetRegisters(contextIndex_);
    return rxRing_.SetupRings(*dmaMemory_, kNumDescriptors, kMaxPacketSize);
}

// ============================================================================
// Runtime
// ============================================================================

kern_return_t IsochReceiveContext::Start() {
    if (!HasStateLock()) return kIOReturnNoMemory;
    while (rxLock_.test_and_set(std::memory_order_acquire)) {}
    if (GetState() != IRPolicy::State::Stopped) {
        rxLock_.clear(std::memory_order_release);
        return kIOReturnInvalid;
    }

    if (!hardware_) {
        ASFW_LOG(Isoch, "❌ Start: hardware_ is null!");
        rxLock_.clear(std::memory_order_release);
        return kIOReturnNotReady;
    }

    const uint32_t cmdPtr = rxRing_.InitialCommandPtrWord();
    if (cmdPtr == 0) {
        ASFW_LOG(Isoch, "❌ Start: Invalid descriptor cmdPtr");
        rxLock_.clear(std::memory_order_release);
        return kIOReturnInternalError;
    }
    const uint32_t contextMatch = 0xF0000000 | (channel_ & 0x3F);
    const uint32_t ctlValue = Driver::ContextControl::kRun | Driver::ContextControl::kIsochHeader;
    const uint32_t contextMask = 1u << contextIndex_;
    {
        auto access = hardware_->TryBeginAccess();
        if (!access) {
            rxLock_.clear(std::memory_order_release);
            return kIOReturnNotReady;
        }
        const auto reset = rxRing_.ResetForStart();
        if (reset != kIOReturnSuccess) {
            rxLock_.clear(std::memory_order_release);
            return reset;
        }
        access.Write(registers_.ContextMatch, contextMatch);
        access.Write(registers_.CommandPtr, cmdPtr);
        access.Write(registers_.ContextControlClear, 0xFFFFFFFFu);
        // A stop can leave an event behind. Clear only our stale event before
        // enabling interrupts and RUN; never clear a new run's completion.
        access.Write(ASFW::Driver::Register32::kIsoRecvIntEventClear, contextMask);
        access.Write(ASFW::Driver::Register32::kIsoRecvIntMaskSet, contextMask);
        access.Write(registers_.ContextControlSet, ctlValue);
    }
    ASFW_LOG(Isoch, "Start: Enabled IR interrupt for context %u (mask=0x%08x)", contextIndex_, contextMask);

    TransitionReceive(IRPolicy::State::Running, "Start");

    if (receiveConsumer_) {
        receiveConsumer_->OnReceiveActivated();
    }
    rxLock_.clear(std::memory_order_release);
    return kIOReturnSuccess;
}

kern_return_t IsochReceiveContext::Stop() {
    if (rxLock_.test_and_set(std::memory_order_acquire)) {
        // Only the control caller waits. Poll and packet consumption keep their
        // nonblocking gate. Use a local timebase: a failed/partial startup must
        // not depend on globally initialized timing or race its initialization.
        mach_timebase_info_data_t timebase{};
        if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
            timebase.numer == 0 || timebase.denom == 0) return kIOReturnNotReady;
        const uint64_t started = mach_absolute_time();
        constexpr uint64_t kStopGateBudgetNs = 100'000'000;
        const auto expired = [&] {
            return ASFW::Timing::detail::ScaleFloor(mach_absolute_time() - started,
                timebase.numer, timebase.denom) >= kStopGateBudgetNs;
        };
        if (!Detail::AcquireReceiveStopGate(rxLock_, expired, [] { IOSleep(1); })) {
            // No ownership was acquired: leave state, descriptors and binding
            // untouched. The caller must retain them and contain the failure.
            return kIOReturnTimeout;
        }
    }

    if (GetState() == IRPolicy::State::Stopped) {
        rxLock_.clear(std::memory_order_release);
        return kIOReturnSuccess;
    }
    if (GetState() == IRPolicy::State::Stopping) {
        const auto failure = stopFailure_;
        rxLock_.clear(std::memory_order_release);
        return failure;
    }

    // Close software consumption even when hardware quiescence cannot be proven.
    TransitionReceive(IRPolicy::State::Stopping, "Stop/begin");

    const uint32_t contextMask = 1u << contextIndex_;
    if (auto access = hardware_->TryBeginAccess()) {
        access.Write(ASFW::Driver::Register32::kIsoRecvIntMaskClear, contextMask);
        access.WriteAndFlush(registers_.ContextControlClear, Driver::ContextControl::kRun);
    } else {
        // Revoking software access is not proof of DMA containment.
        rxLock_.clear(std::memory_order_release);
        return kIOReturnNotReady;
    }
    // Flush RUN-clear and wait for ACTIVE to fall before dropping the direct
    // audio binding.  See Linux firewire/ohci.c:1361-1378 for the same
    // teardown ordering; freeing this mapping while ACTIVE is set can fault
    // the host when OHCI completes a late DMA write.
    ASFW_LOG(Isoch, "Stop: Disabled IR interrupt for context %u", contextIndex_);

    // Two complementary guards, both required: the revocable access scope keeps
    // us from issuing MMIO after Detach, and the all-ones sentinel catches a
    // physically removed device, which still reads 0xFFFFFFFF through a live scope.
    const auto readControl = [this]() -> std::optional<uint32_t> {
        auto access = hardware_->TryBeginAccess();
        if (!access) return std::nullopt;
        const uint32_t value = access.Read(registers_.ContextControlSet);
        if (value == 0xFFFFFFFFu) return std::nullopt;
        return value;
    };
    const auto initialControl = readControl();
    if (initialControl &&
        (*initialControl & Driver::ContextControl::kActive) != 0) {
        IODelay(5);
        constexpr uint32_t kMaxIterations = 250;
        constexpr uint32_t kBaseDelayMicros = 6;
        for (uint32_t iteration = 0; iteration < kMaxIterations; ++iteration) {
            const auto polledControl = readControl();
            if (!polledControl ||
                (*polledControl & Driver::ContextControl::kActive) == 0) {
                break;
            }
            IODelay(kBaseDelayMicros + iteration);
        }
    }

    const auto control = readControl();
    if (!control) {
        rxLock_.clear(std::memory_order_release);
        return kIOReturnNotReady;
    }
    if ((*control & Driver::ContextControl::kActive) != 0) {
        const kern_return_t failure = (*control & Driver::ContextControl::kDead) != 0
            ? kIOReturnDMAError
            : kIOReturnTimeout;
        stopFailure_ = failure;
        ASFW_LOG_ERROR(Isoch,
                       "IR: stop did not quiesce context=%u control=0x%08x kr=0x%08x; retaining direct binding",
                       contextIndex_, *control, failure);
        rxLock_.clear(std::memory_order_release);
        return failure;
    }

    // ACTIVE clear is the ownership barrier, not proof that software already
    // consumed every descriptor completed before that barrier. Publish that
    // final contiguous descriptor prefix to the raw sink before detaching it.
    (void)DrainCompletedLocked(false);
    TransitionReceive(IRPolicy::State::Stopped, "Stop/ACTIVE-clear-final-drain");

    if (receiveConsumer_) {
        receiveConsumer_->OnReceiveQuiesced();
    }

    rxLock_.clear(std::memory_order_release);
    return kIOReturnSuccess;
}

uint32_t IsochReceiveContext::Poll() {
    if (rxLock_.test_and_set(std::memory_order_acquire)) {
        return 0;
    }

    if (GetState() != IRPolicy::State::Running) {
        rxLock_.clear(std::memory_order_release);
        return 0;
    }

    const uint32_t processed = DrainCompletedLocked(true);
    // Extension can race the controller's terminal fetch even if ACTIVE was
    // previously set. OHCI 1.1 section 3.2.1.2 requires WAKE after publication.
    if (rxRing_.TakeWakeRequired()) {
        if (auto access = hardware_->TryBeginAccess()) {
            access.Write(registers_.ContextControlSet, Driver::ContextControl::kWake);
        }
    }

    rxLock_.clear(std::memory_order_release);
    return processed;
}

uint32_t IsochReceiveContext::DrainCompletedLocked(bool recycle) {
    const auto cycleHostPair =
        hardware_
            ? hardware_->ReadCycleTimeAndUpTime()
            : std::pair<uint32_t, uint64_t>{0, mach_absolute_time()};
    const uint32_t drainCycleTimer = cycleHostPair.first;
    const uint64_t drainHostTicks = cycleHostPair.second;
    const IsochReceiveBatch receiveBatch{
        .drainCycleTimer = drainCycleTimer,
        .drainHostTicks = drainHostTicks,
    };
    if (receiveConsumer_) {
        receiveConsumer_->BeginReceiveBatch(receiveBatch);
    }

    return rxRing_.DrainCompleted(
        *dmaMemory_,
        [this, drainHostTicks, drainCycleTimer, receiveBatch](
            const Rx::IsochRxDmaRing::CompletedPacket& pkt) {
        uint64_t callbackTimestamp = 0;
        if (receiveConsumer_) {
            receiveConsumer_->ConsumePacket(
                receiveBatch,
                IsochReceivePacket{
                    .descriptorIndex = pkt.descriptorIndex,
                    .transferStatus = pkt.xferStatus,
                    .residualCount = pkt.resCount,
                    .payload = pkt.payload
                        ? std::span<const uint8_t>(pkt.payload, pkt.actualLength)
                        : std::span<const uint8_t>{},
                });
        }
        if (callback_) {
            const auto span = std::span<const uint8_t>(pkt.payload, pkt.actualLength);
            callback_(span,
                      static_cast<uint32_t>(pkt.xferStatus),
                      callbackTimestamp);
        }
    }, recycle);
}

void IsochReceiveContext::SetCallback(IsochReceiveCallback callback) {
    while (rxLock_.test_and_set(std::memory_order_acquire)) {}
    callback_ = callback;
    rxLock_.clear(std::memory_order_release);
}

void IsochReceiveContext::SetReceiveConsumer(
    IIsochReceiveConsumer* consumer) noexcept {
    while (rxLock_.test_and_set(std::memory_order_acquire)) {}
    receiveConsumer_ = consumer;
    rxLock_.clear(std::memory_order_release);
}

void IsochReceiveContext::LogHardwareState() {
}

void IsochReceiveContext::DrainZtsTelemetry(uint32_t maxRecords) {
    if (rxLock_.test_and_set(std::memory_order_acquire)) return;
    if (GetState() == IRPolicy::State::Running && receiveConsumer_)
        receiveConsumer_->DrainReceiveTelemetry(maxRecords);
    rxLock_.clear(std::memory_order_release);
}

void IsochReceiveContext::DrainPayloadWriterTelemetry() {
    if (rxLock_.test_and_set(std::memory_order_acquire)) return;
    if (GetState() == IRPolicy::State::Running && receiveConsumer_)
        receiveConsumer_->DrainPayloadTelemetry();
    rxLock_.clear(std::memory_order_release);
}

void IsochReceiveContext::LogTxSytTrace() {
    if (rxLock_.test_and_set(std::memory_order_acquire)) return;
    if (GetState() == IRPolicy::State::Running && receiveConsumer_)
        receiveConsumer_->LogTransmitTimingTrace();
    rxLock_.clear(std::memory_order_release);
}

} // namespace ASFW::Isoch
