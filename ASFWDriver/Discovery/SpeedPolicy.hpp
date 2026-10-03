// Modified for RewindDV; see Foundation/NOTICE.md.
#pragma once

#include <cstdint>
#include <optional>
#include <unordered_map>

#include <DriverKit/IOLib.h>

#include "../Async/Interfaces/ILinkSpeedSource.hpp"
#include "DiscoveryTypes.hpp"

namespace ASFW::Discovery {

// Central authority for link speed and max payload policy.
// Provides speed fallback sequencing (S400→S200→S100) and per-node adaptation
// based on observed transaction outcomes.
class SpeedPolicy final : public Async::ILinkSpeedSource {
public:
    SpeedPolicy();
    ~SpeedPolicy() override;

    SpeedPolicy(const SpeedPolicy&) = delete;
    SpeedPolicy& operator=(const SpeedPolicy&) = delete;

    // Establish the only generation allowed to mutate/query learned state.
    // A different generation atomically discards every node-ID keyed entry.
    // Returns an opaque, non-zero admission epoch. Mutations from scan
    // callbacks must present this epoch as well as the wire generation. This
    // remains safe when the finite wire generation repeats or wraps.
    [[nodiscard]] uint64_t BeginGeneration(Generation generation) noexcept;

    // Query current policy for a node
    LinkPolicy ForNode(Generation generation, uint8_t nodeId) const;
    LinkPolicy ForNode(Generation generation, uint64_t admissionEpoch,
                       uint8_t nodeId) const;

    // Async::ILinkSpeedSource. Only an actual successful Config-ROM
    // transaction is exported; a timeout-selected probe fallback remains
    // internal to the scanner until that fallback succeeds.
    [[nodiscard]] std::optional<FW::FwSpeed>
    SuccessfulSpeed(FW::Generation generation, FW::NodeId nodeId) const noexcept override;

    // Adapt policy based on transaction outcomes
    [[nodiscard]] bool RecordSuccess(Generation generation, uint64_t admissionEpoch,
                                     uint8_t nodeId,
                                     FwSpeed speed) noexcept;
    [[nodiscard]] bool RecordTimeout(Generation generation, uint64_t admissionEpoch,
                                     uint8_t nodeId,
                                     FwSpeed speed) noexcept;

    // Admin override: halve packet sizes globally (escape hatch for flaky topologies)
    void SetHalfSizePackets(bool enabled);

    // Reset all per-node state (e.g., after bus reset)
    void InvalidateForBusReset() noexcept;

private:
    struct NodeSpeedState {
        FwSpeed currentSpeed{FwSpeed::S400};
        std::optional<FwSpeed> successfulSpeed;
        uint8_t timeoutCount{0};
        uint8_t successCount{0};
    };

    // Compute max payload based on speed and policy flags
    uint16_t ComputeMaxPayload(FwSpeed speed) const;

    // Downgrade speed to next lower tier
    FwSpeed DowngradeSpeed(FwSpeed current) const;

    [[nodiscard]] bool IsActiveLocked(Generation generation,
                                      uint64_t admissionEpoch) const noexcept;
    [[nodiscard]] uint64_t AdvanceEpochLocked() noexcept;

    mutable IOLock* lock_{nullptr};
    std::optional<Generation> activeGeneration_;
    uint64_t admissionEpoch_{0};
    bool admissionEpochExhausted_{false};
    std::unordered_map<uint8_t, NodeSpeedState> nodeStates_;
    bool halfSizePackets_{false};
};

} // namespace ASFW::Discovery
