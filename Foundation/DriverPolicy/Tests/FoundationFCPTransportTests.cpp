// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../FoundationDriverPolicy.hpp"
#include "../../../ASFWDriver/Discovery/DeviceRegistry.hpp"
#include "../../../ASFWDriver/Discovery/FWDevice.hpp"
#include "../../../ASFWDriver/Protocols/AVC/FCPTransport.hpp"
#include "../../../tests/mocks/DeferredFireWireBus.hpp"
#include "../../../tests/mocks/FakeSessionScheduler.hpp"

#include <array>
#include <cassert>
#include <memory>
#include <utility>
#include <vector>

namespace Policy = RewindDV::Foundation::DriverPolicy;
using ASFW::Async::AsyncHandle;
using ASFW::Async::AsyncStatus;
using ASFW::Async::Testing::DeferredFireWireBus;
using ASFW::Discovery::ConfigROM;
using ASFW::Discovery::DeviceRecord;
using ASFW::Discovery::DeviceRegistry;
using ASFW::Discovery::DeviceRouteToken;
using ASFW::Discovery::FWDevice;
using ASFW::FW::Generation;
using namespace ASFW::Protocols::AVC;
using ASFW::Testing::FakeSessionScheduler;

namespace {

constexpr uint64_t kGuid = 0x0800460106D21234ULL;

ConfigROM MakeROM(Generation generation = Generation{7}, uint16_t nodeID = 3) {
    ConfigROM rom{};
    rom.bib.guid = kGuid;
    rom.gen = generation;
    rom.nodeId = nodeID;
    return rom;
}

FCPFrame PlayCommand() {
    FCPFrame result{};
    const auto bytes = Policy::CommandFrame(Policy::DeckCommand::kPlay);
    result.length = bytes.size();
    std::copy(bytes.begin(), bytes.end(), result.data.begin());
    return result;
}

FCPFrame StopCommand() {
    FCPFrame result{};
    const auto bytes = Policy::CommandFrame(Policy::DeckCommand::kStop);
    result.length = bytes.size();
    std::copy(bytes.begin(), bytes.end(), result.data.begin());
    return result;
}

FCPFrame InspectorCommand(Policy::InspectorQuery query, uint8_t page = 0) {
    FCPFrame result{};
    const auto bytes = Policy::InspectorCommandFrame(query, page);
    result.length = Policy::InspectorCommandLength(query);
    std::copy_n(bytes.begin(), result.length, result.data.begin());
    return result;
}

FCPFrame CapabilityInquiry(Policy::DeckCommand command) {
    FCPFrame result{};
    const auto bytes = Policy::TransportCapabilityInquiryFrame(command);
    result.length = bytes.size();
    std::copy(bytes.begin(), bytes.end(), result.data.begin());
    return result;
}

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

struct Fixture {
    DeferredFireWireBus bus;
    FakeSessionScheduler scheduler;
    DeviceRegistry routes;
    std::shared_ptr<FWDevice> device;
    std::shared_ptr<FCPTransport> transport;

    Fixture() {
        DeviceRecord record{};
        record.guid = kGuid;
        record.nodeId = 3;
        record.gen = Generation{7};
        device = FWDevice::Create(record, ConfigROM{});
        assert(device);
        (void)routes.UpsertFromROM(MakeROM(), {});
        transport = std::make_shared<FCPTransport>();
        FCPTransportConfig config{};
        config.maxRetries = 3; // policy kNever must still force zero retries.
        assert(transport->init(&bus, &bus, device.get(), routes, scheduler, config));
    }

