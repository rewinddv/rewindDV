// Modified for RewindDV; see Foundation/NOTICE.md.
// Regression coverage for generation- and scan-epoch-bound learned link speed.

#include <gtest/gtest.h>

#include <atomic>
#include <optional>
#include <thread>
#include <vector>

#include "ASFWDriver/Async/AsyncSubsystem.hpp"
#include "ASFWDriver/Async/FireWireBusImpl.hpp"
#include "ASFWDriver/Async/Interfaces/ILinkSpeedSource.hpp"
#include "ASFWDriver/Bus/SelfIDCapture.hpp"
#include "ASFWDriver/Bus/TopologyManager.hpp"
#include "ASFWDriver/Discovery/SpeedPolicy.hpp"

namespace {

using ASFW::FW::FwSpeed;
using ASFW::FW::Generation;
using ASFW::FW::NodeId;

// Exact two-node Self-ID topology from upstream ASFireWire's 0bd1c58
// regression fixture. Node zero advertises the supplied speed; node one is the
// local root. Speed is bits [15:14] in the base Self-ID quadlet.
constexpr uint32_t kDeviceSelfID = 0x807F8890;
constexpr uint32_t kLocalSelfID = 0x817FC476;
constexpr uint32_t kNodeIDRegister = 0xC800FFC1;

[[nodiscard]] uint32_t WithSpeed(uint32_t selfId, uint8_t speedCode) {
    return (selfId & ~(0x3u << 14)) |
           ((static_cast<uint32_t>(speedCode) & 0x3u) << 14);
}

[[nodiscard]] ASFW::Driver::SelfIDCapture::Result
TwoNodeBus(uint8_t generation, uint8_t deviceSpeedCode) {
    ASFW::Driver::SelfIDCapture::Result result;
    result.valid = true;
    result.generation = generation;
    result.quads = {0x00010001, WithSpeed(kDeviceSelfID, deviceSpeedCode), kLocalSelfID};
    result.sequences = {{1, 1}, {2, 1}};
    return result;
}

// Three real Self-ID base packets: remote 0 -> repeater 1 -> local root 2.
// Parent/child ports are reciprocal after the production topology builder.
[[nodiscard]] ASFW::Driver::SelfIDCapture::Result
ThreeNodeBus(uint8_t generation, uint8_t middleSpeed, bool middleActive = true) {
    ASFW::Driver::SelfIDCapture::Result result;
    result.valid = true;
    result.generation = generation;
    const auto packet = [](uint8_t id, uint8_t speed, uint32_t ports, bool active) {
        return 0x80000000u | (uint32_t{id} << 24) | (active ? 0x00400000u : 0u) |
               (63u << 16) | (uint32_t{speed} << 14) | ports;
    };
    result.quads = {0x00010001,
        packet(0, 2, 0x80, true),       // port 0 parent
        packet(1, middleSpeed, 0xE0, middleActive), // child 0, parent 1
        packet(2, 2, 0xC0, true)};      // root: child 0
    result.sequences = {{1, 1}, {2, 1}, {3, 1}};
    return result;
}

class StubSpeedSource final : public ASFW::Async::ILinkSpeedSource {
  public:
    Generation acceptedGeneration{0};
    std::optional<FwSpeed> value;

    [[nodiscard]] std::optional<FwSpeed>
    SuccessfulSpeed(Generation generation, NodeId) const noexcept override {
        return generation == acceptedGeneration ? value : std::nullopt;
    }
};

class LinkSpeedClamp : public ::testing::Test {
  protected:
    void SeedTopology(uint8_t generation, uint8_t nodeZeroSpeedCode) {
        async.GetGenerationTracker().OnConfirmedBusGeneration(generation);
        async.GetGenerationTracker().OnSelfIDComplete(
            static_cast<uint16_t>(kNodeIDRegister & 0xFFFFu));
        const auto snapshot = topo.UpdateFromSelfID(
            TwoNodeBus(generation, nodeZeroSpeedCode), 1000, kNodeIDRegister,
            async.GetBusStateSnapshot().requestGeneration);
        ASSERT_TRUE(snapshot.has_value())
            << ASFW::Driver::TopologyManager::TopologyBuildErrorCodeString(
                   snapshot.error().code);
    }

