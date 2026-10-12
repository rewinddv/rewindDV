// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Rewind Digital
// Exercises the production IRMClient, including delayed and ambiguous outcomes.
#include <gtest/gtest.h>
#include "ASFWDriver/Bus/IRM/IRMClient.hpp"
#include <array>
#include <deque>
#include <map>

namespace {
using namespace ASFW;
using IRM::AllocationStatus;
using IRM::ResourceOwnership;
using IRM::ResourceFailureCause;
using IRM::ResourceOperationStage;
using Async::AsyncStatus;
constexpr uint32_t bw = IRM::IRMRegisters::kBandwidthAvailable;
constexpr uint32_t channels = IRM::IRMRegisters::kChannelsAvailable31_0;
constexpr uint32_t bit = 0x10000000; // channel 3

struct Bus final : Async::IFireWireBus {
    std::map<uint32_t, uint32_t> regs{{bw, 3000}, {channels, 0xFFFFFFFFu & ~bit}};
    std::map<uint32_t, std::deque<AsyncStatus>> readResults;
    std::map<uint32_t, unsigned> conflictsRemaining;
    std::deque<AsyncStatus> lockResults;
    AsyncStatus lockResult{AsyncStatus::kSuccess};
    bool applyLostLock{false}, deferRead{false}, deferLock{false}, conflictOnce{false}, conflictAlways{false};
    std::function<void()> pending;
    FW::Generation generation{7};
    unsigned reads{0}, locks{0};
    bool rejectRead{false}, rejectLock{false}, resetOnReject{false};
    static std::array<uint8_t, 4> wire(uint32_t n) {
        return {uint8_t(n >> 24), uint8_t(n >> 16), uint8_t(n >> 8), uint8_t(n)};
    }
    static uint32_t number(std::span<const uint8_t> b) {
        return uint32_t(b[0]) << 24 | uint32_t(b[1]) << 16 | uint32_t(b[2]) << 8 | b[3];
    }
    Async::AsyncHandle ReadBlock(FW::Generation gen, FW::NodeId node, Async::FWAddress address,
        uint32_t length, FW::FwSpeed speed, Async::InterfaceCompletionCallback cb) override {
        ++reads;
        if (rejectRead) {
            if (resetOnReject) generation = FW::Generation{8};
            return {};
        }
        EXPECT_EQ(gen.value, generation.value);
        EXPECT_EQ(node.value, 2);
        EXPECT_EQ(speed, FW::FwSpeed::S100);
        EXPECT_EQ(length, 4u);
        auto& results = readResults[address.addressLo];
        auto status = results.empty() ? AsyncStatus::kSuccess : results.front();
        if (!results.empty()) results.pop_front();
        auto complete = [cb = std::move(cb), status, value = regs[address.addressLo]] {
            cb(status, wire(value));
        };
        if (deferRead) pending = std::move(complete); else complete();
        return Async::AsyncHandle{reads + locks};
    }
    Async::AsyncHandle WriteBlock(FW::Generation, FW::NodeId, Async::FWAddress,
        std::span<const uint8_t>, FW::FwSpeed, Async::InterfaceCompletionCallback) override {
        ADD_FAILURE() << "IRM must never submit a write transaction";
        return {};
    }
    Async::AsyncHandle Lock(FW::Generation gen, FW::NodeId node, Async::FWAddress address,
        FW::LockOp op, std::span<const uint8_t> operands, uint32_t length,
        FW::FwSpeed speed, Async::InterfaceCompletionCallback cb) override {
        ++locks;
        if (rejectLock) {
            if (resetOnReject) generation = FW::Generation{8};
            return {};
        }
        EXPECT_EQ(gen.value, generation.value);
        EXPECT_EQ(node.value, 2);
        EXPECT_EQ(speed, FW::FwSpeed::S100);
        EXPECT_EQ(op, FW::LockOp::kCompareSwap);
        EXPECT_EQ(length, 4u);
        uint32_t& reg = regs[address.addressLo];
        uint32_t old = reg;
        const auto status = lockResults.empty() ? std::exchange(lockResult, AsyncStatus::kSuccess)
                                                : lockResults.front();
        if (!lockResults.empty()) lockResults.pop_front();
        if (conflictsRemaining[address.addressLo] > 0) {
            --conflictsRemaining[address.addressLo];
            old ^= 1;
        } else if (conflictAlways) old ^= 1;
        else if (conflictOnce) { old ^= 1; conflictOnce = false; }
        else if ((status == AsyncStatus::kSuccess || applyLostLock) && old == number(operands))
            reg = number(operands.subspan(4));
        auto complete = [cb = std::move(cb), status, old] { cb(status, wire(old)); };
        if (deferLock) pending = std::move(complete); else complete();
        return Async::AsyncHandle{reads + locks};
    }
    bool Cancel(Async::AsyncHandle) override { return false; }
    FW::FwSpeed GetSpeed(FW::NodeId) const override { return FW::FwSpeed::S400; }
    uint32_t HopCount(FW::NodeId, FW::NodeId) const override { return 0; }
    uint8_t GetGapCount() const override { return 63; }
    FW::Generation GetGeneration() const override { return generation; }
    FW::NodeId GetLocalNodeID() const override { return FW::NodeId{1}; }
    void finish() { auto f = std::move(pending); ASSERT_TRUE(f); f(); }
};

struct IRMClientHardening : testing::Test {
    Bus bus;
    IRM::IRMClient client{bus};
    AllocationStatus result{AllocationStatus::Failed};
    ResourceOwnership ownership{ResourceOwnership::Uncertain};
    IRM::ResourceOperationEvidence evidence{};
    unsigned completions{0};
    IRMClientHardening() { client.SetIRMNode(2, IRM::Generation{7}); }
    auto done() { return [this](AllocationStatus s) { result = s; ++completions; }; }
    auto owned() { return [this](AllocationStatus s, ResourceOwnership o) {
        result = s; ownership = o; ++completions;
    }; }
    auto detailed() { return [this](AllocationStatus s, ResourceOwnership o,
                                    IRM::ResourceOperationEvidence e) {
        result = s; ownership = o; evidence = e; ++completions;
    }; }
    void release() { client.ReleaseResourcesForGeneration(3, 400, 4915, IRM::Generation{7}, owned()); }
};

TEST_F(IRMClientHardening, ReadTimeoutRetriesAreBoundedAndS100) {
    bus.readResults[bw] = {AsyncStatus::kTimeout, AsyncStatus::kTimeout, AsyncStatus::kTimeout};
    client.AllocateBandwidth(400, done());
    EXPECT_EQ(result, AllocationStatus::Success);
    EXPECT_EQ(bus.reads, 4u); EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(completions, 1u);
}

TEST_F(IRMClientHardening, RejectedReadCompletesWithoutMutatingResources) {
    bus.rejectRead = true;
    client.AllocateBandwidth(400, done());
    EXPECT_EQ(completions, 1u);
    EXPECT_EQ(result, AllocationStatus::Failed);
    EXPECT_EQ(bus.reads, 1u); EXPECT_EQ(bus.locks, 0u);
    EXPECT_EQ(bus.regs[bw], 3000u);
}

TEST_F(IRMClientHardening, RejectedLockCompletesAndNextRequestCanSucceed) {
    bus.rejectLock = true;
    client.AllocateBandwidth(400, done());
    EXPECT_EQ(completions, 1u);
    EXPECT_EQ(result, AllocationStatus::Failed);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(bus.regs[bw], 3000u);
    bus.rejectLock = false;
    client.AllocateBandwidth(400, done());
    EXPECT_EQ(completions, 2u);
    EXPECT_EQ(result, AllocationStatus::Success);
    EXPECT_EQ(bus.regs[bw], 2600u);
}

TEST_F(IRMClientHardening, RejectionDuringResetReportsGenerationMismatch) {
    for (bool rejectRead : {true, false}) {
        bus.generation = FW::Generation{7};
        bus.rejectRead = rejectRead; bus.rejectLock = !rejectRead;
        bus.resetOnReject = true;
        client.AllocateBandwidth(400, done());
        EXPECT_EQ(result, AllocationStatus::GenerationMismatch);
    }
    EXPECT_EQ(completions, 2u);
    EXPECT_EQ(bus.regs[bw], 3000u);
}

TEST_F(IRMClientHardening, DetailedChannelOccupiedPreservesLegacyStatusAndExactBranch) {
    static_assert(static_cast<uint8_t>(AllocationStatus::Success) == 0);
    static_assert(static_cast<uint8_t>(AllocationStatus::NoResources) == 1);
    static_assert(static_cast<uint8_t>(AllocationStatus::GenerationMismatch) == 2);
    static_assert(static_cast<uint8_t>(AllocationStatus::Timeout) == 3);
    static_assert(static_cast<uint8_t>(AllocationStatus::NotFound) == 4);
    static_assert(static_cast<uint8_t>(AllocationStatus::Failed) == 5);

    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::NoResources);
    EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::ChannelOccupied);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::ChannelRead);
    EXPECT_EQ(evidence.terminalStage, ResourceOperationStage::ChannelRead);
    EXPECT_EQ(evidence.observedChannelRegister, 0xFFFFFFFFu & ~bit);
    EXPECT_NE(evidence.validFields & IRM::kObservedChannelRegisterValid, 0);
    EXPECT_EQ(evidence.validFields & IRM::kCompareProposalValid, 0);
    EXPECT_EQ(bus.locks, 0u);
}

