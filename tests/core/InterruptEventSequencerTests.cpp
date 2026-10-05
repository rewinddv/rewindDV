// SPDX-License-Identifier: Apache-2.0

#include "Controller/InterruptEventSequencer.hpp"
#include "Hardware/RegisterMap.hpp"

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <iostream>

namespace {

using ASFW::Driver::IntEventBits;

struct LatchedResponseFixture {
    uint32_t latchedEvents{IntEventBits::kARRS};
    std::size_t unreadResponseBytes{16};
    uint32_t responseDrains{0};
    bool injectedFollowup{false};

    void Dispatch(uint32_t events) {
        if ((events & IntEventBits::kARRS) == 0U || unreadResponseBytes == 0U) {
            return;
        }

        unreadResponseBytes = 0;
        ++responseDrains;

        // The first response completion callback synchronously submits a
        // follow-up CAS.  Its response lands after the drain has finished but
        // before ControllerCore performs the trailing W1C.
        if (!injectedFollowup) {
            injectedFollowup = true;
            unreadResponseBytes = 32;
            latchedEvents |= IntEventBits::kARRS;
        }
    }

    void Clear(uint32_t mask) { latchedEvents &= ~mask; }
};

void ServiceSnapshot(LatchedResponseFixture& fixture, uint32_t snapshot) {

    ASFW::Driver::InterruptEventSequencer::DispatchAndAcknowledge(
        snapshot,
        0,
        ASFW::Driver::InterruptEventSequencer::kDeferredHardwareAcks,
        [&fixture](uint32_t events) { fixture.Dispatch(events); },
        [] {},
        [&fixture](uint32_t mask) { fixture.Clear(mask); });
}

TEST(InterruptEventSequencerTests,
     ResponseArrivingAfterDrainBeforeCompletionW1CRetainsWakeForSecondDrain) {
    LatchedResponseFixture fixture;

    ServiceSnapshot(fixture, fixture.latchedEvents);
    const bool followupInterruptVisible =
        (fixture.latchedEvents & IntEventBits::kARRS) != 0U;
    if (followupInterruptVisible) {
        ServiceSnapshot(fixture, fixture.latchedEvents);
    }

    std::cout << "followup_interrupt_visible=" << followupInterruptVisible
              << " response_drains=" << fixture.responseDrains
              << " unread_response_bytes=" << fixture.unreadResponseBytes << '\n';

    EXPECT_TRUE(followupInterruptVisible);
    EXPECT_EQ(fixture.responseDrains, 2U);
    EXPECT_EQ(fixture.unreadResponseBytes, 0U);
}

} // namespace

TEST(InterruptEventSequencerTests, SelfIDIsAcknowledgedBeforeAsyncWorkButResetIsPreserved) {
    using namespace ASFW::Driver;
    const uint32_t completions = IntEventBits::kSelfIDComplete | IntEventBits::kSelfIDComplete2;
    uint32_t hardwareLatch = completions | IntEventBits::kBusReset;
    const uint32_t snapshot = hardwareLatch;
    bool dispatched = false;
    InterruptEventSequencer::DispatchAndAcknowledge(snapshot, 0,
        InterruptEventSequencer::kDeferredHardwareAcks,
        [&](uint32_t events) {
            EXPECT_EQ(events, snapshot);
            EXPECT_EQ(hardwareLatch, IntEventBits::kBusReset);
            dispatched = true;
            // A new completion after IRQ acknowledgement must survive all
            // later work in this dispatch pass.
            hardwareLatch |= IntEventBits::kSelfIDComplete2;
        }, [] {}, [&](uint32_t mask) { hardwareLatch &= ~mask; });
    EXPECT_TRUE(dispatched);
    EXPECT_EQ(hardwareLatch, IntEventBits::kBusReset | IntEventBits::kSelfIDComplete2);
}
