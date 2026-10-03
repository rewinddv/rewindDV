// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
//
// RewindDV: validated Self-ID path ceiling for outbound speed decisions.

#pragma once

#include "TopologyTypes.hpp"
#include "../Common/FWTypes.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>

namespace ASFW::Driver {

// Returns the slowest PHY on the one validated path between two active link
// endpoints. Intermediate PHYs participate even when their link layer is not
// active: their repeater still constrains the forwarded packet rate. Any
// malformed, non-reciprocal, cyclic, disconnected, or ambiguous graph returns
// no evidence so callers can fail conservatively to S100.
[[nodiscard]] inline std::optional<uint8_t>
PathSpeedCodeBetween(const TopologySnapshot& topology, uint8_t nodeA,
                     uint8_t nodeB) noexcept {
    constexpr size_t kNodeSlots = kMaxFireWireNodes;
    const auto& nodes = topology.physical.nodes;
    if (topology.selfIdStatus != SelfIDStreamStatus::Valid ||
        topology.graphStatus != TopologyGraphStatus::Valid || nodes.empty() ||
        nodes.size() > kNodeSlots || topology.nodeCount != nodes.size() ||
        topology.physical.nodeCount != nodes.size() ||
        topology.localNodeId >= kNodeSlots ||
        topology.physical.localId != topology.localNodeId ||
        nodeA >= kNodeSlots || nodeB >= kNodeSlots) {
        return std::nullopt;
    }

    std::array<const TopologyNodeRecord*, kNodeSlots> byId{};
    for (const auto& node : nodes) {
        if (node.physicalId >= kNodeSlots || byId[node.physicalId] != nullptr ||
            node.portCount > kMaxPhyPorts ||
            node.speedCode > static_cast<uint32_t>(FW::FwSpeed::S800) ||
            node.maxSpeedMbps != (100u << node.speedCode)) {
            return std::nullopt;
        }
        byId[node.physicalId] = &node;
        for (size_t port = node.portCount; port < node.links.size(); ++port) {
            if (node.links[port].connected) {
                return std::nullopt;
            }
        }
    }

    const auto* endpointA = byId[nodeA];
    const auto* endpointB = byId[nodeB];
    if (endpointA == nullptr || endpointB == nullptr || !endpointA->linkActive ||
        !endpointB->linkActive) {
        return std::nullopt;
    }

    size_t directedEdges = 0;
    for (const auto& node : nodes) {
        for (size_t port = 0; port < node.portCount; ++port) {
            const auto& link = node.links[port];
            if (!link.connected) {
                continue;
            }
            ++directedEdges;
            if (link.remoteNodeId >= kNodeSlots) {
                return std::nullopt;
            }
            const auto* remote = byId[link.remoteNodeId];
            if (remote == nullptr || link.remotePort >= remote->portCount) {
                return std::nullopt;
            }
            const auto& reciprocal = remote->links[link.remotePort];
            if (!reciprocal.connected || reciprocal.remoteNodeId != node.physicalId ||
                reciprocal.remotePort != port) {
                return std::nullopt;
            }
        }
    }
    if (directedEdges != 2u * (nodes.size() - 1u)) {
        return std::nullopt;
    }

    std::array<bool, kNodeSlots> seen{};
    std::array<uint8_t, kNodeSlots> queue{};
    std::array<FW::FwSpeed, kNodeSlots> ceiling{};
    size_t head = 0;
    size_t tail = 0;
    seen[nodeA] = true;
    queue[tail++] = nodeA;
    ceiling[nodeA] = static_cast<FW::FwSpeed>(endpointA->speedCode);

    while (head < tail) {
        const uint8_t currentId = queue[head++];
        const auto* current = byId[currentId];
        for (size_t port = 0; port < current->portCount; ++port) {
            const auto& link = current->links[port];
            if (!link.connected || seen[link.remoteNodeId]) {
                continue;
            }
            const auto* remote = byId[link.remoteNodeId];
            const auto remoteSpeed = static_cast<FW::FwSpeed>(remote->speedCode);
            ceiling[link.remoteNodeId] =
                static_cast<uint8_t>(remoteSpeed) < static_cast<uint8_t>(ceiling[currentId])
                    ? remoteSpeed
                    : ceiling[currentId];
            seen[link.remoteNodeId] = true;
            queue[tail++] = link.remoteNodeId;
        }
    }

    if (tail != nodes.size() || !seen[nodeB]) {
        return std::nullopt;
    }
    return static_cast<uint8_t>(ceiling[nodeB]);
}

} // namespace ASFW::Driver
