// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../FoundationDriverPolicy.hpp"
#include "../../../ASFWDriver/Async/Rx/ARPacketParser.hpp"
#include "../../../ASFWDriver/Async/Rx/RxPath.hpp"
#include "../../../ASFWDriver/Async/AsyncSubsystem.hpp"
#include "../../../ASFWDriver/Testing/FakeDMAMemory.hpp"
#include "../../../ASFWDriver/Async/Rx/LocalRequestDispatch.hpp"
#include "../../../ASFWDriver/Async/Rx/PacketRouter.hpp"
#include "../../../ASFWDriver/Async/Tx/DescriptorBuilder.hpp"
#include "../../../ASFWDriver/Async/Tx/ResponseSender.hpp"
#include "../../../ASFWDriver/Hardware/HardwareInterface.hpp"
#include "../../../ASFWDriver/Shared/Memory/DMAMemoryManager.hpp"
#include "../../../ASFWDriver/Shared/Rings/DescriptorRing.hpp"
#include "../../../ASFWDriver/Discovery/DeviceRegistry.hpp"
#include "../../../ASFWDriver/Discovery/FWDevice.hpp"
#include "../../../ASFWDriver/Protocols/AVC/FCPTransport.hpp"
#include "../../../ASFWDriver/Service/FCPInboundLocalHandler.hpp"
#include "../../../tests/mocks/DeferredFireWireBus.hpp"
#include "../../../tests/mocks/FakeSessionScheduler.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <vector>

namespace Policy = RewindDV::Foundation::DriverPolicy;
using ASFW::Async::ARContextType;
using ASFW::Async::ARPacketParser;
using ASFW::Async::AsyncStatus;
using ASFW::Async::Testing::DeferredFireWireBus;
using ASFW::Async::LocalRequestDispatch;
using ASFW::Async::PacketRouter;
using ASFW::Discovery::ConfigROM;
using ASFW::Discovery::DeviceRecord;
using ASFW::Discovery::DeviceRegistry;
using ASFW::Discovery::FWDevice;
using ASFW::FW::Generation;
using ASFW::Protocols::AVC::AVCUnit;
using ASFW::Protocols::AVC::FCPCommandPolicy;
using ASFW::Protocols::AVC::FCPControlLease;
using ASFW::Protocols::AVC::FCPFrame;
using ASFW::Protocols::AVC::FCPQueuePolicy;
using ASFW::Protocols::AVC::FCPResponseClassification;
using ASFW::Protocols::AVC::FCPResponseEvidence;
using ASFW::Protocols::AVC::FCPResponseRouter;
using ASFW::Protocols::AVC::FCPRetryClass;
using ASFW::Protocols::AVC::FCPStatus;
using ASFW::Protocols::AVC::FCPTransport;
using ASFW::Protocols::AVC::IAVCDiscovery;
using ASFW::Service::Detail::FCPInboundLocalHandler;
using ASFW::Testing::FakeSessionScheduler;

namespace {

constexpr uint64_t kGuid = 0x0800460106D21234ULL;
constexpr uint32_t kGeneration = 7;
constexpr std::array<uint8_t, 4> kPlayCommand{0x00, 0x20, 0xC3, 0x75};
constexpr std::array<uint8_t, 4> kAcceptedPlay{0x09, 0x20, 0xC3, 0x75};
constexpr std::array<uint8_t, 4> kReversedAcceptedPlay{0x75, 0xC3, 0x20, 0x09};

// Physical Sony HVR-M15U write-quadlet AR record retained by the ASFW lab.
// Q0-Q2 are in OHCI AR header memory order. Q3 is the byte-exact FCP data
// field. The final quadlet is the completed AR-request trailer (event 0x12).
constexpr std::array<uint8_t, 20> kSonyAcceptedPlayAR{
    0x00, 0x19, 0xC0, 0xFF,
    0xFF, 0xFF, 0xC1, 0xFF,
    0x00, 0x0D, 0x00, 0xF0,
    0x09, 0x20, 0xC3, 0x75,
    0x00, 0x00, 0x12, 0x00,
};

class RetainedDiscovery final : public IAVCDiscovery {
public:
    explicit RetainedDiscovery(std::shared_ptr<FCPTransport> transport)
        : transport_(std::move(transport)) {}

