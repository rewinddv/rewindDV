// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include <gtest/gtest.h>
#include "ASFWDriver/ConfigROM/ROMScanner.hpp"
#include "ASFWDriver/Discovery/SpeedPolicy.hpp"
#include "DeferredFireWireBus.hpp"

using namespace ASFW;

namespace {
struct ObservedBus : Async::Testing::DeferredFireWireBus {
    std::function<void()> onSpeed;
    FW::FwSpeed GetSpeed(FW::NodeId) const override {
        if (onSpeed) onSpeed();
        return FW::FwSpeed::S100;
    }
};

TEST(ROMScannerLifetime, RetirementDuringSessionBusUseRequiresRetention) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    Discovery::ROMScanner scanner(bus, speed, {}, queue);
    unsigned visits = 0;
    bus.onSpeed = [&] {
        ++visits;
        EXPECT_FALSE(scanner.RetireDeferredWork());
    };
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{1};
    request.targetNodes = {1};
    EXPECT_TRUE(scanner.Start(request, [](auto, auto, auto) {}));
    EXPECT_GT(queue->DrainReadyForTesting(), 0U);
    EXPECT_EQ(visits, 1U);
    EXPECT_TRUE(scanner.RetireDeferredWork());
    EXPECT_FALSE(scanner.Start(request, [](auto, auto, auto) { ADD_FAILURE(); }));
}

TEST(ROMScannerLifetime, CompletionStillCountsAfterCurrentSessionCleared) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    Discovery::ROMScanner scanner(bus, speed, {}, queue);
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{1};
    unsigned completions = 0;
    ASSERT_TRUE(scanner.Start(request, [&](auto, auto, auto) {
        ++completions;
        EXPECT_FALSE(scanner.RetireDeferredWork());
    }));
    EXPECT_GT(queue->DrainReadyForTesting(), 0U);
    EXPECT_EQ(completions, 1U);
    EXPECT_TRUE(scanner.RetireDeferredWork());
}

TEST(ROMScannerLifetime, QueuedSessionCannotReachReleasedBorrowers) {
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    unsigned completions = 0;
    {
        ObservedBus bus;
        Discovery::SpeedPolicy speed;
        auto scanner = std::make_unique<Discovery::ROMScanner>(bus, speed,
            Discovery::ROMScannerParams{}, queue);
        Discovery::ROMScanRequest request;
        request.gen = FW::Generation{1};
        request.targetNodes = {1};
        ASSERT_TRUE(scanner->Start(request, [&](auto, auto, auto) { ++completions; }));
        ASSERT_TRUE(scanner->RetireDeferredWork());
    }
    EXPECT_GT(queue->DrainReadyForTesting(), 0U);
    EXPECT_EQ(completions, 0U);
}

TEST(ROMScannerLifetime, InlineCompletionMayReleaseScanner) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    auto scanner = std::make_unique<Discovery::ROMScanner>(bus, speed, Discovery::ROMScannerParams{});
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{1};
    ASSERT_TRUE(scanner->Start(request, [&](auto, auto, auto) { scanner.reset(); }));
    EXPECT_FALSE(scanner);
}
TEST(ROMScannerGeneration, ZeroIsValidAndCompletesOnce) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    Discovery::ROMScanner scanner(bus, speed, {});
    unsigned completions = 0;
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{0};
    ASSERT_TRUE(scanner.Start(request, [&](auto gen, auto, auto) {
        EXPECT_EQ(gen.value, 0U); ++completions;
    }));
    EXPECT_EQ(completions, 1U);
}

TEST(ROMScannerGeneration, QueuedAdmissionRejectsDuplicateBeforeStartRuns) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    Discovery::ROMScanner scanner(bus, speed, {}, queue);
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{5};
    unsigned completions = 0;
    ASSERT_TRUE(scanner.Start(request, [&](auto, auto, auto) { ++completions; }));
    EXPECT_FALSE(scanner.Start(request, [](auto, auto, auto) { ADD_FAILURE(); }));
    queue->DrainAllForTesting();
    EXPECT_EQ(completions, 1U);
}

TEST(ROMScannerGeneration, AbortQueuedGenerationZeroRevokesBusAdmission) {
    ObservedBus bus;
    Discovery::SpeedPolicy speed;
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    Discovery::ROMScanner scanner(bus, speed, {}, queue);
    Discovery::ROMScanRequest request;
    request.gen = FW::Generation{0};
    request.targetNodes = {1};
    ASSERT_TRUE(scanner.Start(request, [](auto, auto, auto) { ADD_FAILURE(); }));
    scanner.Abort(request.gen);
    queue->DrainAllForTesting();
    EXPECT_EQ(bus.ReadCount(), 0U);
}
} // namespace