    ~Fixture() { transport->Shutdown(); }
};

FCPCommandPolicy FoundationPolicy(std::vector<FCPAttemptEvidence>* attempts = nullptr,
                                  std::vector<FCPResponseEvidence>* responses = nullptr) {
    FCPCommandPolicy policy{};
    policy.retryClass = FCPRetryClass::kNever;
    policy.queuePolicy = FCPQueuePolicy::kReject;
    policy.maximumInterimResponses = 1;
    policy.expectedRoute = DeviceRouteToken{
        .guid = kGuid,
        .deviceIncarnation = 1,
        .routeEpoch = 1,
        .generation = Generation{7},
        .nodeId = 3,
    };
    policy.responseClassifier = Classify;
    if (attempts) {
        policy.attemptObserver = [attempts](const auto& event) { attempts->push_back(event); };
    }
    if (responses) {
        policy.responseObserver = [responses](const auto& event) { responses->push_back(event); };
    }
    return policy;
}

FCPCommandPolicy InspectorPolicy(
    Policy::InspectorQuery query,
    uint8_t page,
    std::vector<FCPAttemptEvidence>* attempts = nullptr,
    std::vector<FCPResponseEvidence>* responses = nullptr) {
    auto policy = FoundationPolicy(attempts, responses);
    policy.maximumInterimResponses = 0;
    if (query == Policy::InspectorQuery::kTapeTimeCode) {
        policy.responseTimeoutMs = Policy::kTapeTimeCodeResponseDeadlineMs;
    }
    policy.responseClassifier = [query, page](std::span<const uint8_t>,
                                               std::span<const uint8_t> response) {
        switch (Policy::ClassifyInspectorResponse(query, page, response)) {
        case Policy::InspectorResponseClassification::kMismatch:
        case Policy::InspectorResponseClassification::kUnknown:
            return FCPResponseClassification::kMismatch;
        case Policy::InspectorResponseClassification::kInterim:
            return FCPResponseClassification::kInterim;
        case Policy::InspectorResponseClassification::kImplementedStable:
            return FCPResponseClassification::kAccepted;
        case Policy::InspectorResponseClassification::kRejected:
        case Policy::InspectorResponseClassification::kNotImplemented:
            return FCPResponseClassification::kTerminalRejected;
        case Policy::InspectorResponseClassification::kAcceptedInvalidForStatus:
        case Policy::InspectorResponseClassification::kInTransitionInvalidForQuery:
        case Policy::InspectorResponseClassification::kChangedInvalidForStatus:
        case Policy::InspectorResponseClassification::kOtherTerminal:
            return FCPResponseClassification::kOtherTerminal;
        }
        return FCPResponseClassification::kMismatch;
    };
    return policy;
}

FCPCommandPolicy CapabilityPolicy(
    Policy::DeckCommand command,
    std::vector<FCPAttemptEvidence>* attempts = nullptr,
    std::vector<FCPResponseEvidence>* responses = nullptr) {
    auto policy = FoundationPolicy(attempts, responses);
    policy.maximumInterimResponses = 0;
    policy.responseClassifier = [command](std::span<const uint8_t>,
                                          std::span<const uint8_t> response) {
        using Class = Policy::TransportCapabilityResponseClassification;
        switch (Policy::ClassifyTransportCapabilityResponse(command, response)) {
        case Class::kImplemented:
            return FCPResponseClassification::kAccepted;
        case Class::kNotImplemented:
            return FCPResponseClassification::kTerminalRejected;
        case Class::kUnexpectedTerminal:
            return FCPResponseClassification::kOtherTerminal;
        case Class::kUnknown:
        case Class::kMismatch:
            return FCPResponseClassification::kMismatch;
        }
        return FCPResponseClassification::kMismatch;
    };
    return policy;
}

void TestExpectedRouteMismatchNeverReachesBus() {
    Fixture f;
    int completions = 0;
    FCPStatus status = FCPStatus::kOk;
    auto policy = FoundationPolicy();
    const auto selectedRoute = f.routes.CurrentRoute(kGuid);
    assert(selectedRoute.has_value());
    policy.expectedRoute = selectedRoute;
    // Model the exact selection-to-submit TOCTOU: the GUID rebinds to a new
    // generation/node/route epoch after the request captured selectedRoute.
    f.routes.InvalidateLiveMappingsForBusReset();
    (void)f.routes.UpsertFromROM(MakeROM(Generation{8}, 4), {});
    const auto handle = f.transport->SubmitCommand(
        PlayCommand(),
        [&](FCPStatus value, const FCPFrame&) {
            ++completions;
            status = value;
        },
        std::move(policy));
    assert(!handle.IsValid());
    assert(completions == 1);
    assert(status == FCPStatus::kTransportError);
    assert(f.bus.WriteCount() == 0);
}

void TestRejectIfBusyAndRouteEvidence() {
    Fixture f;
    std::vector<FCPAttemptEvidence> attempts;
    int firstCompletions = 0;
    const auto first = f.transport->SubmitCommand(
        PlayCommand(), [&firstCompletions](FCPStatus, const FCPFrame&) { ++firstCompletions; },
        FoundationPolicy(&attempts));
    assert(first.IsValid());
    assert(f.bus.WriteCount() == 1);
    assert(attempts.size() == 2);
    assert(attempts[0].stage == FCPAttemptStage::kRouteBound);
    assert(attempts[1].stage == FCPAttemptStage::kAsyncTransportAccepted);
    assert(attempts[0].attemptID == attempts[1].attemptID);
    assert(attempts[0].route.guid == kGuid);
    assert(attempts[0].route.generation.value == 7);
    assert(attempts[0].route.nodeId == 3);
    assert(attempts[0].route.routeEpoch != 0);
    assert(attempts[0].route.deviceIncarnation != 0);
    assert(attempts[1].asyncHandle == f.bus.WriteAt(0).handle.value);

    int secondCompletions = 0;
    FCPStatus secondStatus = FCPStatus::kOk;
    const auto second = f.transport->SubmitCommand(
        PlayCommand(),
        [&](FCPStatus status, const FCPFrame&) {
            ++secondCompletions;
            secondStatus = status;
        },
        FoundationPolicy());
    assert(!second.IsValid());
    assert(secondCompletions == 1);
    assert(secondStatus == FCPStatus::kBusy);
    assert(f.bus.WriteCount() == 1); // rejected request never reached busOps.
    f.transport->Shutdown();
    assert(firstCompletions == 1);
}

void TestClassifierAndBoundedInterim() {
    Fixture f;
    std::vector<FCPResponseEvidence> responses;
    int completions = 0;
    FCPStatus status = FCPStatus::kOk;
    assert(f.transport->SubmitCommand(
                          PlayCommand(),
                          [&](FCPStatus value, const FCPFrame&) {
                              ++completions;
                              status = value;
                          },
                          FoundationPolicy(nullptr, &responses))
               .IsValid());
    assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));

    constexpr std::array<uint8_t, 4> wrongOperand{0x09, 0x20, 0xC3, 0x60};
    f.transport->OnFCPResponse(3, 7, wrongOperand);
    assert(completions == 0);
    assert(responses.back().classification == FCPResponseClassification::kMismatch);
    assert(responses.back().response.Payload()[3] == 0x60);

    constexpr std::array<uint8_t, 4> interim{0x0F, 0x20, 0xC3, 0x75};
    f.transport->OnFCPResponse(3, 7, interim);
    assert(completions == 0);
    assert(responses.back().classification == FCPResponseClassification::kInterim);
    f.transport->OnFCPResponse(3, 7, interim);
    assert(completions == 1);
    assert(status == FCPStatus::kTimeout);
    assert(responses.size() == 3);
    assert(f.bus.WriteCount() == 1); // bounded terminal failure, never replayed.
}