TEST_F(IRMClientHardening, DetailedBandwidthShortRetainsPrimaryCauseThroughRollback) {
    bus.regs[channels] |= bit;
    bus.regs[bw] = 399;
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::NoResources);
    EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::InsufficientBandwidth);
    EXPECT_EQ(evidence.cleanupCause, ResourceFailureCause::None);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::BandwidthRead);
    EXPECT_EQ(evidence.terminalStage, ResourceOperationStage::ChannelRollback);
    EXPECT_EQ(evidence.observedBandwidthAvailable, 399u);
    EXPECT_NE(evidence.validFields & IRM::kObservedBandwidthAvailableValid, 0);
    EXPECT_NE(bus.regs[channels] & bit, 0u);
}

TEST_F(IRMClientHardening, ConfirmedCASContentionExhaustionIsDistinctFromTransportFailure) {
    bus.regs[channels] |= bit;
    bus.conflictAlways = true;
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::NoResources);
    EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::ContentionExhausted);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::ChannelCompareSwap);
    EXPECT_EQ(evidence.compareStage, ResourceOperationStage::ChannelCompareSwap);
    EXPECT_NE(evidence.validFields & IRM::kCompareProposalValid, 0);
    EXPECT_NE(evidence.validFields & IRM::kCompareResponseValid, 0);
    EXPECT_EQ(bus.locks, 1u);
}

