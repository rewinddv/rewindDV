// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Independent downstream oracle: a unique physical path is limited by every
// PHY on that path, not by unrelated branches or the destination alone.
#include <gtest/gtest.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include "ASFWDriver/Bus/TopologySpeed.hpp"

namespace {
using namespace ASFW::Driver;

void Join(TopologySnapshot& t, uint8_t child, uint8_t childPort,
          uint8_t parent, uint8_t parentPort) {
    auto& c = t.physical.nodes[child];
    auto& p = t.physical.nodes[parent];
    c.links[childPort] = {true, parent, parentPort};
    p.links[parentPort] = {true, child, childPort};
    c.reportedPorts[childPort] = PortState::Parent;
    p.reportedPorts[parentPort] = PortState::Child;
    c.portCount = std::max(c.portCount, static_cast<uint8_t>(childPort + 1));
    p.portCount = std::max(p.portCount, static_cast<uint8_t>(parentPort + 1));
}

TopologySnapshot Nodes(uint8_t count) {
    TopologySnapshot t;
    t.generation = 7;
    t.selfIdStatus = SelfIDStreamStatus::Valid;
    t.graphStatus = TopologyGraphStatus::Valid;
    t.nodeCount = t.physical.nodeCount = count;
    t.localNodeId = t.physical.localId = 0;
    t.rootNodeId = t.physical.rootId = count - 1;
    for (uint8_t id = 0; id < count; ++id) {
        TopologyNodeRecord n;
        n.physicalId = id;
        n.linkActive = true;
        n.isLocal = id == 0;
        n.isRoot = id == count - 1;
        n.speedCode = 2;
        n.maxSpeedMbps = 400;
        t.physical.nodes.push_back(n);
    }
    return t;
}

TopologySnapshot Chain(uint8_t count = 3) {
    auto t = Nodes(count);
    for (uint8_t id = 0; id + 1 < count; ++id)
        Join(t, id, id == 0 ? 0 : 1, id + 1, 0);
    return t;
}

void Speed(TopologySnapshot& t, uint8_t node, uint8_t speed) {
    t.physical.nodes[node].speedCode = speed;
    t.physical.nodes[node].maxSpeedMbps = 100u << speed;
}

TEST(TopologySpeed, EveryLegacyThreeNodeSpeedCombinationUsesPathMinimumBothDirections) {
    for (uint8_t a = 0; a < 3; ++a)
        for (uint8_t b = 0; b < 3; ++b)
            for (uint8_t c = 0; c < 3; ++c) {
                auto t = Chain(); Speed(t, 0, a); Speed(t, 1, b); Speed(t, 2, c);
                const uint8_t expected = std::min({a, b, c});
                SCOPED_TRACE(::testing::Message() << +a << '/' << +b << '/' << +c);
                EXPECT_EQ(PathSpeedCodeBetween(t, 0, 2), expected);
                EXPECT_EQ(PathSpeedCodeBetween(t, 2, 0), expected);
            }
}

TEST(TopologySpeed, InactiveIntermediatePHYStillLimitsPath) {
    auto t = Chain(); Speed(t, 1, 0); t.physical.nodes[1].linkActive = false;
    EXPECT_EQ(PathSpeedCodeBetween(t, 0, 2), 0);
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 1));
    EXPECT_FALSE(PathSpeedCodeBetween(t, 1, 2));
}

TEST(TopologySpeed, SlowerUnrelatedBranchDoesNotReduceSelectedPath) {
    auto t = Nodes(4);
    Join(t, 0, 0, 3, 0); Join(t, 1, 0, 3, 1); Join(t, 2, 0, 3, 2);
    Speed(t, 2, 0);
    EXPECT_EQ(PathSpeedCodeBetween(t, 0, 1), 2);
    EXPECT_EQ(PathSpeedCodeBetween(t, 0, 2), 0);
}

TEST(TopologySpeed, SingleNodeAndSelfPathsUseOnlyOwnPHY) {
    auto t = Nodes(1); Speed(t, 0, 1);
    EXPECT_EQ(PathSpeedCodeBetween(t, 0, 0), 1);
    t = Chain(); Speed(t, 1, 0);
    EXPECT_EQ(PathSpeedCodeBetween(t, 2, 2), 2);
}

TEST(TopologySpeed, MaximumLegalNodeCountTerminatesAndIncludesFarEnd) {
    auto t = Chain(kMaxFireWireNodes); Speed(t, kMaxFireWireNodes - 2, 0);
    EXPECT_EQ(PathSpeedCodeBetween(t, 0, kMaxFireWireNodes - 1), 0);
    EXPECT_EQ(PathSpeedCodeBetween(t, kMaxFireWireNodes - 1, 0), 0);
}

TEST(TopologySpeed, InvalidGraphMissingEndpointAndBroadcastAreUnknown) {
    auto t = Chain();
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 4));
    EXPECT_FALSE(PathSpeedCodeBetween(t, 63, 0));
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 255));
    t.graphStatus = TopologyGraphStatus::Invalid;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t.graphStatus = TopologyGraphStatus::Unknown;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Nodes(1); t.physical.nodes.clear();
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 0));
}

TEST(TopologySpeed, DuplicateOrOutOfRangePhysicalIdsAreRejected) {
    auto t = Chain(); t.physical.nodes[2].physicalId = 1;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 1));
    t = Chain(); t.physical.nodes[1].physicalId = 63;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
}

TEST(TopologySpeed, MalformedPortExtentsNeverIndexOutsideFixedArrays) {
    for (uint8_t count : {uint8_t{17}, uint8_t{255}}) {
        auto t = Chain(); t.physical.nodes[1].portCount = count;
        EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    }
    for (uint8_t remotePort : {uint8_t{16}, uint8_t{255}}) {
        auto t = Chain(); t.physical.nodes[0].links[0].remotePort = remotePort;
        EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    }
}

TEST(TopologySpeed, NonreciprocalOrMissingLinksAreRejected) {
    auto t = Chain(); t.physical.nodes[1].links[0].connected = false;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[1].links[0].remotePort = 1;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[0].links[0].remoteNodeId = 8;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
}

TEST(TopologySpeed, CyclesSelfLoopsAndDisconnectedForestsAreRejected) {
    auto t = Chain(); Join(t, 0, 1, 2, 1);
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[0].links[0] = {true, 0, 0};
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Nodes(4); Join(t, 0, 0, 1, 0); Join(t, 2, 0, 3, 0);
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 3));
}

TEST(TopologySpeed, ReservedSpeedCannotRaisePathCeiling) {
    auto t = Chain(); t.physical.nodes[1].speedCode = 4;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
}

TEST(TopologySpeed, ContradictorySpeedRepresentationsAreUnknown) {
    auto t = Chain(); t.physical.nodes[1].maxSpeedMbps = 100;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[1].speedCode = 0;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
}

TEST(TopologySpeed, DeclaredExtentAndObserverIdentityMustAgree) {
    auto t = Chain(); t.nodeCount = 2;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodeCount = 2;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    for (const auto status : {SelfIDStreamStatus::Unknown, SelfIDStreamStatus::Invalid,
                              SelfIDStreamStatus::Timeout, SelfIDStreamStatus::CrcError}) {
        t = Chain(); t.selfIdStatus = status;
        EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    }
    t = Chain(); t.physical.localId = 1;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[1].portCount = 1;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 2));
    t = Chain(); t.physical.nodes[0].linkActive = false;
    EXPECT_FALSE(PathSpeedCodeBetween(t, 0, 0));
}
} // namespace
