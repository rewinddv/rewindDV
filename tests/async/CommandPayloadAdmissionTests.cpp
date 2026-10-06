// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
// Host-only: real command Submit, packet/payload/descriptor builders and tracking.
// Allocation/mapping are controlled host doubles. The final submit boundary always
// rejects the chain, so no AT context is armed and no completion is fabricated.
#include <gtest/gtest.h>
#include <algorithm>
#include <array>
#include <cstring>
#include "ASFWDriver/Async/Commands/WriteCommand.hpp"
#include "ASFWDriver/Async/Commands/LockCommand.hpp"
#include "ASFWDriver/Async/Commands/ReadCommand.hpp"
#include "ASFWDriver/Async/Commands/PhyCommand.hpp"
#include "ASFWDriver/Async/Contexts/ATRequestContext.hpp"
#include "ASFWDriver/Async/Tx/ResponseSender.hpp"
#include "ASFWDriver/Debug/BusResetPacketCapture.hpp"
#include "ASFWDriver/Hardware/OHCIDescriptors.hpp"

namespace {
using namespace ASFW::Async;
enum class Fault { none, allocation, mapping, nullAddress };
Fault fault = Fault::none;
size_t allocationAttempts = 0, submitAttempts = 0;
size_t liveBuffers = 0;
std::array<uint32_t, 4> submittedHeader{};
uint32_t submittedLength = 0;
uint64_t submittedAddress = 0;

class Buffer final : public IOBufferMemoryDescriptor {
public:
    explicit Buffer(size_t length) : bytes(length) { ++liveBuffers; }
    ~Buffer() override { --liveBuffers; }
    kern_return_t GetAddressRange(IOAddressSegment* range) override {
        *range = {reinterpret_cast<uint64_t>(bytes.data()), bytes.size()}; return kIOReturnSuccess;
    }
    kern_return_t GetLength(uint64_t* length) override { *length = bytes.size(); return kIOReturnSuccess; }
    kern_return_t CreateMapping(uint64_t, uint64_t, uint64_t offset,
                               uint64_t length, uint64_t, IOMemoryMap** map) override {
        if (fault == Fault::mapping) { *map = nullptr; return kIOReturnNoMemory; }
        if (offset > bytes.size() || length > bytes.size() - offset) return kIOReturnBadArgument;
        *map = new IOMemoryMap;
        (*map)->SetMockData(fault == Fault::nullAddress ? 0 : reinterpret_cast<uint64_t>(bytes.data()) + offset,
                           length ? length : bytes.size() - offset);
        return kIOReturnSuccess;
    }
    std::vector<uint8_t> bytes;
};

struct Rig {
    ASFW::Driver::HardwareInterface hardware;
    ASFW::Shared::DMAMemoryManager dma;
    ASFW::Shared::DescriptorRing ring;
    std::unique_ptr<DescriptorBuilder> builder;
    IODispatchQueue unusedWorkloop;
    OSAction unusedAction;
    ATRequestContext unusedContext; // Constructed, never initialized or armed.
    ASFW::Async::HW::OHCIDescriptor* descriptors = nullptr;
    static constexpr size_t capacity = 16;
    void Initialize() {
        ASSERT_TRUE(dma.Initialize(hardware, 4096));
        auto region = dma.AllocateRegion(capacity * sizeof(*descriptors));
        ASSERT_TRUE(region.has_value());
        descriptors = reinterpret_cast<ASFW::Async::HW::OHCIDescriptor*>(region->virtualBase);
        std::memset(descriptors, 0, capacity * sizeof(*descriptors));
        ASSERT_TRUE(ring.Initialize({descriptors, capacity}));
        ASSERT_TRUE(ring.Finalize(region->deviceBase));
        builder = std::make_unique<DescriptorBuilder>(ring, dma);
    }
    bool DescriptorsUntouched() const {
        const auto* first = reinterpret_cast<const uint8_t*>(descriptors);
        return std::all_of(first, first + capacity * sizeof(*descriptors), [](uint8_t b) { return b == 0; });
    }
};
Rig* currentRig = nullptr;
TransactionManager* currentTransactions = nullptr;
LabelAllocator* currentLabels = nullptr;
}

