#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <utility>

#include <gtest/gtest.h>

#include "ASFWDriver/Async/Contexts/ContextBase.hpp"
#include "ASFWDriver/Async/Contexts/ATRequestContext.hpp"
#include "ASFWDriver/Async/Engine/ATManager.hpp"
#include "ASFWDriver/Async/Tx/DescriptorBuilder.hpp"
#include "ASFWDriver/Hardware/OHCIConstants.hpp"
#include "ASFWDriver/Hardware/OHCIDescriptors.hpp"
#include "ASFWDriver/Hardware/HardwareInterface.hpp"
#include "ASFWDriver/Shared/Memory/DMAMemoryManager.hpp"
#include "ASFWDriver/Shared/Rings/DescriptorRing.hpp"

namespace ASFW::Async::Engine {
namespace {

using ASFW::Async::DescriptorBuilder;
using ASFW::Async::HW::OHCIDescriptor;
using ASFW::Async::HW::OHCIDescriptorImmediate;
using ASFW::Driver::kContextControlActiveBit;
using ASFW::Driver::kContextControlRunBit;
using ASFW::Driver::kContextControlWakeBit;
using ASFW::Shared::DescriptorRing;
using ASFW::Shared::DMAMemoryManager;
using ASFW::Driver::HardwareInterface;

constexpr uint32_t kDescriptorIOVABase = 0x10000000u;

class FakeATContext {
public:
    void LockSubmissionQueue() noexcept {
        ++submissionLockDepth_;
        ++submissionLockCount_;
    }

    void UnlockSubmissionQueue() noexcept {
        --submissionLockDepth_;
        ++submissionUnlockCount_;
    }

    [[nodiscard]] bool IsRunning() const noexcept {
        return (control_ & kContextControlRunBit) != 0;
    }

    [[nodiscard]] bool IsActive() const noexcept {
        if (activePollsRemaining_ != 0 && --activePollsRemaining_ == 0) control_ &= ~kContextControlActiveBit;
        return (control_ & kContextControlActiveBit) != 0;
    }
    void ClearActiveAfterPolls(unsigned count) noexcept { activePollsRemaining_ = count; }
    void SetControl(uint32_t value) noexcept { control_ = value; }
    void ChangeControlAfterNextRead(uint32_t value) noexcept { afterRead_ = value; }
    [[nodiscard]] uint32_t ReadControl() const noexcept {
        const auto result = control_;
        if (afterRead_) { control_ = *afterRead_; afterRead_.reset(); }
        return result;
    }

    void WriteControlSet(uint32_t bits) noexcept {
        control_ |= bits;
        if ((bits & kContextControlWakeBit) != 0) {
            ++wakeCount_;
            wakeObservedWithSubmissionLock_ = submissionLockDepth_ > 0;
        }
    }

    void WriteControlClear(uint32_t bits) noexcept { control_ &= ~bits; }

    void WriteCommandPtr(uint32_t commandPtr) noexcept {
        commandPtr_ = commandPtr;
        ++commandPtrWriteCount_;
    }

