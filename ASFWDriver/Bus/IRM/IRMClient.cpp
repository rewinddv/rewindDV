// Modified by Rewind Digital: selective ASFireWire 3ad56c1b hardening;
// ambiguous mutating locks remain fail-closed. See Foundation/NOTICE.md.
#include "IRMClient.hpp"
#include "../../Common/CallbackUtils.hpp"
#include "../../Logging/Logging.hpp"
#include "IRMCSRConstants.hpp"
#ifdef ASFW_HOST_TEST
#include "../../Testing/HostDriverKitStubs.hpp"
#endif
#include <DriverKit/IOLib.h>
#include <array>
#include <cstring>
#include <optional>
#include <utility>

namespace ASFW::IRM {

namespace {

[[nodiscard]] std::optional<uint32_t> LocalIRMSelectorForAddress(uint32_t addressLo) noexcept {
    using namespace ASFW::Driver::IRMCSR;
    constexpr uint32_t kCSRRegisterSpaceBaseLo = 0xF0000000u;

    switch (addressLo) {
    case kCSRRegisterSpaceBaseLo + kCSRBusManagerIdOffset:
        return static_cast<uint32_t>(CSRSelector::BusManagerId);
    case IRMRegisters::kBandwidthAvailable:
        return static_cast<uint32_t>(CSRSelector::BandwidthAvailable);
    case IRMRegisters::kChannelsAvailable31_0:
        return static_cast<uint32_t>(CSRSelector::ChannelsAvailableHi);
    case IRMRegisters::kChannelsAvailable63_32:
        return static_cast<uint32_t>(CSRSelector::ChannelsAvailableLo);
    default:
        return std::nullopt;
    }
}

[[nodiscard]] const char* LocalIRMSelectorName(uint32_t selector) noexcept {
    using namespace ASFW::Driver::IRMCSR;

    switch (static_cast<CSRSelector>(selector & 0x3u)) {
    case CSRSelector::BusManagerId:
        return "BUS_MANAGER_ID";
    case CSRSelector::BandwidthAvailable:
        return "BANDWIDTH_AVAILABLE";
    case CSRSelector::ChannelsAvailableHi:
        return "CHANNELS_AVAILABLE_31_0";
    case CSRSelector::ChannelsAvailableLo:
        return "CHANNELS_AVAILABLE_63_32";
    }
    return "UNKNOWN";
}

[[nodiscard]] const char* LocalCSRStatusName(
    Driver::LocalCSRLockResult::Status status) noexcept {
    switch (status) {
    case Driver::LocalCSRLockResult::Status::Success:
        return "success";
    case Driver::LocalCSRLockResult::Status::Timeout:
        return "timeout";
    case Driver::LocalCSRLockResult::Status::HardwareUnavailable:
        return "hardware_unavailable";
    }
    return "unknown";
}

} // namespace

struct IRMClient::ChannelLockState {
    AllocationCallback userCallback;
    uint8_t channel{0};
    uint32_t addressLo{0};
    uint32_t bitMask{0};
    bool allocate{false};
    uint8_t retriesLeft{0};
    Generation expectedGeneration{0};
    uint64_t routeEpoch{0};
    uint8_t readTimeoutRetriesLeft{0};
    std::shared_ptr<ResourceOperationEvidence> evidence;
};

struct IRMClient::BandwidthLockState {
    AllocationCallback userCallback;
    uint32_t units{0};
    bool allocate{false};
    uint8_t retriesLeft{0};
    Generation expectedGeneration{0};
    uint32_t releaseCeiling{kMaxBandwidthUnitsS400};
    uint64_t routeEpoch{0};
    uint8_t readTimeoutRetriesLeft{0};
    std::shared_ptr<ResourceOperationEvidence> evidence;
};

// ============================================================================
// Constructor / Destructor
// ============================================================================

IRMClient::IRMClient(Async::IFireWireBus& bus, LocalIRMAccess localIRMAccess)
    : bus_(bus)
    , localIRMAccess_(std::move(localIRMAccess))
{
}

IRMClient::~IRMClient() = default;

bool IRMClient::RouteIsCurrent(Generation expected, uint64_t epoch) const {
    return generation_ == expected && routeEpoch_ == epoch &&
           bus_.GetGeneration() == FW::Generation{expected.value};
}

AllocationStatus IRMClient::MapAsyncStatus(const Async::AsyncStatus status) noexcept {
    switch (status) {
    case Async::AsyncStatus::kSuccess:
        return AllocationStatus::Success;
    case Async::AsyncStatus::kStaleGeneration:
        return AllocationStatus::GenerationMismatch;
    case Async::AsyncStatus::kTimeout:
        return AllocationStatus::Timeout;
    case Async::AsyncStatus::kBusyRetryExhausted:
    case Async::AsyncStatus::kAborted:
    case Async::AsyncStatus::kHardwareError:
    case Async::AsyncStatus::kLockCompareFail:
    case Async::AsyncStatus::kShortRead:
        return AllocationStatus::Failed;
    }
    return AllocationStatus::Failed;
}

AllocationStatus IRMClient::MapLocalCSRStatus(
    const Driver::LocalCSRLockResult::Status status) noexcept {
    switch (status) {
    case Driver::LocalCSRLockResult::Status::Success:
        return AllocationStatus::Success;
    case Driver::LocalCSRLockResult::Status::Timeout:
        return AllocationStatus::Timeout;
    case Driver::LocalCSRLockResult::Status::HardwareUnavailable:
        return AllocationStatus::Failed;
    }
    return AllocationStatus::Failed;
}

uint64_t IRMClient::CurrentMonotonicNowNs() noexcept {
#ifdef ASFW_HOST_TEST
    return ASFW::Testing::HostMonotonicNow();
#else
    static mach_timebase_info_data_t timebase{};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    const uint64_t ticks = mach_absolute_time();
    return (ticks * timebase.numer) / timebase.denom;
#endif
}

bool IRMClient::IsLocalIRMNode() const noexcept {
    if (irmNodeId_ == 0xFF) {
        return false;
    }

    const auto localNodeId = bus_.GetLocalNodeID();
    return (irmNodeId_ & 0x3Fu) == (localNodeId.value & 0x3Fu);
}

void IRMClient::DelayForPostResetQuietPeriod() const {
    constexpr uint64_t kQuietPeriodNs = 1'000'000'000ULL;

    if (lastBusResetNs_ == 0) {
        return;
    }

    const uint64_t nowNs = CurrentMonotonicNowNs();
    if (nowNs <= lastBusResetNs_) {
        return;
    }

    const uint64_t elapsedNs = nowNs - lastBusResetNs_;
    if (elapsedNs >= kQuietPeriodNs) {
        return;
    }

    const uint64_t remainingMs = (kQuietPeriodNs - elapsedNs + 999'999ULL) / 1'000'000ULL;
    ASFW_LOG(IRM, "IRMClient: waiting %llums for post-reset quiet period", remainingMs);
    IOSleep(static_cast<unsigned int>(remainingMs));
}

void IRMClient::ReadIRMQuadlet(
    uint32_t addressLo,
    std::function<void(AllocationStatus status, uint32_t value)> callback,
    Generation expectedGeneration)
{
    const uint64_t epoch = routeEpoch_;
    if (!RouteIsCurrent(expectedGeneration, epoch)) {
        callback(AllocationStatus::GenerationMismatch, 0u);
        return;
    }
    if (IsLocalIRMNode()) {
        const auto selector = LocalIRMSelectorForAddress(addressLo);
        if (selector.has_value()) {
            if (bus_.GetGeneration() != FW::Generation{generation_.value}) {
                callback(AllocationStatus::GenerationMismatch, 0u);
                return;
            }

            if (!localIRMAccess_.read) {
                ASFW_LOG_ERROR(IRM,
                               "ReadIRMQuadlet: local IRM addr=0x%08x but no local CSR backend",
                               addressLo);
                callback(AllocationStatus::Failed, 0u);
                return;
            }

            const auto result = localIRMAccess_.read(*selector);
            const AllocationStatus mapped = MapLocalCSRStatus(result.status);
            ASFW_LOG(IRM,
                     "IRMClient: local CSR read %{public}s selector=%u addr=0x%08x "
                     "status=%{public}s mapped=%{public}s value=0x%08x",
                     LocalIRMSelectorName(*selector),
                     *selector,
                     addressLo,
                     LocalCSRStatusName(result.status),
                     ToString(mapped),
                     result.value);
            callback(RouteIsCurrent(expectedGeneration, epoch) ? mapped
                     : AllocationStatus::GenerationMismatch, result.value);
            return;
        }
    }

    auto callbackState = Common::ShareCallback(std::move(callback));
    Async::FWAddress addr{.nodeID = 0,
        .addressHi = IRMRegisters::kAddressHi,
        .addressLo = addressLo};

    FW::FwSpeed speed{0};
    FW::NodeId node{irmNodeId_};
    FW::Generation gen{expectedGeneration};

    const auto handle = bus_.ReadQuad(gen, node, addr, speed,
        [this, callbackState, expectedGeneration, epoch](Async::AsyncStatus status, std::span<const uint8_t> payload) {
            if (!RouteIsCurrent(expectedGeneration, epoch)) {
                Common::InvokeSharedCallback(callbackState, AllocationStatus::GenerationMismatch, 0u);
                return;
            }
            const AllocationStatus mapped = IRMClient::MapAsyncStatus(status);
            if (mapped != AllocationStatus::Success) {
                Common::InvokeSharedCallback(callbackState, mapped, 0u);
                return;
            }

            if (payload.size() != 4) {
                Common::InvokeSharedCallback(callbackState, AllocationStatus::Failed, 0u);
                return;
            }

            uint32_t raw = 0;
            std::memcpy(&raw, payload.data(), sizeof(raw));
            const uint32_t hostValue = OSSwapBigToHostInt32(raw);
            Common::InvokeSharedCallback(callbackState, AllocationStatus::Success, hostValue);
        });
    if (!handle) {
        Common::InvokeSharedCallback(callbackState,
            RouteIsCurrent(expectedGeneration, epoch) ? AllocationStatus::Failed
                                                     : AllocationStatus::GenerationMismatch, 0u);
    }
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
void IRMClient::CompareSwapIRMQuadlet(
    uint32_t addressLo, // NOLINT(bugprone-easily-swappable-parameters)
    uint32_t expected,
    uint32_t desired,
    std::function<void(AllocationStatus status, uint32_t oldValue)> callback,
    Generation expectedGeneration)
{
    const uint64_t epoch = routeEpoch_;
    if (!RouteIsCurrent(expectedGeneration, epoch)) {
        callback(AllocationStatus::GenerationMismatch, 0u);
        return;
    }
    if (IsLocalIRMNode()) {
        const auto selector = LocalIRMSelectorForAddress(addressLo);
        if (selector.has_value()) {
            if (bus_.GetGeneration() != FW::Generation{generation_.value}) {
                callback(AllocationStatus::GenerationMismatch, 0u);
                return;
            }

            if (!localIRMAccess_.compareSwap) {
                ASFW_LOG_ERROR(IRM,
                               "CompareSwapIRMQuadlet: local IRM addr=0x%08x but no local CSR backend",
                               addressLo);
                callback(AllocationStatus::Failed, 0u);
                return;
            }

            const auto result = localIRMAccess_.compareSwap(*selector, expected, desired);
            const AllocationStatus mapped = MapLocalCSRStatus(result.status);
            ASFW_LOG(IRM,
                     "IRMClient: local CSR CAS %{public}s selector=%u addr=0x%08x "
                     "expected=0x%08x desired=0x%08x status=%{public}s "
                     "mapped=%{public}s old=0x%08x matched=%u",
                     LocalIRMSelectorName(*selector),
                     *selector,
                     addressLo,
                     expected,
                     desired,
                     LocalCSRStatusName(result.status),
                     ToString(mapped),
                     result.oldValue,
                     result.compareMatched ? 1u : 0u);
            callback(RouteIsCurrent(expectedGeneration, epoch) ? mapped
                     : AllocationStatus::GenerationMismatch, result.oldValue);
            return;
        }
    }

    auto callbackState = Common::ShareCallback(std::move(callback));
    Async::FWAddress addr{.nodeID = 0,
        .addressHi = IRMRegisters::kAddressHi,
        .addressLo = addressLo};

    FW::FwSpeed speed{0};
    FW::NodeId node{irmNodeId_};
    FW::Generation gen{expectedGeneration};

    std::array<uint8_t, 8> operand;
    uint32_t expectedBE = OSSwapHostToBigInt32(expected);
    uint32_t desiredBE = OSSwapHostToBigInt32(desired);
    std::memcpy(&operand[0], &expectedBE, 4);
    std::memcpy(&operand[4], &desiredBE, 4);

    const auto handle = bus_.Lock(gen, node, addr, FW::LockOp::kCompareSwap,
        std::span{operand}, 4, speed,
        [this, callbackState, expectedGeneration, epoch](Async::AsyncStatus status, std::span<const uint8_t> payload) {
            if (!RouteIsCurrent(expectedGeneration, epoch)) {
                Common::InvokeSharedCallback(callbackState, AllocationStatus::GenerationMismatch, 0u);
                return;
            }
            const AllocationStatus mapped = IRMClient::MapAsyncStatus(status);
            if (mapped != AllocationStatus::Success) {
                Common::InvokeSharedCallback(callbackState, mapped, 0u);
                return;
            }

            if (payload.size() != 4) {
                Common::InvokeSharedCallback(callbackState, AllocationStatus::Failed, 0u);
                return;
            }

            uint32_t raw = 0;
            std::memcpy(&raw, payload.data(), sizeof(raw));
            const uint32_t oldValue = OSSwapBigToHostInt32(raw);
            Common::InvokeSharedCallback(callbackState, AllocationStatus::Success, oldValue);
        });
    if (!handle) {
        Common::InvokeSharedCallback(callbackState,
            RouteIsCurrent(expectedGeneration, epoch) ? AllocationStatus::Failed
                                                     : AllocationStatus::GenerationMismatch, 0u);
    }
}

void IRMClient::ReadIRMWindow(ResourceSnapshotCallback callback)
{
    if (irmNodeId_ == 0xFF) {
        callback(AllocationStatus::NotFound, {});
        return;
    }

    auto callbackState = Common::ShareCallback(std::move(callback));
    auto snapshot = std::make_shared<ResourceSnapshot>();
    const Generation expectedGeneration = generation_;
    const uint64_t epoch = routeEpoch_;

    ReadIRMQuadlet(IRMRegisters::kBandwidthAvailable,
        [this, callbackState, snapshot, expectedGeneration, epoch](AllocationStatus status, uint32_t bandwidthAvailable) {
            if (!RouteIsCurrent(expectedGeneration, epoch)) status = AllocationStatus::GenerationMismatch;
            if (status != AllocationStatus::Success) {
                Common::InvokeSharedCallback(callbackState, status, ResourceSnapshot{});
                return;
            }

            snapshot->bandwidthAvailable = bandwidthAvailable;
            ReadIRMQuadlet(IRMRegisters::kChannelsAvailable31_0,
                [this, callbackState, snapshot, expectedGeneration, epoch](AllocationStatus status, uint32_t channelsAvailable31_0) {
                    if (!RouteIsCurrent(expectedGeneration, epoch)) status = AllocationStatus::GenerationMismatch;
                    if (status != AllocationStatus::Success) {
                        Common::InvokeSharedCallback(callbackState, status, ResourceSnapshot{});
                        return;
                    }

                    snapshot->channelsAvailable31_0 = channelsAvailable31_0;
                    ReadIRMQuadlet(IRMRegisters::kChannelsAvailable63_32,
                        [this, callbackState, snapshot, expectedGeneration, epoch](AllocationStatus status, uint32_t channelsAvailable63_32) {
                            if (!RouteIsCurrent(expectedGeneration, epoch)) status = AllocationStatus::GenerationMismatch;
                            if (status != AllocationStatus::Success) {
                                Common::InvokeSharedCallback(callbackState, status, ResourceSnapshot{});
                                return;
                            }

                            snapshot->channelsAvailable63_32 = channelsAvailable63_32;
                            Common::InvokeSharedCallback(callbackState, AllocationStatus::Success, *snapshot);
                        }, expectedGeneration);
                }, expectedGeneration);
        }, expectedGeneration);
}

void IRMClient::SetIRMNode(uint8_t irmNodeId, Generation generation, uint64_t lastBusResetNs) {
    if (irmNodeId_ != irmNodeId || generation_ != generation ||
        (lastBusResetNs != 0 && lastBusResetNs_ != lastBusResetNs)) {
        ++routeEpoch_;
    }
    irmNodeId_ = irmNodeId;
    generation_ = generation;
    lastBusResetNs_ = lastBusResetNs;

    ASFW_LOG(IRM, "IRMClient: Set IRM node=%u generation=%u resetNs=%llu",
             irmNodeId, generation.value, lastBusResetNs);
}

void IRMClient::AllocateChannel(uint8_t channel,
                                 AllocationCallback callback,
                                 const RetryPolicy& retryPolicy)
{
    if (channel >= 64) {
        ASFW_LOG_ERROR(IRM, "AllocateChannel: Invalid channel %u", channel);
        callback(AllocationStatus::Failed);
        return;
    }

    if (irmNodeId_ == 0xFF) {
        ASFW_LOG_ERROR(IRM, "AllocateChannel: No IRM node on bus");
        callback(AllocationStatus::NotFound);
        return;
    }

    PerformChannelLock(channel, true, callback, retryPolicy, generation_);
}

void IRMClient::ReleaseChannel(uint8_t channel,
                                AllocationCallback callback,
                                const RetryPolicy& retryPolicy)
{
    if (channel >= 64) {
        ASFW_LOG_ERROR(IRM, "ReleaseChannel: Invalid channel %u", channel);
        callback(AllocationStatus::Failed);
        return;
    }

    if (irmNodeId_ == 0xFF) {
        ASFW_LOG_ERROR(IRM, "ReleaseChannel: No IRM node on bus");
        callback(AllocationStatus::NotFound);
        return;
    }

    PerformChannelLock(channel, false, callback, retryPolicy, generation_);
}

void IRMClient::AllocateBandwidth(uint32_t units,
                                   AllocationCallback callback,
                                   const RetryPolicy& retryPolicy)
{
    if (units == 0) {
        callback(AllocationStatus::Success);
        return;
    }

    if (irmNodeId_ == 0xFF) {
        ASFW_LOG_ERROR(IRM, "AllocateBandwidth: No IRM node on bus");
        callback(AllocationStatus::NotFound);
        return;
    }

    PerformBandwidthLock(units, true, callback, retryPolicy, generation_);
}

void IRMClient::ReleaseBandwidth(uint32_t units,
                                  AllocationCallback callback,
                                  const RetryPolicy& retryPolicy)
{
    if (units == 0) {
        callback(AllocationStatus::Success);
        return;
    }

    if (irmNodeId_ == 0xFF) {
        ASFW_LOG_ERROR(IRM, "ReleaseBandwidth: No IRM node on bus");
        callback(AllocationStatus::NotFound);
        return;
    }

    PerformBandwidthLock(units, false, callback, retryPolicy, generation_);
}

void IRMClient::AllocateResources(uint8_t channel,
                                   uint32_t bandwidthUnits,
                                   AllocationCallback callback,
                                   const RetryPolicy& retryPolicy)
{
    AllocateResourcesForGeneration(channel, bandwidthUnits, generation_,
        [callback = std::move(callback)](AllocationStatus status, ResourceOwnership) mutable {
            callback(status);
        }, retryPolicy);
}

void IRMClient::AllocateResourcesForGeneration(uint8_t channel,
                                   uint32_t bandwidthUnits,
                                   Generation expectedGeneration,
                                   ResourceOperationCallback callback,
                                   const RetryPolicy& retryPolicy)
{
    AllocateResourcesDetailedForGeneration(
        channel, bandwidthUnits, expectedGeneration,
        [callback = std::move(callback)](AllocationStatus status,
                                         ResourceOwnership ownership,
                                         ResourceOperationEvidence) mutable {
            callback(status, ownership);
        },
        retryPolicy);
}

void IRMClient::AllocateResourcesDetailedForGeneration(
    uint8_t channel, uint32_t bandwidthUnits, Generation expectedGeneration,
    DetailedResourceOperationCallback callback, const RetryPolicy& retryPolicy)
{
    auto callbackState = Common::ShareCallback(std::move(callback));
    auto evidence = std::make_shared<ResourceOperationEvidence>();
    evidence->channel = channel;
    evidence->requestedBandwidthUnits = bandwidthUnits;
    const uint64_t epoch = routeEpoch_;

    if (channel >= 64) {
        evidence->cause = ResourceFailureCause::InvalidRequest;
        Common::InvokeSharedCallback(callbackState, AllocationStatus::Failed,
                                     ResourceOwnership::None, *evidence);
        return;
    }
    if (irmNodeId_ == 0xFF) {
        evidence->cause = ResourceFailureCause::IRMUnavailable;
        Common::InvokeSharedCallback(callbackState, AllocationStatus::NotFound,
                                     ResourceOwnership::None, *evidence);
        return;
    }
    if (!RouteIsCurrent(expectedGeneration, epoch)) {
        evidence->cause = ResourceFailureCause::RouteInvalidated;
        Common::InvokeSharedCallback(callbackState, AllocationStatus::GenerationMismatch,
                                     ResourceOwnership::None, *evidence);
        return;
    }

    DelayForPostResetQuietPeriod();
    if (!RouteIsCurrent(expectedGeneration, epoch)) {
        evidence->cause = ResourceFailureCause::RouteInvalidated;
        Common::InvokeSharedCallback(callbackState, AllocationStatus::GenerationMismatch,
                                     ResourceOwnership::None, *evidence);
        return;
    }

    PerformChannelLock(channel, true,
        [this, callbackState, evidence, channel, bandwidthUnits, expectedGeneration, epoch, retryPolicy](AllocationStatus channelStatus) mutable {
            if (!RouteIsCurrent(expectedGeneration, epoch)) {
                channelStatus = AllocationStatus::GenerationMismatch;
                evidence->cause = ResourceFailureCause::RouteInvalidated;
                evidence->failureStage = evidence->terminalStage;
            }
            if (channelStatus != AllocationStatus::Success) {
                const auto ownership = channelStatus == AllocationStatus::Timeout ||
                                               channelStatus == AllocationStatus::Failed
                                           ? ResourceOwnership::Uncertain
                                           : ResourceOwnership::None;
                Common::InvokeSharedCallback(callbackState, channelStatus, ownership, *evidence);
                return;
            }
            PerformBandwidthLock(bandwidthUnits, true,
                [this, callbackState, evidence, channel, expectedGeneration, epoch, retryPolicy](AllocationStatus bandwidthStatus) mutable {
                    if (!RouteIsCurrent(expectedGeneration, epoch)) {
                        bandwidthStatus = AllocationStatus::GenerationMismatch;
                        evidence->cause = ResourceFailureCause::RouteInvalidated;
                        evidence->failureStage = evidence->terminalStage;
                    }
                    if (bandwidthStatus == AllocationStatus::Success) {
                        evidence->terminalStage = ResourceOperationStage::Complete;
                        Common::InvokeSharedCallback(callbackState, AllocationStatus::Success,
                                                     ResourceOwnership::Owned, *evidence);
                        return;
                    }

                    if (bandwidthStatus == AllocationStatus::GenerationMismatch) {
                        Common::InvokeSharedCallback(callbackState, bandwidthStatus,
                                                     ResourceOwnership::None, *evidence);
                        return;
                    }
                    if (bandwidthStatus == AllocationStatus::Timeout ||
                        bandwidthStatus == AllocationStatus::Failed) {
                        Common::InvokeSharedCallback(callbackState, bandwidthStatus,
                                                     ResourceOwnership::Uncertain, *evidence);
                        return;
                    }
                    auto rollbackEvidence = std::make_shared<ResourceOperationEvidence>();
                    rollbackEvidence->channel = channel;
                    rollbackEvidence->requestedBandwidthUnits =
                        evidence->requestedBandwidthUnits;
                    PerformChannelLock(channel, false,
                        [this, callbackState, evidence, rollbackEvidence, bandwidthStatus, expectedGeneration, epoch](AllocationStatus releaseStatus) mutable {
                            if (releaseStatus == AllocationStatus::GenerationMismatch ||
                                !RouteIsCurrent(expectedGeneration, epoch)) {
                                evidence->cleanupCause = ResourceFailureCause::RouteInvalidated;
                                evidence->terminalStage = ResourceOperationStage::ChannelRollback;
                                Common::InvokeSharedCallback(callbackState, AllocationStatus::GenerationMismatch,
                                                             ResourceOwnership::None, *evidence);
                                return;
                            }
                            if (releaseStatus != AllocationStatus::Success) {
                                ASFW_LOG_ERROR(IRM,
                                               "AllocateResources: rollback release channel failed "
                                               "status=%{public}s original=%{public}s",
                                               ToString(releaseStatus),
                                               ToString(bandwidthStatus));
                                evidence->cleanupCause = ResourceFailureCause::RollbackFailed;
                            }
                            evidence->terminalStage = ResourceOperationStage::ChannelRollback;
                            Common::InvokeSharedCallback(
                                callbackState, bandwidthStatus,
                                releaseStatus == AllocationStatus::Success
                                    ? ResourceOwnership::None
                                    : ResourceOwnership::Uncertain,
                                *evidence);
                        },
                        retryPolicy, expectedGeneration, rollbackEvidence);
                },
                retryPolicy, expectedGeneration, kMaxBandwidthUnitsS400, evidence);
        },
        retryPolicy, expectedGeneration, evidence);
}

void IRMClient::ReadResourcesSnapshot(ResourceSnapshotCallback callback)
{
    ReadIRMWindow(std::move(callback));
}

void IRMClient::CompareSwapBandwidth(uint32_t expected,
                                     uint32_t desired,
                                     CompareSwapCallback callback)
{
    auto callbackState = Common::ShareCallback(std::move(callback));
    CompareSwapIRMQuadlet(IRMRegisters::kBandwidthAvailable,
                          expected,
                          desired,
                          [callbackState, expected](AllocationStatus status, uint32_t oldValue) {
                              if (status != AllocationStatus::Success) {
                                  Common::InvokeSharedCallback(callbackState, status, uint32_t{0});
                                  return;
                              }

                              const auto result =
                                  (oldValue == expected) ? AllocationStatus::Success
                                                         : AllocationStatus::NoResources;
                              Common::InvokeSharedCallback(callbackState, result, oldValue);
                          }, generation_);
}

void IRMClient::CompareSwapChannel(uint8_t channel,
                                   uint32_t expected,
                                   uint32_t desired,
                                   CompareSwapCallback callback)
{
    auto callbackState = Common::ShareCallback(std::move(callback));
    CompareSwapIRMQuadlet(ChannelToRegisterAddress(channel),
                          expected,
                          desired,
                          [callbackState, expected](AllocationStatus status, uint32_t oldValue) {
                              if (status != AllocationStatus::Success) {
                                  Common::InvokeSharedCallback(callbackState, status, uint32_t{0});
                                  return;
                              }

                              const auto result =
                                  (oldValue == expected) ? AllocationStatus::Success
                                                         : AllocationStatus::NoResources;
                              Common::InvokeSharedCallback(callbackState, result, oldValue);
                          }, generation_);
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
void IRMClient::ReleaseResources(uint8_t channel,
                                 uint32_t bandwidthUnits,
                                 AllocationCallback callback,
                                 const RetryPolicy& retryPolicy)
{
    ReleaseResourcesForGeneration(channel, bandwidthUnits, kMaxBandwidthUnitsS400, generation_,
        [callback = std::move(callback)](AllocationStatus status, ResourceOwnership) mutable {
            callback(status);
        }, retryPolicy);
}

void IRMClient::ReleaseResourcesForGeneration(uint8_t channel,
                                 uint32_t bandwidthUnits,
                                 uint32_t bandwidthCeiling,
                                 Generation expectedGeneration,
                                 ResourceOperationCallback callback,
                                 const RetryPolicy& retryPolicy)
{
    const uint64_t epoch = routeEpoch_;
    if (!RouteIsCurrent(expectedGeneration, epoch)) {
        callback(AllocationStatus::GenerationMismatch, ResourceOwnership::None);
        return;
    }
    if (channel >= 64 || irmNodeId_ == 0xFF ||
        bandwidthCeiling > kBandwidthAvailableValueMask ||
        bandwidthUnits > bandwidthCeiling) {
        callback(AllocationStatus::Failed, ResourceOwnership::Uncertain);
        return;
    }
    PerformBandwidthLock(bandwidthUnits, false,
        [this, channel, expectedGeneration, epoch, callback = std::move(callback), retryPolicy](AllocationStatus bandwidthStatus) mutable {
            if (bandwidthStatus == AllocationStatus::GenerationMismatch ||
                !RouteIsCurrent(expectedGeneration, epoch)) {
                callback(AllocationStatus::GenerationMismatch, ResourceOwnership::None);
                return;
            }
            // Derived from ASFireWire 3ad56c1b: a bandwidth failure must not
            // strand the channel. Keep the first error and uncertain ownership.
            PerformChannelLock(channel, false,
                [callback = std::move(callback), bandwidthStatus](AllocationStatus channelStatus) mutable {
                    const auto result = channelStatus == AllocationStatus::GenerationMismatch ||
                                                bandwidthStatus == AllocationStatus::Success
                                            ? channelStatus : bandwidthStatus;
                    callback(result, ReleaseOwnershipAfter(result));
                },
                retryPolicy, expectedGeneration);
        },
        retryPolicy, expectedGeneration, bandwidthCeiling);
}

void IRMClient::PerformChannelLock(uint8_t channel, bool allocate,
                                    AllocationCallback callback,
                                    const RetryPolicy& retryPolicy,
                                    Generation expectedGeneration,
                                    std::shared_ptr<ResourceOperationEvidence> evidence)
{
    const uint32_t addressLo = ChannelToRegisterAddress(channel);
    const uint32_t bitMask = ChannelToBitMask(channel);

    ASFW_LOG(IRM, "%{public}s channel %u (addr=0x%08x bit=0x%08x)",
             allocate ? "Allocating" : "Releasing",
             channel, addressLo, bitMask);

    auto ctx = std::make_shared<ChannelLockState>(ChannelLockState{
        std::move(callback),
        channel,
        addressLo,
        bitMask,
        allocate,
        retryPolicy.maxRetries,
        expectedGeneration,
        routeEpoch_,
        retryPolicy.maxReadTimeoutRetries,
        std::move(evidence)
    });

    StartChannelLock(ctx);
}

void IRMClient::PerformBandwidthLock(uint32_t units, bool allocate,
                                      AllocationCallback callback,
                                      const RetryPolicy& retryPolicy,
                                      Generation expectedGeneration,
                                      uint32_t releaseCeiling,
                                      std::shared_ptr<ResourceOperationEvidence> evidence)
{
    ASFW_LOG(IRM, "%{public}s bandwidth %u units",
             allocate ? "Allocating" : "Releasing", units);

    auto ctx = std::make_shared<BandwidthLockState>(BandwidthLockState{
        std::move(callback),
        units,
        allocate,
        retryPolicy.maxRetries,
        expectedGeneration,
        releaseCeiling,
        routeEpoch_,
        retryPolicy.maxReadTimeoutRetries,
        std::move(evidence)
    });

    StartBandwidthLock(ctx);
}

void IRMClient::StartChannelLock(const std::shared_ptr<ChannelLockState>& ctx) {
    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::ChannelRead;
        ctx->evidence->compareExpected = 0;
        ctx->evidence->compareDesired = 0;
        ctx->evidence->compareObserved = 0;
        ctx->evidence->compareStage = ResourceOperationStage::Admission;
        ctx->evidence->validFields = static_cast<uint8_t>(
            ctx->evidence->validFields &
            ~(kCompareProposalValid | kCompareResponseValid));
    }
    if (!RouteIsCurrent(ctx->expectedGeneration, ctx->routeEpoch)) {
        if (ctx->evidence) {
            ctx->evidence->cause = ResourceFailureCause::RouteInvalidated;
            ctx->evidence->failureStage = ResourceOperationStage::ChannelRead;
            ctx->evidence->terminalStage = ResourceOperationStage::ChannelRead;
        }
        ctx->userCallback(AllocationStatus::GenerationMismatch);
        return;
    }
    ReadIRMQuadlet(ctx->addressLo, [this, ctx](AllocationStatus status, uint32_t currentValue) {
        if (status == AllocationStatus::Timeout && ctx->readTimeoutRetriesLeft > 0) {
            --ctx->readTimeoutRetriesLeft;
            ASFW_LOG(IRM, "Channel read timeout; bounded retry remaining=%u", ctx->readTimeoutRetriesLeft);
            StartChannelLock(ctx);
            return;
        }
        if (status != AllocationStatus::Success) {
            if (ctx->evidence) {
                ctx->evidence->cause = status == AllocationStatus::GenerationMismatch
                                           ? ResourceFailureCause::RouteInvalidated
                                           : ResourceFailureCause::TransportFailure;
                ctx->evidence->failureStage = ResourceOperationStage::ChannelRead;
                ctx->evidence->terminalStage = ResourceOperationStage::ChannelRead;
            }
            ctx->userCallback(status);
            return;
        }

        OnChannelRead(ctx, true, currentValue);
    }, ctx->expectedGeneration);
}

void IRMClient::OnChannelRead(const std::shared_ptr<ChannelLockState>& ctx,
                              const bool success,
                              const uint32_t currentValue) {
    if (!success) {
        ASFW_LOG_ERROR(IRM, "Channel read failed");
        ctx->userCallback(AllocationStatus::Failed);
        return;
    }

    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::ChannelRead;
        ctx->evidence->observedChannelRegister = currentValue;
        ctx->evidence->validFields |= kObservedChannelRegisterValid;
    }

    uint32_t newValue = currentValue | ctx->bitMask;
    if (ctx->allocate) {
        if ((currentValue & ctx->bitMask) == 0) {
            ASFW_LOG(IRM, "Channel %u not available (current=0x%08x mask=0x%08x)",
                     ctx->channel, currentValue, ctx->bitMask);
            if (ctx->evidence) {
                ctx->evidence->cause = ResourceFailureCause::ChannelOccupied;
                ctx->evidence->failureStage = ResourceOperationStage::ChannelRead;
            }
            ctx->userCallback(AllocationStatus::NoResources);
            return;
        }
        newValue = currentValue & ~ctx->bitMask;
    }

    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::ChannelCompareSwap;
        ctx->evidence->compareExpected = currentValue;
        ctx->evidence->compareDesired = newValue;
        ctx->evidence->compareObserved = 0;
        ctx->evidence->compareStage = ResourceOperationStage::ChannelCompareSwap;
        ctx->evidence->validFields = static_cast<uint8_t>(
            (ctx->evidence->validFields | kCompareProposalValid) &
            ~kCompareResponseValid);
    }

    CompareSwapIRMQuadlet(ctx->addressLo, currentValue, newValue,
                          [this, ctx, currentValue](AllocationStatus status, uint32_t oldValue) {
                              if (status != AllocationStatus::Success) {
                                  if (ctx->evidence) {
                                      ctx->evidence->cause =
                                          status == AllocationStatus::GenerationMismatch
                                              ? ResourceFailureCause::RouteInvalidated
                                              : ResourceFailureCause::TransportUncertain;
                                      ctx->evidence->failureStage =
                                          ResourceOperationStage::ChannelCompareSwap;
                                  }
                                  ctx->userCallback(status);
                                  return;
                              }
                              OnChannelCompareSwap(ctx, currentValue, true, oldValue);
                          }, ctx->expectedGeneration);
}

void IRMClient::OnChannelCompareSwap(const std::shared_ptr<ChannelLockState>& ctx,
                                     const uint32_t expectedValue,
                                     const bool success,
                                     const uint32_t oldValue) {
    if (!success) {
        ASFW_LOG_ERROR(IRM, "Channel lock operation failed");
        ctx->userCallback(AllocationStatus::Failed);
        return;
    }

    if (oldValue == expectedValue) {
        if (ctx->evidence) {
            ctx->evidence->compareObserved = oldValue;
            ctx->evidence->validFields |= kCompareResponseValid;
        }
        ASFW_LOG(IRM, "Channel %u %{public}s succeeded",
                 ctx->channel,
                 ctx->allocate ? "allocation" : "release");
        ctx->userCallback(AllocationStatus::Success);
        return;
    }

    if (ctx->evidence) {
        ctx->evidence->compareObserved = oldValue;
        ctx->evidence->validFields |= kCompareResponseValid;
    }

    ASFW_LOG(IRM, "Channel lock contention (expected=0x%08x actual=0x%08x retries=%u)",
             expectedValue, oldValue, ctx->retriesLeft);
    if (ctx->retriesLeft == 0) {
        ASFW_LOG(IRM, "Channel lock exhausted retries");
        if (ctx->evidence) {
            ctx->evidence->cause = ResourceFailureCause::ContentionExhausted;
            ctx->evidence->failureStage = ResourceOperationStage::ChannelCompareSwap;
        }
        ctx->userCallback(AllocationStatus::NoResources);
        return;
    }

    if (ctx->evidence && ctx->evidence->contentionRetriesUsed != UINT8_MAX) {
        ++ctx->evidence->contentionRetriesUsed;
    }
    ctx->retriesLeft--;
    StartChannelLock(ctx);
}

void IRMClient::StartBandwidthLock(const std::shared_ptr<BandwidthLockState>& ctx) {
    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::BandwidthRead;
        ctx->evidence->compareExpected = 0;
        ctx->evidence->compareDesired = 0;
        ctx->evidence->compareObserved = 0;
        ctx->evidence->compareStage = ResourceOperationStage::Admission;
        ctx->evidence->validFields = static_cast<uint8_t>(
            ctx->evidence->validFields &
            ~(kCompareProposalValid | kCompareResponseValid));
    }
    if (!RouteIsCurrent(ctx->expectedGeneration, ctx->routeEpoch)) {
        if (ctx->evidence) {
            ctx->evidence->cause = ResourceFailureCause::RouteInvalidated;
            ctx->evidence->failureStage = ResourceOperationStage::BandwidthRead;
            ctx->evidence->terminalStage = ResourceOperationStage::BandwidthRead;
        }
        ctx->userCallback(AllocationStatus::GenerationMismatch);
        return;
    }
    ReadIRMQuadlet(IRMRegisters::kBandwidthAvailable,
                   [this, ctx](AllocationStatus status, uint32_t currentBandwidth) {
                       if (status == AllocationStatus::Timeout && ctx->readTimeoutRetriesLeft > 0) {
                           --ctx->readTimeoutRetriesLeft;
                           ASFW_LOG(IRM, "Bandwidth read timeout; bounded retry remaining=%u", ctx->readTimeoutRetriesLeft);
                           StartBandwidthLock(ctx);
                           return;
                       }
                       if (status != AllocationStatus::Success) {
                           if (ctx->evidence) {
                               ctx->evidence->cause = status == AllocationStatus::GenerationMismatch
                                                          ? ResourceFailureCause::RouteInvalidated
                                                          : ResourceFailureCause::TransportFailure;
                               ctx->evidence->failureStage = ResourceOperationStage::BandwidthRead;
                               ctx->evidence->terminalStage = ResourceOperationStage::BandwidthRead;
                           }
                           ctx->userCallback(status);
                           return;
                       }
                       OnBandwidthRead(ctx, true, currentBandwidth);
        }, ctx->expectedGeneration);
}