// Only heap-backed host allocations exist in this executable. No PCI, driver,
// controller, workloop, reset or register implementation is linked or invoked.
namespace ASFW::Driver {
HardwareInterface::HardwareInterface() = default;
HardwareInterface::~HardwareInterface() = default;
std::optional<HardwareInterface::DMABuffer> HardwareInterface::AllocateDMA(size_t length, uint64_t, size_t) {
    ++allocationAttempts;
    if (fault == Fault::allocation) return std::nullopt;
    DMABuffer result;
    result.descriptor = OSSharedPtr<IOBufferMemoryDescriptor>(new Buffer(length), OSNoRetain);
    result.dmaCommand = OSSharedPtr<IODMACommand>(new IODMACommand, OSNoRetain);
    result.deviceAddress = 0x10000000; result.length = length;
    return result;
}
}
namespace ASFW::Async::Engine {
struct ContextManager::State {};
ContextManager::ContextManager() noexcept = default;
ContextManager::~ContextManager() = default;
}
namespace ASFW::Debug { BusResetPacketCapture::~BusResetPacketCapture() = default; }
namespace ASFW::Async::Tx {
Submitter::Submitter(Engine::ContextManager& manager, DescriptorBuilder& builder) noexcept
    : ctxMgr_(manager), descriptorBuilder_(builder) {}
SubmitResult Submitter::submit_tx_chain(ATRequestContext*, DescriptorBuilder::DescriptorChain&& chain) noexcept {
    ++submitAttempts;
    const auto* immediate = reinterpret_cast<const HW::OHCIDescriptorImmediate*>(chain.first);
    std::copy(std::begin(immediate->immediateData), std::end(immediate->immediateData), submittedHeader.begin());
    submittedLength = chain.last != chain.first ? chain.last->reqCount : 0;
    submittedAddress = chain.last != chain.first ? chain.last->dataAddress : 0;
    // Reject at the hardware boundary; exercises unposted cleanup for every case.
    return {.kr = kIOReturnNotReady};
}
}
namespace ASFW::Async {
AsyncSubsystem::AsyncSubsystem() {
    sharedLock_ = IOLockAlloc();
    acceptingSubmissions_.store(true);
    hardware_ = &currentRig->hardware;
    descriptorBuilder_ = currentRig->builder.get();
    packetBuilder_ = std::make_unique<PacketBuilder>();
    labelAllocator_ = std::make_unique<LabelAllocator>(); labelAllocator_->Reset();
    txnMgr_ = std::make_unique<TransactionManager>();
    if (!txnMgr_->Initialize()) std::abort();
    EXPECT_EQ(CompletionQueue::Create(&currentRig->unusedWorkloop, 1024, &currentRig->unusedAction, completionQueue_), kIOReturnSuccess);
    if (!completionQueue_) std::abort();
    tracking_ = std::make_unique<Track_Tracking<CompletionQueue>>(labelAllocator_.get(), txnMgr_.get(), *completionQueue_);
    contextManager_ = std::make_unique<Engine::ContextManager>();
    submitter_ = std::make_unique<Tx::Submitter>(*contextManager_, *descriptorBuilder_);
    currentTransactions = txnMgr_.get(); currentLabels = labelAllocator_.get();
}
AsyncSubsystem::~AsyncSubsystem() { if (sharedLock_) IOLockFree(sharedLock_); }
std::optional<TransactionContext> AsyncSubsystem::PrepareTransactionContext() {
    return TransactionContext{.sourceNodeID = 0xFFC0, .generation = 1, .speedCode = 0,
                              .packetContext = {.sourceNodeID = 0xFFC0, .generation = 1, .speedCode = 0}};
}
ATRequestContext* AsyncSubsystem::ResolveAtRequestContext() noexcept { return &currentRig->unusedContext; }
uint64_t AsyncSubsystem::GetCurrentTimeUsec() const { return 1; }
// Unused virtual interfaces are link-only, never exercised by these tests.
AsyncHandle AsyncSubsystem::ReadWithRetry(const ReadParams&, const RetryPolicy&, CompletionCallback) { ADD_FAILURE(); return {}; }
bool AsyncSubsystem::Cancel(AsyncHandle) { ADD_FAILURE(); return false; }
void AsyncSubsystem::OnTxInterrupt() { ADD_FAILURE(); }
void AsyncSubsystem::OnRxInterrupt(ARContextType) { ADD_FAILURE(); }
kern_return_t AsyncSubsystem::ArmARContextsOnly() { ADD_FAILURE(); return kIOReturnNotReady; }
void AsyncSubsystem::OnBusResetBegin(uint8_t) { ADD_FAILURE(); }
void AsyncSubsystem::OnBusResetObserved() noexcept { ADD_FAILURE(); }
void AsyncSubsystem::OnBusResetComplete(uint8_t) { ADD_FAILURE(); }
void AsyncSubsystem::ConfirmBusGeneration(uint8_t) { ADD_FAILURE(); }
void AsyncSubsystem::StopATContextsOnly() { ADD_FAILURE(); }
void AsyncSubsystem::FlushATContexts() { ADD_FAILURE(); }
void AsyncSubsystem::RearmATContexts() { ADD_FAILURE(); }
void AsyncSubsystem::OnTimeoutTick() { ADD_FAILURE(); }
AsyncWatchdogStats AsyncSubsystem::GetWatchdogStats() const { return {}; }
DMAMemoryManager* AsyncSubsystem::GetDMAManager() { return &currentRig->dma; }
std::optional<AsyncStatusSnapshot> AsyncSubsystem::GetStatusSnapshot() const { return std::nullopt; }
Debug::AsyncTraceCapture* AsyncSubsystem::GetAsyncTraceCapture() const { return nullptr; }
ASFWDiagInboundCSRStats* AsyncSubsystem::GetInboundCSRStats() const { return nullptr; }
}