void TestTerminalClassifications() {
    for (const uint8_t responseType : {uint8_t{0x09}, uint8_t{0x0A}, uint8_t{0x08},
                                       uint8_t{0x0B}}) {
        Fixture f;
        std::vector<FCPResponseEvidence> responses;
        int completions = 0;
        FCPStatus status = FCPStatus::kTimeout;
        assert(f.transport->SubmitCommand(
                              PlayCommand(),
                              [&](FCPStatus value, const FCPFrame&) {
                                  ++completions;
                                  status = value;
                              },
                              FoundationPolicy(nullptr, &responses))
                   .IsValid());
        assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
        const std::array<uint8_t, 4> response{responseType, 0x20, 0xC3, 0x75};
        f.transport->OnFCPResponse(3, 7, response);
        assert(completions == 1);
        assert(status == FCPStatus::kOk); // correlated terminal delivery, not deck motion.
        assert(responses.size() == 1);
        const auto expected = responseType == 0x09
                                  ? FCPResponseClassification::kAccepted
                                  : (responseType == 0x0B
                                         ? FCPResponseClassification::kOtherTerminal
                                         : FCPResponseClassification::kTerminalRejected);
        assert(responses[0].classification == expected);
        assert(responses[0].response.Payload()[0] == responseType);
    }
}

