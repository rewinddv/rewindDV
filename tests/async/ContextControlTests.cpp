#include <gtest/gtest.h>
#include "ASFWDriver/Async/Contexts/ATRequestContext.hpp"
#include "ASFWDriver/Async/Contexts/ARRequestContext.hpp"
#include "ASFWDriver/Hardware/OHCIConstants.hpp"
#include "ASFWDriver/Async/Engine/ContextManager.hpp"
using namespace ASFW::Async;
using namespace ASFW::Driver;
struct TestContext : ContextBase<TestContext, ATRequestTag> {};
TEST(ContextControlTests, UsesActualActiveBitAndUnavailableReadIsNotIdleEvidence) {
    HardwareInterface hw; TestContext ctx;
    ASSERT_EQ(ctx.Initialize(hw), kIOReturnSuccess);
    hw.SetTestRegister(ATRequestTag::kControlSetReg, kContextControlActiveBit);
    EXPECT_TRUE(ctx.IsActive());
    hw.SetTestRegister(ATRequestTag::kControlSetReg, 1u << 13);
    EXPECT_FALSE(ctx.IsActive());
    hw.RevokeAndDrain();
    EXPECT_EQ(ctx.ReadControl(), 0xFFFFFFFFu);
}
TEST(ContextControlTests, ATStopAndArmRefuseActiveOrUnknownHardware) {
    HardwareInterface hw; ATRequestContext ctx;
    ASSERT_EQ((ctx.ContextBase<ATRequestContext,ATRequestTag>::Initialize(hw)),kIOReturnSuccess);
    for (uint32_t value : {kContextControlActiveBit, kContextControlActiveBit | kContextControlDeadBit, 0xFFFFFFFFu}) {
        hw.SetTestRegister(ATRequestTag::kControlSetReg, value);
        EXPECT_NE(ctx.Stop(), kIOReturnSuccess);
        EXPECT_NE(ctx.Arm(0x10000002), kIOReturnSuccess);
        EXPECT_EQ(hw.GetTestRegister(ATRequestTag::kCommandPtrReg), 0u);
    }
    hw.SetTestRegister(ATRequestTag::kControlSetReg, 0);
    EXPECT_EQ(ctx.Stop(), kIOReturnSuccess);
    hw.RevokeAndDrain();
    EXPECT_EQ(ctx.Stop(), kIOReturnNotReady);
}
TEST(ContextControlTests, ARRunClearDoesNotMeanStoppedAndArmNeverOverwritesActive) {
    HardwareInterface hw; ARRequestContext ctx;
    ASSERT_EQ((ctx.ContextBase<ARRequestContext,ARRequestTag>::Initialize(hw)),kIOReturnSuccess);
    hw.SetTestRegister(ARRequestTag::kControlSetReg, kContextControlActiveBit);
    EXPECT_EQ(ctx.Stop(1), kIOReturnTimeout);
    EXPECT_EQ(ctx.Arm(0x10000001), kIOReturnBusy);
    EXPECT_EQ(hw.GetTestRegister(ARRequestTag::kCommandPtrReg), 0u);
    hw.SetTestRegister(ARRequestTag::kControlSetReg, 0xFFFFFFFFu);
    EXPECT_EQ(ctx.Stop(1), kIOReturnNotReady);
    EXPECT_EQ(ctx.Arm(0x10000001), kIOReturnNotReady);
    hw.SetTestRegister(ARRequestTag::kControlSetReg, 0);
    EXPECT_EQ(ctx.Stop(1), kIOReturnSuccess);
}