    [[nodiscard]] uint32_t CommandPtr() const noexcept { return commandPtr_; }
    [[nodiscard]] uint32_t CommandPtrWriteCount() const noexcept { return commandPtrWriteCount_; }
    [[nodiscard]] uint32_t WakeCount() const noexcept { return wakeCount_; }
    [[nodiscard]] uint32_t SubmissionLockCount() const noexcept { return submissionLockCount_; }
    [[nodiscard]] uint32_t SubmissionUnlockCount() const noexcept { return submissionUnlockCount_; }
    [[nodiscard]] bool WakeObservedWithSubmissionLock() const noexcept {
        return wakeObservedWithSubmissionLock_;
    }

private:
    mutable unsigned activePollsRemaining_{0};
    mutable uint32_t control_{0};
    mutable std::optional<uint32_t> afterRead_{};
    uint32_t commandPtr_{0};
    uint32_t commandPtrWriteCount_{0};
    uint32_t wakeCount_{0};
    uint32_t submissionLockDepth_{0};
    uint32_t submissionLockCount_{0};
    uint32_t submissionUnlockCount_{0};
    bool wakeObservedWithSubmissionLock_{false};
};

struct TestRoleTag {
    static constexpr const char* kContextName = "ATReqTest";
};

using TestATManager = ATManager<FakeATContext, DescriptorRing, TestRoleTag>;

void ConfigureDescriptor(OHCIDescriptor& descriptor,
                         uint8_t command,
                         uint8_t key,
                         uint8_t interruptBits,
                         uint8_t branchBits,
                         uint16_t requestCount) {
    descriptor = {};
    descriptor.control = OHCIDescriptor::BuildControl({
        .reqCount = requestCount,
        .command = command,
        .key = key,
        .interruptBits = interruptBits,
        .branchBits = branchBits,
    });
}

DescriptorBuilder::DescriptorChain MakeBlockWriteChain(
    std::array<OHCIDescriptor, 8>& storage,
    size_t startIndex,
    uint32_t txid) {
    auto* first = &storage[startIndex];
    auto* last = &storage[startIndex + 2];
    ConfigureDescriptor(*first,
                        OHCIDescriptor::kCmdOutputMore,
                        OHCIDescriptor::kKeyImmediate,
                        OHCIDescriptor::kIntNever,
                        OHCIDescriptor::kBranchNever,
                        16);
    auto* immediate = reinterpret_cast<OHCIDescriptorImmediate*>(first);
    immediate->immediateData[0] = (txid & 0x3fu) << 10;
    immediate->immediateData[1] = 0x11223344u;
    immediate->immediateData[2] = 0x55667788u;
    immediate->immediateData[3] = 0x99aabbccu;
    ConfigureDescriptor(*last,
                        OHCIDescriptor::kCmdOutputLast,
                        OHCIDescriptor::kKeyStandard,
                        OHCIDescriptor::kIntAlways,
                        OHCIDescriptor::kBranchAlways,
                        8);
    last->dataAddress = 0x20000000u + txid * 4u;
    return DescriptorBuilder::DescriptorChain{
        .first = first,
        .last = last,
        .firstIOVA32 = kDescriptorIOVABase + static_cast<uint32_t>(startIndex * sizeof(OHCIDescriptor)),
        .lastIOVA32 = kDescriptorIOVABase + static_cast<uint32_t>((startIndex + 2) * sizeof(OHCIDescriptor)),
        .firstBlocks = 2,
        .lastBlocks = 1,
        .firstRingIndex = startIndex,
        .lastRingIndex = startIndex + 2,
        .needsFlush = true,
        .txid = txid,
    };
}

DescriptorBuilder::DescriptorChain MakeImmediateChain(
    std::array<OHCIDescriptor, 8>& storage,
    size_t startIndex,
    uint32_t txid) {
    auto* first = &storage[startIndex];
    ConfigureDescriptor(*first,
                        OHCIDescriptor::kCmdOutputLast,
                        OHCIDescriptor::kKeyImmediate,
                        OHCIDescriptor::kIntAlways,
                        OHCIDescriptor::kBranchAlways,
                        16);
    auto* immediate = reinterpret_cast<OHCIDescriptorImmediate*>(first);
    immediate->immediateData[0] = (txid & 0x3fu) << 10;
    immediate->immediateData[1] = 0x11223344u;
    immediate->immediateData[2] = 0x55667788u;
    immediate->immediateData[3] = 0x99aabbccu;
    return DescriptorBuilder::DescriptorChain{
        .first = first,
        .last = first,
        .firstIOVA32 = kDescriptorIOVABase + static_cast<uint32_t>(startIndex * sizeof(OHCIDescriptor)),
        .lastIOVA32 = kDescriptorIOVABase + static_cast<uint32_t>(startIndex * sizeof(OHCIDescriptor)),
        .firstBlocks = 2,
        .lastBlocks = 2,
        .firstRingIndex = startIndex,
        .lastRingIndex = startIndex + 1,
        .needsFlush = false,
        .txid = txid,
    };
}

class ATManagerHotAppendTest : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_TRUE(ring_.Initialize(storage_));
        ASSERT_TRUE(ring_.Finalize(kDescriptorIOVABase));
    }

    alignas(16) std::array<OHCIDescriptor, 8> storage_{};
    DescriptorRing ring_{};
    DMAMemoryManager dma_{};
};

TEST_F(ATManagerHotAppendTest, MissingStateLockRejectsSubmissionAndStop) {
    FakeATContext context;
    DescriptorBuilder builder(ring_, dma_);
    auto chain = MakeImmediateChain(storage_, 0, 1);
    const auto nullCalls = ASFW::Testing::nullLockCalls;
    ASFW::Testing::ScopedLockAllocationFailure failure;
    TestATManager manager(context, ring_, builder);
    EXPECT_EQ(manager.Submit(std::move(chain), {}), kIOReturnNoMemory);
    manager.RequestStop(1, "allocation failure");
    EXPECT_EQ(manager.GetState(), ATState::IDLE);
    EXPECT_EQ(context.SubmissionLockCount(), 0U);
    EXPECT_EQ(context.CommandPtrWriteCount(), 0U);
    EXPECT_TRUE(ring_.IsEmpty());
    EXPECT_EQ(ASFW::Testing::nullLockCalls, nullCalls);
}