class ResponseInsideWriteBus final : public DeferredFireWireBus {
public:
    FCPTransport* transport{nullptr};

    AsyncHandle WriteBlock(ASFW::FW::Generation generation,
                           ASFW::FW::NodeId nodeId,
                           ASFW::Async::FWAddress,
                           std::span<const uint8_t>,
                           ASFW::FW::FwSpeed,
                           ASFW::Async::InterfaceCompletionCallback) override {
        assert(transport);
        constexpr std::array<uint8_t, 4> accepted{0x09, 0x20, 0xC3, 0x75};
        transport->OnFCPResponse(nodeId.value, generation.value, accepted);
        return AsyncHandle{99};
    }
};

void TestResponseBeforeWriteReturnPublicationBarrier() {
    ResponseInsideWriteBus bus;
    FakeSessionScheduler scheduler;
    DeviceRegistry routes;
    DeviceRecord record{};
    record.guid = kGuid;
    record.nodeId = 3;
    record.gen = Generation{7};
    auto device = FWDevice::Create(record, ConfigROM{});
    assert(device);
    (void)routes.UpsertFromROM(MakeROM(), {});
    auto transport = std::make_shared<FCPTransport>();
    assert(transport->init(&bus, &bus, device.get(), routes, scheduler, {}));
    bus.transport = transport.get();

    bool terminalObserved = false;
    bool submissionClosed = false;
    bool ready = false;
    bool asyncAcceptedObserved = false;
    auto policy = FoundationPolicy();
    policy.attemptObserver = [&](const FCPAttemptEvidence& evidence) {
        if (evidence.stage == FCPAttemptStage::kAsyncTransportAccepted) {
            asyncAcceptedObserved = true;
        }
    };
    const auto handle = transport->SubmitCommand(
        PlayCommand(),
        [&](FCPStatus status, const FCPFrame&) {
            assert(status == FCPStatus::kOk);
            terminalObserved = true;
            ready = submissionClosed;
            assert(!ready);
        },
        std::move(policy));
    (void)handle; // response completion can make the public handle invalid.
    assert(terminalObserved);
    assert(asyncAcceptedObserved);
    submissionClosed = true;
    ready = terminalObserved;
    assert(ready); // publication happens only after SubmitCommand returns.
    transport->Shutdown();
}

void TestRetainedTransportShutdownCompletesOnce() {
    Fixture f;
    std::shared_ptr<FCPTransport> retained = f.transport;
    int completions = 0;
    assert(retained->SubmitCommand(
                       PlayCommand(),
                       [&](FCPStatus status, const FCPFrame&) {
                           assert(status == FCPStatus::kTransportError);
                           ++completions;
                       },
                       FoundationPolicy())
               .IsValid());
    retained->Shutdown();
    assert(completions == 1);
    (void)f.bus.CompleteNextWrite(AsyncStatus::kSuccess);
    assert(completions == 1);
}

void TestTransportDoesNotRetainOrDereferenceDeviceOwnerAfterInit() {
    Fixture f;
    f.device.reset();
    int completions = 0;
    const auto handle = f.transport->SubmitCommand(
        PlayCommand(), [&](FCPStatus, const FCPFrame&) { ++completions; }, FoundationPolicy());
    assert(handle.IsValid());
    assert(f.bus.WriteCount() == 1);
    f.transport->Shutdown();
    assert(completions == 1);
}

