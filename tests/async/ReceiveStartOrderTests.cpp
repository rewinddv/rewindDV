#include <gtest/gtest.h>
#include <map>
#include <vector>
#include "ASFWDriver/Hardware/HardwareInterface.hpp"
#include "ASFWDriver/Hardware/OHCIConstants.hpp"
#include "ASFWDriver/Isoch/Receive/IsochReceiveContext.hpp"
#include "ASFWDriver/Testing/FakeDMAMemory.hpp"
using namespace ASFW::Driver;
using ASFW::Isoch::IsochReceiveContext;
namespace {
class Memory final : public ASFW::Isoch::Memory::IIsochDMAMemory {
    ASFW::Testing::FakeDMAMemory backing_{IsochReceiveContext::kNumDescriptors * 4096 + 1048576};
public:
    std::optional<ASFW::Shared::DMARegion> AllocateRegion(size_t n,size_t a=16) override { return backing_.AllocateRegion(n,a); }
    std::optional<ASFW::Shared::DMARegion> AllocateDescriptor(size_t n) override {return AllocateRegion(n);}
    std::optional<ASFW::Shared::DMARegion> AllocatePayloadBuffer(size_t n) override {return AllocateRegion(n);}
    uint64_t VirtToIOVA(const std::byte* p) const noexcept override {return backing_.VirtToIOVA(p);}
    std::byte* IOVAToVirt(uint64_t a) const noexcept override {return backing_.IOVAToVirt(a);}
    void PublishToDevice(const std::byte* p,size_t n) const noexcept override {backing_.PublishToDevice(p,n);}
    void FetchFromDevice(const std::byte* p,size_t n) const noexcept override {backing_.FetchFromDevice(p,n);}
    size_t TotalSize() const noexcept override {return backing_.TotalSize();}
    size_t AvailableSize() const noexcept override {return backing_.AvailableSize();}
};
class Device final : public IOPCIDevice {
public:
    std::map<uint64_t,uint32_t> regs;
    std::vector<std::pair<uint64_t,uint32_t>> writes;
    bool readyAtRun=false;
    kern_return_t Open(IOService*) override {return kIOReturnSuccess;}
    void Close(IOService*) override {}
    kern_return_t GetBARInfo(uint8_t,uint8_t* i,uint64_t* size,uint8_t* type) override {*i=0;*size=4096;*type=1;return kIOReturnSuccess;}
    void MemoryRead32(uint8_t,uint64_t offset,uint32_t* value) override {*value=regs[offset];}
    void MemoryWrite32(uint8_t,uint64_t offset,uint32_t value) override {
        writes.emplace_back(offset,value);
        const uint64_t event=uint64_t(Register32::kIsoRecvIntEventSet), mask=uint64_t(Register32::kIsoRecvIntMaskSet);
        if(offset==uint64_t(Register32::kIsoRecvIntEventClear)) {regs[event]&=~value;return;}
        if(offset==mask) {regs[mask]|=value;return;}
        if(offset==DMAContextHelpers::IsoRcvContextControlSet(0) && (value&ContextControl::kRun)) {
            readyAtRun=(regs[event]&1u)==0 && (regs[mask]&1u)!=0;
            regs[event]|=1u; // A completion arriving immediately when RUN is set.
        }
        regs[offset]=value;
    }
};
}
TEST(ReceiveStartOrderTests, ClearsOnlyOwnStaleEventBeforeUnmaskAndRunIncludingRestart) {
    auto* device=new Device; HardwareInterface hardware;
    ASSERT_EQ(hardware.Attach(nullptr,device),kIOReturnSuccess);
    auto memory=std::make_shared<Memory>(); auto ctx=IsochReceiveContext::Create(&hardware,memory);
    ASSERT_TRUE(ctx); ASSERT_EQ(ctx->Configure(2,0),kIOReturnSuccess);
    unsigned received = 0;
    ctx->SetCallback([&](std::span<const uint8_t> payload, uint32_t, uint64_t) {
        EXPECT_EQ(payload.size(), 1U);
        EXPECT_EQ(payload[0], received % 3);
        ++received;
    });
    for(unsigned iteration=0;iteration<2;++iteration) {
        device->regs[uint64_t(Register32::kIsoRecvIntEventSet)]=3u; // own stale event plus sibling
        device->regs[uint64_t(Register32::kIsoRecvIntMaskSet)]=2u;
        device->readyAtRun=false;
        ASSERT_EQ(ctx->Start(),kIOReturnSuccess);
        EXPECT_TRUE(device->readyAtRun);
        EXPECT_EQ(device->regs[uint64_t(Register32::kIsoRecvIntEventSet)],3u); // new completion + sibling retained
        EXPECT_EQ(ctx->Poll(), 0U); // no old completion after Start without Configure
        for (unsigned index = 0; index < 2; ++index) {
            ctx->TestPayloadAt(index)[0] = static_cast<uint8_t>(index);
            ctx->TestDescriptorAt(index)->statusWord = (0x11u << 16) | 4095;
        }
        const auto beforePoll = device->writes.size();
        EXPECT_EQ(ctx->Poll(), 2U);
        ASSERT_EQ(device->writes.size(), beforePoll + 1);
        EXPECT_EQ(device->writes.back().first, DMAContextHelpers::IsoRcvContextControlSet(0));
        EXPECT_EQ(device->writes.back().second, ContextControl::kWake);
        ctx->TestPayloadAt(2)[0] = 2;
        ctx->TestDescriptorAt(2)->statusWord = (0x11u << 16) | 4095;
        const auto beforeStop = device->writes.size();
        ASSERT_EQ(ctx->Stop(),kIOReturnSuccess);
        EXPECT_EQ(received, (iteration + 1) * 3);
        EXPECT_EQ(ctx->TestDescriptorAt(2)->statusWord, (0x11u << 16) | 4095);
        for (size_t index = beforeStop; index < device->writes.size(); ++index) {
            EXPECT_FALSE(device->writes[index].first == DMAContextHelpers::IsoRcvContextControlSet(0)
                         && (device->writes[index].second & ContextControl::kWake));
        }
    }
    ctx.reset(); hardware.Detach(); device->release();
}

