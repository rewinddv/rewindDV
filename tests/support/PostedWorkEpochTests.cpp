#include <gtest/gtest.h>
#include <latch>
#include <thread>
#include "ASFWDriver/Shared/Completion/PostedWorkEpoch.hpp"

using ASFW::Shared::PostedWorkEpoch;

TEST(PostedWorkEpoch, ConcurrentEnteredWorkPreventsReleaseUntilLeaseLeaves) {
    PostedWorkEpoch epoch;
    std::latch entered(1), retireChecked(1);
    std::thread callback([&] {
        PostedWorkEpoch::Lease lease(epoch);
        EXPECT_TRUE(lease);
        entered.count_down();
        retireChecked.wait();
    });
    entered.wait();
    epoch.Retire();
    EXPECT_FALSE(epoch.Quiesced());
    EXPECT_FALSE(epoch.TryEnter());
    retireChecked.count_down();
    callback.join();
    EXPECT_TRUE(epoch.Quiesced());
    EXPECT_FALSE(epoch.TryEnter());
}

TEST(PostedWorkEpoch, SimultaneousAdmissionAndRetirementHaveOneOutcome) {
    for (unsigned iteration = 0; iteration < 1000; ++iteration) {
        PostedWorkEpoch epoch;
        std::latch ready(1), start(1), attempted(1), release(1);
        bool accepted = false;
        std::thread callback([&] {
            ready.count_down();
            start.wait();
            accepted = epoch.TryEnter();
            attempted.count_down();
            release.wait();
            if (accepted) epoch.Leave();
        });
        ready.wait();
        start.count_down();
        epoch.Retire();
        const bool releaseAllowed = epoch.Quiesced();
        attempted.wait();
        EXPECT_FALSE(releaseAllowed && accepted);
        EXPECT_FALSE(epoch.TryEnter());
        release.count_down();
        callback.join();
        EXPECT_TRUE(epoch.Quiesced());
    }
}
