#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>

#include "ASFWDriver/Async/AsyncSubsystem.hpp"
#include "ASFWDriver/Async/FireWireBusImpl.hpp"
#include "ASFWDriver/Async/Track/Tracking.hpp"
#include "ASFWDriver/Bus/GenerationTracker.hpp"
#include "ASFWDriver/Bus/TopologyManager.hpp"
#include "ASFWDriver/ConfigROM/ROMReader.hpp"

namespace {

struct DummyCompletionQueue {};

using namespace ASFW::Async;

// Host-side helper that mirrors the minimal transaction-handle cancellation pattern:
// Extract the transaction, mark cancelled, invoke response handler, free label.
[[nodiscard]] bool CancelTransactionHandleForTest(TransactionManager& txnMgr,
                                                  LabelAllocator& allocator, AsyncHandle handle) {
    if (!allocator.Matches(handle.value)) {
        return false;
    }

    const uint8_t label = static_cast<uint8_t>((handle.value - 1) & 63);
    auto txn = txnMgr.Extract(TLabel{label}, handle.value);
    if (!txn) {
        return false;
    }

    allocator.CompleteLogical(label, true);

    if (!IsTerminalState(txn->state())) {
        txn->TransitionTo(TransactionState::Cancelled, "CancelTransactionHandleForTest");
        txn->InvokeResponseHandler(kIOReturnAborted, 0xFF, {});
    }

    return true;
}

} // namespace

TEST(AsyncBusContract, Cancel_TransactionHandle_FiresExactlyOnceWithAborted) {
    DummyCompletionQueue dummyQueue;

    LabelAllocator allocator;
    allocator.Reset();

    TransactionManager txnMgr;
    auto initRes = txnMgr.Initialize();
    ASSERT_TRUE(initRes) << "TransactionManager::Initialize failed";

    Track_Tracking<DummyCompletionQueue> tracking(&allocator, &txnMgr, dummyQueue);

    std::atomic<uint32_t> called{0};
    AsyncStatus lastStatus = AsyncStatus::kSuccess;

    TxMetadata meta{};
    meta.generation = 1;
    meta.destinationNodeID = 0x0001;
    meta.tCode = 0x0;
    meta.expectedLength = 0;
    meta.callback = [&](AsyncHandle, AsyncStatus status, uint8_t, std::span<const uint8_t>) {
        lastStatus = status;
        called.fetch_add(1, std::memory_order_relaxed);
    };

    const AsyncHandle handle = tracking.RegisterTx(meta);
    ASSERT_TRUE(handle) << "RegisterTx returned invalid handle";

    EXPECT_TRUE(CancelTransactionHandleForTest(txnMgr, allocator, handle));
    EXPECT_EQ(1u, called.load(std::memory_order_relaxed));
    EXPECT_EQ(AsyncStatus::kAborted, lastStatus);
}

TEST(AsyncBusContract, Cancel_UnknownHandle_ReturnsFalse_NoCallback) {
    DummyCompletionQueue dummyQueue;

    LabelAllocator allocator;
    allocator.Reset();

    TransactionManager txnMgr;
    auto initRes = txnMgr.Initialize();
    ASSERT_TRUE(initRes) << "TransactionManager::Initialize failed";

    Track_Tracking<DummyCompletionQueue> tracking(&allocator, &txnMgr, dummyQueue);

    std::atomic<uint32_t> called{0};

    TxMetadata meta{};
    meta.generation = 1;
    meta.destinationNodeID = 0x0001;
    meta.tCode = 0x0;
    meta.expectedLength = 0;
    meta.callback = [&](AsyncHandle, AsyncStatus, uint8_t, std::span<const uint8_t>) {
        called.fetch_add(1, std::memory_order_relaxed);
    };

    // Do not register any transaction for this handle.
    EXPECT_FALSE(CancelTransactionHandleForTest(txnMgr, allocator, AsyncHandle{42}));
    EXPECT_EQ(0u, called.load(std::memory_order_relaxed));
}