void TestRegistrySnapshotIsAnImmutableValueCopy() {
    DeviceRegistry routes;
    (void)routes.UpsertFromROM(MakeROM(), {});
    const auto before = routes.SnapshotAll();
    assert(before.size() == 1);
    assert(before[0].guid == kGuid);
    assert(before[0].gen.value == 7);
    assert(before[0].nodeId == 3);

    routes.InvalidateLiveMappingsForBusReset();
    const auto after = routes.SnapshotAll();
    assert(after.size() == 1);
    assert(after[0].nodeId == ASFW::Discovery::kInvalidNodeId);
    assert(before[0].gen.value == 7);
    assert(before[0].nodeId == 3);
}

void TestInspectorConnectedRouteClassifierAndNoRetry() {
    Fixture f;
    std::vector<FCPAttemptEvidence> attempts;
    std::vector<FCPResponseEvidence> responses;
    int completions = 0;
    FCPStatus status = FCPStatus::kTimeout;
    const auto handle = f.transport->SubmitCommand(
        InspectorCommand(Policy::InspectorQuery::kUnitInfo),
        [&](FCPStatus value, const FCPFrame&) {
            ++completions;
            status = value;
        },
        InspectorPolicy(Policy::InspectorQuery::kUnitInfo, 0, &attempts, &responses));
    assert(handle.IsValid());
    assert(f.bus.WriteCount() == 1);
    assert(attempts.size() == 2);
    assert(attempts[0].route.guid == kGuid);
    assert(attempts[0].route.generation.value == 7);
    assert(attempts[0].route.nodeId == 3);
    assert(f.bus.WriteAt(0).data ==
           std::vector<uint8_t>({0x01, 0xFF, 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}));
    assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));

    constexpr std::array<uint8_t, 8> stable{
        0x0C, 0xFF, 0x30, 0x07, 0x27, 0x00, 0xA0, 0x2D};
    // A well-formed response from a different source stays a transport-level
    // mismatch and cannot be promoted by payload-only classification.
    f.transport->OnFCPResponse(4, 7, stable);
    assert(completions == 0);
    assert(responses.size() == 1);
    assert(responses.back().classification == FCPResponseClassification::kMismatch);
    assert(responses.back().sourceNodeID == 4);
    f.transport->OnFCPResponse(3, 8, stable);
    assert(completions == 0);
    assert(responses.size() == 2);
    assert(responses.back().classification == FCPResponseClassification::kMismatch);
    assert(responses.back().generation == 8);
    f.transport->OnFCPResponse(3, 7, stable);
    assert(completions == 1);
    assert(status == FCPStatus::kOk);
    assert(responses.back().classification == FCPResponseClassification::kAccepted);
    assert(f.bus.WriteCount() == 1);
}

void TestTapeStatusExactWireLengthAndRoute() {
    for (auto query : {Policy::InspectorQuery::kTapeMediumInfo, Policy::InspectorQuery::kTapeTransportState, Policy::InspectorQuery::kTapeAbsoluteTrackNumber, Policy::InspectorQuery::kTapeTimeCode}) {
        Fixture f;
        std::vector<FCPResponseEvidence> responses;
        int completions = 0;
        FCPStatus status = FCPStatus::kTimeout;
        const auto command = InspectorCommand(query);
        assert(f.transport->SubmitCommand(command, [&](FCPStatus value, const FCPFrame&) {
            ++completions; status = value;
        }, InspectorPolicy(query, 0, nullptr, &responses)).IsValid());
        assert(f.bus.WriteCount() == 1);
        assert(f.bus.WriteAt(0).data == std::vector<uint8_t>(command.data.begin(), command.data.begin() + command.length));
        assert(command.length == (query == Policy::InspectorQuery::kTapeMediumInfo ? 5 : query == Policy::InspectorQuery::kTapeTransportState ? 4 : 8));
        assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
        const std::vector<uint8_t> reply = query == Policy::InspectorQuery::kTapeMediumInfo ?
            std::vector<uint8_t>{0x0C,0x20,0xDA,0x7F,0x7F} : query == Policy::InspectorQuery::kTapeTransportState ?
            std::vector<uint8_t>{0x0C,0x20,0xC4,0x60} : query == Policy::InspectorQuery::kTapeAbsoluteTrackNumber ?
            std::vector<uint8_t>{0x0C,0x20,0x52,0x71,3,0,0,255} :
            std::vector<uint8_t>{0x0C,0x20,0x51,0x71,0x12,0x34,0x56,0x07};
        f.transport->OnFCPResponse(4,7,reply);
        f.transport->OnFCPResponse(3,8,reply);
        assert(completions == 0);
        f.transport->OnFCPResponse(3,7,reply);
        assert(completions == 1 && status == FCPStatus::kOk);
        assert(responses.back().classification == FCPResponseClassification::kAccepted);
        assert(f.bus.WriteCount() == 1);
    }
}

