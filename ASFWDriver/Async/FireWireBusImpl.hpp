// Modified for RewindDV; see Foundation/NOTICE.md.
#pragma once
#include <optional>

#include "Interfaces/IAsyncControllerPort.hpp"
#include "Interfaces/IFireWireBus.hpp"

// Forward declare TopologyManager
namespace ASFW::Driver {
class TopologyManager;
}

namespace ASFW::Async {

class ILinkSpeedSource;

/**
 * @brief Concrete implementation of IFireWireBus using an async controller port.
 *
 * Thin adapter that delegates to existing CRTP-based async engine.
 * Cost: One virtual dispatch per operation (negligible vs. actual bus latency).
 *
 * Note: Only implements virtual methods (ReadBlock/WriteBlock/Lock/Cancel/Get*).
 * ReadQuad/WriteQuad are non-virtual helpers in IFireWireBusOps (no override needed).
 */
class FireWireBusImpl final : public IFireWireBus {
  public:
    struct LinkSpeedDecision {
        FW::FwSpeed selected{FW::FwSpeed::S100};
        FW::FwSpeed topologyCeiling{FW::FwSpeed::S100};
        FW::FwSpeed learnedCeiling{FW::FwSpeed::S100};
        uint16_t generation16{0};
        uint8_t generation8{0};
        uint8_t localNodeId{0xFF};
        uint8_t targetNodeId{0xFF};
        bool topologyValid{false};
        bool learnedSuccess{false};
    };

    /**
     * @brief Construct bus facade.
     *
     * @param async Reference to async controller port (must outlive this object)
     * @param topo Reference to topology manager (for speed/hop queries)
     */
    FireWireBusImpl(IAsyncControllerPort& async, Driver::TopologyManager& topo,
                    const ILinkSpeedSource* learnedSpeeds = nullptr);

    // IFireWireBusOps implementation (virtual methods only)
    AsyncHandle ReadBlock(FW::Generation gen, FW::NodeId node, FWAddress addr, uint32_t length,
                          FW::FwSpeed speed, InterfaceCompletionCallback callback) override;
    AsyncHandle WriteBlock(FW::Generation gen, FW::NodeId node, FWAddress addr,
                           std::span<const uint8_t> data, FW::FwSpeed speed,
                           InterfaceCompletionCallback callback) override;
    AsyncHandle Lock(FW::Generation gen, FW::NodeId node, FWAddress addr, FW::LockOp op,
                     std::span<const uint8_t> operand, uint32_t responseLength, FW::FwSpeed speed,
                     InterfaceCompletionCallback callback) override;
    bool Cancel(AsyncHandle handle) override;
    void FenceUncertainResponse() noexcept override;


    // IFireWireBusInfo implementation
    FW::FwSpeed GetSpeed(FW::NodeId nodeId) const override;
    [[nodiscard]] LinkSpeedDecision GetSpeedDecision(FW::NodeId nodeId) const;
    uint32_t HopCount(FW::NodeId nodeA, FW::NodeId nodeB) const override;
    uint8_t GetGapCount() const override;
    FW::Generation GetGeneration() const override;
    FW::NodeId GetLocalNodeID() const override;

  private:
    struct AdvertisedLinkSpeed {
        FW::Generation generation{0};
        FW::FwSpeed speed{FW::FwSpeed::S100};
        uint8_t localNodeId{0xFF};
    };

    [[nodiscard]] std::optional<AdvertisedLinkSpeed>
    AdvertisedSpeed(FW::NodeId nodeId) const;

    IAsyncControllerPort& async_;
    Driver::TopologyManager& topo_;
    const ILinkSpeedSource* learnedSpeeds_{nullptr};
};

} // namespace ASFW::Async