TEST(AsyncBusContract, GenerationMismatch_RejectsEveryOperationWithoutCallback) {
    ASFW::Async::AsyncSubsystem async;
    async.GetGenerationTracker().OnConfirmedBusGeneration(10);
    async.HostTest_SetDeferPostedWork(true);

    ASFW::Driver::TopologyManager topo;
    ASFW::Async::FireWireBusImpl bus(async, topo);

    bool called = false;

    const ASFW::FW::Generation current{async.GetBusState().requestGeneration};
    const ASFW::FW::Generation stale{current.value + 1};

    ASFW::Async::FWAddress addr{.nodeID = 0,
        .addressHi = 0xFFFF,
        .addressLo = 0xF0000400};
    std::array<uint8_t, 8> bytes{};
    {
        IFireWireBusOps* adapter = &bus;
        auto completion = [&](AsyncStatus, std::span<const uint8_t>) { called = true; };
        EXPECT_FALSE(adapter->ReadBlock(stale, ASFW::FW::NodeId{1}, addr, 4,
                                        ASFW::FW::FwSpeed::S100, completion));
        EXPECT_FALSE(adapter->WriteBlock(stale, ASFW::FW::NodeId{1}, addr, bytes,
                                         ASFW::FW::FwSpeed::S100, completion));
        EXPECT_FALSE(adapter->Lock(stale, ASFW::FW::NodeId{1}, addr,
                                   ASFW::FW::LockOp::kCompareSwap, bytes, 4,
                                   ASFW::FW::FwSpeed::S100, completion));
    }

    // Must not invoke callback inline on the submit path.
    EXPECT_FALSE(called);

    async.HostTest_DrainPostedWork();

    EXPECT_FALSE(called) << "A rejected handle must not also schedule completion";
}

TEST(AsyncBusContract, StaleROMReadCompletesOnceAfterPostedWorkIsDrained) {
    AsyncSubsystem async;
    async.GetGenerationTracker().OnConfirmedBusGeneration(10);
    async.HostTest_SetDeferPostedWork(true);
    ASFW::Driver::TopologyManager topo;
    FireWireBusImpl bus(async, topo);
    ASFW::Discovery::ROMReader reader(bus);
    unsigned completions = 0;
    reader.ReadQuadletsBE(1, ASFW::FW::Generation{11}, ASFW::FW::FwSpeed::S100,
        0, 1, [&](auto result) {
            ++completions;
            EXPECT_FALSE(result.success);
            EXPECT_TRUE(result.quadletsBE.empty());
        });
    EXPECT_EQ(completions, 1u);
    async.HostTest_DrainPostedWork();
    EXPECT_EQ(completions, 1u);
}