void IRMClient::OnBandwidthRead(const std::shared_ptr<BandwidthLockState>& ctx,
                                const bool success,
                                const uint32_t currentBandwidth) {
    if (!success) {
        ASFW_LOG_ERROR(IRM, "Bandwidth read failed");
        ctx->userCallback(AllocationStatus::Failed);
        return;
    }


    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::BandwidthRead;
        ctx->evidence->observedBandwidthAvailable = currentBandwidth;
        ctx->evidence->validFields |= kObservedBandwidthAvailableValid;
    }

    const uint64_t releasedBandwidth = static_cast<uint64_t>(currentBandwidth) + ctx->units;
    uint32_t newBandwidth = static_cast<uint32_t>(releasedBandwidth);
    if (ctx->allocate) {
        if (currentBandwidth < ctx->units) {
            ASFW_LOG(IRM, "Insufficient bandwidth (available=%u needed=%u)",
                     currentBandwidth, ctx->units);
            if (ctx->evidence) {
                ctx->evidence->cause = ResourceFailureCause::InsufficientBandwidth;
                ctx->evidence->failureStage = ResourceOperationStage::BandwidthRead;
            }
            ctx->userCallback(AllocationStatus::NoResources);
            return;
        }
        newBandwidth = currentBandwidth - ctx->units;
    } else if (currentBandwidth > kBandwidthAvailableValueMask ||
               releasedBandwidth > ctx->releaseCeiling ||
               releasedBandwidth > kBandwidthAvailableValueMask) {
        ASFW_LOG_ERROR(IRM,
                 "Bandwidth release rejected available=%u release=%u result=%llu lease_ceiling=%u csr_ceiling=%u status=%u",
                 currentBandwidth, ctx->units, releasedBandwidth, ctx->releaseCeiling,
                 kBandwidthAvailableValueMask, static_cast<unsigned>(AllocationStatus::Failed));
        ctx->userCallback(AllocationStatus::Failed);
        return;
    }


    if (ctx->evidence) {
        ctx->evidence->terminalStage = ResourceOperationStage::BandwidthCompareSwap;
        ctx->evidence->compareExpected = currentBandwidth;
        ctx->evidence->compareDesired = newBandwidth;
        ctx->evidence->compareObserved = 0;
        ctx->evidence->compareStage = ResourceOperationStage::BandwidthCompareSwap;
        ctx->evidence->validFields = static_cast<uint8_t>(
            (ctx->evidence->validFields | kCompareProposalValid) &
            ~kCompareResponseValid);
    }

    ASFW_LOG(IRM,
             "Bandwidth %{public}s CAS gen=%u expected=%u desired=%u units=%u lease_ceiling=%u",
             ctx->allocate ? "allocate" : "release", ctx->expectedGeneration.value,
             currentBandwidth, newBandwidth, ctx->units, ctx->releaseCeiling);

    CompareSwapIRMQuadlet(IRMRegisters::kBandwidthAvailable, currentBandwidth, newBandwidth,
                          [this, ctx, currentBandwidth](AllocationStatus status, uint32_t oldValue) {
                              if (status != AllocationStatus::Success) {
                                  if (ctx->evidence) {
                                      ctx->evidence->cause =
                                          status == AllocationStatus::GenerationMismatch
                                              ? ResourceFailureCause::RouteInvalidated
                                              : ResourceFailureCause::TransportUncertain;
                                      ctx->evidence->failureStage =
                                          ResourceOperationStage::BandwidthCompareSwap;
                                  }
                                  ctx->userCallback(status);
                                  return;
                              }
                              OnBandwidthCompareSwap(ctx, currentBandwidth, true, oldValue);
                           }, ctx->expectedGeneration);
}