struct RealBuilderRig {
    static constexpr size_t kCapacity = 8;

    bool Initialize() {
        if (!dma.Initialize(hardware, 4096)) {
            return false;
        }
        descriptorRegion = dma.AllocateRegion(kCapacity * sizeof(OHCIDescriptor));
        payloadRegion = dma.AllocateRegion(64);
        if (!descriptorRegion || !payloadRegion) {
            return false;
        }
        descriptors = reinterpret_cast<OHCIDescriptor*>(descriptorRegion->virtualBase);
        if (!ring.Initialize(std::span<OHCIDescriptor>{descriptors, kCapacity}) ||
            !ring.Finalize(descriptorRegion->deviceBase)) {
            return false;
        }
        builder = std::make_unique<DescriptorBuilder>(ring, dma);
        return true;
    }

    DescriptorBuilder::DescriptorChain BuildBlockWrite(uint8_t tLabel) {
        const std::array<uint32_t, 4> header{
            static_cast<uint32_t>(tLabel & 0x3fu) << 10,
            0x11223344u,
            0x55667788u,
            0x00080000u,
        };
        return builder->BuildTransactionChain(
            reinterpret_cast<const uint8_t*>(header.data()),
            sizeof(header),
            payloadRegion->deviceBase,
            8,
            true);
    }

    DescriptorBuilder::DescriptorChain BuildImmediate(uint8_t tLabel) {
        const std::array<uint32_t, 4> header{
            static_cast<uint32_t>(tLabel & 0x3fu) << 10,
            0x11223344u,
            0x55667788u,
            0x99aabbccu,
        };
        return builder->BuildTransactionChain(
            reinterpret_cast<const uint8_t*>(header.data()),
            sizeof(header),
            0,
            0,
            false);
    }

    HardwareInterface hardware;
    DMAMemoryManager dma;
    DescriptorRing ring;
    std::optional<DMAMemoryManager::Region> descriptorRegion;
    std::optional<DMAMemoryManager::Region> payloadRegion;
    OHCIDescriptor* descriptors{nullptr};
    std::unique_ptr<DescriptorBuilder> builder;
};

TEST_F(ATManagerHotAppendTest, FCPBlockWriteHotAppendUsesPreviousPayloadDescriptor) {
    DescriptorBuilder builder(ring_, dma_);
    FakeATContext context;
    TestATManager manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto first = MakeBlockWriteChain(storage_, 0, 1);
    auto second = MakeBlockWriteChain(storage_, 3, 2);

    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    ASSERT_EQ(ring_.PrevLastBlocks(), 3u);
    ASSERT_EQ(manager.Submit(std::move(second), options), kIOReturnSuccess);

    EXPECT_EQ(context.CommandPtrWriteCount(), 1u)
        << "The second FCP write must append, not re-arm CommandPtr";
    EXPECT_EQ(context.WakeCount(), 1u);
    EXPECT_TRUE(context.WakeObservedWithSubmissionLock());
    EXPECT_EQ(context.SubmissionLockCount(), 2u);
    EXPECT_EQ(context.SubmissionUnlockCount(), 2u);
    EXPECT_EQ(storage_[2].branchWord, kDescriptorIOVABase + 3u * sizeof(OHCIDescriptor) + 3u);
    EXPECT_EQ(ring_.Tail(), 6u);
    EXPECT_EQ(ring_.PrevLastBlocks(), 3u);
}

TEST_F(ATManagerHotAppendTest, ImmediateOnlyHotAppendRemainsCompatible) {
    DescriptorBuilder builder(ring_, dma_);
    FakeATContext context;
    TestATManager manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto first = MakeImmediateChain(storage_, 0, 1);
    auto second = MakeImmediateChain(storage_, 2, 2);

    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    ASSERT_EQ(manager.Submit(std::move(second), options), kIOReturnSuccess);

    EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
    EXPECT_EQ(context.WakeCount(), 1u);
    EXPECT_EQ(storage_[0].branchWord, kDescriptorIOVABase + 2u * sizeof(OHCIDescriptor) + 2u);
    EXPECT_EQ(ring_.Tail(), 4u);
    EXPECT_EQ(ring_.PrevLastBlocks(), 2u);
}