    void SeedChain(uint8_t generation, uint8_t middleSpeed, bool active = true) {
        constexpr uint32_t localRoot = 0xC800FFC2;
        async.GetGenerationTracker().OnConfirmedBusGeneration(generation);
        async.GetGenerationTracker().OnSelfIDComplete(
            static_cast<uint16_t>(localRoot & 0xFFFFu));
        const auto snapshot = topo.UpdateFromSelfID(
            ThreeNodeBus(generation, middleSpeed, active), 1000, localRoot,
            async.GetBusStateSnapshot().requestGeneration);
        ASSERT_TRUE(snapshot.has_value());
    }

    ASFW::Async::AsyncSubsystem async;
    ASFW::Driver::TopologyManager topo;
};

TEST_F(LinkSpeedClamp, UnconfirmedZeroCannotAuthorizeARequest) {
    ASFW::Async::FireWireBusImpl bus(async, topo);
    unsigned completions = 0;
    EXPECT_FALSE(bus.ReadBlock(Generation{0}, NodeId{0}, {}, 4, FwSpeed::S100,
        [&](auto, auto) { ++completions; }));
    EXPECT_EQ(completions, 0U);
}

TEST_F(LinkSpeedClamp, PublishedTopologyRemainsAdmissibleAcrossRawWrap) {
    SeedTopology(255, 2);
    SeedTopology(0, 2);
    ASFW::Async::FireWireBusImpl bus(async, topo);
    const auto current = topo.LatestSnapshot();
    ASSERT_TRUE(current);
    unsigned completions = 0;
    EXPECT_TRUE(bus.ReadBlock(Generation{current->generation}, NodeId{0}, {}, 4, FwSpeed::S100,
        [&](auto, auto) { ++completions; }));
    EXPECT_EQ(completions, 1U);
}

TEST_F(LinkSpeedClamp, RepeatedInternalCounterCannotAuthorizeOldRoute) {
    SeedTopology(0, 2);
    ASFW::Async::FireWireBusImpl bus(async, topo);
    const auto oldGeneration = bus.GetGeneration();
    for (unsigned wrap = 0; wrap < 4; ++wrap) {
        SeedTopology(255, 2);
        SeedTopology(0, 2);
    }
    unsigned completions = 0;
    EXPECT_FALSE(bus.ReadBlock(oldGeneration, NodeId{0}, {}, 4, FwSpeed::S100,
        [&](auto, auto) { ++completions; }));
    EXPECT_EQ(completions, 0U);
}

TEST_F(LinkSpeedClamp, NoEvidenceKeepsSelfIDAdvertisedCeiling) {
    SeedTopology(7, 2 /* S400 */);
    ASFW::Discovery::SpeedPolicy policy;
    (void)policy.BeginGeneration(Generation{7});
    ASFW::Async::FireWireBusImpl bus(async, topo, &policy);

    EXPECT_EQ(FwSpeed::S400, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, AdvertisedS100RemainsS100) {
    SeedTopology(7, 0 /* S100 */);
    StubSpeedSource source;
    source.acceptedGeneration = Generation{7};
    source.value = FwSpeed::S400;
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);

    EXPECT_EQ(FwSpeed::S100, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, MissingTopologyAndUnknownNodeFallBackToS100) {
    ASFW::Async::FireWireBusImpl emptyBus(async, topo);
    EXPECT_EQ(FwSpeed::S100, emptyBus.GetSpeed(NodeId{0}));

    SeedTopology(7, 2 /* S400 */);
    ASFW::Async::FireWireBusImpl populatedBus(async, topo);
    EXPECT_EQ(FwSpeed::S100, populatedBus.GetSpeed(NodeId{9}));
}

TEST_F(LinkSpeedClamp, TopologyGenerationMismatchFallsBackToS100) {
    SeedTopology(7, 2 /* S400 */);
    async.GetGenerationTracker().OnConfirmedBusGeneration(8);
    StubSpeedSource source;
    source.acceptedGeneration = Generation{8};
    source.value = FwSpeed::S400;
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);

    EXPECT_EQ(FwSpeed::S100, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, ExtendedGenerationAfterEightBitWrapUsesCanonicalTopologyGeneration) {
    // Drive the tracker across the finite 8-bit generation boundary: the
    // controller state becomes generation16=0x0102 while Self-ID/topology and
    // the scan authority carry canonical request generation 258.
    async.GetGenerationTracker().OnConfirmedBusGeneration(250);
    SeedTopology(2, 2 /* S400 */);
    ASSERT_EQ(0x0102u, async.GetBusState().generation16);
    ASSERT_EQ(2u, async.GetBusState().generation8);

    ASFW::Discovery::SpeedPolicy policy;
    const uint64_t epoch = policy.BeginGeneration(Generation{258});
    ASSERT_TRUE(policy.RecordSuccess(Generation{258}, epoch, 0, FwSpeed::S200));
    ASFW::Async::FireWireBusImpl bus(async, topo, &policy);

    EXPECT_EQ(FwSpeed::S200, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, SuccessfulSlowerProbeClampsAdvertisedSpeed) {
    SeedTopology(7, 2 /* S400 */);
    ASFW::Discovery::SpeedPolicy policy;
    const uint64_t epoch = policy.BeginGeneration(Generation{7});
    ASSERT_NE(0u, epoch);
    ASSERT_TRUE(policy.RecordSuccess(Generation{7}, epoch, 0, FwSpeed::S200));
    ASFW::Async::FireWireBusImpl bus(async, topo, &policy);

    EXPECT_EQ(FwSpeed::S200, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, SuccessfulSpeedNeverRaisesSelfIDCeiling) {
    SeedTopology(7, 1 /* S200 */);
    StubSpeedSource source;
    source.acceptedGeneration = Generation{7};
    source.value = FwSpeed::S800;
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);

    EXPECT_EQ(FwSpeed::S200, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, RealSelfIDSlowMiddleLimitsInitialDiscoveryWithoutLearnedEvidence) {
    SeedChain(7, 0);
    ASFW::Async::FireWireBusImpl bus(async, topo);
    EXPECT_EQ(FwSpeed::S100, bus.GetSpeed(NodeId{0}));
    const auto decision = bus.GetSpeedDecision(NodeId{0});
    EXPECT_TRUE(decision.topologyValid);
    EXPECT_FALSE(decision.learnedSuccess);
    EXPECT_EQ(FwSpeed::S100, decision.topologyCeiling);
    EXPECT_EQ(2, decision.localNodeId);
    EXPECT_EQ(0, decision.targetNodeId);
    EXPECT_EQ(7, decision.generation8);
    SeedChain(8, 1);
    EXPECT_EQ(FwSpeed::S200, bus.GetSpeed(NodeId{0}));
}

TEST_F(LinkSpeedClamp, RealSelfIDInactiveRepeaterStillLimitsFasterSuccessfulEvidence) {
    SeedChain(7, 0, false);
    StubSpeedSource source;
    source.acceptedGeneration = Generation{7}; source.value = FwSpeed::S400;
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);
    const auto decision = bus.GetSpeedDecision(NodeId{0});
    EXPECT_TRUE(decision.topologyValid);
    EXPECT_TRUE(decision.learnedSuccess);
    EXPECT_EQ(FwSpeed::S400, decision.learnedCeiling);
    EXPECT_EQ(FwSpeed::S100, decision.topologyCeiling);
    EXPECT_EQ(FwSpeed::S100, decision.selected);
    EXPECT_EQ(FwSpeed::S100, bus.GetSpeed(NodeId{1})); // inactive endpoint: unknown
    EXPECT_FALSE(bus.GetSpeedDecision(NodeId{1}).topologyValid);
}

TEST_F(LinkSpeedClamp, DecisionDistinguishesSuccessfulClampFromPhysicalPath) {
    SeedChain(7, 2);
    StubSpeedSource source;
    source.acceptedGeneration = Generation{7}; source.value = FwSpeed::S100;
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);
    const auto decision = bus.GetSpeedDecision(NodeId{0});
    EXPECT_EQ(FwSpeed::S400, decision.topologyCeiling);
    EXPECT_EQ(FwSpeed::S100, decision.learnedCeiling);
    EXPECT_EQ(FwSpeed::S100, decision.selected);
    EXPECT_TRUE(decision.learnedSuccess);
    source.value.reset();
    const auto noProof = bus.GetSpeedDecision(NodeId{0});
    EXPECT_FALSE(noProof.learnedSuccess);
    EXPECT_EQ(FwSpeed::S400, noProof.selected);
}

TEST_F(LinkSpeedClamp, LocalNodeMismatchCannotReuseTopologyObserver) {
    SeedChain(7, 2);
    async.GetGenerationTracker().OnSelfIDComplete(0xFFC1u);
    ASFW::Async::FireWireBusImpl bus(async, topo);
    EXPECT_EQ(FwSpeed::S100, bus.GetSpeed(NodeId{0}));
    EXPECT_FALSE(bus.GetSpeedDecision(NodeId{0}).topologyValid);
}

TEST_F(LinkSpeedClamp, ResetDuringSuccessfulSpeedLookupInvalidatesWholeDecision) {
    class ResetOnLookup final : public ASFW::Async::ILinkSpeedSource {
      public:
        explicit ResetOnLookup(ASFW::Async::AsyncSubsystem& bus) : bus_(bus) {}
        std::optional<FwSpeed> SuccessfulSpeed(Generation, NodeId) const noexcept override {
            ++calls;
            bus_.GetGenerationTracker().OnConfirmedBusGeneration(8);
            return FwSpeed::S400;
        }
        mutable unsigned calls{0};
        ASFW::Async::AsyncSubsystem& bus_;
    } source(async);
    SeedChain(7, 2);
    ASFW::Async::FireWireBusImpl bus(async, topo, &source);
    const auto decision = bus.GetSpeedDecision(NodeId{0});
    EXPECT_EQ(1u, source.calls);
    EXPECT_EQ(FwSpeed::S100, decision.selected);
    EXPECT_FALSE(decision.topologyValid);
    EXPECT_FALSE(decision.learnedSuccess);
}

TEST(SpeedPolicyEvidence, TimeoutFallbackIsNotSuccessfulSpeedEvidence) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation generation{9};
    const uint64_t epoch = policy.BeginGeneration(generation);
    ASSERT_NE(0u, epoch);

    ASSERT_TRUE(policy.RecordTimeout(generation, epoch, 3, FwSpeed::S400));
    EXPECT_EQ(FwSpeed::S200, policy.ForNode(generation, epoch, 3).localToNode);
    EXPECT_FALSE(policy.SuccessfulSpeed(generation, NodeId{3}).has_value());
}

TEST(SpeedPolicyEvidence, ResetRejectsLateCallbackAndReusedNode) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation oldGeneration{11};
    const uint64_t oldEpoch = policy.BeginGeneration(oldGeneration);
    ASSERT_TRUE(policy.RecordSuccess(oldGeneration, oldEpoch, 4, FwSpeed::S200));