void IRMClient::OnBandwidthCompareSwap(const std::shared_ptr<BandwidthLockState>& ctx,
                                       const uint32_t expectedBandwidth,
                                       const bool success,
                                       const uint32_t oldValue) {
    if (!success) {
        ASFW_LOG_ERROR(IRM, "Bandwidth lock operation failed");
        ctx->userCallback(AllocationStatus::Failed);
        return;
    }

    if (oldValue == expectedBandwidth) {
        if (ctx->evidence) {
            ctx->evidence->compareObserved = oldValue;
            ctx->evidence->validFields |= kCompareResponseValid;
        }
        const uint32_t desired = ctx->allocate ? expectedBandwidth - ctx->units
                                                : expectedBandwidth + ctx->units;
        ASFW_LOG(IRM,
                 "Bandwidth %{public}s CAS complete gen=%u expected=%u observed=%u desired=%u units=%u lease_ceiling=%u status=%u",
                 ctx->allocate ? "allocate" : "release", ctx->expectedGeneration.value,
                 expectedBandwidth, oldValue, desired, ctx->units, ctx->releaseCeiling,
                 static_cast<unsigned>(AllocationStatus::Success));
        ctx->userCallback(AllocationStatus::Success);
        return;
    }


    if (ctx->evidence) {
        ctx->evidence->compareObserved = oldValue;
        ctx->evidence->validFields |= kCompareResponseValid;
    }

    ASFW_LOG(IRM, "Bandwidth lock contention (expected=%u actual=%u retries=%u)",
             expectedBandwidth, oldValue, ctx->retriesLeft);
    if (ctx->retriesLeft == 0) {
        ASFW_LOG(IRM, "Bandwidth lock exhausted retries");
        if (ctx->evidence) {
            ctx->evidence->cause = ResourceFailureCause::ContentionExhausted;
            ctx->evidence->failureStage = ResourceOperationStage::BandwidthCompareSwap;
        }
        ctx->userCallback(AllocationStatus::NoResources);
        return;
    }

    if (ctx->evidence && ctx->evidence->contentionRetriesUsed != UINT8_MAX) {
        ++ctx->evidence->contentionRetriesUsed;
    }
    ctx->retriesLeft--;
    StartBandwidthLock(ctx);
}

} // namespace ASFW::IRM
