// Modified for RewindDV; see Foundation/NOTICE.md.
#include "FireWireBusImpl.hpp"
#include "../Bus/TopologyManager.hpp"
#include "../Bus/TopologySpeed.hpp"
#include "../Logging/Logging.hpp"
#include "Interfaces/ILinkSpeedSource.hpp"
#include <algorithm>
#include <atomic>
#include <map>
#include <queue>
#include <vector>

namespace ASFW::Async {

namespace {

[[nodiscard]] bool HasCurrentGeneration(IAsyncControllerPort& async, FW::Generation generation) {
    const auto busState = async.GetBusStateSnapshot();
    const FW::Generation current{busState.requestGeneration};
    if (busState.requestGenerationValid && generation == current) {
        return true;
    }
    return false;
}

[[nodiscard]] uint16_t ResolveDestinationNodeId(const char* operation, FW::NodeId node,
                                                FWAddress addr) {
    const uint16_t addrNodeIdRaw = addr.nodeID;
    const uint8_t addrNodeNumber = static_cast<uint8_t>(addrNodeIdRaw & 0x3Fu);
    if (addrNodeIdRaw != 0 && addrNodeNumber != node.value) {
        static std::atomic<bool> sLoggedNodeMismatch{false};
        if (!sLoggedNodeMismatch.exchange(true, std::memory_order_relaxed)) {
            ASFW_LOG_V2(Async,
                        "FireWireBusImpl::%{public}s: FWAddress.nodeID mismatch "
                        "(addr.nodeID=0x%04x nodeId=%u); using nodeId",
                        operation, addrNodeIdRaw, node.value);
        }
    }

    return static_cast<uint16_t>(node.value);
}

[[nodiscard]] CompletionCallback AdaptInterfaceCompletion(InterfaceCompletionCallback callback) {
    return [callback = std::move(callback)](AsyncHandle, AsyncStatus status, uint8_t,
                                            std::span<const uint8_t> payload) {
        if (callback) {
            callback(status, payload);
        }
    };
}

} // namespace

FireWireBusImpl::FireWireBusImpl(IAsyncControllerPort& async, Driver::TopologyManager& topo,
                                 const ILinkSpeedSource* learnedSpeeds)
    : async_(async), topo_(topo), learnedSpeeds_(learnedSpeeds) {}

AsyncHandle FireWireBusImpl::ReadBlock(FW::Generation gen, FW::NodeId node, FWAddress addr,
                                       uint32_t length, FW::FwSpeed speed,
                                       InterfaceCompletionCallback callback) {
    if (!HasCurrentGeneration(async_, gen)) {
        return AsyncHandle{0};
    }

    ReadParams params{.destinationID = ResolveDestinationNodeId("ReadBlock", node, addr),
                      .addressHigh = addr.addressHi,
                      .addressLow = addr.addressLo,
                      .length = length,
                      .speedCode = static_cast<uint8_t>(speed)};
    return async_.Read(params, AdaptInterfaceCompletion(std::move(callback)));
}

AsyncHandle FireWireBusImpl::WriteBlock(FW::Generation gen, FW::NodeId node, FWAddress addr,
                                        std::span<const uint8_t> data, FW::FwSpeed speed,
                                        InterfaceCompletionCallback callback) {
    if (!HasCurrentGeneration(async_, gen)) {
        return AsyncHandle{0};
    }

    WriteParams params{.destinationID = ResolveDestinationNodeId("WriteBlock", node, addr),
                       .addressHigh = addr.addressHi,
                       .addressLow = addr.addressLo,
                       .payload = data.data(),
                       .length = static_cast<uint32_t>(data.size()),
                       .speedCode = static_cast<uint8_t>(speed)};
    return async_.Write(params, AdaptInterfaceCompletion(std::move(callback)));
}

AsyncHandle FireWireBusImpl::Lock(FW::Generation gen, FW::NodeId node, FWAddress addr,
                                  FW::LockOp op, std::span<const uint8_t> operand,
                                  uint32_t responseLength, FW::FwSpeed speed,
                                  InterfaceCompletionCallback callback) {
    if (!HasCurrentGeneration(async_, gen)) {
        return AsyncHandle{0};
    }

    LockParams params{};
    params.destinationID = ResolveDestinationNodeId("Lock", node, addr);
    params.addressHigh = addr.addressHi;
    params.addressLow = addr.addressLo;
    params.operand = operand.data();
    params.operandLength = static_cast<uint32_t>(operand.size());
    params.responseLength = responseLength;
    params.speedCode = static_cast<uint8_t>(speed);

    const uint16_t extendedTCode = static_cast<uint16_t>(op);

    return async_.Lock(params, extendedTCode, AdaptInterfaceCompletion(std::move(callback)));
}

bool FireWireBusImpl::Cancel(AsyncHandle handle) { return async_.Cancel(handle); }

FW::FwSpeed FireWireBusImpl::GetSpeed(FW::NodeId nodeId) const {
    return GetSpeedDecision(nodeId).selected;
}

FireWireBusImpl::LinkSpeedDecision
FireWireBusImpl::GetSpeedDecision(FW::NodeId nodeId) const {
    LinkSpeedDecision decision{};
    decision.targetNodeId = nodeId.value;
    // Do not combine a pre-reset topology ceiling with post-reset learned
    // evidence. Read the controller generation on both sides of the topology
    // snapshot; any transition or generation mismatch fails conservatively.
    const AsyncBusStateSnapshot stateBefore = async_.GetBusStateSnapshot();
    const auto advertised = AdvertisedSpeed(nodeId);
    const AsyncBusStateSnapshot stateAfter = async_.GetBusStateSnapshot();
    decision.generation16 = stateAfter.generation16;
    decision.generation8 = stateAfter.generation8;
    decision.localNodeId = static_cast<uint8_t>(stateAfter.localNodeID & 0x3Fu);
    if (!advertised.has_value() || !stateBefore.requestGenerationValid ||
        !stateAfter.requestGenerationValid ||
        stateBefore.requestGeneration != stateAfter.requestGeneration ||
        stateBefore.localNodeID != stateAfter.localNodeID ||
        advertised->generation.value != stateAfter.requestGeneration ||
        advertised->localNodeId != decision.localNodeId) {
        return decision;
    }

    decision.topologyValid = true;
    decision.topologyCeiling = advertised->speed;
    decision.selected = advertised->speed;

    if (learnedSpeeds_ == nullptr) {
        return decision;
    }

    // Linux similarly seeds a per-device maximum from topology, probes down
    // until a Config-ROM read completes, then uses that learned maximum for
    // later transactions (references/linux-firewire-22098763/core-device.c:
    // 772-798, 1028-1051). The generation is part of this query so a late
    // completion cannot constrain a different device that reused the node ID.
    // Topology, ROM scans and learned evidence share the request identity.
    // A scan admission epoch independently rejects callbacks from replaced scans.
    const auto learned = learnedSpeeds_->SuccessfulSpeed(
        FW::Generation{stateAfter.requestGeneration}, nodeId);
    const AsyncBusStateSnapshot stateFinal = async_.GetBusStateSnapshot();
    if (!stateFinal.requestGenerationValid ||
        stateFinal.requestGeneration != stateAfter.requestGeneration ||
        stateFinal.localNodeID != stateAfter.localNodeID) {
        return LinkSpeedDecision{};
    }
    if (!learned.has_value()) {
        return decision;
    }

    // Learned evidence may only constrain the topology ceiling, never raise it.
    decision.learnedSuccess = true;
    decision.learnedCeiling = *learned;
    if (static_cast<uint8_t>(*learned) < static_cast<uint8_t>(decision.selected)) {
        decision.selected = *learned;
    }
    return decision;
}

std::optional<FireWireBusImpl::AdvertisedLinkSpeed>
FireWireBusImpl::AdvertisedSpeed(FW::NodeId nodeId) const {
    // Get the latest topology snapshot
    auto snapshot = topo_.LatestSnapshot();
    if (!snapshot) {
        return std::nullopt;
    }

    const auto ceiling = Driver::PathSpeedCodeBetween(
        *snapshot, snapshot->physical.localId, nodeId.value);
    if (!ceiling.has_value()) {
        return std::nullopt;
    }
    return AdvertisedLinkSpeed{FW::Generation{snapshot->generation},
                               static_cast<FW::FwSpeed>(*ceiling),
                               snapshot->physical.localId};
}

uint32_t FireWireBusImpl::HopCount(FW::NodeId nodeA, FW::NodeId nodeB) const {
    // Special case: same node
    if (nodeA.value == nodeB.value) {
        return 0;
    }

    // Get the latest topology snapshot
    auto snapshot = topo_.LatestSnapshot();
    if (!snapshot || snapshot->physical.nodes.empty()) {
        return UINT32_MAX; // Unknown
    }


    // Build a map from physicalId to TopologyNodeRecord for fast lookup
    std::map<uint8_t, const Driver::TopologyNodeRecord*> nodeMap;
    for (const auto& node : snapshot->physical.nodes) {
        nodeMap[node.physicalId] = &node;
    }

    // Check that both nodes exist
    if (nodeMap.find(nodeA.value) == nodeMap.end() || nodeMap.find(nodeB.value) == nodeMap.end()) {
        return UINT32_MAX; // Unknown
    }

    // BFS to find shortest path from nodeA to nodeB
    std::map<uint8_t, uint32_t> distance;
    std::queue<uint8_t> queue;

    distance[nodeA.value] = 0;
    queue.push(nodeA.value);

    while (!queue.empty()) {
        uint8_t currentId = queue.front();
        queue.pop();

        if (currentId == nodeB.value) {
            return distance[currentId];
        }

        const auto* currentNode = nodeMap[currentId];
        if (!currentNode)
            continue;

        // Visit all connected ports
        for (const auto& link : currentNode->links) {
            if (!link.connected || link.remoteNodeId == Driver::kInvalidPhysicalId) {
                continue;
            }

            if (distance.find(link.remoteNodeId) == distance.end()) {
                distance[link.remoteNodeId] = distance[currentId] + 1;
                queue.push(link.remoteNodeId);
            }
        }
    }

    return UINT32_MAX; // No path found
}

uint8_t FireWireBusImpl::GetGapCount() const {
    const auto snapshot = topo_.LatestSnapshot();
    // Linux uses the unoptimised gap count as the conservative fallback for
    // isochronous overhead (sound/firewire/iso-resources.c:64-79).
    return snapshot ? snapshot->gapCount : 63;
}

FW::Generation FireWireBusImpl::GetGeneration() const {
    const auto state = async_.GetBusStateSnapshot();
    return FW::Generation{state.requestGenerationValid ? state.requestGeneration : FW::Generation::kInvalid};
}

FW::NodeId FireWireBusImpl::GetLocalNodeID() const {
    const auto state = async_.GetBusStateSnapshot();
    uint8_t nodeId = static_cast<uint8_t>(state.localNodeID & 0x3Fu); // Extract low 6 bits
    return FW::NodeId{nodeId};
}

} // namespace ASFW::Async