    std::vector<AVCUnit*> GetAllAVCUnits() override { return {}; }
    std::vector<std::shared_ptr<AVCUnit>> AcquireAllAVCUnits() override { return {}; }
    void ReScanAllUnits() override {}
    FCPTransport* GetFCPTransportForNodeID(uint16_t) override { return nullptr; }
    std::shared_ptr<FCPTransport> AcquireFCPTransportForNodeID(uint16_t nodeID) override {
        acquiredNodeID = nodeID;
        return transport_;
    }
    FCPControlLease AcquireFCPControlLeaseForGuid(uint64_t) override { return {}; }
    std::optional<ASFW::Discovery::DeviceRouteToken>
    CopyCurrentRouteForGuid(uint64_t) override {
        return std::nullopt;
    }
    [[nodiscard]] uint64_t GetFoundationDriverInstanceID() const noexcept override { return 1; }

    uint16_t acquiredNodeID{0};

private:
    std::shared_ptr<FCPTransport> transport_;
};

FCPResponseClassification Classify(std::span<const uint8_t> command,
                                   std::span<const uint8_t> response) {
    switch (Policy::ClassifyDeckResponse(command, response)) {
    case Policy::DeckResponseClassification::kInterim:
        return FCPResponseClassification::kInterim;
    case Policy::DeckResponseClassification::kAccepted:
        return FCPResponseClassification::kAccepted;
    case Policy::DeckResponseClassification::kRejected:
    case Policy::DeckResponseClassification::kNotImplemented:
        return FCPResponseClassification::kTerminalRejected;
    case Policy::DeckResponseClassification::kOtherTerminal:
        return FCPResponseClassification::kOtherTerminal;
    case Policy::DeckResponseClassification::kUnknown:
    case Policy::DeckResponseClassification::kMismatch:
        return FCPResponseClassification::kMismatch;
    }
    return FCPResponseClassification::kMismatch;
}

FCPFrame PlayFrame() {
    FCPFrame frame{};
    frame.length = kPlayCommand.size();
    std::copy(kPlayCommand.begin(), kPlayCommand.end(), frame.data.begin());
    return frame;
}

struct ResponseRig {
    ASFW::Driver::HardwareInterface hardware;
    ASFW::Shared::DMAMemoryManager dma;
    ASFW::Shared::DescriptorRing ring;
    std::unique_ptr<ASFW::Async::DescriptorBuilder> builder;
    std::unique_ptr<ASFW::Async::ResponseSender> sender;
    unsigned queued{0};

