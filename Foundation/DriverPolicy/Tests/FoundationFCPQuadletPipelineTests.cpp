// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../FoundationDriverPolicy.hpp"
#include "../../../ASFWDriver/Async/Rx/ARPacketParser.hpp"
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

void TestPhysicalWriteQuadletRetainsCanonicalFCPBytes() {
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
    FCPCommandPolicy policy{};
    policy.retryClass = FCPRetryClass::kNever;
    policy.queuePolicy = FCPQueuePolicy::kReject;
    policy.expectedRoute = routes.CurrentRoute(kGuid);
    policy.responseClassifier = Classify;
    policy.responseObserver = [&](FCPResponseEvidence evidence) {
        assert(responses.queued == 1); // actual response chain precedes all FCP callbacks
        responseEvidence.push_back(std::move(evidence));
    };
    assert(transport
               ->SubmitCommand(
                   PlayFrame(),
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
    router.RouteParsedPacket(ARContextType::Request, *packet, kGeneration);

    assert(discovery.acquiredNodeID == 0xFFC1);
    assert(completions == 1);
    assert(completionStatus == FCPStatus::kOk);
    assert(completionResponse.length == kAcceptedPlay.size());
    assert(std::equal(kAcceptedPlay.begin(), kAcceptedPlay.end(),
                      completionResponse.Payload().begin()));
    assert(responseEvidence.size() == 1);
    assert(responseEvidence[0].classification == FCPResponseClassification::kAccepted);
    assert(std::equal(kAcceptedPlay.begin(), kAcceptedPlay.end(),
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
