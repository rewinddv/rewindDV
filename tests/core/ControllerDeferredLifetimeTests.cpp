#include <gtest/gtest.h>
#include <algorithm>
#include <condition_variable>
#include "ASFWDriver/Bus/TopologyManager.hpp"
#include <mutex>
#include <thread>
#include "ASFWDriver/Controller/ControllerCore.hpp"
#include "ASFWDriver/Controller/ControllerStateMachine.hpp"
#include "ASFWDriver/Hardware/HardwareInterface.hpp"
#include "ASFWDriver/Hardware/InterruptManager.hpp"
#include "ASFWDriver/Scheduling/Scheduler.hpp"

using namespace ASFW::Driver;
namespace {
struct ControllerRig {
    OSSharedPtr<IODispatchQueue> queue{new IODispatchQueue(), OSNoRetain};
    std::shared_ptr<HardwareInterface> hardware = std::make_shared<HardwareInterface>();
    std::shared_ptr<ControllerCore> controller;
    ControllerRig() {
        queue->SetManualDispatchForTesting(true);
        auto scheduler = std::make_shared<Scheduler>();
        scheduler->Bind(queue);
        ControllerCore::Dependencies deps;
        deps.hardware = hardware;
        deps.topology = std::make_shared<TopologyManager>();
        deps.interrupts = std::make_shared<InterruptManager>();
        deps.scheduler = scheduler;
        deps.stateMachine = std::make_shared<ControllerStateMachine>();
        controller = std::make_shared<ControllerCore>(ControllerConfig{}, RolePolicy{}, std::move(deps));
    }
    void QueueObservation() {
        TopologySnapshot topology;
        topology.generation = 1;
        topology.rootNodeId = 1;
        topology.localNodeId = 0;
        controller->BeginRootCapabilityEvidence(topology, 0);
    }
};

TEST(ControllerDeferredLifetime, DestroyNeverStartedControllerBeforeActualTimer) {
    auto rig = std::make_unique<ControllerRig>();
    rig->QueueObservation();
    auto queue = rig->queue;
    rig.reset();
    EXPECT_GT(queue->DrainAllForTesting(), 0U);
}
TEST(ControllerDeferredLifetime, StopInvalidatesActualTimerWhileOwnerSurvives) {
    ControllerRig rig;
    rig.QueueObservation();
    ASSERT_TRUE(rig.controller->cycleLostWindowActive_);
    rig.controller->Stop();
    EXPECT_GT(rig.queue->DrainAllForTesting(), 0U);
    EXPECT_FALSE(rig.controller->currentRootEvidence_.cycleObservationComplete);
    EXPECT_FALSE(rig.controller->cycleLostWindowActive_);
}
TEST(ControllerDeferredLifetime, ActualTimerCompletesCurrentObservation) {
    ControllerRig rig;
    rig.QueueObservation();
    EXPECT_GT(rig.queue->DrainAllForTesting(), 0U);
    EXPECT_TRUE(rig.controller->currentRootEvidence_.cycleObservationComplete);
}
TEST(ControllerDeferredLifetime, EnteredTimerPreventsOwnerReleaseUntilItReturns) {
    ControllerRig rig;
    rig.QueueObservation();
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false, release = false;
    rig.hardware->SetTestReadHook([&](Register32 reg) {
        if (reg != Register32::kLinkControl) return;
        std::unique_lock lock(mutex);
        entered = true;
        changed.notify_all();
        EXPECT_TRUE(changed.wait_for(lock, std::chrono::seconds(2), [&] { return release; }));
    });
    std::thread delivery([&] { rig.queue->DrainAllForTesting(); });
    {
        std::unique_lock lock(mutex);
        const bool reached = changed.wait_for(lock, std::chrono::seconds(2), [&] { return entered; });
        EXPECT_TRUE(reached);
        if (reached) EXPECT_FALSE(rig.controller->RetireDeferredWork());
        release = true;
        changed.notify_all();
    }
    delivery.join();
    rig.hardware->SetTestReadHook({});
    EXPECT_TRUE(rig.controller->RetireDeferredWork());
}
// Exercise the production final bring-up phase with MMIO replaced by the host
// HardwareInterface. Config ROM/Self-ID preparation has its own component gates;
// these tests deliberately isolate the initial reset owner and its PHY inputs.
size_t ResetAttempts(const ControllerRig& rig) {
    const auto operations = rig.hardware->CopyTestOperations();
    return std::count(operations.begin(), operations.end(),
                      HardwareInterface::TestOperation::InitiateBusReset);
}
TEST(ControllerInitialReset, PhyProgrammingSupportedAndSucceeds) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = true;
    rig.controller->phyConfigOk_ = true;
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
    EXPECT_FALSE(rig.hardware->TestLastBusResetWasShort());
}
TEST(ControllerInitialReset, PhyProgrammingUnsupported) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = false;
    rig.controller->phyConfigOk_ = false;
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
}
TEST(ControllerInitialReset, PhyProgrammingFails) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = true;
    rig.controller->phyConfigOk_ = false;
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
}
TEST(ControllerInitialReset, RepeatedEnableDoesNotRequestAnotherReset) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = true;
    rig.controller->phyConfigOk_ = true;
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
}
TEST(ControllerInitialReset, ExplicitFailureDoesNotInventFreshTopologyOrRetry) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = true;
    rig.controller->phyConfigOk_ = true;
    rig.hardware->SetTestInitiateBusResetResult(false);
    ASSERT_FALSE(rig.controller->deps_.topology->LatestSnapshot().has_value());
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
    EXPECT_FALSE(rig.hardware->TestLastBusResetSucceeded());
    EXPECT_FALSE(rig.controller->deps_.topology->LatestSnapshot().has_value());
    EXPECT_EQ(rig.controller->deps_.stateMachine->CurrentState(), ControllerState::kStopped);
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    EXPECT_EQ(ResetAttempts(rig), 1U);
}
TEST(ControllerInitialReset, LinkAndBIBEnabledBeforeReset) {
    ControllerRig rig;
    rig.controller->phyProgramSupported_ = true;
    rig.controller->phyConfigOk_ = true;
    bool observedLinkEnableWrite = false;
    rig.hardware->SetTestReadHook([&](Register32 reg) {
        if (reg != Register32::kHCControl) return;
        if (observedLinkEnableWrite) return; // Later LogInitSummary read.
        EXPECT_EQ(ResetAttempts(rig), 0U);
        observedLinkEnableWrite = true;
    });
    ASSERT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnSuccess);
    rig.hardware->SetTestReadHook({});
    EXPECT_TRUE(observedLinkEnableWrite);
    const auto bits = HCControlBits::kLinkEnable | HCControlBits::kBibImageValid;
    EXPECT_EQ(rig.hardware->ReadHCControl() & bits, bits);
    EXPECT_EQ(ResetAttempts(rig), 1U);
    const auto operations = rig.hardware->CopyTestOperations();
    const auto reset = std::find(operations.begin(), operations.end(),
                                HardwareInterface::TestOperation::InitiateBusReset);
    ASSERT_NE(reset, operations.end());
    ASSERT_NE(reset, operations.begin());
    EXPECT_EQ(*(reset - 1), HardwareInterface::TestOperation::Write);
}
TEST(ControllerInitialReset, MissingHardwareCannotClaimInitialisation) {
    ControllerRig rig;
    rig.controller->deps_.hardware.reset();
    EXPECT_EQ(rig.controller->EnableInterruptsAndStartBus(), kIOReturnNoDevice);
    EXPECT_FALSE(rig.controller->hardwareInitialised_);
    EXPECT_EQ(ResetAttempts(rig), 0U);
}
} // namespace
