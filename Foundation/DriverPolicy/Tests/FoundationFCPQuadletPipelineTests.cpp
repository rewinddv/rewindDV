// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../FoundationDriverPolicy.hpp"
#include "../../../ASFWDriver/Async/Rx/ARPacketParser.hpp"
#include "../../../ASFWDriver/Async/Rx/LocalRequestDispatch.hpp"
#include "../../../ASFWDriver/Async/Rx/PacketRouter.hpp"
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

void TestPhysicalWriteQuadletRetainsCanonicalFCPBytes() {
    DeferredFireWireBus bus;
    FakeSessionScheduler scheduler;
    DeviceRegistry routes;
    DeviceRecord record{};
    record.guid = kGuid;
    record.nodeId = 1;
    record.gen = Generation{kGeneration};
    auto device = FWDevice::Create(record, ConfigROM{});
    assert(device);
    ConfigROM rom{};
    rom.bib.guid = kGuid;
    rom.nodeId = 1;
    rom.gen = Generation{kGeneration};
    (void)routes.UpsertFromROM(rom, {});

    auto transport = std::make_shared<FCPTransport>();
    assert(transport->init(&bus, &bus, device.get(), routes, scheduler, {}));
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
    dispatch.Install(router, nullptr);
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
    return 0;
}