TEST_F(ATManagerHotAppendTest, HotAppendFindsImmediateBranchAnchorAcrossRingWrap) {
    DescriptorBuilder builder(ring_, dma_);
    FakeATContext context;
    TestATManager manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto first = MakeBlockWriteChain(storage_, 0, 1);
    auto second = MakeBlockWriteChain(storage_, 3, 2);
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    ASSERT_EQ(manager.Submit(std::move(second), options), kIOReturnSuccess);

    // Model retirement of the first program, then append a two-block request
    // at the end of the ring so its tail wraps to index zero.
    ring_.SetHead(3);
    auto atEnd = MakeImmediateChain(storage_, 6, 3);
    ASSERT_EQ(manager.Submit(std::move(atEnd), options), kIOReturnSuccess);
    ASSERT_EQ(ring_.Tail(), 0u);

    // Retire the second program and reuse the leading slots. The previous
    // immediate request remains the live branch anchor at index six.
    ring_.SetHead(6);
    auto wrapped = MakeBlockWriteChain(storage_, 0, 4);
    ASSERT_EQ(manager.Submit(std::move(wrapped), options), kIOReturnSuccess);

    EXPECT_EQ(storage_[6].branchWord, kDescriptorIOVABase + 3u);
    EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
    EXPECT_EQ(context.WakeCount(), 3u);
    EXPECT_EQ(ring_.Tail(), 3u);
    EXPECT_EQ(ring_.PrevLastBlocks(), 3u);
}

TEST_F(ATManagerHotAppendTest, BlockWriteHotAppendFindsPayloadAnchorAtRingBoundary) {
    DescriptorBuilder builder(ring_, dma_);
    FakeATContext context;
    TestATManager manager(context, ring_, builder);
    AsyncCmdOptions options{};

    // Begin with an empty ring positioned at index five. The three-block FCP
    // program occupies 5,6,7 and advances the tail naturally across the ring
    // boundary to zero.
    ring_.SetHead(5);
    ring_.SetTail(5);
    auto atEnd = MakeBlockWriteChain(storage_, 5, 1);
    ASSERT_EQ(manager.Submit(std::move(atEnd), options), kIOReturnSuccess);
    ASSERT_EQ(ring_.Tail(), 0u);
    ASSERT_EQ(ring_.PrevLastBlocks(), 3u);

    auto wrapped = MakeBlockWriteChain(storage_, 0, 2);
    ASSERT_EQ(manager.Submit(std::move(wrapped), options), kIOReturnSuccess);

    EXPECT_EQ(storage_[7].branchWord, kDescriptorIOVABase + 3u);
    EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
    EXPECT_EQ(context.WakeCount(), 1u);
    EXPECT_EQ(ring_.Tail(), 3u);
    EXPECT_EQ(ring_.PrevLastBlocks(), 3u);
}

TEST_F(ATManagerHotAppendTest, RealBuilderRebasesEmptyRingBeforeWrappedAllocation) {
    RealBuilderRig rig;
    ASSERT_TRUE(rig.Initialize());
    rig.ring.SetHead(7);
    rig.ring.SetTail(7);

    auto chain = rig.BuildBlockWrite(21);
    ASSERT_FALSE(chain.Empty());
    EXPECT_EQ(chain.firstRingIndex, 0u);
    EXPECT_EQ(chain.lastRingIndex, 2u);
    EXPECT_EQ(rig.ring.Head(), 0u);
    EXPECT_EQ(rig.ring.Tail(), 0u);

    ATRequestContext context;
    ASSERT_EQ(context.Initialize(rig.hardware, rig.ring, rig.dma), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(
        context, rig.ring, *rig.builder);
    AsyncCmdOptions options{};
    ASSERT_EQ(manager.Submit(std::move(chain), options), kIOReturnSuccess);
    rig.descriptors[2].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);

    const auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->tLabel, 21u);
    EXPECT_EQ(rig.ring.Head(), 3u);
    EXPECT_TRUE(rig.ring.IsEmpty());
}

TEST_F(ATManagerHotAppendTest, RealBuilderRejectsNonEmptyGapWrapWithoutMutation) {
    RealBuilderRig rig;
    ASSERT_TRUE(rig.Initialize());
    rig.ring.SetHead(5);
    rig.ring.SetTail(5);

    auto first = rig.BuildImmediate(22);
    ASSERT_FALSE(first.Empty());
    ASSERT_EQ(first.firstRingIndex, 5u);
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(rig.hardware, rig.ring, rig.dma), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(
        context, rig.ring, *rig.builder);
    AsyncCmdOptions options{};
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    ASSERT_EQ(rig.ring.Head(), 5u);
    ASSERT_EQ(rig.ring.Tail(), 7u);

    const std::array<OHCIDescriptor, 3> leadingBefore{
        rig.descriptors[0], rig.descriptors[1], rig.descriptors[2]};
    auto rejected = rig.BuildBlockWrite(23);
    EXPECT_TRUE(rejected.Empty());
    EXPECT_EQ(rig.ring.Head(), 5u);
    EXPECT_EQ(rig.ring.Tail(), 7u);
    EXPECT_EQ(rig.descriptors[0].control, leadingBefore[0].control);
    EXPECT_EQ(rig.descriptors[1].control, leadingBefore[1].control);
    EXPECT_EQ(rig.descriptors[2].control, leadingBefore[2].control);
}