void TestTapeTimeCodeUsesOnlyShortPerCommandDeadline() {
    {
        Fixture f;
        int completions = 0;
        FCPStatus status = FCPStatus::kOk;
        assert(f.transport->SubmitCommand(
                   InspectorCommand(Policy::InspectorQuery::kTapeTimeCode),
                   [&](FCPStatus value, const FCPFrame&) {
                       ++completions;
                       status = value;
                   },
                   InspectorPolicy(Policy::InspectorQuery::kTapeTimeCode, 0))
                   .IsValid());
        assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
        f.scheduler.Advance(249'000'000);
        assert(completions == 0);
        f.scheduler.Advance(1'000'000);
        assert(completions == 1 && status == FCPStatus::kTimeout);
        assert(f.bus.WriteCount() == 1);
    }
    {
        Fixture f;
        int completions = 0;
        assert(f.transport->SubmitCommand(
                   InspectorCommand(Policy::InspectorQuery::kUnitInfo),
                   [&](FCPStatus, const FCPFrame&) { ++completions; },
                   InspectorPolicy(Policy::InspectorQuery::kUnitInfo, 0))
                   .IsValid());
        assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
        f.scheduler.Advance(Policy::kTapeTimeCodeResponseDeadlineMs * 1'000'000ULL);
        assert(completions == 0); // Ordinary inspector deadline remains 2000 ms.
    }
}

void TestTapeTimeCodeAndStopNeverQueueBehindEachOther() {
    {
        Fixture f;
        int timeCodeCompletions = 0;
        assert(f.transport->SubmitCommand(
                   InspectorCommand(Policy::InspectorQuery::kTapeTimeCode),
                   [&](FCPStatus, const FCPFrame&) { ++timeCodeCompletions; },
                   InspectorPolicy(Policy::InspectorQuery::kTapeTimeCode, 0))
                   .IsValid());
        int stopCompletions = 0;
        FCPStatus stopStatus = FCPStatus::kOk;
        const auto stop = f.transport->SubmitCommand(
            StopCommand(),
            [&](FCPStatus value, const FCPFrame&) {
                ++stopCompletions;
                stopStatus = value;
            },
            FoundationPolicy());
        assert(!stop.IsValid());
        assert(stopCompletions == 1 && stopStatus == FCPStatus::kBusy);
        assert(f.bus.WriteCount() == 1);
        f.transport->Shutdown();
        assert(timeCodeCompletions == 1);
    }
    {
        Fixture f;
        int stopCompletions = 0;
        assert(f.transport->SubmitCommand(
                   StopCommand(),
                   [&](FCPStatus, const FCPFrame&) { ++stopCompletions; },
                   FoundationPolicy())
                   .IsValid());
        int timeCodeCompletions = 0;
        FCPStatus timeCodeStatus = FCPStatus::kOk;
        const auto timeCode = f.transport->SubmitCommand(
            InspectorCommand(Policy::InspectorQuery::kTapeTimeCode),
            [&](FCPStatus value, const FCPFrame&) {
                ++timeCodeCompletions;
                timeCodeStatus = value;
            },
            InspectorPolicy(Policy::InspectorQuery::kTapeTimeCode, 0));
        assert(!timeCode.IsValid());
        assert(timeCodeCompletions == 1 && timeCodeStatus == FCPStatus::kBusy);
        assert(f.bus.WriteCount() == 1);
        f.transport->Shutdown();
        assert(stopCompletions == 1);
    }
}