    explicit ResponseRig(size_t capacity = 32) {
        assert(dma.Initialize(hardware, 4096));
        auto region = dma.AllocateRegion(capacity * sizeof(ASFW::Async::HW::OHCIDescriptor));
        assert(region);
        auto* descriptors = reinterpret_cast<ASFW::Async::HW::OHCIDescriptor*>(region->virtualBase);
        assert(ring.Initialize({descriptors, capacity}));
        assert(ring.Finalize(region->deviceBase));
        builder = std::make_unique<ASFW::Async::DescriptorBuilder>(ring, dma);
        sender = std::make_unique<ASFW::Async::ResponseSender>(*builder,
            [](const void*, uint8_t, void* context) noexcept {
                ++static_cast<ResponseRig*>(context)->queued;
            }, this);
    }
};

void TestPhysicalWriteQuadletRetainsCanonicalFCPBytes(bool lostInterrupt = false) {
    DeferredFireWireBus bus;
    FakeSessionScheduler scheduler;
    DeviceRegistry routes;
    ConfigROM rom{};
    rom.bib.guid = kGuid;
    rom.nodeId = 1;
    rom.gen = Generation{kGeneration};
    const auto& record = routes.UpsertFromROM(rom, {});
    assert(record.deviceIncarnation != 0);
    auto device = FWDevice::Create(record, rom);
    assert(device);

    auto transport = std::make_shared<FCPTransport>();
    assert(transport->init(&bus, &bus, device.get(), routes, scheduler, {}));
    ResponseRig responses;
    std::vector<FCPResponseEvidence> responseEvidence;
    int completions = 0;
    FCPStatus completionStatus = FCPStatus::kTimeout;
    FCPFrame completionResponse{};
    auto initialFrame = PlayFrame();
    auto initialAR = kSonyAcceptedPlayAR;
    auto initialResponse = kAcceptedPlay;
    if (lostInterrupt) {
        initialFrame.data[0] = 0x01; initialFrame.data[2] = 0xD0; initialFrame.data[3] = 0x7F;
        initialAR[12] = 0x0C; initialResponse[0] = 0x0C; // transport STATUS stable reply
    }
    FCPCommandPolicy policy{};
    policy.retryClass = FCPRetryClass::kNever;
    policy.queuePolicy = FCPQueuePolicy::kReject;
    policy.expectedRoute = routes.CurrentRoute(kGuid);
    policy.responseClassifier = [lostInterrupt](auto command, auto response) {
        if (!lostInterrupt) return Classify(command, response);
        using C = Policy::InspectorResponseClassification;
        switch (Policy::ClassifyInspectorResponse(Policy::InspectorQuery::kTapeTransportState, 0, response)) {
        case C::kImplementedStable: return FCPResponseClassification::kAccepted;
        case C::kInterim: return FCPResponseClassification::kInterim;
        case C::kRejected: case C::kNotImplemented: return FCPResponseClassification::kTerminalRejected;
        case C::kMismatch: case C::kUnknown: return FCPResponseClassification::kMismatch;
        default: return FCPResponseClassification::kOtherTerminal;
        }
    };
    policy.responseObserver = [&](FCPResponseEvidence evidence) {
        assert(responses.queued == 1); // actual response chain precedes all FCP callbacks
        responseEvidence.push_back(std::move(evidence));
    };
    assert(transport
               ->SubmitCommand(
                   initialFrame,
                   [&](FCPStatus status, const FCPFrame& response) {
                       ++completions;
                       completionStatus = status;
                       completionResponse = response;
                   },
                   std::move(policy))
               .IsValid());
    assert(bus.CompleteNextWrite(AsyncStatus::kSuccess));

    const auto packet = ARPacketParser::ParseNext(kSonyAcceptedPlayAR, 0);
    assert(packet.has_value());
    assert(packet->tCode == 0);
    assert(packet->headerLength == 16);
    assert(packet->dataLength == 0);
    assert(packet->totalLength == kSonyAcceptedPlayAR.size());

    PacketRouter router;
    LocalRequestDispatch dispatch;
    RetainedDiscovery discovery(transport);
    FCPResponseRouter responseRouter(discovery);
    dispatch.AddHandler(std::make_unique<FCPInboundLocalHandler>(&responseRouter));
    router.SetResponseSender(responses.sender.get());
    dispatch.Install(router, responses.sender.get());
    if (lostInterrupt) {
        // No IRQ delivered. The command-write callback already completed and
        // there are NO expired low-level transactions to trigger the old drain.
        ASFW::Testing::FakeDMAMemory memory{256 * 1024};
        ASFW::Shared::BufferRing requestRing, responseRing;
        constexpr size_t count = 4, bytes = 200;
        auto initRing = [&](ASFW::Shared::BufferRing& ring) {
            auto descriptors = memory.AllocateRegion(count * sizeof(ASFW::Async::HW::OHCIDescriptor));
            auto buffers = memory.AllocateRegion(count * bytes);
            assert(descriptors && buffers);
            assert(ring.Initialize({reinterpret_cast<ASFW::Async::HW::OHCIDescriptor*>(descriptors->virtualBase), count},
                {buffers->virtualBase, count * bytes}, count, bytes));
            ring.BindDma(&memory);
            assert(ring.Finalize(descriptors->deviceBase, buffers->deviceBase));
        };
        initRing(requestRing); initRing(responseRing);
        ASFW::Async::ARRequestContext requestContext;
        ASFW::Async::ARResponseContext responseContext;
        assert(requestContext.Initialize(responses.hardware, requestRing) == kIOReturnSuccess);
        assert(responseContext.Initialize(responses.hardware, responseRing) == kIOReturnSuccess);
        ASFW::Async::LabelAllocator labels;
        ASFW::Async::TransactionManager transactions;
        assert(transactions.Initialize());
        ASFW::Async::CompletionQueue completionsQueue;
        ASFW::Async::Rx::TrackingActor tracking(&labels, &transactions, completionsQueue);
        ASFW::Async::Bus::GenerationTracker generations(labels);
        generations.OnConfirmedBusGeneration(kGeneration);
        ASFW::Async::AsyncSubsystem async;
        async.hardware_ = &responses.hardware;
        async.isRunning_ = true;
        async.rxPath_ = std::make_unique<ASFW::Async::Rx::RxPath>(
            requestContext, responseContext, tracking, generations, router);
        auto& receive = *async.rxPath_;
        std::memcpy(requestRing.GetBufferAddress(0), initialAR.data(), initialAR.size());
        ASFW::Async::HW::AR_init_status(*requestRing.GetDescriptor(0), bytes - kSonyAcceptedPlayAR.size());
        assert(tracking.CopyExpiredSnapshots(UINT64_MAX).empty());
        assert(completions == 0 && scheduler.PendingCount() == 1);
        assert(receive.ProcessWatchdogReceive(false, nullptr).request.packetsFound == 0);
        assert(requestRing.BufferCount() == count);
        assert(requestContext.GetBufferRing().BufferCount() == count);
        using ASFW::Driver::Register32;
        using ASFW::Driver::IntEventBits;
        // Actual watchdog entry: none of these states may consume queued FCP.
        async.isRunning_ = false; async.OnTimeoutTick(); async.isRunning_ = true;
        async.is_bus_reset_in_progress_.store(1); async.OnTimeoutTick();
        async.is_bus_reset_in_progress_.store(0);
        async.hardware_ = nullptr; async.OnTimeoutTick(); async.hardware_ = &responses.hardware;
        for (auto event : {UINT32_MAX, IntEventBits::kBusReset, IntEventBits::kSelfIDComplete,
                IntEventBits::kSelfIDComplete2, IntEventBits::kUnrecoverableError,
                IntEventBits::kRegAccessFail, IntEventBits::kPostedWriteErr}) {
            responses.hardware.SetTestRegister(Register32::kIntEvent, event);
            async.OnTimeoutTick();
            assert(completions == 0 && requestContext.SnapshotRingHead().unreadBytes == 20);
        }
        responses.hardware.SetTestRegister(Register32::kIntEvent, 0x00300031u);
        async.OnTimeoutTick();
        assert(completions == 1 && requestContext.SnapshotRingHead().unreadBytes == 0);
        assert(async.watchdogTickCount_.load() == 1);
        assert(receive.ProcessWatchdogReceive(true, nullptr).request.packetsFound == 0);
        assert(completions == 1 && bus.WriteCount() == 1); // no command replay
        scheduler.Advance(21'000'000ULL);
        assert(completions == 1 && !transport->CopyUncertainResponseEvidence().admissionFenced);
        unsigned followups = 0;
        size_t used = initialAR.size();
        for (bool stop : {true, false}) {
            auto command = PlayFrame();
            if (stop) { command.data[2] = 0xC4; command.data[3] = 0x60; }
            FCPCommandPolicy fresh{};
            fresh.retryClass = FCPRetryClass::kNever;
            fresh.queuePolicy = FCPQueuePolicy::kReject;
            fresh.expectedRoute = routes.CurrentRoute(kGuid);
            fresh.responseClassifier = Classify;
            assert(transport->SubmitCommand(command, [&](FCPStatus status, const FCPFrame&) {
                assert(status == FCPStatus::kOk); ++followups;
            }, fresh).IsValid());
            assert(bus.CompleteNextWrite(AsyncStatus::kSuccess));
            assert(tracking.CopyExpiredSnapshots(UINT64_MAX).empty());
            auto reply = kSonyAcceptedPlayAR;
            reply[14] = command.data[2]; reply[15] = command.data[3];
            std::memcpy(requestRing.GetBufferAddress(0) + used, reply.data(), reply.size());
            used += reply.size();
            ASFW::Async::HW::AR_init_status(*requestRing.GetDescriptor(0), bytes - used);
            // Force the next eligible interval without sleeping or inventing an IRQ.
            async.lastReceiveServiceUsec_ = 0;
            async.OnTimeoutTick();
            assert(requestContext.SnapshotRingHead().unreadBytes == 0);
            assert(receive.ProcessWatchdogReceive(true, nullptr).request.packetsFound == 0);
        }
        assert(followups == 2 && bus.WriteCount() == 3); // STATUS, fresh STOP, fresh PLAY
        assert(!transport->CopyUncertainResponseEvidence().admissionFenced);
        // Fill/drain the old head, then deliver a fresh STOP only in its
        // successor. SnapshotHead().unreadBytes is zero at this boundary.
        while (used < bytes) {
            std::memcpy(requestRing.GetBufferAddress(0) + used,
                kSonyAcceptedPlayAR.data(), kSonyAcceptedPlayAR.size());
            used += kSonyAcceptedPlayAR.size();
        }
        ASFW::Async::HW::AR_init_status(*requestRing.GetDescriptor(0), 0);
        assert(receive.ProcessWatchdogReceive(true, nullptr).request.packetsFound == 7);
        assert(requestContext.SnapshotRingHead().unreadBytes == 0);
        auto stopFrame = PlayFrame(); stopFrame.data[2] = 0xC4; stopFrame.data[3] = 0x60;
        FCPCommandPolicy finalPolicy{};
        finalPolicy.retryClass = FCPRetryClass::kNever;
        finalPolicy.queuePolicy = FCPQueuePolicy::kReject;
        finalPolicy.expectedRoute = routes.CurrentRoute(kGuid);
        finalPolicy.responseClassifier = Classify;
        assert(transport->SubmitCommand(stopFrame, [&](FCPStatus status, const FCPFrame&) {
            assert(status == FCPStatus::kOk); ++followups;
        }, finalPolicy).IsValid());
        assert(bus.CompleteNextWrite(AsyncStatus::kSuccess));
        auto stopAR = kSonyAcceptedPlayAR; stopAR[14] = 0xC4; stopAR[15] = 0x60;
        std::memcpy(requestRing.GetBufferAddress(1), stopAR.data(), stopAR.size());
        ASFW::Async::HW::AR_init_status(*requestRing.GetDescriptor(1), bytes - stopAR.size());
        assert(receive.ProcessWatchdogReceive(true, nullptr).request.packetsFound == 1);
        assert(followups == 3 && bus.WriteCount() == 4);
        assert(!transport->CopyUncertainResponseEvidence().admissionFenced);
    } else {
        router.RouteParsedPacket(ARContextType::Request, *packet, kGeneration);
    }

    assert(discovery.acquiredNodeID == 0xFFC1);
    assert(completions == 1);
    assert(completionStatus == FCPStatus::kOk);
    assert(completionResponse.length == kAcceptedPlay.size());
    assert(std::equal(initialResponse.begin(), initialResponse.end(),
                      completionResponse.Payload().begin()));
    assert(responseEvidence.size() == 1);
    assert(responseEvidence[0].classification == FCPResponseClassification::kAccepted);
    assert(std::equal(initialResponse.begin(), initialResponse.end(),
                      responseEvidence[0].response.Payload().begin()));
    transport->Shutdown();
}


// Frozen four-byte fixture through the real parser, router, dispatch, FCP and
// response descriptor builder. Only the final hardware submission is captured.
void TestSubmissionBoundary(uint16_t receiveStatus, bool senderPresent,
                            size_t capacity, bool interim, bool expectQueued,
                            bool expectCompletion, bool block = false,
                            bool recoverFailedResponse = false,
                            bool lateWriteCompletion = false,
                            bool reentrant = false, uint32_t responseGeneration = kGeneration) {
    DeferredFireWireBus bus;
    FakeSessionScheduler scheduler;
    DeviceRegistry routes;
    ConfigROM rom{};
    rom.bib.guid = kGuid;
    rom.nodeId = 1;
    rom.gen = Generation{kGeneration};
    const auto& record = routes.UpsertFromROM(rom, {});
    assert(record.deviceIncarnation != 0);
    auto device = FWDevice::Create(record, rom);
    assert(device);
    auto transport = std::make_shared<FCPTransport>();
    assert(transport->init(&bus, &bus, device.get(), routes, scheduler, {}));
    ResponseRig responses(capacity);
    unsigned observed = 0;
    unsigned completed = 0;
    unsigned rejectedQueued = 0;
    unsigned expectedResponses = unsigned(expectQueued);
    FCPStatus terminal = FCPStatus::kBusy;
    FCPCommandPolicy policy{};
    policy.retryClass = FCPRetryClass::kNever;
    policy.queuePolicy = FCPQueuePolicy::kFifo;
    policy.responseClassifier = Classify;
    policy.maximumInterimResponses = 0;
    policy.responseTimeoutMs = 20;
    policy.responseObserver = [&](FCPResponseEvidence evidence) {
        assert(responses.queued == expectedResponses);
        assert(evidence.response.length == 4);
        ++observed;
        if (reentrant) {
            assert(bus.WriteCount() == 1);
            assert(transport->SubmitCommand(PlayFrame(), [](FCPStatus, const FCPFrame&) {}, policy).IsValid());
            assert(bus.WriteCount() == 1);
        }
    };
    assert(transport->SubmitCommand(PlayFrame(), [&](FCPStatus status, const FCPFrame&) {
        assert(responses.queued == expectedResponses);
        ++completed;
        terminal = status;
        if (reentrant) {
            assert(responses.queued == expectedResponses);
            assert(transport->SubmitCommand(PlayFrame(), [](FCPStatus, const FCPFrame&) {}, policy).IsValid());
        }
    }, policy).IsValid());
    if (!lateWriteCompletion) assert(bus.CompleteNextWrite(AsyncStatus::kSuccess));
    assert(transport->SubmitCommand(PlayFrame(), [&](FCPStatus status, const FCPFrame&) {
        if (status == FCPStatus::kTransportError) ++rejectedQueued;
    }, policy).IsValid());
    assert(bus.WriteCount() == 1);

    std::vector<uint8_t> bytes(kSonyAcceptedPlayAR.begin(), kSonyAcceptedPlayAR.end());
    bytes[18] = static_cast<uint8_t>(receiveStatus);
    bytes[19] = static_cast<uint8_t>(receiveStatus >> 8);
    if (interim) bytes[12] = 0x0F;
    if (block) {
        bytes.insert(bytes.begin() + 12, {0, 0, 4, 0});
        bytes[0] = 0x10; // write-block; original Q3 becomes its byte-exact payload
    }
    const auto packet = ARPacketParser::ParseNext(bytes, 0);
    assert(packet);
    RetainedDiscovery discovery(transport);
    FCPResponseRouter responseRouter(discovery);
    PacketRouter router;
    LocalRequestDispatch dispatch;
    dispatch.AddHandler(std::make_unique<FCPInboundLocalHandler>(&responseRouter));
    auto* sender = senderPresent ? responses.sender.get() : nullptr;
    router.SetResponseSender(sender);
    dispatch.Install(router, sender);
    router.RouteParsedPacket(ARContextType::Request, *packet, responseGeneration);
    assert(observed == 1); // failed submission still preserves received evidence
    assert(responses.queued == unsigned(expectQueued)); // no duplicate response
    assert(completed == unsigned(expectCompletion));
    assert(bus.WriteCount() == (expectCompletion && !interim ? 2U : 1U));
    if (expectCompletion) {
        assert(terminal == (interim ? FCPStatus::kTimeout : FCPStatus::kOk));
        if (interim) {
            assert(rejectedQueued == 1);
            assert(transport->CopyUncertainResponseEvidence().admissionFenced);
        }
    } else {
        // Failure never consumes the never-retry policy. The existing deadline
        // remains live and bounded; receipt alone did not advance the FIFO.
        if (lateWriteCompletion) {
            assert(scheduler.PendingCount() == 0);
            assert(bus.CompleteNextWrite(AsyncStatus::kSuccess));
            assert(completed == 0 && bus.WriteCount() == 1);
        }
        assert(scheduler.PendingCount() == 1);
        if (recoverFailedResponse) {
            // The target retransmits after an unacknowledged response. Receipt
            // is retained twice, but only the successfully submitted response
            // advances the pending FCP command, exactly once.
            expectedResponses = 1;
            router.SetResponseSender(responses.sender.get());
            dispatch.Install(router, responses.sender.get());
            router.RouteParsedPacket(ARContextType::Request, *packet, kGeneration);
            assert(observed == 2 && completed == 1 && responses.queued == 1);
            assert(terminal == FCPStatus::kOk && bus.WriteCount() == 2);
        } else {
            scheduler.Advance(21'000'000ULL);
            assert(completed == 1 && terminal == FCPStatus::kTimeout);
            // An issued command timed out without a definitive response. Its
            // uncertainty rejects the queued command rather than attributing a
            // late response to that next command.
            assert(bus.WriteCount() == 1 && rejectedQueued == 1);
            assert(transport->CopyUncertainResponseEvidence().admissionFenced);
        }
    }
    transport->Shutdown();
}

void TestStrictClassifierDoesNotAcceptReversedResponse() {
    assert(Policy::ClassifyDeckResponse(kPlayCommand, kAcceptedPlay) ==
           Policy::DeckResponseClassification::kAccepted);
    assert(Policy::ClassifyDeckResponse(kPlayCommand, kReversedAcceptedPlay) ==
           Policy::DeckResponseClassification::kMismatch);
}

} // namespace

int main() {
    TestPhysicalWriteQuadletRetainsCanonicalFCPBytes();
    TestPhysicalWriteQuadletRetainsCanonicalFCPBytes(true);
    TestStrictClassifierDoesNotAcceptReversedResponse();
    TestSubmissionBoundary(0x12, true, 32, false, true, true);
    TestSubmissionBoundary(0x12, true, 32, true, true, true);
    TestSubmissionBoundary(0x11, true, 32, false, false, true);
    TestSubmissionBoundary(0x12, false, 32, false, false, false);
    TestSubmissionBoundary(0x92, true, 32, false, false, false);
    TestSubmissionBoundary(0x00, true, 32, false, false, false);
    TestSubmissionBoundary(0x12, true, 1, false, false, false);
    TestSubmissionBoundary(0x12, true, 32, false, true, true, true);
    TestSubmissionBoundary(0x12, false, 32, false, false, false, false, true);
    TestSubmissionBoundary(0x12, false, 32, false, false, false, false, false, true);
    TestSubmissionBoundary(0x12, true, 32, false, true, true, false, false, false, true);
    TestSubmissionBoundary(0x12, true, 32, false, true, false, false, false, false, false, kGeneration + 1);
    return 0;
}