TEST_F(ATManagerHotAppendTest, RealBuilderAllowsExactEndQueuedProgramsAndRetiresBoth) {
    RealBuilderRig rig;
    ASSERT_TRUE(rig.Initialize());
    rig.ring.SetHead(2);
    rig.ring.SetTail(2);

    auto first = rig.BuildBlockWrite(24);
    ASSERT_FALSE(first.Empty());
    ASSERT_EQ(first.firstRingIndex, 2u);
    ASSERT_EQ(first.lastRingIndex, 4u);
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(rig.hardware, rig.ring, rig.dma), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(
        context, rig.ring, *rig.builder);
    AsyncCmdOptions options{};
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);

    auto exactEnd = rig.BuildBlockWrite(25);
    ASSERT_FALSE(exactEnd.Empty());
    ASSERT_EQ(exactEnd.firstRingIndex, 5u);
    ASSERT_EQ(exactEnd.lastRingIndex, 7u);
    ASSERT_EQ(manager.Submit(std::move(exactEnd), options), kIOReturnSuccess);
    ASSERT_EQ(rig.ring.Head(), 2u);
    ASSERT_EQ(rig.ring.Tail(), 0u);

    rig.descriptors[4].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);
    auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->tLabel, 24u);
    EXPECT_EQ(rig.ring.Head(), 5u);

    rig.descriptors[7].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);
    completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->tLabel, 25u);
    EXPECT_EQ(rig.ring.Head(), 0u);
    EXPECT_TRUE(rig.ring.IsEmpty());
}

TEST_F(ATManagerHotAppendTest, TerminalOnlyCompletionRetiresBlockWriteAtEndOfList) {
    DescriptorBuilder builder(ring_, dma_);
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto first = MakeBlockWriteChain(storage_, 0, 1);
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);

    const OHCIDescriptor headerPayloadBlock = storage_[1];
    const uint32_t payloadAddress = storage_[2].dataAddress;
    ASSERT_EQ(storage_[0].xferStatus, 0u);
    storage_[2].timeStamp = 0x3456u;
    storage_[2].xferStatus = static_cast<uint16_t>(
        (2u << 5) | static_cast<uint16_t>(OHCIEventCode::kAckComplete));

    const auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->eventCode, OHCIEventCode::kAckComplete);
    EXPECT_EQ(completion->tLabel, 1u);
    EXPECT_EQ(completion->timeStamp, 0x3456u);
    EXPECT_EQ(completion->descriptor, &storage_[2]);
    EXPECT_EQ(ring_.Head(), 3u);
    EXPECT_TRUE(ring_.IsEmpty());

    EXPECT_EQ(storage_[0].statusWord, 0u);
    EXPECT_EQ(storage_[2].statusWord, 0u);
    EXPECT_EQ(storage_[1].control, headerPayloadBlock.control);
    EXPECT_EQ(storage_[1].dataAddress, headerPayloadBlock.dataAddress);
    EXPECT_EQ(storage_[1].branchWord, headerPayloadBlock.branchWord);
    EXPECT_EQ(storage_[1].statusWord, headerPayloadBlock.statusWord);
    EXPECT_EQ(storage_[2].dataAddress, payloadAddress);
    EXPECT_EQ(storage_[2].branchWord, 0u);
}

TEST_F(ATManagerHotAppendTest, TerminalOnlyCompletionRetiresQueuedBlockWriteAndPreservesBranch) {
    DescriptorBuilder builder(ring_, dma_);
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto first = MakeBlockWriteChain(storage_, 0, 1);
    auto second = MakeBlockWriteChain(storage_, 3, 2);
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    ASSERT_EQ(manager.Submit(std::move(second), options), kIOReturnSuccess);

    const uint32_t publishedBranch = kDescriptorIOVABase + 3u * sizeof(OHCIDescriptor) + 3u;
    const uint32_t nextHeaderPayloadQ0 = storage_[4].control;
    const uint32_t nextPayloadAddress = storage_[5].dataAddress;
    ASSERT_EQ(storage_[0].xferStatus, 0u);
    ASSERT_EQ(storage_[2].branchWord, publishedBranch);
    storage_[2].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckPending);

    const auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->eventCode, OHCIEventCode::kAckPending);
    EXPECT_EQ(completion->tLabel, 1u);
    EXPECT_EQ(completion->descriptor, &storage_[2]);
    EXPECT_EQ(ring_.Head(), 3u);
    EXPECT_EQ(ring_.Tail(), 6u);
    EXPECT_EQ(ring_.PrevLastBlocks(), 3u);
    EXPECT_EQ(storage_[2].statusWord, 0u);
    EXPECT_EQ(storage_[2].branchWord, publishedBranch)
        << "Retirement must not erase a branch that OHCI may not have consumed yet";
    EXPECT_EQ(storage_[4].control, nextHeaderPayloadQ0);
    EXPECT_EQ(storage_[5].dataAddress, nextPayloadAddress);
}

