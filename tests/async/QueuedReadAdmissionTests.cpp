// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Real queued-read/cancel implementation; controlled transaction Read boundary.
#include <gtest/gtest.h>
#include "ASFWDriver/Async/AsyncSubsystem.hpp"
#include <deque>
#include <thread>
#include "ASFWDriver/Async/Track/QueuedHandleSequence.hpp"

namespace {
using namespace ASFW::Async;
unsigned readAttempts = 0, rejectAttempt = 0;
struct PendingRead { AsyncHandle handle; CompletionCallback callback; };
std::deque<PendingRead> pendingReads;
void FinishRead(AsyncStatus status) {
    ASSERT_FALSE(pendingReads.empty());
    auto pending = std::move(pendingReads.front()); pendingReads.pop_front();
    pending.callback(pending.handle, status, 0xFF, {});
}
class QueuedReadAdmission : public testing::Test {
    void SetUp() override { readAttempts = 0; rejectAttempt = 0; pendingReads.clear(); }
    void TearDown() override { pendingReads.clear(); }
};
}

namespace ASFW::Async {
AsyncHandle AsyncSubsystem::Read(const ReadParams&, CompletionCallback callback) {
    const auto attempt = ++readAttempts;
    if (attempt == rejectAttempt) return {};
    const AsyncHandle handle{attempt};
    pendingReads.push_back({handle, std::move(callback)});
    return handle;
}
}

TEST_F(QueuedReadAdmission, InitialRefusalCompletesAcceptedQueueHandleAndAdvances) {
    AsyncSubsystem subsystem;
    rejectAttempt = 1;
    unsigned failed = 0, succeeded = 0;
    AsyncHandle reported{};
    const auto first = subsystem.ReadWithRetry({}, RetryPolicy::Default(),
        [&](auto handle, auto status, auto, auto) {
            ++failed; reported = handle; EXPECT_EQ(status, AsyncStatus::kHardwareError);
        });
    const auto second = subsystem.ReadWithRetry({}, RetryPolicy::None(),
        [&](auto, auto status, auto, auto) { ++succeeded; EXPECT_EQ(status, AsyncStatus::kSuccess); });
    EXPECT_TRUE(first); EXPECT_TRUE(second); EXPECT_NE(first.value, second.value);
    EXPECT_EQ(failed, 0u); EXPECT_EQ(readAttempts, 1u);
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(failed, 1u); EXPECT_EQ(reported.value, first.value);
    ASSERT_EQ(readAttempts, 2u);
    FinishRead(AsyncStatus::kSuccess);
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(failed, 1u); EXPECT_EQ(succeeded, 1u);
    EXPECT_FALSE(subsystem.Cancel(first)); EXPECT_FALSE(subsystem.Cancel(second));
}

TEST_F(QueuedReadAdmission, RetryRefusalCompletesOnceWithStablePublicHandle) {
    AsyncSubsystem subsystem;
    rejectAttempt = 2;
    unsigned completions = 0;
    AsyncHandle reported{};
    const auto handle = subsystem.ReadWithRetry({}, RetryPolicy::Default(),
        [&](auto h, auto status, auto, auto) {
            ++completions; reported = h; EXPECT_EQ(status, AsyncStatus::kHardwareError);
        });
    ASSERT_TRUE(handle); ASSERT_EQ(pendingReads.size(), 1u);
    FinishRead(AsyncStatus::kTimeout);
    EXPECT_EQ(readAttempts, 2u);
    subsystem.HostTest_DrainPostedWork();
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(completions, 1u); EXPECT_EQ(reported.value, handle.value);
    EXPECT_FALSE(subsystem.Cancel(handle));
}

TEST_F(QueuedReadAdmission, CancellationBeforeRefusalDeliveryCompletesAbortedOnce) {
    AsyncSubsystem subsystem;
    rejectAttempt = 1;
    unsigned completions = 0;
    auto owner = std::make_shared<int>(0);
    std::weak_ptr<int> lifetime = owner;
    const auto handle = subsystem.ReadWithRetry({}, RetryPolicy::None(),
        [&, owner](auto, auto status, auto, auto) {
            ++completions; ++*owner; EXPECT_EQ(status, AsyncStatus::kAborted);
        });
    owner.reset();
    EXPECT_TRUE(subsystem.Cancel(handle));
    subsystem.HostTest_DrainPostedWork();
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(completions, 1u);
    EXPECT_FALSE(subsystem.Cancel(handle));
    EXPECT_TRUE(lifetime.expired());
}

TEST_F(QueuedReadAdmission, AdmittedReadSuccessKeepsOneCompletion) {
    AsyncSubsystem subsystem;
    unsigned completions = 0;
    const auto handle = subsystem.ReadWithRetry({}, RetryPolicy::None(),
        [&](auto, auto status, auto, auto) { ++completions; EXPECT_EQ(status, AsyncStatus::kSuccess); });
    EXPECT_TRUE(handle); EXPECT_EQ(completions, 0u);
    FinishRead(AsyncStatus::kSuccess);
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(completions, 1u); EXPECT_FALSE(subsystem.Cancel(handle));
}


TEST(QueuedHandleSequence, ExhaustionNeverEntersTransactionNamespace) {
    std::atomic<uint32_t> next{UINT32_MAX - 1};
    EXPECT_EQ(ReserveQueuedHandle(next).value, UINT32_MAX - 1);
    EXPECT_EQ(ReserveQueuedHandle(next).value, UINT32_MAX);
    for (unsigned i = 0; i < 128; ++i) EXPECT_FALSE(ReserveQueuedHandle(next));
    EXPECT_EQ(next.load(), 0u);
}

TEST(QueuedHandleSequence, ConcurrentLastIssuanceHasExactlyOneOwner) {
    std::atomic<uint32_t> next{UINT32_MAX};
    std::atomic<unsigned> admitted{0};
    std::vector<std::thread> racers;
    for (unsigned i = 0; i < 8; ++i) racers.emplace_back([&] {
        const auto handle = ReserveQueuedHandle(next);
        if (handle) { EXPECT_EQ(handle.value, UINT32_MAX); ++admitted; }
    });
    for (auto& racer : racers) racer.join();
    EXPECT_EQ(admitted.load(), 1u);
    EXPECT_FALSE(ReserveQueuedHandle(next));
}

TEST_F(QueuedReadAdmission, UncertainWireTimeoutDoesNotReplayQueuedRead) {
    AsyncSubsystem subsystem;
    (void)subsystem.GetGenerationTracker(); // production-owned label allocator
    unsigned completions = 0;
    AsyncHandle handle{};
    handle = subsystem.ReadWithRetry({}, RetryPolicy::Default(),
        [&](auto reported, auto status, auto, auto) {
            ++completions;
            EXPECT_EQ(reported.value, handle.value);
            EXPECT_EQ(status, AsyncStatus::kTimeout);
        });
    ASSERT_TRUE(handle);
    subsystem.FenceUncertainResponse();
    FinishRead(AsyncStatus::kTimeout);
    subsystem.HostTest_DrainPostedWork();
    EXPECT_EQ(readAttempts, 1u);
    EXPECT_EQ(completions, 1u);
    EXPECT_FALSE(subsystem.Cancel(handle));
}