TEST(AsyncBusContract, ReentrantARCompletionPreservesOutstandingATReservation) {
    DummyCompletionQueue dummyQueue;

    LabelAllocator allocator;
    allocator.Reset();

    TransactionManager txnMgr;
    auto initRes = txnMgr.Initialize();
    ASSERT_TRUE(initRes) << "TransactionManager::Initialize failed";

    Track_Tracking<DummyCompletionQueue> tracking(&allocator, &txnMgr, dummyQueue);

    std::optional<AsyncHandle> nestedHandle;

    TxMetadata nestedMeta{};
    nestedMeta.generation = 9;
    nestedMeta.destinationNodeID = 0x0001;
    nestedMeta.tCode = 0x4;
    nestedMeta.expectedLength = 4;
    nestedMeta.completionStrategy = CompletionStrategy::CompleteOnAR;
    nestedMeta.callback = [](AsyncHandle, AsyncStatus, uint8_t, std::span<const uint8_t>) {};

    TxMetadata meta{};
    meta.generation = 9;
    meta.destinationNodeID = 0x0001;
    meta.tCode = 0x4;
    meta.expectedLength = 4;
    meta.completionStrategy = CompletionStrategy::CompleteOnAR;
    meta.callback = [&](AsyncHandle, AsyncStatus status, uint8_t, std::span<const uint8_t>) {
        EXPECT_EQ(AsyncStatus::kSuccess, status);
        if (status == AsyncStatus::kSuccess) nestedHandle = tracking.RegisterTx(nestedMeta);
    };

    const AsyncHandle handle = tracking.RegisterTx(meta);
    ASSERT_TRUE(handle);
    tracking.OnTxPosted(handle, /*nowUsec=*/1000, /*timeoutUsec=*/500000);

    tracking.OnRxResponse(RxResponse{
        .generation = 9,
        .sourceNodeID = 0x0001,
        .destinationNodeID = 0xffc0,
        .tLabel = static_cast<uint8_t>((handle.value - 1) & 63),
        .tCode = 0x6,
        .rCode = 0x0,
        .payload = {},
    });

    EXPECT_TRUE(nestedHandle.has_value());
    const uint8_t originalLabel = static_cast<uint8_t>((handle.value - 1) & 63);
    EXPECT_TRUE(allocator.IsLabelInUse(originalLabel)) << "AR cannot retire the old AT program";
    if (nestedHandle) {
        EXPECT_EQ(1u, tracking.GetLabelFromHandle(*nestedHandle));
        EXPECT_NE(handle.value, nestedHandle->value);
        tracking.AbandonUnposted(*nestedHandle);
    }
    TxCompletion completed{};
    completed.tLabel = originalLabel;
    completed.operationIdentity = handle.value;
    completed.eventCode = OHCIEventCode::kAckComplete;
    tracking.OnTxCompletion(completed);
    EXPECT_FALSE(allocator.IsLabelInUse(originalLabel));
    txnMgr.CancelAll(); // Keep failure-path callbacks within the captured locals' lifetime.
}

TEST(AsyncBusContract, OutstandingReservationWithoutTransactionPreservesGeneration) {
    DummyCompletionQueue dummyQueue;

    LabelAllocator allocator;
    allocator.Reset();
    ASFW::Async::Bus::GenerationTracker tracker{allocator};
    tracker.Reset();
    tracker.OnConfirmedBusGeneration(10);

    TransactionManager txnMgr;
    auto initRes = txnMgr.Initialize();
    ASSERT_TRUE(initRes) << "TransactionManager::Initialize failed";

    Track_Tracking<DummyCompletionQueue> tracking(&allocator, &txnMgr, dummyQueue);

    TxMetadata meta{};
    meta.generation = tracker.GetCurrentState().generation8;
    meta.destinationNodeID = 0x0001;
    meta.tCode = 0x4;
    meta.expectedLength = 4;
    meta.completionStrategy = CompletionStrategy::CompleteOnAR;
    meta.callback = [](AsyncHandle, AsyncStatus, uint8_t, std::span<const uint8_t>) {};

    const AsyncHandle first = tracking.RegisterTx(meta);
    ASSERT_TRUE(first);
    auto firstTxn = txnMgr.Extract(TLabel{static_cast<uint8_t>((first.value - 1) & 63)}, first.value);
    ASSERT_NE(firstTxn, nullptr);

    EXPECT_EQ(10u, tracker.GetCurrentState().generation8);
    EXPECT_EQ(10u, tracker.GetCurrentState().generation16);

    const AsyncHandle second = tracking.RegisterTx(meta);
    ASSERT_TRUE(second);
    EXPECT_TRUE(allocator.IsLabelInUse(static_cast<uint8_t>((first.value - 1) & 63)));
    EXPECT_NE((first.value - 1) & 63, (second.value - 1) & 63);

    EXPECT_EQ(10u, tracker.GetCurrentState().generation8);
    EXPECT_EQ(10u, tracker.GetCurrentState().generation16);
    tracking.RollbackUnpublished(first);
    tracking.AbandonUnposted(second);
}