TEST_F(ATManagerHotAppendTest, TerminalOnlyCompletionRetiresBlockWriteAcrossRingBoundary) {
    DescriptorBuilder builder(ring_, dma_);
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(context, ring_, builder);
    AsyncCmdOptions options{};

    ring_.SetHead(5);
    ring_.SetTail(5);
    auto atEnd = MakeBlockWriteChain(storage_, 5, 7);
    ASSERT_EQ(manager.Submit(std::move(atEnd), options), kIOReturnSuccess);
    ASSERT_EQ(ring_.Tail(), 0u);
    auto wrapped = MakeBlockWriteChain(storage_, 0, 8);
    ASSERT_EQ(manager.Submit(std::move(wrapped), options), kIOReturnSuccess);
    const uint32_t publishedBranch = kDescriptorIOVABase + 3u;
    ASSERT_EQ(storage_[7].branchWord, publishedBranch);
    ASSERT_EQ(storage_[5].xferStatus, 0u);
    storage_[7].timeStamp = 0x4567u;
    storage_[7].xferStatus = static_cast<uint16_t>(
        (3u << 5) | static_cast<uint16_t>(OHCIEventCode::kAckComplete));

    const auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->tLabel, 7u);
    EXPECT_EQ(completion->timeStamp, 0x4567u);
    EXPECT_EQ(completion->descriptor, &storage_[7]);
    EXPECT_EQ(ring_.Head(), 0u);
    EXPECT_EQ(ring_.Tail(), 3u);
    EXPECT_FALSE(ring_.IsEmpty());
    EXPECT_EQ(storage_[7].statusWord, 0u);
    EXPECT_EQ(storage_[7].branchWord, publishedBranch);
}

TEST_F(ATManagerHotAppendTest, ImmediateOnlyCompletionStillRetiresTwoBlocks) {
    DescriptorBuilder builder(ring_, dma_);
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);
    ATManager<ATRequestContext, DescriptorRing, ATRequestTag> manager(context, ring_, builder);
    AsyncCmdOptions options{};

    auto immediate = MakeImmediateChain(storage_, 0, 9);
    ASSERT_EQ(manager.Submit(std::move(immediate), options), kIOReturnSuccess);
    const OHCIDescriptor immediatePayloadBlock = storage_[1];
    storage_[0].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);

    const auto completion = context.ScanCompletion();
    ASSERT_TRUE(completion.has_value());
    EXPECT_EQ(completion->eventCode, OHCIEventCode::kAckComplete);
    EXPECT_EQ(completion->tLabel, 9u);
    EXPECT_EQ(completion->descriptor, &storage_[0]);
    EXPECT_EQ(ring_.Head(), 2u);
    EXPECT_TRUE(ring_.IsEmpty());
    EXPECT_EQ(storage_[1].control, immediatePayloadBlock.control);
    EXPECT_EQ(storage_[1].dataAddress, immediatePayloadBlock.dataAddress);
    EXPECT_EQ(storage_[1].branchWord, immediatePayloadBlock.branchWord);
    EXPECT_EQ(storage_[1].statusWord, immediatePayloadBlock.statusWord);
}

TEST_F(ATManagerHotAppendTest, MalformedProgramFailsClosedWithoutRetirement) {
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);

    ConfigureDescriptor(storage_[0],
                        OHCIDescriptor::kCmdOutputMore,
                        OHCIDescriptor::kKeyImmediate,
                        OHCIDescriptor::kIntNever,
                        OHCIDescriptor::kBranchNever,
                        16);
    ConfigureDescriptor(storage_[2],
                        OHCIDescriptor::kCmdOutputMore,
                        OHCIDescriptor::kKeyStandard,
                        OHCIDescriptor::kIntAlways,
                        OHCIDescriptor::kBranchAlways,
                        8);
    storage_[2].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);
    ring_.SetHead(0);
    ring_.SetTail(3);

    EXPECT_FALSE(context.ScanCompletion().has_value());
    EXPECT_EQ(ring_.Head(), 0u);
    EXPECT_EQ(storage_[2].xferStatus,
              static_cast<uint16_t>(OHCIEventCode::kAckComplete));
    EXPECT_EQ(context.DiscardStoppedPrograms(), 0u);
    EXPECT_EQ(ring_.Head(), 0u);
}