void TestInspectorInterimIsImmediateBoundedFailure() {
    Fixture f;
    std::vector<FCPResponseEvidence> responses;
    int completions = 0;
    FCPStatus status = FCPStatus::kOk;
    assert(f.transport->SubmitCommand(
                          InspectorCommand(Policy::InspectorQuery::kUnitPlugInfo),
                          [&](FCPStatus value, const FCPFrame&) {
                              ++completions;
                              status = value;
                          },
                          InspectorPolicy(Policy::InspectorQuery::kUnitPlugInfo, 0,
                                          nullptr, &responses))
               .IsValid());
    assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
    constexpr std::array<uint8_t, 8> interim{
        0x0F, 0xFF, 0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF};
    f.transport->OnFCPResponse(3, 7, interim);
    assert(completions == 1);
    assert(status == FCPStatus::kTimeout);
    assert(responses.size() == 1);
    assert(responses[0].classification == FCPResponseClassification::kInterim);
    assert(f.bus.WriteCount() == 1);
}

void TestInspectorStaleRouteNeverWrites() {
    Fixture f;
    auto policy = InspectorPolicy(Policy::InspectorQuery::kSubunitInfo, 7);
    f.routes.InvalidateLiveMappingsForBusReset();
    (void)f.routes.UpsertFromROM(MakeROM(Generation{8}, 4), {});
    int completions = 0;
    FCPStatus status = FCPStatus::kOk;
    const auto handle = f.transport->SubmitCommand(
        InspectorCommand(Policy::InspectorQuery::kSubunitInfo, 7),
        [&](FCPStatus value, const FCPFrame&) {
            ++completions;
            status = value;
        },
        std::move(policy));
    assert(!handle.IsValid());
    assert(completions == 1);
    assert(status == FCPStatus::kTransportError);
    assert(f.bus.WriteCount() == 0);
}

void TestCapabilityInquiryConnectedClassifierAndNoRetry() {
    for (const auto [responseType, expected] :
         std::array<std::pair<uint8_t, FCPResponseClassification>, 4>{
             {{0x0C, FCPResponseClassification::kAccepted},
              {0x08, FCPResponseClassification::kTerminalRejected},
              {0x09, FCPResponseClassification::kOtherTerminal},
              {0x0F, FCPResponseClassification::kOtherTerminal}}}) {
        Fixture f;
        std::vector<FCPAttemptEvidence> attempts;
        std::vector<FCPResponseEvidence> responses;
        int completions = 0;
        FCPStatus status = FCPStatus::kTimeout;
        const auto handle = f.transport->SubmitCommand(
            CapabilityInquiry(Policy::DeckCommand::kFastForward),
            [&](FCPStatus value, const FCPFrame&) {
                ++completions;
                status = value;
            },
            CapabilityPolicy(Policy::DeckCommand::kFastForward, &attempts, &responses));
        assert(handle.IsValid());
        assert(f.bus.WriteCount() == 1);
        assert(f.bus.WriteAt(0).data ==
               std::vector<uint8_t>({0x02, 0x20, 0xC4, 0x75}));
        assert(attempts.size() == 2);
        assert(attempts[0].route.guid == kGuid);
        assert(attempts[0].route.generation.value == 7);
        assert(attempts[0].route.nodeId == 3);
        assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
        const std::array<uint8_t, 4> response{responseType, 0x20, 0xC4, 0x75};
        f.transport->OnFCPResponse(3, 7, response);
        assert(completions == 1);
        assert(status == FCPStatus::kOk);
        assert(responses.size() == 1);
        assert(responses[0].classification == expected);
        assert(f.bus.WriteCount() == 1);
    }
}

