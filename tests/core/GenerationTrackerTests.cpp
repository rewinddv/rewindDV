// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include <gtest/gtest.h>
#include "ASFWDriver/Bus/GenerationTracker.hpp"

namespace ASFW::Async::Bus {
class GenerationTrackerTestPeer {
public:
    static void SeedPreviousConfirmation(GenerationTracker& tracker, uint32_t previous) {
        tracker.lastConfirmedRequest_ = previous;
        tracker.hasConfirmedRequest_ = true;
        tracker.OnBusResetObserved();
    }
};
}
using ASFW::Async::Bus::GenerationTracker;
using ASFW::Async::Bus::GenerationTrackerTestPeer;

TEST(RequestGeneration, ZeroRequiresConfirmationAndResetRevokesItImmediately) {
    ASFW::Async::LabelAllocator labels;
    GenerationTracker tracker(labels);
    EXPECT_FALSE(tracker.GetCurrentState().requestGenerationValid);
    tracker.OnConfirmedBusGeneration(0);
    EXPECT_TRUE(tracker.GetCurrentState().requestGenerationValid);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, 0U);
    tracker.OnBusResetObserved();
    EXPECT_FALSE(tracker.GetCurrentState().requestGenerationValid);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, UINT32_MAX);
}
TEST(RequestGeneration, RawAndInternalWrapDoNotRepeatRequestIdentity) {
    ASFW::Async::LabelAllocator labels;
    GenerationTracker tracker(labels);
    tracker.OnConfirmedBusGeneration(254);
    for (uint32_t generation = 255; generation <= 1025; ++generation) {
        tracker.OnBusResetObserved();
        tracker.OnConfirmedBusGeneration(static_cast<uint8_t>(generation));
        const auto state = tracker.GetCurrentState();
        ASSERT_TRUE(state.requestGenerationValid);
        EXPECT_EQ(state.requestGeneration, generation);
        EXPECT_EQ(state.generation8, static_cast<uint8_t>(generation));
        EXPECT_EQ(state.generation16, generation & 0x3FFU);
    }
}
TEST(RequestGeneration, StableDuplicateIsIdempotentButRepeatedRawAfterResetIsNew) {
    ASFW::Async::LabelAllocator labels;
    GenerationTracker tracker(labels);
    tracker.OnConfirmedBusGeneration(7);
    tracker.OnConfirmedBusGeneration(7);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, 7U);
    tracker.OnBusResetObserved();
    tracker.OnBusResetObserved();
    tracker.OnConfirmedBusGeneration(7);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, 263U);
    tracker.OnConfirmedBusGeneration(7);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, 263U);
}
TEST(RequestGeneration, ExhaustionNeverReissuesAnOldIdentityUntilRuntimeReset) {
    ASFW::Async::LabelAllocator labels;
    GenerationTracker tracker(labels);
    GenerationTrackerTestPeer::SeedPreviousConfirmation(tracker, UINT32_MAX - 2);
    tracker.OnConfirmedBusGeneration(254);
    EXPECT_EQ(tracker.GetCurrentState().requestGeneration, UINT32_MAX - 1);
    ASSERT_TRUE(tracker.GetCurrentState().requestGenerationValid);
    tracker.OnBusResetObserved();
    tracker.OnConfirmedBusGeneration(255);
    EXPECT_FALSE(tracker.GetCurrentState().requestGenerationValid);
    tracker.OnBusResetObserved();
    tracker.OnConfirmedBusGeneration(0);
    EXPECT_FALSE(tracker.GetCurrentState().requestGenerationValid);
    tracker.Reset();
    EXPECT_FALSE(tracker.GetCurrentState().requestGenerationValid);
    tracker.OnConfirmedBusGeneration(0);
    EXPECT_TRUE(tracker.GetCurrentState().requestGenerationValid);
}
