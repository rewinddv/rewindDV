// Modified for RewindDV; see Foundation/NOTICE.md.
#pragma once

#include "IRMTypes.hpp"
#include "../../Async/Interfaces/IFireWireBus.hpp"
#include "../../Hardware/HardwareInterface.hpp"
#include <functional>
#include <memory>
#include <utility>

namespace ASFW::IRM {

/**
 * Callback for IRM allocation operations.
 * Invoked asynchronously when allocation completes (success or failure).
 *
 * @param status Result of allocation operation
 */
using AllocationCallback = std::function<void(AllocationStatus status)>;
using ResourceOperationCallback =
    std::function<void(AllocationStatus status, ResourceOwnership ownership)>;
using DetailedResourceOperationCallback = std::function<void(
    AllocationStatus status, ResourceOwnership ownership,
    ResourceOperationEvidence evidence)>;
using CompareSwapCallback = std::function<void(AllocationStatus status, uint32_t oldValue)>;

struct ResourceSnapshot {
    // Sequential observations under one route/epoch, not one atomic IRM
    // reservation snapshot. Another node may mutate resources between reads.
    uint32_t bandwidthAvailable{0};
    uint32_t channelsAvailable31_0{0};
    uint32_t channelsAvailable63_32{0};
};

using ResourceSnapshotCallback = std::function<void(AllocationStatus status, ResourceSnapshot snapshot)>;

// Threading/lifetime contract (same as TopologyManager): all entry points,
// SetIRMNode and bus completions run on the driver's serial Default queue.
// No side-queue callers. Route epochs fence queued stale work, not data races.
// The owner must quiesce/drain async callbacks before destroying this client
// or the borrowed bus. Foundation runtime teardown enforces that ordering.
class IRMClient {
public:
    struct LocalIRMAccess {
        using ReadFn = std::function<Driver::LocalCSRReadResult(uint32_t selector)>;
        using CompareSwapFn = std::function<Driver::LocalCSRLockResult(
            uint32_t selector,
            uint32_t compareValue,
            uint32_t newValue)>;

        ReadFn read;
        CompareSwapFn compareSwap;
    };

    explicit IRMClient(Async::IFireWireBus& bus, LocalIRMAccess localIRMAccess = {});
    ~IRMClient();

    void SetIRMNode(uint8_t irmNodeId, Generation generation, uint64_t lastBusResetNs = 0);

    void AllocateChannel(uint8_t channel,
                        AllocationCallback callback,
                        const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void ReleaseChannel(uint8_t channel,
                       AllocationCallback callback,
                       const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void AllocateBandwidth(uint32_t units,
                          AllocationCallback callback,
                          const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void ReleaseBandwidth(uint32_t units,
                         AllocationCallback callback,
                         const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void AllocateResources(uint8_t channel,
                          uint32_t bandwidthUnits,
                          AllocationCallback callback,
                          const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void AllocateResourcesForGeneration(uint8_t channel,
                          uint32_t bandwidthUnits,
                          Generation expectedGeneration,
                          ResourceOperationCallback callback,
                          const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void AllocateResourcesDetailedForGeneration(
        uint8_t channel, uint32_t bandwidthUnits, Generation expectedGeneration,
        DetailedResourceOperationCallback callback,
        const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void ReleaseResources(uint8_t channel,
                         uint32_t bandwidthUnits,
                         AllocationCallback callback,
                         const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void ReleaseResourcesForGeneration(uint8_t channel,
                         uint32_t bandwidthUnits,
                         uint32_t bandwidthCeiling,
                         Generation expectedGeneration,
                         ResourceOperationCallback callback,
                         const RetryPolicy& retryPolicy = RetryPolicy::Default());

    void ReadResourcesSnapshot(ResourceSnapshotCallback callback);

    void CompareSwapBandwidth(uint32_t expected,
                              uint32_t desired,
                              CompareSwapCallback callback);

    void CompareSwapChannel(uint8_t channel,
                            uint32_t expected,
                            uint32_t desired,
                            CompareSwapCallback callback);

    [[nodiscard]] uint8_t GetIRMNodeID() const { return irmNodeId_; }

    [[nodiscard]] Generation GetGeneration() const { return generation_; }

private:
    struct ChannelLockState;
    struct BandwidthLockState;

    Async::IFireWireBus& bus_;
    LocalIRMAccess localIRMAccess_;

    uint8_t irmNodeId_{0xFF};
    Generation generation_{0};
    uint64_t lastBusResetNs_{0};
    // Controller workloop owned, like the route fields above. Invalidates
    // delayed completions even when a node/generation tuple is later reused.
    uint64_t routeEpoch_{0};
    [[nodiscard]] bool RouteIsCurrent(Generation expected, uint64_t epoch) const;

    void ReadIRMQuadlet(
        uint32_t addressLo,
        std::function<void(AllocationStatus status, uint32_t value)> callback,
        Generation expectedGeneration);

    void CompareSwapIRMQuadlet(
        uint32_t addressLo,
        uint32_t expected,
        uint32_t desired,
        std::function<void(AllocationStatus status, uint32_t oldValue)> callback,
        Generation expectedGeneration);

    void ReadIRMWindow(ResourceSnapshotCallback callback);
    void DelayForPostResetQuietPeriod() const;

    [[nodiscard]] static AllocationStatus MapAsyncStatus(Async::AsyncStatus status) noexcept;
    [[nodiscard]] static AllocationStatus
    MapLocalCSRStatus(Driver::LocalCSRLockResult::Status status) noexcept;
    [[nodiscard]] static uint64_t CurrentMonotonicNowNs() noexcept;
    [[nodiscard]] bool IsLocalIRMNode() const noexcept;

    void PerformChannelLock(uint8_t channel, bool allocate,
                           AllocationCallback callback,
                           const RetryPolicy& retryPolicy,
                           Generation expectedGeneration,
                           std::shared_ptr<ResourceOperationEvidence> evidence = {});

    void StartChannelLock(const std::shared_ptr<ChannelLockState>& ctx);
    void OnChannelRead(const std::shared_ptr<ChannelLockState>& ctx,
                       bool success,
                       uint32_t currentValue);
    void OnChannelCompareSwap(const std::shared_ptr<ChannelLockState>& ctx,
                              uint32_t expectedValue,
                              bool success,
                              uint32_t oldValue);

    void PerformBandwidthLock(uint32_t units, bool allocate,
                             AllocationCallback callback,
                             const RetryPolicy& retryPolicy,
                             Generation expectedGeneration,
                             uint32_t releaseCeiling = kMaxBandwidthUnitsS400,
                             std::shared_ptr<ResourceOperationEvidence> evidence = {});

    void StartBandwidthLock(const std::shared_ptr<BandwidthLockState>& ctx);
    void OnBandwidthRead(const std::shared_ptr<BandwidthLockState>& ctx,
                         bool success,
                         uint32_t currentBandwidth);
    void OnBandwidthCompareSwap(const std::shared_ptr<BandwidthLockState>& ctx,
                                uint32_t expectedBandwidth,
                                bool success,
                                uint32_t oldValue);
};

} // namespace ASFW::IRM