    policy.InvalidateForBusReset();
    const Generation newGeneration{12};
    const uint64_t newEpoch = policy.BeginGeneration(newGeneration);
    ASSERT_NE(0u, newEpoch);
    ASSERT_NE(oldEpoch, newEpoch);

    EXPECT_FALSE(policy.RecordSuccess(oldGeneration, oldEpoch, 4, FwSpeed::S100));
    EXPECT_FALSE(policy.SuccessfulSpeed(newGeneration, NodeId{4}).has_value());
    EXPECT_EQ(FwSpeed::S400, policy.ForNode(newGeneration, newEpoch, 4).localToNode);
}

TEST(SpeedPolicyEvidence, NewScanEpochRejectsLateCallbackWhenWireGenerationRepeats) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation repeatedGeneration{0};
    const uint64_t firstEpoch = policy.BeginGeneration(repeatedGeneration);
    ASSERT_TRUE(policy.RecordSuccess(repeatedGeneration, firstEpoch, 5, FwSpeed::S200));

    // Models a same-generation rescan and also the finite wire-generation wrap
    // case. The software epoch, not generation alone, is the callback authority.
    const uint64_t secondEpoch = policy.BeginGeneration(repeatedGeneration);
    ASSERT_NE(firstEpoch, secondEpoch);
    EXPECT_FALSE(
        policy.RecordSuccess(repeatedGeneration, firstEpoch, 5, FwSpeed::S100));
    ASSERT_EQ(FwSpeed::S200,
              policy.SuccessfulSpeed(repeatedGeneration, NodeId{5}).value());

    ASSERT_TRUE(
        policy.RecordSuccess(repeatedGeneration, secondEpoch, 5, FwSpeed::S400));
    ASSERT_EQ(FwSpeed::S400,
              policy.SuccessfulSpeed(repeatedGeneration, NodeId{5}).value());
}