void TestCapabilityWrongSourceAndStaleRouteFailClosed() {
    Fixture f;
    std::vector<FCPResponseEvidence> responses;
    int completions = 0;
    auto policy = CapabilityPolicy(
        Policy::DeckCommand::kFastForward, nullptr, &responses);
    const auto handle = f.transport->SubmitCommand(
        CapabilityInquiry(Policy::DeckCommand::kFastForward),
        [&](FCPStatus, const FCPFrame&) { ++completions; }, std::move(policy));
    assert(handle.IsValid());
    assert(f.bus.CompleteNextWrite(AsyncStatus::kSuccess));
    constexpr std::array<uint8_t, 4> implemented{0x0C, 0x20, 0xC4, 0x75};
    f.transport->OnFCPResponse(4, 7, implemented);
    f.transport->OnFCPResponse(3, 8, implemented);
    assert(completions == 0);
    assert(responses.size() == 2);
    assert(responses[0].classification == FCPResponseClassification::kMismatch);
    assert(responses[1].classification == FCPResponseClassification::kMismatch);
    f.transport->Shutdown();
    assert(completions == 1);

    Fixture stale;
    auto stalePolicy = CapabilityPolicy(Policy::DeckCommand::kFastForward);
    stale.routes.InvalidateLiveMappingsForBusReset();
    (void)stale.routes.UpsertFromROM(MakeROM(Generation{8}, 4), {});
    int staleCompletions = 0;
    FCPStatus staleStatus = FCPStatus::kOk;
    const auto staleHandle = stale.transport->SubmitCommand(
        CapabilityInquiry(Policy::DeckCommand::kFastForward),
        [&](FCPStatus value, const FCPFrame&) {
            ++staleCompletions;
            staleStatus = value;
        },
        std::move(stalePolicy));
    assert(!staleHandle.IsValid());
    assert(staleCompletions == 1);
    assert(staleStatus == FCPStatus::kTransportError);
    assert(stale.bus.WriteCount() == 0);
}

void TestCapabilityProbeRejectsBusyWithoutBusWrite() {
    Fixture f;
    int controlCompletions = 0;
    const auto control = f.transport->SubmitCommand(
        PlayCommand(), [&](FCPStatus, const FCPFrame&) { ++controlCompletions; },
        FoundationPolicy());
    assert(control.IsValid());
    assert(f.bus.WriteCount() == 1);

    int probeCompletions = 0;
    FCPStatus probeStatus = FCPStatus::kOk;
    const auto probe = f.transport->SubmitCommand(
        CapabilityInquiry(Policy::DeckCommand::kFastForward),
        [&](FCPStatus value, const FCPFrame&) {
            ++probeCompletions;
            probeStatus = value;
        },
        CapabilityPolicy(Policy::DeckCommand::kFastForward));
    assert(!probe.IsValid());
    assert(probeCompletions == 1);
    assert(probeStatus == FCPStatus::kBusy);
    assert(f.bus.WriteCount() == 1);
    f.transport->Shutdown();
    assert(controlCompletions == 1);
}

} // namespace

int main() {
    TestRejectIfBusyAndRouteEvidence();
    TestExpectedRouteMismatchNeverReachesBus();
    TestClassifierAndBoundedInterim();
    TestTerminalClassifications();
    TestResponseBeforeWriteReturnPublicationBarrier();
    TestRetainedTransportShutdownCompletesOnce();
    TestTransportDoesNotRetainOrDereferenceDeviceOwnerAfterInit();
    TestRegistrySnapshotIsAnImmutableValueCopy();
    TestInspectorConnectedRouteClassifierAndNoRetry();
    TestTapeStatusExactWireLengthAndRoute();
    TestTapeTimeCodeUsesOnlyShortPerCommandDeadline();
    TestTapeTimeCodeAndStopNeverQueueBehindEachOther();
    TestInspectorInterimIsImmediateBoundedFailure();
    TestInspectorStaleRouteNeverWrites();
    TestCapabilityInquiryConnectedClassifierAndNoRetry();
    TestCapabilityWrongSourceAndStaleRouteFailClosed();
    TestCapabilityProbeRejectsBusyWithoutBusWrite();
    return 0;
}