TEST(ContextControlTests, ManagerAttemptsBothStopsAndQuarantinesUnprovenDMA) {
    HardwareInterface hw; ASFW::Async::Engine::ContextManager manager;
    ASFW::Async::Engine::ProvisionSpec spec;
    ASSERT_EQ(manager.provision(hw,spec),kIOReturnSuccess);
    hw.SetTestRegister(ATRequestTag::kControlSetReg,kContextControlActiveBit);
    hw.SetTestRegister(ATResponseTag::kControlSetReg,kContextControlRunBit);
    EXPECT_EQ(manager.stopAT(),kIOReturnTimeout);
    EXPECT_EQ(hw.GetTestRegister(ATResponseTag::kControlSetReg)&kContextControlRunBit,0u);
    hw.SetTestRegister(ARRequestTag::kControlSetReg,kContextControlActiveBit);
    hw.SetTestRegister(ARResponseTag::kControlSetReg,kContextControlRunBit);
    EXPECT_EQ(manager.stopAR(),kIOReturnTimeout);
    EXPECT_EQ(hw.GetTestRegister(ARResponseTag::kControlSetReg)&kContextControlRunBit,0u);
    EXPECT_FALSE(manager.teardown(true));
    EXPECT_EQ(manager.provision(hw,spec),kIOReturnNotReady);
}
TEST(ContextControlTests, ManagerReleasesOnlyPositiveIdleOrRevokedProvider) {
    HardwareInterface hw; ASFW::Async::Engine::ContextManager manager;
    ASFW::Async::Engine::ProvisionSpec spec;
    ASSERT_EQ(manager.provision(hw,spec),kIOReturnSuccess);
    EXPECT_TRUE(manager.teardown(false));
    ASSERT_EQ(manager.provision(hw,spec),kIOReturnSuccess);
    hw.SetTestRegister(ATRequestTag::kControlSetReg,kContextControlActiveBit);
    hw.LatchProviderRevokedAndDrain();
    EXPECT_TRUE(manager.teardown(false));
}

TEST(ContextControlTests, PayloadReleaseRequiresBothATContextsPositivelyIdle) {
    HardwareInterface hw; ASFW::Async::Engine::ContextManager manager;
    ASFW::Async::Engine::ProvisionSpec spec;
    EXPECT_FALSE(manager.ATContextsQuiescent());
    ASSERT_EQ(manager.provision(hw,spec),kIOReturnSuccess);
    EXPECT_TRUE(manager.ATContextsQuiescent());
    for (auto reg : {ATRequestTag::kControlSetReg,ATResponseTag::kControlSetReg}) {
        for (auto value : {kContextControlActiveBit,kContextControlRunBit,0xFFFFFFFFu}) {
            hw.SetTestRegister(reg,value);
            EXPECT_FALSE(manager.ATContextsQuiescent());
        }
        hw.SetTestRegister(reg,0);
    }
    EXPECT_TRUE(manager.ATContextsQuiescent());
    hw.LatchProviderRevokedAndDrain();
    EXPECT_FALSE(manager.ATContextsQuiescent());
    EXPECT_TRUE(manager.teardown(false));
}

TEST(ContextAllocationFailure, EachMandatoryLockFailureRejectsProvisionAndUnwinds) {
    for (int allocation = 0; allocation < 6; ++allocation) {
        SCOPED_TRACE(allocation);
        HardwareInterface hw;
        const auto locks = ASFW::Testing::liveLocks;
        const auto nullCalls = ASFW::Testing::nullLockCalls;
        {
            ASFW::Async::Engine::ContextManager manager;
            ASFW::Testing::ScopedLockAllocationFailure failure(allocation);
            EXPECT_EQ(manager.provision(hw, {}), kIOReturnNoMemory);
            EXPECT_EQ(manager.GetATRequestManager(), nullptr);
            EXPECT_EQ(hw.GetTestRegister(ATRequestTag::kCommandPtrReg), 0U);
            EXPECT_EQ(hw.GetTestRegister(ATResponseTag::kCommandPtrReg), 0U);
            EXPECT_EQ(hw.GetTestRegister(ARRequestTag::kCommandPtrReg), 0U);
            EXPECT_EQ(hw.GetTestRegister(ARResponseTag::kCommandPtrReg), 0U);
        }
        EXPECT_EQ(ASFW::Testing::liveLocks, locks);
        EXPECT_EQ(ASFW::Testing::nullLockCalls, nullCalls);
    }
    HardwareInterface hw;
    ASFW::Async::Engine::ContextManager manager;
    ASSERT_EQ(manager.provision(hw, {}), kIOReturnSuccess);
    EXPECT_TRUE(manager.teardown(false));
}