TEST(SpeedPolicyEvidence, ResetThenRepeatedWireGenerationRejectsOldCallback) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation wrappedGeneration{0};
    const uint64_t oldEpoch = policy.BeginGeneration(wrappedGeneration);
    ASSERT_TRUE(policy.RecordSuccess(wrappedGeneration, oldEpoch, 5, FwSpeed::S200));

    policy.InvalidateForBusReset();
    const uint64_t newEpoch = policy.BeginGeneration(wrappedGeneration);
    ASSERT_NE(oldEpoch, newEpoch);
    EXPECT_FALSE(policy.RecordSuccess(wrappedGeneration, oldEpoch, 5, FwSpeed::S100));
    EXPECT_FALSE(policy.SuccessfulSpeed(wrappedGeneration, NodeId{5}).has_value());

    ASSERT_TRUE(policy.RecordSuccess(wrappedGeneration, newEpoch, 5, FwSpeed::S400));
    EXPECT_EQ(FwSpeed::S400,
              policy.SuccessfulSpeed(wrappedGeneration, NodeId{5}).value());
}

TEST(SpeedPolicyEvidence, SameGenerationTargetedRescanPreservesOtherNodeEvidence) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation generation{31};
    const uint64_t firstEpoch = policy.BeginGeneration(generation);
    ASSERT_TRUE(policy.RecordSuccess(generation, firstEpoch, 1, FwSpeed::S200));
    ASSERT_TRUE(policy.RecordSuccess(generation, firstEpoch, 2, FwSpeed::S100));

    const uint64_t rescanEpoch = policy.BeginGeneration(generation);
    ASSERT_NE(firstEpoch, rescanEpoch);
    EXPECT_EQ(FwSpeed::S200, policy.SuccessfulSpeed(generation, NodeId{1}).value());
    EXPECT_EQ(FwSpeed::S100, policy.SuccessfulSpeed(generation, NodeId{2}).value());
    EXPECT_FALSE(policy.RecordTimeout(generation, firstEpoch, 1, FwSpeed::S200));
}

TEST(SpeedPolicyEvidence, ConcurrentReadersAndWritersRemainBoundToOneEpoch) {
    ASFW::Discovery::SpeedPolicy policy;
    const Generation generation{21};
    const uint64_t epoch = policy.BeginGeneration(generation);
    ASSERT_NE(0u, epoch);

    std::atomic<bool> start{false};
    std::vector<std::thread> workers;
    for (uint8_t node = 0; node < 8; ++node) {
        workers.emplace_back([&, node] {
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            for (size_t i = 0; i < 200; ++i) {
                (void)policy.RecordTimeout(generation, epoch, node, FwSpeed::S400);
                (void)policy.RecordSuccess(generation, epoch, node, FwSpeed::S200);
                (void)policy.ForNode(generation, epoch, node);
                (void)policy.SuccessfulSpeed(generation, NodeId{node});
            }
        });
    }

    start.store(true, std::memory_order_release);
    for (auto& worker : workers) {
        worker.join();
    }

    for (uint8_t node = 0; node < 8; ++node) {
        const auto learned = policy.SuccessfulSpeed(generation, NodeId{node});
        ASSERT_TRUE(learned.has_value());
        EXPECT_EQ(FwSpeed::S200, *learned);
    }
}

} // namespace
