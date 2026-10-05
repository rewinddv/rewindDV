#include "../FoundationReceiveService.hpp"
#include "../FoundationRawReceiveSink.hpp"
#include "../FoundationActivityGate.hpp"
#include "../../../ASFWDriver/Discovery/DeviceRegistry.hpp"
#include "../../../ASFWDriver/Isoch/IsochService.hpp"
#include "../../../ASFWDriver/Protocols/AVC/CMP/CMPClient.hpp"
#include "../../../ASFWDriver/Bus/IRM/IRMClient.hpp"
#include "../../../tests/mocks/DeferredFireWireBus.hpp"
#include "../../../ASFWDriver/UserClient/Core/ReceiveOwnerToken.hpp"
#include <DriverKit/IOUserClient.h>
#include <cassert>
#include <cstdio>
#include <deque>
#include <vector>
#include <thread>
#include <algorithm>
#include <chrono>

namespace RewindDV::Foundation::Receive::Testing {
void FailNextRingAllocation() noexcept;
}

namespace RX = RewindDV::Foundation::Receive;
namespace Policy = RewindDV::Foundation::DriverPolicy;
using ASFW::Async::AsyncStatus;
using ASFW::Driver::HardwareInterface;
using ASFW::Driver::Register32;

class HeldReads : public ASFW::Async::Testing::DeferredFireWireBus {
public:
    std::deque<ASFW::Async::InterfaceCompletionCallback> pending;
    uint32_t reads{};
    ASFW::Async::AsyncHandle ReadBlock(ASFW::FW::Generation, ASFW::FW::NodeId,
        ASFW::Async::FWAddress, uint32_t length, ASFW::FW::FwSpeed,
        ASFW::Async::InterfaceCompletionCallback callback) override {
        assert(length == 4);
        pending.push_back(std::move(callback));
        return ASFW::Async::AsyncHandle{++reads};
    }
    void Complete(uint32_t value) {
        assert(!pending.empty());
        auto callback = std::move(pending.front());
        pending.pop_front();
        std::array<uint8_t, 4> bytes{uint8_t(value >> 24), uint8_t(value >> 16), uint8_t(value >> 8), uint8_t(value)};
        callback(AsyncStatus::kSuccess, bytes);
    }
    void CompleteWithStatus(AsyncStatus status) {
        assert(status != AsyncStatus::kSuccess);
        assert(!pending.empty());
        auto callback = std::move(pending.front());
        pending.pop_front();
        callback(status, std::span<const uint8_t>{});
    }
};
uint32_t DecodeBigEndianQuadlet(std::span<const uint8_t> bytes) {
    assert(bytes.size() >= 4);
    return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
           (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}
struct Fixture {
    HeldReads bus;
    std::shared_ptr<HardwareInterface> hardware = std::make_shared<HardwareInterface>();
    std::shared_ptr<ASFW::Discovery::DeviceRegistry> registry = std::make_shared<ASFW::Discovery::DeviceRegistry>();
    std::shared_ptr<ASFW::CMP::CMPClient> cmp;
    std::shared_ptr<ASFW::IRM::IRMClient> irm;
    ASFW::Driver::IsochService isoch;
    RX::Service service;
    Policy::FoundationRouteWire route;
    RX::SessionWire session;
    ASFW::Async::FireWireBusImpl::LinkSpeedDecision speedDecision{};
    unsigned quarantineCalls{};
    explicit Fixture(ASFW::FW::FwSpeed storedSpeed = ASFW::FW::FwSpeed::S100) {
        ASFW::Discovery::ConfigROM rom{};
        rom.bib.guid = 0x800460106d21234ULL;
        rom.gen = ASFW::FW::Generation{7};
        rom.nodeId = 3;
        ASFW::Discovery::LinkPolicy link{};
        link.localToNode = storedSpeed;
        (void)registry->UpsertFromROM(rom, link);
        const auto token = registry->CurrentRoute(rom.bib.guid);
        assert(token);
        route.guid = token->guid;
        route.driverInstanceID = 123;
        route.deviceIncarnation = token->deviceIncarnation;
        route.routeEpoch = token->routeEpoch;
        route.generation = token->generation.value;
        route.nodeID = token->nodeId;
        cmp = std::make_shared<ASFW::CMP::CMPClient>(bus, bus, *registry);
        bus.SetGeneration(ASFW::FW::Generation{7});
        bus.SetLocalNodeID(ASFW::FW::NodeId{0});
        irm = std::make_shared<ASFW::IRM::IRMClient>(bus);
        irm->SetIRMNode(2, ASFW::IRM::Generation{7});
    }
    kern_return_t Start() { return service.Start(10, route, 123, isoch, hardware, registry, cmp, irm,
        speedDecision, [this] { ++quarantineCalls; }, session); }
    RX::StatusWire Status() {
        RX::StatusWire result{};
        assert(service.Snapshot(10, session.epoch, result) == kIOReturnSuccess);
        return result;
    }
    void Active() {
        assert(Start() == kIOReturnSuccess);
        assert(Status().state == uint32_t(RX::State::Preparing));
        bus.Complete(1); // one output plug
        bus.Complete(0xc0020078); // online broadcast on observed channel 2
        assert(Status().state == uint32_t(RX::State::Active));
        assert(Status().channel == 2 && Status().channelEvidence == 1);
        assert(bus.WriteCount() == 0 && bus.LockCount() == 0);
    }
    void ManagedActive(uint32_t bandwidthBaseline = 4915) {
        bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(Start() == kIOReturnSuccess);
        bus.Complete(0x3fffff01); // one output plug, S100, broadcast channel 63
        bus.Complete(0x803f3c7a); // M25: online, free, channel 63, payload 0x7a
        bus.Complete(bandwidthBaseline); // observed pre-allocation accounting baseline
        bus.Complete(0x80000000); // channel 0 available
        bus.Complete(0xffffffff); // channels 32-63 available
        bus.Complete(0x80000000); // allocate channel 0 read
        bus.Complete(bandwidthBaseline); // allocate bandwidth read
        bus.Complete(0x3fffff01); // CMP connect reads oMPR
        bus.Complete(0x803f3c7a); // CMP connect reads free oPCR
        assert(Status().state == uint32_t(RX::State::Active));
        assert(Status().channel == 0);
        assert(Status().channelEvidence == uint32_t(RX::ChannelEvidence::OwnedManagedP2P));
        assert(bus.WriteCount() == 0 && bus.LockCount() == 3);
    }
};

int main() {
    static_assert(RX::RawSink::RequiredBytes() == 272630016);
    {
        Fixture f;
        f.speedDecision.topologyValid = true;
        f.speedDecision.generation8 = 8;
        f.speedDecision.targetNodeId = 3;
        assert(f.Start() == kIOReturnNotReady);
        assert(f.bus.pending.empty());
        assert(f.bus.LockCount() == 0);
    }
    {
        // The stored discovery policy and both plug registers permit S400, but
        // an owned admission-time topology decision proves only S100. The
        // production receive path must charge the unchanged DV formula at the
        // slowest full-path ceiling: 480 overhead + 2000 packet = 2480 units.
        Fixture f{ASFW::FW::FwSpeed::S400};
        f.speedDecision.selected = ASFW::FW::FwSpeed::S100;
        f.speedDecision.topologyCeiling = ASFW::FW::FwSpeed::S100;
        f.speedDecision.generation16 = 7;
        f.speedDecision.generation8 = 7;
        f.speedDecision.localNodeId = 0;
        f.speedDecision.targetNodeId = 3;
        f.speedDecision.topologyValid = true;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0xbf000001); // one output plug, S400
        f.bus.Complete(0x803fbc7a); // online/free, S400, overhead 15, payload 0x7a
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.Complete(0x80000000);
        f.bus.Complete(4915);
        const auto& allocationOperand = f.bus.LastLockOperand();
        assert(allocationOperand.size() == 8);
        assert(DecodeBigEndianQuadlet(
                   std::span<const uint8_t>{allocationOperand}.subspan(0, 4)) == 4915);
        assert(DecodeBigEndianQuadlet(
                   std::span<const uint8_t>{allocationOperand}.subspan(4, 4)) == 2435);
        f.bus.Complete(0xbf000001);
        f.bus.Complete(0x803fbc7a);
        const auto& connectOperand = f.bus.LastLockOperand();
        assert(connectOperand.size() == 8);
        const uint32_t connectedPCR = DecodeBigEndianQuadlet(
            std::span<const uint8_t>{connectOperand}.subspan(4, 4));
        assert(ASFW::CMP::PCRBits::GetP2P(connectedPCR) == 1);
        assert(ASFW::CMP::PCRBits::GetChannel(connectedPCR) == 0);
        assert(f.Status().state == uint32_t(RX::State::Active));
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        f.bus.Complete(connectedPCR);
        f.bus.Complete(2435);
        const auto& releaseBandwidthOperand = f.bus.LastLockOperand();
        assert(releaseBandwidthOperand.size() == 8);
        assert(DecodeBigEndianQuadlet(
                   std::span<const uint8_t>{releaseBandwidthOperand}.subspan(0, 4)) == 2435);
        assert(DecodeBigEndianQuadlet(
                   std::span<const uint8_t>{releaseBandwidthOperand}.subspan(4, 4)) == 4915);
        f.bus.Complete(0x00000000);
        const auto& releaseChannelOperand = f.bus.LastLockOperand();
        assert(releaseChannelOperand.size() == 8);
        assert(DecodeBigEndianQuadlet(
                   std::span<const uint8_t>{releaseChannelOperand}.subspan(4, 4)) ==
               0x80000000);
        assert(f.Status().state == uint32_t(RX::State::Stopped));
    }
    {
        const auto began = std::chrono::steady_clock::now();
        IOBufferMemoryDescriptor* memory{};
        assert(IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOutIn,
            RX::RawSink::RequiredBytes(), 64, &memory) == kIOReturnSuccess);
        const auto allocated = std::chrono::steady_clock::now();
        assert(memory != nullptr);
        IOAddressSegment range{};
        assert(memory->GetAddressRange(&range) == kIOReturnSuccess);
        assert(range.length == RX::RawSink::RequiredBytes());
        RX::RawSink sink;
        assert(!sink.Initialize(nullptr, range.length, 1, {}));
        assert(!sink.Initialize(reinterpret_cast<void*>(range.address), range.length - 1, 1, {}));
        assert(sink.Initialize(reinterpret_cast<void*>(range.address), range.length, 1, {}));
        const auto initialized = std::chrono::steady_clock::now();
        assert(sink.Snapshot().capacity == RX::kCapacity);
        const std::array<uint8_t, 1> opaque{0x5a};
        ASFW::Isoch::IsochReceivePacket packet{.descriptorIndex = 1, .payload = opaque};
        const ASFW::Isoch::IsochReceiveBatch batch{};
        for (uint32_t i = 0; i < RX::kCapacity; ++i) sink.ConsumePacket(batch, packet);
        auto* records = reinterpret_cast<RX::Record*>(range.address + sizeof(RX::RingHeader));
        assert(sink.Snapshot().writeSequence == RX::kCapacity);
        assert(records[0].writeSequence == 1 && records[RX::kCapacity - 1].writeSequence == RX::kCapacity);
        sink.ConsumePacket(batch, packet);
        assert(sink.Snapshot().dropped == 1 && sink.Snapshot().writeSequence == RX::kCapacity);
        assert(!sink.Acknowledge(RX::kCapacity + 1));
        assert(sink.Acknowledge(1));
        sink.ConsumePacket(batch, packet);
        assert(sink.Snapshot().writeSequence == RX::kCapacity + 1);
        assert(records[0].writeSequence == RX::kCapacity + 1);
        assert(records[0].lossBefore == 1 && records[0].observedSequence == RX::kCapacity + 2);
        assert(records[1].writeSequence == 2);
        assert(!sink.Acknowledge(0));
        memory->release();
        const auto allocationMs = std::chrono::duration<double, std::milli>(allocated - began).count();
        const auto zeroMs = std::chrono::duration<double, std::milli>(initialized - allocated).count();
        std::printf("Host ring allocation %.2f ms; initialize/zero %.2f ms; bytes %llu (not DriverKit timing)\n",
            allocationMs, zeroMs, static_cast<unsigned long long>(RX::RawSink::RequiredBytes()));
    }
    {
        Fixture f;
        RX::Testing::FailNextRingAllocation();
        assert(f.Start() == kIOReturnNoMemory && f.bus.reads == 0);
        assert(!Policy::IsActivityActive(Policy::ActivityKind::kReceive));
        assert(f.Start() == kIOReturnSuccess);
        assert(f.Status().capacity == RX::kCapacity);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
    }
    {
        ASFW::UserClient::ReceiveOwnerTokenAllocator allocator;
        std::array<std::array<uint64_t, 256>, 4> tokens{};
        std::array<std::thread, 4> threads;
        for (size_t i = 0; i < threads.size(); ++i)
            threads[i] = std::thread([&, i] { for (auto& token : tokens[i]) token = allocator.Allocate(); });
        for (auto& thread : threads) thread.join();
        std::vector<uint64_t> all;
        for (const auto& group : tokens) all.insert(all.end(), group.begin(), group.end());
        std::sort(all.begin(), all.end());
        for (size_t i = 0; i < all.size(); ++i) assert(all[i] == i + 1);
        ASFW::UserClient::ReceiveOwnerTokenAllocator exhausted(UINT64_MAX - 1);
        assert(exhausted.Allocate() == UINT64_MAX - 1);
        assert(exhausted.Allocate() == 0 && exhausted.Allocate() == 0);
    }
    {
        alignas(8) std::array<uint8_t, RX::RawSink::RequiredBytes(2)> storage{};
        RX::RawSink sink;
        assert(sink.Initialize(storage.data(), storage.size(), 1, {}, 2));
        const std::array<uint8_t, 7> opaque{0xff, 0, 0x81, 4, 5, 6, 7};
        ASFW::Isoch::IsochReceivePacket packet{.descriptorIndex = 22, .transferStatus = 0x12,
            .residualCount = 4096 - 7, .payload = opaque};
        const ASFW::Isoch::IsochReceiveBatch batch{.drainCycleTimer = 33, .drainHostTicks = 44};
        sink.ConsumePacket(batch, packet);
        sink.ConsumePacket(batch, packet);
        sink.ConsumePacket(batch, packet);
        assert(sink.Snapshot().writeSequence == 2 && sink.Snapshot().dropped == 1);
        assert(!sink.Acknowledge(3));
        auto* records = reinterpret_cast<RX::Record*>(storage.data() + 256);
        assert(records[0].payloadBytes == 7 && records[0].transferStatus == 0x12);
        assert(records[0].descriptorIndex == 22 && records[0].hostTicks == 44);
        assert(std::memcmp(records[0].payload.data(), opaque.data(), 7) == 0);
        assert(sink.Acknowledge(1) && !sink.Acknowledge(0));
        sink.ConsumePacket(batch, packet);
        assert(records[0].writeSequence == 3 && records[0].observedSequence == 4 && records[0].lossBefore == 1);
        assert(records[1].writeSequence == 2); // unacknowledged record not overwritten
    }
    {
        Fixture f;
        f.route.driverInstanceID = 124;
        assert(f.Start() == kIOReturnBadArgument && f.bus.reads == 0);
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
        f.bus.Complete(1); // late CMP callback retains its own dependencies
        assert(f.bus.reads == 1 && f.isoch.ReceiveContext() == nullptr);
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(1);
        f.registry->InvalidateLiveMappingsForBusReset();
        f.bus.Complete(0xc0020078);
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.isoch.ReceiveContext() == nullptr);
        assert(Policy::TryAcquireActivity(Policy::ActivityKind::kInspector) == 0);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
        const auto inspector = Policy::TryAcquireActivity(Policy::ActivityKind::kInspector);
        assert(inspector != 0);
        Policy::ReleaseActivity(inspector);
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(1);
        f.bus.Complete(0x80020078); // online but neither broadcast nor connected
        f.bus.Complete(4915);
        f.bus.Complete(0); // no allocatable channel: fail closed, no guessed fallback
        f.bus.Complete(0);
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.isoch.ReceiveContext() == nullptr); // no guessed fallback channel
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.CompleteWithStatus(AsyncStatus::kTimeout); // no resource values observed
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.bus.pending.empty() && f.bus.LockCount() == 0);
    }
    {
        Fixture f;
        f.ManagedActive();
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        // Positive IR quiescence precedes owned CMP disconnect; only after its
        // successful BREAK may this session release its IRM bandwidth/channel.
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        f.bus.Complete(0x8100007a); // disconnect reads our p2p=1/channel=0 oPCR
        f.bus.Complete(4915 - 2480); // release the exact owned bandwidth
        const auto& releaseOperand = f.bus.LastLockOperand();
        assert(DecodeBigEndianQuadlet(std::span<const uint8_t>{releaseOperand}.subspan(4, 4)) == 4915);
        f.bus.Complete(0x00000000);  // release channel 0 read
        assert(f.Status().state == uint32_t(RX::State::Stopped));
        assert(f.bus.LockCount() == 6); // connect + allocate(2) + disconnect + release(2)
    }
    for (unsigned cycle = 0; cycle != 2; ++cycle) {
        Fixture f;
        f.ManagedActive(5000);
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        f.bus.Complete(0x8100007a);
        f.bus.Complete(2520);
        const auto& operand = f.bus.LastLockOperand();
        assert(operand.size() == 8);
        assert(DecodeBigEndianQuadlet(std::span<const uint8_t>{operand}.subspan(0, 4)) == 2520);
        assert(DecodeBigEndianQuadlet(std::span<const uint8_t>{operand}.subspan(4, 4)) == 5000);
        f.bus.Complete(0x00000000);
        assert(f.Status().state == uint32_t(RX::State::Stopped));
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(0x2000); // outside the 13-bit CSR value field
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.bus.pending.empty() && f.bus.LockCount() == 0);
    }
    {
        Fixture f;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f03ff); // legal PCR fields, but impossible S100 DV budget
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.bus.pending.empty() && f.bus.LockCount() == 0);
    }
    {
        Fixture f;
        f.ManagedActive(5000);
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        f.bus.Complete(0x8100007a);
        f.bus.Complete(UINT32_MAX); // checked-wide sum exceeds CSR and owned baseline
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        f.bus.Complete(0x00000000); // channel cleanup still runs; bandwidth remains uncertain
        assert(f.Status().state == uint32_t(RX::State::Quarantined));
        assert(f.quarantineCalls == 1 && f.bus.pending.empty());
        assert(f.service.ReleaseOwner(10) != kIOReturnSuccess);
    }
    {
        Fixture f;
        f.ManagedActive(5000);
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        f.bus.Complete(0x8100007a);
        f.bus.Complete(5001); // another participant moved availability above our baseline
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        f.bus.Complete(0x00000000); // no bandwidth credit; release only our channel
        assert(f.Status().state == uint32_t(RX::State::Quarantined));
        assert(f.quarantineCalls == 1 && f.bus.pending.empty());
        assert(f.service.ReleaseOwner(10) != kIOReturnSuccess);
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        // Stop while resource allocation is preparing. A late successful
        // allocation is released and can never arm receive or connect the PCR.
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        f.bus.Complete(0x80000000);
        f.bus.Complete(4915);
        f.bus.Complete(4915 - 2480);
        f.bus.Complete(0x00000000);
        assert(f.Status().state == uint32_t(RX::State::Stopped));
        assert(f.isoch.ReceiveContext() == nullptr);
        assert(f.bus.LockCount() == 4); // allocation and exact owned rollback only
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.SetDeferLocks(true);
        f.bus.Complete(0x80000000); // channel allocation CAS now pending in generation 7
        assert(f.bus.PendingLockCount() == 1);
        const auto locks = f.bus.LockCount();
        f.bus.SetGeneration(ASFW::FW::Generation{8});
        f.irm->SetIRMNode(2, ASFW::IRM::Generation{8});
        f.bus.SetDeferLocks(false);
        assert(f.bus.DrainLocks() == 1);
        assert(f.Status().state == uint32_t(RX::State::Failed));
        assert(f.bus.LockCount() == locks && f.bus.pending.empty());
        assert(f.isoch.ReceiveContext() == nullptr); // no bandwidth/CMP retry in generation 8
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.Complete(0x80000000);
        f.bus.Complete(4915);
        f.bus.Complete(0x3fffff01);
        f.bus.SetDeferLocks(true);
        f.bus.Complete(0x803f3c7a);
        assert(f.bus.PendingLockCount() == 1);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        assert(f.isoch.ReceiveContext() == nullptr);
        // The allocation stays owned while the CMP CAS is unresolved.
        assert(f.bus.pending.empty());
        f.bus.SetDeferLocks(false);
        assert(f.bus.DrainLocks() == 1);
        f.bus.Complete(0x8100007a);
        f.bus.Complete(4915 - 2480);
        f.bus.Complete(0x00000000);
        assert(f.Status().state == uint32_t(RX::State::Stopped));
        assert(f.isoch.ReceiveContext() == nullptr);
        assert(f.bus.LockCount() == 6);
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.Complete(0x80000000);
        f.bus.Complete(4915);
        f.bus.Complete(0x3fffff01);
        f.bus.SetDeferLocks(true);
        f.bus.SetNextLockStatus(AsyncStatus::kTimeout);
        f.bus.Complete(0x803f3c7a); // connect CAS submitted; mutation result ambiguous
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        assert(f.bus.DrainLocks() == 1);
        assert(f.Status().state == uint32_t(RX::State::Quarantined));
        assert(f.quarantineCalls == 1 && f.isoch.ReceiveContext() == nullptr);
        assert(f.bus.pending.empty()); // no CMP disconnect or IRM release from guessed ownership
        assert(f.service.ReleaseOwner(10) == kIOReturnTimeout);
        assert(f.Start() == kIOReturnBusy);
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.Complete(0x80000000); // channel allocation succeeds
        f.bus.Complete(0);          // insufficient bandwidth, rollback channel read follows
        f.bus.SetDeferLocks(true);
        f.bus.SetNextLockStatus(AsyncStatus::kTimeout);
        f.bus.Complete(0);          // rollback CAS submitted; release result ambiguous
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::CleanupPending));
        assert(f.bus.DrainLocks() == 1);
        assert(f.Status().state == uint32_t(RX::State::Quarantined));
        assert(f.quarantineCalls == 1 && f.isoch.ReceiveContext() == nullptr);
        assert(f.bus.pending.empty());
        assert(f.service.ReleaseOwner(10) == kIOReturnNoResources);
        assert(f.Start() == kIOReturnBusy);
    }
    {
        Fixture f;
        f.ManagedActive();
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        const auto locksBeforeReset = f.bus.LockCount();
        assert(f.service.StopAll(true) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.Status().capacity == RX::kCapacity);
        assert(f.service.Acknowledge(10, f.session.epoch, 0) == kIOReturnSuccess);
        assert(f.service.Acknowledge(11, f.session.epoch, 0) == kIOReturnNotPrivileged);
        assert(f.bus.LockCount() == locksBeforeReset && f.bus.pending.empty());
    }
    {
        Fixture f;
        f.ManagedActive();
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        const auto locks = f.bus.LockCount();
        f.registry->InvalidateLiveMappingsForBusReset();
        f.bus.SetGeneration(ASFW::FW::Generation{8});
        f.irm->SetIRMNode(2, ASFW::IRM::Generation{8});
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.bus.LockCount() == locks && f.bus.pending.empty());
    }
    {
        Fixture f;
        f.ManagedActive();
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        const auto locks = f.bus.LockCount();
        f.registry->InvalidateLiveMappingsForBusReset();
        f.bus.SetGeneration(ASFW::FW::Generation{8});
        f.irm->SetIRMNode(2, ASFW::IRM::Generation{8});
        f.bus.Complete(0x8100007a); // late disconnect read; no stale CAS or IRM release
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.bus.LockCount() == locks && f.bus.pending.empty());
    }
    {
        Fixture f;
        f.bus.SetLockMode(HeldReads::LockMode::kEchoCompare);
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(0x3fffff01);
        f.bus.Complete(0x803f3c7a);
        f.bus.Complete(4915);
        f.bus.Complete(0x80000000);
        f.bus.Complete(0xffffffff);
        f.bus.Complete(0x80000000);
        f.bus.Complete(4915);
        f.bus.Complete(0x3fffff01);
        f.bus.SetDeferLocks(true);
        f.bus.Complete(0x803f3c7a);
        const auto locks = f.bus.LockCount();
        f.registry->InvalidateLiveMappingsForBusReset();
        f.bus.SetGeneration(ASFW::FW::Generation{8});
        f.irm->SetIRMNode(2, ASFW::IRM::Generation{8});
        f.bus.SetDeferLocks(false);
        assert(f.bus.DrainLocks() == 1); // late connect CAS completion owns nothing in gen 8
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.isoch.ReceiveContext() == nullptr);
        assert(f.bus.LockCount() == locks && f.bus.pending.empty());
    }
    {
        Fixture f;
        f.Active();
        uint64_t options{};
        IOMemoryDescriptor* memory{};
        assert(f.service.CopyMemory(11, &options, &memory) == kIOReturnNotPrivileged);
        assert(f.service.CopyMemory(10, &options, &memory) == kIOReturnSuccess);
        assert(options == kIOUserClientMemoryReadOnly);
        uint64_t length{};
        assert(memory->GetLength(&length) == kIOReturnSuccess);
        assert(length == RX::RawSink::RequiredBytes());
        IOAddressSegment range{};
        assert(memory->GetAddressRange(&range) == kIOReturnSuccess);
        auto* records = reinterpret_cast<const RX::Record*>(range.address + sizeof(RX::RingHeader));
        // Reset-time partial/error completion: the final drain must preserve the
        // exact bytes and status, including a tail not divisible by 16. The real
        // DMA alignment trap is covered separately by the ARM64 codegen check.
        auto context = f.isoch.CopyReceiveContext();
        // Crash registers retained statusWord=0x841d0ea4: 4096-0x0ea4=348 bytes.
        constexpr uint16_t partialLength = 348;
        constexpr uint16_t partialStatus = 0x841d;
        for (uint16_t i = 0; i < partialLength; ++i) context->TestPayloadAt(0)[i] = uint8_t(i * 17);
        context->TestDescriptorAt(0)->statusWord = (uint32_t(partialStatus) << 16) | (4096 - partialLength);
        memory->release();
        assert(f.service.Stop(11, f.session.epoch) == kIOReturnNotPrivileged);
        assert(f.service.Stop(10, f.session.epoch + 1) == kIOReturnNotPrivileged);
        f.hardware->SetTestRegister(static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.StopAll(true) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.Status().writeSequence == 1 && f.Status().dropped == 0);
        assert(records[0].payloadBytes == partialLength && records[0].transferStatus == partialStatus);
        assert(records[0].residualCount == 4096 - partialLength);
        for (uint16_t i = 0; i < partialLength; ++i) assert(records[0].payload[i] == uint8_t(i * 17));
        for (size_t i = partialLength; i < RX::kPayloadBytes; ++i) assert(records[0].payload[i] == 0);
        assert(f.service.StopAll(true) == kIOReturnSuccess);
        assert(context->Poll() == 0 && f.Status().writeSequence == 1); // no duplicate final drain
        const auto terminalEpoch = f.session.epoch;
        assert(f.Start() == kIOReturnBusy);
        RX::SessionWire other;
        assert(f.service.Start(11, f.route, 123, f.isoch, f.hardware, f.registry, f.cmp, f.irm,
                              f.speedDecision, [] {}, other) == kIOReturnBusy);
        assert(f.Status().epoch == terminalEpoch);
        // Terminal status does not end inspector exclusion: the raw ring is
        // still owner-retained for final snapshot/acknowledgement and drain.
        assert(Policy::TryAcquireActivity(Policy::ActivityKind::kInspector) == 0);
        assert(f.isoch.ReleaseQuiescedReceiveContexts() == kIOReturnSuccess);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
        const auto inspector = Policy::TryAcquireActivity(Policy::ActivityKind::kInspector);
        assert(inspector != 0);
        Policy::ReleaseActivity(inspector);
        assert(f.service.CopyMemory(10, &options, &memory) == kIOReturnNotReady);
    }
    {
        // Whole-tape -> whole-tape reuses the DMA context but must replace the
        // consumer/session and reset every completion, anchor and terminal link.
        Fixture f;
        std::shared_ptr<ASFW::Isoch::IsochReceiveContext> reused;
        uint64_t previousEpoch = 0;
        for (unsigned run = 0; run < 3; ++run) {
            f.Active();
            auto context = f.isoch.CopyReceiveContext();
            if (reused) assert(context == reused);
            reused = context;
            assert(f.session.epoch > previousEpoch);
            previousEpoch = f.session.epoch;
            const auto capacity = ASFW::Isoch::IsochReceiveContext::kNumDescriptors;
            for (size_t i = 0; i < capacity; ++i) {
                assert(context->TestDescriptorAt(i)->statusWord == 4096);
                assert((context->TestDescriptorAt(i)->branchWord & 0xf) == (i + 1 < capacity ? 1 : 0));
            }
            assert(context->Poll() == 0 && f.Status().writeSequence == 0);
            // Leave a consumed anchor away from descriptor zero after wraps.
            const size_t packets = 2 * capacity + 184;
            for (size_t i = 0; i < packets; ++i) {
                const size_t index = i % capacity;
                context->TestPayloadAt(index)[0] = uint8_t(run);
                context->TestDescriptorAt(index)->statusWord = (0x8411u << 16) | (4096 - 496);
                assert(context->Poll() == 1);
            }
            auto* finalDescriptor = context->TestDescriptorAt(packets % capacity);
            finalDescriptor->statusWord = (0x841du << 16) | (4096 - 348);
            f.hardware->SetTestRegister(static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
            const auto stopped = run == 0 ? f.service.Stop(10, f.session.epoch) : f.service.StopAll(true);
            assert(stopped == kIOReturnSuccess);
            assert(f.Status().writeSequence == packets + 1 && f.Status().dropped == 0);
            assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
            assert(f.isoch.CopyReceiveContext() == context);
        }
        assert(f.isoch.ReleaseQuiescedReceiveContexts() == kIOReturnSuccess);
    }
    {
        // A real generation transition invalidates the old route. Rearm the
        // same service/context only after final ACK and owner close, using a
        // newly discovered route and new receive epoch. No stale cleanup CAS.
        Fixture f;
        f.ManagedActive();
        const auto oldRoute = f.route;
        const auto oldEpoch = f.session.epoch;
        auto context = f.isoch.CopyReceiveContext();
        context->TestPayloadAt(0)[0] = 0x42;
        context->TestDescriptorAt(0)->statusWord = (0x841du << 16) | (4096 - 348);
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        f.registry->InvalidateLiveMappingsForBusReset();
        f.bus.SetGeneration(ASFW::FW::Generation{8});
        f.irm->SetIRMNode(2, ASFW::IRM::Generation{8});
        const auto locks = f.bus.LockCount();
        assert(f.service.StopAll(true) == kIOReturnSuccess);
        assert(f.Status().state == uint32_t(RX::State::BusReset));
        assert(f.Status().writeSequence == 1 && f.Status().acknowledgedSequence == 0);
        assert(f.bus.LockCount() == locks && f.bus.pending.empty());
        assert(f.service.Acknowledge(10, oldEpoch, 1) == kIOReturnSuccess);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
        ASFW::Discovery::ConfigROM rom{};
        rom.bib.guid = oldRoute.guid; rom.gen = ASFW::FW::Generation{8}; rom.nodeId = 4;
        ASFW::Discovery::LinkPolicy link{}; link.localToNode = ASFW::FW::FwSpeed::S100;
        (void)f.registry->UpsertFromROM(rom, link);
        const auto token = f.registry->CurrentRoute(oldRoute.guid); assert(token);
        assert(f.Start() != kIOReturnSuccess); // old generation never readmitted
        f.route.deviceIncarnation = token->deviceIncarnation; f.route.routeEpoch = token->routeEpoch;
        f.route.generation = token->generation.value; f.route.nodeID = token->nodeId;
        assert(f.Start() == kIOReturnSuccess);
        f.bus.Complete(1); f.bus.Complete(0xc0020078);
        assert(f.Status().state == uint32_t(RX::State::Active));
        assert(f.bus.LockCount() == locks && f.bus.WriteCount() == 0);
        assert(f.session.epoch > oldEpoch && f.Status().writeSequence == 0);
        assert(f.isoch.CopyReceiveContext() == context);
        assert(f.service.Acknowledge(10, oldEpoch, 1) != kIOReturnSuccess);
        context->TestPayloadAt(0)[0] = 0x43;
        context->TestDescriptorAt(0)->statusWord = (0x8411u << 16) | (4096 - 496);
        assert(context->Poll() == 1 && f.Status().writeSequence == 1);
        f.hardware->SetTestRegister(
            static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)), 0);
        assert(f.service.Stop(10, f.session.epoch) == kIOReturnSuccess);
        assert(f.service.ReleaseOwner(10) == kIOReturnSuccess);
    }
    {
        auto* f = new Fixture; // deliberate retained quarantine graph
        f->Active();
        f->hardware->SetTestRegister(static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0)),
                                     ASFW::Driver::ContextControl::kActive);
        assert(f->service.Stop(10, f->session.epoch) == kIOReturnTimeout);
        assert(f->Status().state == uint32_t(RX::State::Quarantined));
        assert(f->service.ReleaseOwner(10) == kIOReturnTimeout);
        assert(f->service.StopAll() == kIOReturnTimeout);
        assert(f->Start() == kIOReturnBusy);
    }
    std::puts("Raw receive host tests passed: 65536-slot wrap/full/ACK, allocation failure, opaque retention/loss, read-only memory, route/owner/epoch gates, broadcast regression, owned CMP/IRM setup and cleanup, pending allocation/connect cancellation, reset fencing, terminal drain protection and quarantine; no media transmit");
}