TEST(ReceiveAllocationFailure, FactoryRejectsMissingLockWithoutTouchingHardware) {
    auto* device = new Device;
    HardwareInterface hardware;
    ASSERT_EQ(hardware.Attach(nullptr, device), kIOReturnSuccess);
    auto memory = std::make_shared<Memory>();
    const auto writes = device->writes.size();
    const auto nullCalls = ASFW::Testing::nullLockCalls;
    const auto available = memory->AvailableSize();
    {
        ASFW::Testing::ScopedLockAllocationFailure failure;
        auto context = IsochReceiveContext::Create(&hardware, memory);
        EXPECT_FALSE(context);
    }
    EXPECT_EQ(ASFW::Testing::nullLockCalls, nullCalls);
    EXPECT_EQ(device->writes.size(), writes);
    EXPECT_EQ(memory->AvailableSize(), available);
    EXPECT_EQ(memory.use_count(), 1);
    EXPECT_TRUE(IsochReceiveContext::Create(&hardware, memory));
    hardware.Detach();
    device->release();
}

TEST(ReceiveAllocationFailure, PublicConstructorStaysInertAfterMissingLock) {
    const auto nullCalls = ASFW::Testing::nullLockCalls;
    {
        ASFW::Testing::ScopedLockAllocationFailure failure;
        IsochReceiveContext context;
        EXPECT_EQ(context.GetState(), ASFW::Isoch::IRPolicy::State::Stopped);
        EXPECT_EQ(context.Configure(1, 0), kIOReturnNoMemory);
        EXPECT_EQ(context.Start(), kIOReturnNoMemory);
        EXPECT_EQ(context.Stop(), kIOReturnSuccess);
        EXPECT_EQ(context.Poll(), 0U);
    }
    EXPECT_EQ(ASFW::Testing::nullLockCalls, nullCalls);
}