TEST_F(IRMClientHardening, LostCASResponseIsUncertainAndHasNoCompareResponseValue) {
    bus.regs[channels] |= bit;
    bus.lockResult = AsyncStatus::kTimeout;
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::Timeout);
    EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::TransportUncertain);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::ChannelCompareSwap);
    EXPECT_NE(evidence.validFields & IRM::kCompareProposalValid, 0);
    EXPECT_EQ(evidence.validFields & IRM::kCompareResponseValid, 0);
    EXPECT_EQ(bus.locks, 1u);
}

TEST_F(IRMClientHardening, RollbackFailureRetainsPrimaryBandwidthCauseAndUncertainOwnership) {
    bus.regs[channels] |= bit;
    bus.regs[bw] = 399;
    bus.readResults[channels] = {AsyncStatus::kSuccess, AsyncStatus::kTimeout};
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::NoResources);
    EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::InsufficientBandwidth);
    EXPECT_EQ(evidence.cleanupCause, ResourceFailureCause::RollbackFailed);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::BandwidthRead);
    EXPECT_EQ(evidence.terminalStage, ResourceOperationStage::ChannelRollback);
}

TEST_F(IRMClientHardening, RollbackGenerationChangeRetainsPrimaryCauseAndRecordsCleanupCause) {
    bus.regs[channels] |= bit;
    bus.regs[bw] = 399;
    bus.readResults[channels] = {AsyncStatus::kSuccess,
                                 AsyncStatus::kStaleGeneration};
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch);
    EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::InsufficientBandwidth);
    EXPECT_EQ(evidence.cleanupCause, ResourceFailureCause::RouteInvalidated);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::BandwidthRead);
    EXPECT_EQ(evidence.terminalStage, ResourceOperationStage::ChannelRollback);
}

TEST_F(IRMClientHardening, LostBandwidthCASIsUncertainAtExactStageWithoutResponseValue) {
    bus.regs[channels] |= bit;
    bus.lockResults = {AsyncStatus::kSuccess, AsyncStatus::kTimeout};
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::Timeout);
    EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::TransportUncertain);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::BandwidthCompareSwap);
    EXPECT_EQ(evidence.compareStage, ResourceOperationStage::BandwidthCompareSwap);
    EXPECT_NE(evidence.validFields & IRM::kCompareProposalValid, 0);
    EXPECT_EQ(evidence.validFields & IRM::kCompareResponseValid, 0);
}