TEST_F(ATManagerHotAppendTest, PendingTerminalIgnoresCommandPtrMismatch) {
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);

    auto pending = MakeBlockWriteChain(storage_, 0, 11);
    (void)pending;
    ring_.SetHead(0);
    ring_.SetTail(3);
    hardware.SetTestRegister(ATRequestTag::kControlSetReg, kContextControlRunBit);
    hardware.SetTestRegister(ATRequestTag::kCommandPtrReg,
                             kDescriptorIOVABase + 3u * sizeof(OHCIDescriptor) + 3u);

    ASSERT_EQ(storage_[0].xferStatus, 0u);
    ASSERT_EQ(storage_[2].xferStatus, 0u);
    EXPECT_FALSE(context.ScanCompletion().has_value());
    EXPECT_EQ(ring_.Head(), 0u)
        << "CommandPtr movement is not completion evidence for an AT program";
    EXPECT_EQ(storage_[0].control >> OHCIDescriptor::kControlHighShift,
              static_cast<uint32_t>(OHCIDescriptor::kKeyImmediate)
                  << OHCIDescriptor::kKeyShift);
}

TEST_F(ATManagerHotAppendTest, PendingTerminalDoesNotRetireWhenContextIsStopped) {
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);

    auto pending = MakeBlockWriteChain(storage_, 0, 12);
    (void)pending;
    ring_.SetHead(0);
    ring_.SetTail(3);
    hardware.SetTestRegister(ATRequestTag::kControlSetReg, 0u);
    hardware.SetTestRegister(ATRequestTag::kCommandPtrReg, 0u);

    EXPECT_FALSE(context.ScanCompletion().has_value());
    EXPECT_EQ(ring_.Head(), 0u);
    EXPECT_EQ(storage_[0].statusWord, 0u);
    EXPECT_EQ(storage_[2].statusWord, 0u);

    EXPECT_EQ(context.DiscardStoppedPrograms(), 1u);
    EXPECT_EQ(ring_.Head(), 3u);
    EXPECT_TRUE(ring_.IsEmpty());
    EXPECT_EQ(ring_.PrevLastBlocks(), 0u);
}

TEST_F(ATManagerHotAppendTest, ExplicitFlushFailsClosedWhileContextIsActiveOrUnavailable) {
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);

    auto pending = MakeBlockWriteChain(storage_, 0, 13);
    (void)pending;
    ring_.SetHead(0);
    ring_.SetTail(3);

    hardware.SetTestRegister(ATRequestTag::kControlSetReg, kContextControlActiveBit);
    EXPECT_EQ(context.DiscardStoppedPrograms(), 0u);
    EXPECT_EQ(ring_.Head(), 0u);

    hardware.SetTestRegister(ATRequestTag::kControlSetReg, 0xFFFFFFFFu);
    EXPECT_EQ(context.DiscardStoppedPrograms(), 0u);
    EXPECT_EQ(ring_.Head(), 0u);
}

TEST_F(ATManagerHotAppendTest, CrossBoundaryBlockWriteShapeFailsClosed) {
    HardwareInterface hardware;
    ATRequestContext context;
    ASSERT_EQ(context.Initialize(hardware, ring_, dma_), kIOReturnSuccess);

    // DescriptorBuilder never emits a program starting at six because its
    // three blocks would cross the allocation boundary. Model corrupt ring
    // metadata and ensure the scanner does not reinterpret it as a wrapped
    // program with its terminal at zero.
    ConfigureDescriptor(storage_[6],
                        OHCIDescriptor::kCmdOutputMore,
                        OHCIDescriptor::kKeyImmediate,
                        OHCIDescriptor::kIntNever,
                        OHCIDescriptor::kBranchNever,
                        16);
    ConfigureDescriptor(storage_[0],
                        OHCIDescriptor::kCmdOutputLast,
                        OHCIDescriptor::kKeyStandard,
                        OHCIDescriptor::kIntAlways,
                        OHCIDescriptor::kBranchAlways,
                        8);
    storage_[0].xferStatus = static_cast<uint16_t>(OHCIEventCode::kAckComplete);
    ring_.SetHead(6);
    ring_.SetTail(1);

    EXPECT_FALSE(context.ScanCompletion().has_value());
    EXPECT_EQ(ring_.Head(), 6u);
    EXPECT_EQ(storage_[0].xferStatus,
              static_cast<uint16_t>(OHCIEventCode::kAckComplete));
}