namespace {
class CommandPayloadAdmission : public testing::Test {
protected:
    Rig rig;
    std::unique_ptr<AsyncSubsystem> subsystem;
    size_t callbacks = 0;
    void SetUp() override {
        IODataQueueDispatchSource::allowInertCreationForTest = true;
        fault = Fault::none; submitAttempts = 0; allocationAttempts = 0;
        submittedHeader = {}; submittedLength = 0; submittedAddress = 0;
        rig.Initialize(); ASSERT_NE(rig.builder, nullptr);
        currentRig = &rig; subsystem = std::make_unique<AsyncSubsystem>();
        allocationAttempts = 0;
    }
    void TearDown() override {
        fault = Fault::none;
        subsystem.reset(); currentRig = nullptr; currentTransactions = nullptr; currentLabels = nullptr;
        rig.builder.reset(); rig.dma.Reset(); EXPECT_EQ(liveBuffers, 0u);
        IODataQueueDispatchSource::allowInertCreationForTest = false;
    }
    CompletionCallback Callback() { return [this](auto, auto, auto, auto) { ++callbacks; }; }
    void RejectedWithoutSubmission(AsyncHandle handle) {
        EXPECT_EQ(handle.value, 0u);
        EXPECT_EQ(submitAttempts, 0u);
        EXPECT_TRUE(rig.DescriptorsUntouched());
        EXPECT_EQ(currentTransactions->Count(), 0u);
        EXPECT_FALSE(currentLabels->HasAnyLabelsInUse());
        EXPECT_EQ(callbacks, 0u); // Existing unposted admission contract; R2-004 is separate.
        EXPECT_EQ(liveBuffers, 1u); // Only descriptor slab remains; temporary payload released.
    }
    WriteParams Write(bool forceBlock = false) {
        static const std::array<uint8_t, 8> data{1,2,3,4,5,6,7,8};
        return {.destinationID=1, .addressHigh=0xFFFF, .addressLow=0xF0000B00,
                .payload=data.data(), .length=forceBlock ? 4u : 8u, .forceBlock=forceBlock};
    }
    LockParams Lock() {
        static const std::array<uint8_t, 8> operands{0,0,0,1,0,0,0,2};
        return {.destinationID=1, .addressHigh=0xFFFF, .addressLow=0xF0000900,
                .operand=operands.data(), .operandLength=8, .responseLength=4};
    }
};
TEST_F(CommandPayloadAdmission, AllocationFailureRejectsBlockWriteBeforeDescriptors) {
    fault=Fault::allocation; RejectedWithoutSubmission(subsystem->Write(Write(), Callback())); EXPECT_EQ(allocationAttempts,1u);
}
TEST_F(CommandPayloadAdmission, MappingFailureRejectsBlockWriteBeforeDescriptors) {
    fault=Fault::mapping; RejectedWithoutSubmission(subsystem->Write(Write(), Callback())); EXPECT_EQ(allocationAttempts,1u);
}
TEST_F(CommandPayloadAdmission, NullCPUAddressRejectsBlockWriteBeforeDescriptors) {
    fault=Fault::nullAddress; RejectedWithoutSubmission(subsystem->Write(Write(), Callback()));
}
TEST_F(CommandPayloadAdmission, AllocationFailureRejectsLockBeforeDescriptors) {
    fault=Fault::allocation; RejectedWithoutSubmission(subsystem->Lock(Lock(), 2, Callback())); EXPECT_EQ(allocationAttempts,1u);
}
TEST_F(CommandPayloadAdmission, MappingFailureRejectsLockBeforeDescriptors) {
    fault=Fault::mapping; RejectedWithoutSubmission(subsystem->Lock(Lock(), 2, Callback())); EXPECT_EQ(allocationAttempts,1u);
}
TEST_F(CommandPayloadAdmission, ForcedFourByteBlockStillRequiresPayload) {
    fault=Fault::allocation; RejectedWithoutSubmission(subsystem->Write(Write(true), Callback()));
}
TEST_F(CommandPayloadAdmission, RepeatedFailureReturnsTransactionLabels) {
    fault=Fault::allocation;
    for (unsigned i=0;i<100;++i) RejectedWithoutSubmission(subsystem->Write(Write(), Callback()));
    EXPECT_EQ(allocationAttempts,100u);
}
TEST_F(CommandPayloadAdmission, ValidBlockWriteReachesBoundaryWithDeclaredPayload) {
    (void)subsystem->Write(Write(), Callback()); EXPECT_EQ(submitAttempts,1u);
    EXPECT_EQ((submittedHeader[0] >> 4) & 0xF,1u); EXPECT_EQ(submittedHeader[3] >> 16,8u);
    EXPECT_EQ(submittedLength,8u); EXPECT_NE(submittedAddress,0u);
    EXPECT_EQ(currentTransactions->Count(),0u); EXPECT_EQ(liveBuffers,1u);
}
TEST_F(CommandPayloadAdmission, ValidLockReachesBoundaryWithDeclaredPayload) {
    (void)subsystem->Lock(Lock(),2,Callback()); EXPECT_EQ(submitAttempts,1u);
    EXPECT_EQ((submittedHeader[0] >> 4) & 0xF,9u); EXPECT_EQ(submittedHeader[3] >> 16,8u);
    EXPECT_EQ(submittedLength,8u); EXPECT_NE(submittedAddress,0u);
}
TEST_F(CommandPayloadAdmission, ImmediateQuadletWriteNeedsNoDMA) {
    fault=Fault::allocation; auto p=Write(true); p.forceBlock=false;
    (void)subsystem->Write(p,Callback()); EXPECT_EQ(submitAttempts,1u); EXPECT_EQ(allocationAttempts,0u);
    EXPECT_EQ((submittedHeader[0] >> 4) & 0xF,0u); EXPECT_EQ(submittedLength,0u);
}
TEST_F(CommandPayloadAdmission, BlockReadNeedsNoOutgoingDMA) {
    fault=Fault::allocation;
    (void)subsystem->Read({.destinationID=1,.addressHigh=0xFFFF,.addressLow=0xF0000400,.length=16},Callback());
    EXPECT_EQ(submitAttempts,1u); EXPECT_EQ(allocationAttempts,0u);
    EXPECT_EQ((submittedHeader[0] >> 4) & 0xF,5u); EXPECT_EQ(submittedLength,0u);
}
TEST_F(CommandPayloadAdmission, PhyImmediateNeedsNoDMA) {
    fault=Fault::allocation; (void)subsystem->PhyRequest({.quadlet1=0x12345678,.quadlet2=0xEDCBA987},Callback());
    EXPECT_EQ(submitAttempts,1u); EXPECT_EQ(allocationAttempts,0u); EXPECT_EQ(submittedLength,0u);
}
}