TEST_F(IRMClientHardening, StaleAdmissionHasNoFabricatedObservedValues) {
    bus.generation = FW::Generation{8};
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed(), IRM::RetryPolicy::None());
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch);
    EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::RouteInvalidated);
    EXPECT_EQ(evidence.failureStage, ResourceOperationStage::Admission);
    EXPECT_EQ(evidence.validFields, 0);
    EXPECT_EQ(bus.reads, 0u);
    EXPECT_EQ(bus.locks, 0u);
}

TEST_F(IRMClientHardening, DetailedEvidenceCountsOnlyRetriesActuallyScheduled) {
    bus.regs[channels] |= bit;
    bus.conflictsRemaining[channels] = 1;
    bus.conflictsRemaining[bw] = 1;
    client.AllocateResourcesDetailedForGeneration(
        3, 400, IRM::Generation{7}, detailed());
    EXPECT_EQ(result, AllocationStatus::Success);
    EXPECT_EQ(ownership, ResourceOwnership::Owned);
    EXPECT_EQ(evidence.cause, ResourceFailureCause::None);
    EXPECT_EQ(evidence.terminalStage, ResourceOperationStage::Complete);
    EXPECT_EQ(evidence.contentionRetriesUsed, 2);
    EXPECT_EQ(bus.locks, 4u);
}
TEST_F(IRMClientHardening, ReadBudgetExhaustionAndNoneNeverMutate) {
    bus.readResults[bw] = std::deque<AsyncStatus>(8, AsyncStatus::kTimeout);
    client.ReleaseBandwidth(400, done());
    EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(bus.reads, 4u);
    client.ReleaseBandwidth(400, done(), IRM::RetryPolicy::None());
    EXPECT_EQ(bus.reads, 5u); EXPECT_EQ(bus.locks, 0u); EXPECT_EQ(completions, 2u);
}
TEST_F(IRMClientHardening, ChannelReadAlsoRetries) {
    bus.readResults[channels] = {AsyncStatus::kTimeout};
    client.ReleaseChannel(3, done());
    EXPECT_EQ(result, AllocationStatus::Success); EXPECT_EQ(bus.reads, 2u);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, ConfirmedContentionStillRetries) {
    bus.conflictOnce = true;
    client.ReleaseBandwidth(400, done());
    EXPECT_EQ(result, AllocationStatus::Success);
    EXPECT_EQ(bus.locks, 2u); EXPECT_EQ(bus.regs[bw], 3400u);
}
TEST_F(IRMClientHardening, LostBandwidthResponseNeverDoubleCreditsEvenAfterOtherNodeChangesValue) {
    bus.lockResult = AsyncStatus::kTimeout; bus.applyLostLock = true; bus.deferLock = true;
    client.ReleaseBandwidth(400, done());
    ASSERT_EQ(bus.regs[bw], 3400u);
    bus.regs[bw] = 3100; // another allocator intervenes before the timeout arrives
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(bus.regs[bw], 3100u);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(bus.reads, 1u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, LostChannelResponseNeverFreesAnotherNodesNewReservation) {
    bus.lockResult = AsyncStatus::kTimeout; bus.applyLostLock = true; bus.deferLock = true;
    client.ReleaseChannel(3, done());
    bus.regs[channels] &= ~bit; // another node acquires the released channel
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(bus.regs[channels] & bit, 0u);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, DroppedAndAppliedAllocationLocksRemainUncertain) {
    for (bool applied : {false, true}) {
        bus.regs[channels] |= bit; bus.applyLostLock = applied; bus.lockResult = AsyncStatus::kTimeout;
        client.AllocateResourcesForGeneration(3, 400, IRM::Generation{7}, owned());
        EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    }
    EXPECT_EQ(bus.locks, 2u); EXPECT_EQ(bus.regs[bw], 3000u); EXPECT_EQ(completions, 2u);
}
TEST_F(IRMClientHardening, SuccessfulReadAfterRouteChangeIsRejectedBeforeCAS) {
    bus.deferRead = true;
    client.AllocateBandwidth(400, done());
    client.SetIRMNode(3, IRM::Generation{7});
    client.SetIRMNode(2, IRM::Generation{7}); // same tuple returns: epoch must still reject
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(bus.locks, 0u);
}
TEST_F(IRMClientHardening, SuccessfulLockAfterResetPublicationCannotClaimOwnership) {
    bus.deferLock = true;
    bus.regs[channels] |= bit;
    client.AllocateResourcesForGeneration(3, 400, IRM::Generation{7}, owned());
    client.SetIRMNode(2, IRM::Generation{7}, 1234);
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(bus.regs[bw], 3000u);
}
TEST_F(IRMClientHardening, DroppedBandwidthReleaseStillCleansChannelWithoutCreditingBandwidth) {
    bus.lockResult = AsyncStatus::kTimeout;
    release();
    EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_EQ(bus.regs[bw], 3000u); EXPECT_NE(bus.regs[channels] & bit, 0u);
    EXPECT_EQ(bus.locks, 2u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, SuccessfulDeferredLockAfterGenerationChangeDoesNotContinueCleanup) {
    bus.deferLock = true;
    release();
    bus.generation = FW::Generation{8};
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(bus.reads, 1u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, BusGenerationDriftAndReportedStaleGenerationNeverRetry) {
    bus.deferRead = true;
    bus.readResults[bw] = {AsyncStatus::kTimeout};
    client.ReleaseBandwidth(400, done());
    bus.generation = FW::Generation{8}; bus.finish();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(bus.reads, 1u);
    bus.generation = FW::Generation{7}; bus.deferRead = false;
    bus.readResults[bw] = {AsyncStatus::kStaleGeneration};
    release();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(bus.reads, 2u);
    EXPECT_EQ(bus.locks, 0u); EXPECT_EQ(ownership, ResourceOwnership::None);
}
TEST_F(IRMClientHardening, BandwidthFailureStillReleasesChannelAndRetainsFirstFailure) {
    bus.readResults[bw] = std::deque<AsyncStatus>(4, AsyncStatus::kTimeout);
    release();
    EXPECT_EQ(result, AllocationStatus::Timeout); EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_NE(bus.regs[channels] & bit, 0u); EXPECT_EQ(bus.locks, 1u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, GenerationFailureDuringChannelCleanupSupersedesBandwidthFailure) {
    bus.readResults[bw] = {AsyncStatus::kHardwareError};
    bus.readResults[channels] = {AsyncStatus::kStaleGeneration};
    release();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(ownership, ResourceOwnership::None);
    EXPECT_EQ(bus.locks, 0u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, ChannelCleanupFailurePreservesEarlierBandwidthFailure) {
    bus.readResults[bw] = {AsyncStatus::kHardwareError};
    bus.readResults[channels] = std::deque<AsyncStatus>(4, AsyncStatus::kTimeout);
    release();
    EXPECT_EQ(result, AllocationStatus::Failed); EXPECT_EQ(ownership, ResourceOwnership::Uncertain);
    EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, InvalidChannelRejectedBeforeIO) {
    client.ReleaseResourcesForGeneration(64, 400, 4915, IRM::Generation{7}, owned());
    EXPECT_EQ(result, AllocationStatus::Failed); EXPECT_EQ(bus.reads, 0u); EXPECT_EQ(bus.locks, 0u);
}
TEST_F(IRMClientHardening, LocalCSRReadsRetryButLocalLocksDoNotReplay) {
    using Status = Driver::LocalCSRLockResult::Status;
    unsigned localReads = 0, localLocks = 0;
    IRM::IRMClient local{bus, {
        [&](uint32_t) -> Driver::LocalCSRReadResult {
            ++localReads;
            return {localReads <= 3 ? Status::Timeout : Status::Success, 3000};
        },
        [&](uint32_t, uint32_t, uint32_t) -> Driver::LocalCSRLockResult {
            ++localLocks;
            return {Status::Timeout, 0, false};
        }
    }};
    local.SetIRMNode(1, IRM::Generation{7});
    local.ReleaseBandwidth(400, done());
    EXPECT_EQ(result, AllocationStatus::Timeout);
    EXPECT_EQ(localReads, 4u); EXPECT_EQ(localLocks, 1u);
    EXPECT_EQ(bus.reads, 0u); EXPECT_EQ(bus.locks, 0u); EXPECT_EQ(completions, 1u);
}
TEST_F(IRMClientHardening, SnapshotRejectsRouteChangeDuringSecondRead) {
    bus.deferRead = true;
    client.ReadResourcesSnapshot([this](AllocationStatus s, IRM::ResourceSnapshot snapshot) {
        result = s; ++completions;
        EXPECT_EQ(snapshot.bandwidthAvailable, 0u);
    });
    bus.finish(); // second read pending
    client.SetIRMNode(2, IRM::Generation{7}, 1234);
    bus.finish();
    EXPECT_EQ(result, AllocationStatus::GenerationMismatch); EXPECT_EQ(bus.reads, 2u);
    EXPECT_EQ(completions, 1u); EXPECT_EQ(bus.locks, 0u);
}
} // namespace