TEST_F(ATManagerHotAppendTest, RefusedRearmDoesNotPublishOrConsumeNewProgram) {
    for (const uint32_t control : {kContextControlActiveBit,
                                  kContextControlActiveBit | kContextControlRunBit,
                                  kContextControlActiveBit | ASFW::Driver::kContextControlDeadBit,
                                  0xFFFFFFFFu}) {
        RealBuilderRig rig;
        ASSERT_TRUE(rig.Initialize());
        FakeATContext context;
        context.SetControl(control);
        TestATManager manager(context, rig.ring, *rig.builder);
        AsyncCmdOptions options{};
        auto chain = rig.BuildBlockWrite(1);
        ASSERT_FALSE(chain.Empty());
        const auto head = rig.ring.Head();
        const auto tail = rig.ring.Tail();
        EXPECT_EQ(manager.Submit(std::move(chain), options),
                  control == 0xFFFFFFFFu ? kIOReturnNotReady : kIOReturnBusy);
        EXPECT_EQ(context.CommandPtrWriteCount(), 0u);
        EXPECT_EQ(context.WakeCount(), 0u);
        EXPECT_EQ(rig.ring.Head(), head);
        EXPECT_EQ(rig.ring.Tail(), tail);
        EXPECT_EQ(rig.ring.PrevLastBlocks(), 0u);
        EXPECT_EQ(context.SubmissionLockCount(), context.SubmissionUnlockCount());
        // A refused unlinked chain reserves no ring slots. Once actually idle,
        // rebuilding reuses that capacity, not an imaginary completed packet.
        context.SetControl(0);
        auto retry = rig.BuildBlockWrite(2);
        ASSERT_FALSE(retry.Empty());
        EXPECT_EQ(manager.Submit(std::move(retry), options), kIOReturnSuccess);
        EXPECT_EQ(rig.ring.Size(), 3u);
    }
}

TEST_F(ATManagerHotAppendTest, PublishedAppendRetainsOwnershipWhenHardwareChangesBeforeWake) {
    for (uint32_t changed : {0u, kContextControlActiveBit,
                            ASFW::Driver::kContextControlDeadBit, 0xFFFFFFFFu}) {
        RealBuilderRig rig;
        ASSERT_TRUE(rig.Initialize());
        FakeATContext context;
        TestATManager manager(context, rig.ring, *rig.builder);
        AsyncCmdOptions options{};
        auto first = rig.BuildBlockWrite(1);
        auto* anchor = first.last;
        ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
        auto next = rig.BuildBlockWrite(2);
        const auto expectedBranch = next.firstIOVA32 | next.TotalBlocks();
        context.ChangeControlAfterNextRead(changed);
        EXPECT_EQ(manager.Submit(std::move(next), options), kIOReturnSuccess);
        EXPECT_EQ(anchor->branchWord, expectedBranch);
        EXPECT_EQ(rig.ring.Size(), 6u);
        EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
        EXPECT_EQ(context.WakeCount(), 0u);
        EXPECT_EQ(context.SubmissionLockCount(), context.SubmissionUnlockCount());
    }
}

TEST_F(ATManagerHotAppendTest, UnknownControlBeforeAppendDoesNotPublishBranch) {
    RealBuilderRig rig;
    ASSERT_TRUE(rig.Initialize());
    FakeATContext context;
    TestATManager manager(context, rig.ring, *rig.builder);
    AsyncCmdOptions options{};
    auto first = rig.BuildBlockWrite(1);
    auto* anchor = first.last;
    ASSERT_EQ(manager.Submit(std::move(first), options), kIOReturnSuccess);
    auto next = rig.BuildBlockWrite(2);
    context.SetControl(0xFFFFFFFFu);
    EXPECT_EQ(manager.Submit(std::move(next), options), kIOReturnNotReady);
    EXPECT_EQ(anchor->branchWord, 0u);
    EXPECT_EQ(rig.ring.Size(), 3u);
    EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
    EXPECT_EQ(context.WakeCount(), 0u);
}

TEST_F(ATManagerHotAppendTest, RearmWaitsForDelayedActiveClearWithinShortBudget) {
    RealBuilderRig rig;
    ASSERT_TRUE(rig.Initialize());
    FakeATContext context;
    context.SetControl(kContextControlRunBit | kContextControlActiveBit);
    context.ClearActiveAfterPolls(5);
    TestATManager manager(context, rig.ring, *rig.builder);
    auto chain = rig.BuildBlockWrite(1);
    EXPECT_EQ(manager.Submit(std::move(chain), AsyncCmdOptions{}), kIOReturnSuccess);
    EXPECT_FALSE(context.IsActive());
    EXPECT_EQ(context.CommandPtrWriteCount(), 1u);
    EXPECT_EQ(rig.ring.Size(), 3u);
}

} // namespace
} // namespace ASFW::Async::Engine
