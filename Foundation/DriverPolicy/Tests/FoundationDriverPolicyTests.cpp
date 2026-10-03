// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../FoundationDriverPolicy.hpp"
#include "../FoundationActivityGate.hpp"
#include "../FoundationReceiveWire.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstring>
#include <cstdint>
#include <thread>

namespace Policy = RewindDV::Foundation::DriverPolicy;

int main() {
    using Disposition = Policy::ExternalMethodDisposition;

    constexpr std::array<uint64_t, 34> readOnlySelectors{
        0, 1, 2, 3, 5, 7, 10, 11, 14, 16, 18, 21, 34,
        1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007,
        1009, 1010, 1011, 1012, 1013, 1014,
        Policy::kMethodGetFoundationCapabilities,
        Policy::kMethodGetDeckControlResult,
        Policy::kMethodGetFoundationRoute,
        Policy::kMethodGetInspectorCapabilities,
        Policy::kMethodGetInspectorResult,
        Policy::kMethodGetTransportCapabilityCatalog,
        Policy::kMethodGetTransportCapabilityResult,
    };
    for (const uint64_t selector : readOnlySelectors) {
        assert(Policy::ClassifyExternalMethod(selector) == Disposition::kReadOnly);
    }
    assert(Policy::ClassifyExternalMethod(Policy::kMethodSubmitDeckControl) ==
           Disposition::kBoundedControl);
    assert(Policy::ClassifyExternalMethod(Policy::kMethodSubmitInspectorProbe) ==
           Disposition::kBoundedControl);
    assert(Policy::ClassifyExternalMethod(
               Policy::kMethodSubmitTransportCapabilityProbe) ==
           Disposition::kBoundedControl);

    // Legacy public mutation/raw surfaces stay closed in a Foundation build.
    constexpr std::array<uint64_t, 37> forbiddenSelectors{
        4,   // clear retained bus-reset history
        6,   // retired topology selector
        8, 9, 12, 13, 15, 17, // raw async CSR and its completion surface
        19, 20, 25,            // log setters and discovery rescan
        26, 27, 28, 29, 30, 31,
        32, 33, 35, 36, 37,    // direct isoch/metric mutation and isoch TX
        38, 39,                 // raw FCP passthrough and result
        40, 41, 42, 43, 44, 45,
        46, 47, 48, 49, 50, 51, // raw storage/address and filtered DV capture
        61,
    };
    for (const uint64_t selector : forbiddenSelectors) {
        assert(Policy::ClassifyExternalMethod(selector) == Disposition::kReject);
    }
    // Mutable AV/C probe caches are not a Foundation v1 read surface. The app
    // uses selector 16's registry snapshot for device identity.
    assert(Policy::ClassifyExternalMethod(22) == Disposition::kReject);
    assert(Policy::ClassifyExternalMethod(23) == Disposition::kReject);
    assert(Policy::ClassifyExternalMethod(24) == Disposition::kReject);
    for (uint64_t selector = 52; selector <= 63; ++selector) {
        assert(Policy::ClassifyExternalMethod(selector) == Disposition::kReject);
    }
    assert(Policy::ClassifyExternalMethod(1008) == Disposition::kReject);
    assert(Policy::ClassifyExternalMethod(UINT64_MAX) == Disposition::kReject);
    assert(Policy::IsAllowedClientMemoryType(0));
    assert(!Policy::IsAllowedClientMemoryType(1));
    assert(Policy::IsAllowedClientMemoryType(2));
    assert(Policy::ClassifyExternalMethod(68) == Disposition::kBoundedControl);
    assert(Policy::ClassifyExternalMethod(69) == Disposition::kBoundedControl);
    assert(Policy::ClassifyExternalMethod(70) == Disposition::kReadOnly);
    assert(Policy::ClassifyExternalMethod(71) == Disposition::kBoundedControl);
    assert(Policy::ClassifyExternalMethod(78) == Disposition::kReject);
    assert(!Policy::IsAllowedClientMemoryType(UINT64_MAX));

    using Admission = Policy::AttemptAdmission;
    assert(Policy::ClassifyAttemptAdmission(0, false, 0, Policy::kMaximumLifetimeAttempts) ==
           Admission::kAdmit);
    assert(Policy::ClassifyAttemptAdmission(12, false, 0,
                                            Policy::kMaximumLifetimeAttempts) ==
           Admission::kBusy);
    // A completed, consumed attempt is still a replay and remains closed.
    assert(Policy::ClassifyAttemptAdmission(0, true, 1,
                                            Policy::kMaximumLifetimeAttempts) ==
           Admission::kReplay);
    assert(Policy::ClassifyAttemptAdmission(0, false,
                                            Policy::kMaximumLifetimeAttempts - 1,
                                            Policy::kMaximumLifetimeAttempts) ==
           Admission::kAdmit);
    assert(Policy::ClassifyAttemptAdmission(0, false,
                                            Policy::kMaximumLifetimeAttempts,
                                            Policy::kMaximumLifetimeAttempts) ==
           Admission::kLifetimeLimit);
    assert(Policy::ClassifyAttemptAdmission(0, false,
                                            Policy::kMaximumLifetimeAttempts + 1,
                                            Policy::kMaximumLifetimeAttempts) ==
           Admission::kLifetimeLimit);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(1, 2, 1) == Admission::kBusy);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(0, 0, 0) == Admission::kReplay);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(0, 41, 42) == Admission::kReplay);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(0, 42, 42) == Admission::kReplay);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(0, 43, 42) == Admission::kAdmit);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(0, UINT64_MAX, UINT64_MAX) ==
           Admission::kReplay);
    // Mixed closed inspector queries share one replay domain and are not
    // lifetime-count bounded. A consumed terminal result or restarted caller
    // with lower IDs cannot reopen an attempt across query types.
    constexpr std::array<Policy::InspectorQuery, 7> allInspectorQueries{
        Policy::InspectorQuery::kUnitInfo,
        Policy::InspectorQuery::kSubunitInfo,
        Policy::InspectorQuery::kUnitPlugInfo,
        Policy::InspectorQuery::kTapeMediumInfo,
        Policy::InspectorQuery::kTapeTransportState,
        Policy::InspectorQuery::kTapeAbsoluteTrackNumber,
        Policy::InspectorQuery::kTapeTimeCode,
    };
    uint64_t inspectorHighWater = 8'000'000;
    for (uint64_t i = 1; i <= Policy::kMaximumLifetimeAttempts + 1024; ++i) {
        const uint64_t attempt = 8'000'000 + i;
        const auto query = allInspectorQueries[(i - 1) % allInspectorQueries.size()];
        assert(Policy::InspectorCommandLength(query) != 0);
        assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(
                   0, attempt, inspectorHighWater) == Admission::kAdmit);
        inspectorHighWater = attempt;
    }
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(
               0, inspectorHighWater, inspectorHighWater) == Admission::kReplay);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(
               0, inspectorHighWater - 3, inspectorHighWater) == Admission::kReplay);
    assert(Policy::ClassifyMonotonicInspectorAttemptAdmission(
               0, 1, inspectorHighWater) == Admission::kReplay);
    assert(Policy::HasResultStorageCapacity(255, 256));
    assert(!Policy::HasResultStorageCapacity(256, 256));
    assert(!Policy::HasResultStorageCapacity(257, 256));
    assert(!Policy::HasResultStorageCapacity(0, 0));
    assert(Policy::IsCurrentDriverInstance(12, 12));
    assert(!Policy::IsCurrentDriverInstance(12, 13));
    assert(!Policy::IsCurrentDriverInstance(0, 0));
    assert(Policy::MayInspectorQueryOverlapReceive(
        Policy::InspectorQuery::kTapeTransportState));
    for (const auto query : {Policy::InspectorQuery::kUnitInfo,
                             Policy::InspectorQuery::kSubunitInfo,
                             Policy::InspectorQuery::kUnitPlugInfo,
                             Policy::InspectorQuery::kTapeMediumInfo,
                             Policy::InspectorQuery::kTapeAbsoluteTrackNumber,
                             Policy::InspectorQuery::kTapeTimeCode,
                             static_cast<Policy::InspectorQuery>(0),
                             static_cast<Policy::InspectorQuery>(UINT8_MAX)}) {
        assert(!Policy::MayInspectorQueryOverlapReceive(query));
    }

    const auto play = Policy::CommandFrame(Policy::DeckCommand::kPlay);
    const auto stop = Policy::CommandFrame(Policy::DeckCommand::kStop);
    const auto rewind = Policy::CommandFrame(Policy::DeckCommand::kRewind);
    const auto fastForward = Policy::CommandFrame(Policy::DeckCommand::kFastForward);
    const auto shuttleForward = Policy::CommandFrame(Policy::DeckCommand::kShuttleForward);
    const auto shuttleReverse = Policy::CommandFrame(Policy::DeckCommand::kShuttleReverse);
    assert((play == std::array<uint8_t, 4>{0x00, 0x20, 0xC3, 0x75}));
    assert((stop == std::array<uint8_t, 4>{0x00, 0x20, 0xC4, 0x60}));
    assert((rewind == std::array<uint8_t, 4>{0x00, 0x20, 0xC4, 0x65}));
    assert((fastForward == std::array<uint8_t, 4>{0x00, 0x20, 0xC4, 0x75}));
    assert((shuttleForward == std::array<uint8_t, 4>{0x00, 0x20, 0xC3, 0x3F}));
    assert((shuttleReverse == std::array<uint8_t, 4>{0x00, 0x20, 0xC3, 0x4F}));
    assert(Policy::IsExactPermittedFrame(play));
    assert(Policy::IsExactPermittedFrame(stop));
    assert(Policy::IsExactPermittedFrame(rewind));
    assert(!Policy::IsExactPermittedFrame(fastForward));
    assert(Policy::IsExactCatalogFrame(fastForward));
    assert(Policy::IsExactCatalogFrame(shuttleForward));
    assert(Policy::IsExactCatalogFrame(shuttleReverse));
    assert(!Policy::IsExactPermittedFrame(shuttleForward));
    assert(!Policy::IsExactPermittedFrame(shuttleReverse));

    auto record = play;
    record[2] = 0xC2;
    assert(!Policy::IsExactPermittedFrame(record));
    auto alternatePlay = play;
    alternatePlay[3] = 0x7D;
    assert(!Policy::IsExactPermittedFrame(alternatePlay));
    assert(!Policy::IsExactPermittedFrame(std::span<const uint8_t>(play).first<3>()));
    assert(!Policy::IsPermittedDeckCommand(static_cast<Policy::DeckCommand>(0)));
    assert(!Policy::IsPermittedDeckCommand(Policy::DeckCommand::kFastForward));
    assert(Policy::IsCatalogDeckCommand(Policy::DeckCommand::kFastForward));
    assert(Policy::DeckCommandRequiresCapabilityProof(
        Policy::DeckCommand::kFastForward));
    assert(!Policy::CanAdmitDeckCommand(Policy::DeckCommand::kFastForward, false));
    assert(Policy::CanAdmitDeckCommand(Policy::DeckCommand::kFastForward, true));
    assert(!Policy::CanAdmitDeckCommand(Policy::DeckCommand::kShuttleForward, false));
    assert(Policy::CanAdmitDeckCommand(Policy::DeckCommand::kShuttleForward, true));
    assert(!Policy::CanAdmitDeckCommand(Policy::DeckCommand::kShuttleReverse, false));
    assert(Policy::CanAdmitDeckCommand(Policy::DeckCommand::kShuttleReverse, true));
    assert(Policy::CanAdmitDeckCommand(Policy::DeckCommand::kStop, false));
    assert(!Policy::CanAdmitDeckCommand(static_cast<Policy::DeckCommand>(7), true));

    constexpr std::array<uint8_t, 4> acceptedPlay{0x09, 0x20, 0xC3, 0x75};
    constexpr std::array<uint8_t, 4> acceptedStop{0x09, 0x20, 0xC4, 0x60};
    constexpr std::array<uint8_t, 4> acceptedRewind{0x09, 0x20, 0xC4, 0x65};
    constexpr std::array<uint8_t, 4> acceptedFastForward{0x09, 0x20, 0xC4, 0x75};
    assert(Policy::IsCorrelatedDeckResponse(play, acceptedPlay));
    assert(Policy::IsCorrelatedDeckResponse(stop, acceptedStop));
    assert(Policy::IsCorrelatedDeckResponse(rewind, acceptedRewind));
    assert(Policy::IsCorrelatedDeckResponse(fastForward, acceptedFastForward));
    assert(!Policy::IsCorrelatedDeckResponse(stop, acceptedRewind));
    assert(!Policy::IsCorrelatedDeckResponse(rewind, acceptedStop));
    auto wrongSubunit = acceptedPlay;
    wrongSubunit[1] = 0x21;
    assert(!Policy::IsCorrelatedDeckResponse(play, wrongSubunit));
    assert(!Policy::IsCorrelatedDeckResponse(
        play, std::span<const uint8_t>(acceptedPlay).first<3>()));
    assert(Policy::ClassifyDeckResponse(play, acceptedPlay) ==
           Policy::DeckResponseClassification::kAccepted);
    constexpr std::array<uint8_t, 4> interimPlay{0x0F, 0x20, 0xC3, 0x75};
    constexpr std::array<uint8_t, 4> rejectedPlay{0x0A, 0x20, 0xC3, 0x75};
    constexpr std::array<uint8_t, 4> unsupportedPlay{0x08, 0x20, 0xC3, 0x75};
    constexpr std::array<uint8_t, 4> transitioningPlay{0x0B, 0x20, 0xC3, 0x75};
    assert(Policy::ClassifyDeckResponse(play, interimPlay) ==
           Policy::DeckResponseClassification::kInterim);
    assert(Policy::ClassifyDeckResponse(play, rejectedPlay) ==
           Policy::DeckResponseClassification::kRejected);
    assert(Policy::ClassifyDeckResponse(play, unsupportedPlay) ==
           Policy::DeckResponseClassification::kNotImplemented);
    assert(Policy::ClassifyDeckResponse(play, transitioningPlay) ==
           Policy::DeckResponseClassification::kOtherTerminal);
    assert(Policy::ClassifyDeckResponse(play, acceptedStop) ==
           Policy::DeckResponseClassification::kMismatch);

    Policy::DeckControlRequestWire request{};
    request.operationID = 0x1020304050607080ULL;
    request.attemptID = 0x8877665544332211ULL;
    request.guid = 0x0800460106D21234ULL;
    request.command = static_cast<uint32_t>(Policy::DeckCommand::kPlay);
    request.driverInstanceID = 5;
    request.deviceIncarnation = 7;
    request.routeEpoch = 9;
    request.generation = 11;
    request.nodeID = 3;
    assert(Policy::IsValidRequest(request));

    auto invalid = request;
    invalid.version++;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.size--;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.attemptID = 0;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.command = 7;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.command = static_cast<uint32_t>(Policy::DeckCommand::kFastForward);
    assert(Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.reserved = 1;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.driverInstanceID = 0;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.deviceIncarnation = 0;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.routeEpoch = 0;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.nodeID = 0xFFFF;
    assert(!Policy::IsValidRequest(invalid));
    invalid = request;
    invalid.routeReserved = 1;
    assert(!Policy::IsValidRequest(invalid));

    auto conditionalRequest = request;
    conditionalRequest.command =
        static_cast<uint32_t>(Policy::DeckCommand::kFastForward);
    Policy::ConditionalDeckAuthorization authorization{
        .driverInstanceID = conditionalRequest.driverInstanceID,
        .guid = conditionalRequest.guid,
        .deviceIncarnation = conditionalRequest.deviceIncarnation,
        .routeEpoch = conditionalRequest.routeEpoch,
        .generation = conditionalRequest.generation,
        .nodeID = conditionalRequest.nodeID,
        .reserved = 0,
        .command = conditionalRequest.command,
    };
    assert(Policy::MatchesConditionalDeckAuthorization(
        authorization, conditionalRequest, conditionalRequest.driverInstanceID));
    assert(!Policy::MatchesConditionalDeckAuthorization(
        authorization, conditionalRequest, conditionalRequest.driverInstanceID + 1));
    constexpr std::array<void (*)(Policy::DeckControlRequestWire&), 7> routeMutations{
             [](Policy::DeckControlRequestWire& value) { ++value.driverInstanceID; },
             [](Policy::DeckControlRequestWire& value) { ++value.guid; },
             [](Policy::DeckControlRequestWire& value) { ++value.deviceIncarnation; },
             [](Policy::DeckControlRequestWire& value) { ++value.routeEpoch; },
             [](Policy::DeckControlRequestWire& value) { ++value.generation; },
             [](Policy::DeckControlRequestWire& value) { ++value.nodeID; },
             [](Policy::DeckControlRequestWire& value) {
                 value.command = static_cast<uint32_t>(Policy::DeckCommand::kPlay);
             },
         };
    for (const auto mutation : routeMutations) {
        auto changed = conditionalRequest;
        mutation(changed);
        assert(!Policy::MatchesConditionalDeckAuthorization(
            authorization, changed, conditionalRequest.driverInstanceID));
    }

    const auto capabilities = Policy::Capabilities();
    assert(capabilities.version == Policy::kWireVersion);
    assert(capabilities.size == sizeof(capabilities));
    assert(capabilities.maximumMutatingCommands == 1);
    assert(capabilities.deckCommandLength == 4);
    assert((capabilities.capabilities & Policy::kNoControlReplay) != 0);
    assert((capabilities.capabilities & Policy::kArchivalCaptureUnavailable) != 0);
    assert(capabilities.capabilities == 0x3ff);
    assert(capabilities.permittedDeckCommands == 0x7);

    const auto catalog = Policy::TransportCapabilityCatalog();
    assert(catalog.version == Policy::kWireVersion);
    assert(catalog.size == 176);
    assert(catalog.entryCount == 6);
    assert(catalog.flags == 0x3F);
    assert(catalog.maximumConcurrentProbes == 1);
    assert(catalog.maximumRetainedResults == 128);
    assert(catalog.maximumResponseBytes == 512);
    assert(catalog.maximumResponseEvents == 2);
    for (size_t index = 0; index < catalog.entries.size(); ++index) {
        const auto& entry = catalog.entries[index];
        assert(entry.command == index + 1);
        assert(entry.inquiryLength == 4 && entry.controlLength == 4);
        assert(entry.inquiry[0] == 0x02 && entry.control[0] == 0x00);
        assert(std::equal(entry.inquiry.begin() + 1, entry.inquiry.end(),
                          entry.control.begin() + 1));
        assert(entry.flags == (index < 3 ? 0x0B : 0x0D));
    }
    assert(catalog.entries[3].inquiry ==
           (std::array<uint8_t, 4>{0x02, 0x20, 0xC4, 0x75}));
    assert(catalog.entries[3].control == fastForward);
    assert(catalog.entries[4].inquiry ==
           (std::array<uint8_t, 4>{0x02, 0x20, 0xC3, 0x3F}));
    assert(catalog.entries[4].control == shuttleForward);
    assert(catalog.entries[5].inquiry ==
           (std::array<uint8_t, 4>{0x02, 0x20, 0xC3, 0x4F}));
    assert(catalog.entries[5].control == shuttleReverse);

    Policy::TransportCapabilityProbeRequestWire probe{};
    probe.operationID = 21;
    probe.attemptID = 22;
    probe.guid = request.guid;
    probe.driverInstanceID = request.driverInstanceID;
    probe.deviceIncarnation = request.deviceIncarnation;
    probe.routeEpoch = request.routeEpoch;
    probe.generation = request.generation;
    probe.nodeID = request.nodeID;
    probe.command = static_cast<uint32_t>(Policy::DeckCommand::kFastForward);
    assert(Policy::IsValidTransportCapabilityProbeRequest(probe));
    auto invalidProbe = probe;
    invalidProbe.command = 7;
    assert(!Policy::IsValidTransportCapabilityProbeRequest(invalidProbe));
    invalidProbe = probe;
    invalidProbe.reserved16 = 1;
    assert(!Policy::IsValidTransportCapabilityProbeRequest(invalidProbe));
    invalidProbe = probe;
    invalidProbe.reserved32 = 1;
    assert(!Policy::IsValidTransportCapabilityProbeRequest(invalidProbe));

    const auto fastForwardInquiry = Policy::TransportCapabilityInquiryFrame(
        Policy::DeckCommand::kFastForward);
    assert(fastForwardInquiry ==
           (std::array<uint8_t, 4>{0x02, 0x20, 0xC4, 0x75}));
    constexpr std::array<uint8_t, 4> implementedFastForward{
        0x0C, 0x20, 0xC4, 0x75};
    constexpr std::array<uint8_t, 4> notImplementedFastForward{
        0x08, 0x20, 0xC4, 0x75};
    constexpr std::array<uint8_t, 4> acceptedInvalidFastForward{
        0x09, 0x20, 0xC4, 0x75};
    constexpr std::array<uint8_t, 4> interimInvalidFastForward{
        0x0F, 0x20, 0xC4, 0x75};
    assert(Policy::ClassifyTransportCapabilityResponse(
               Policy::DeckCommand::kFastForward, implementedFastForward) ==
           Policy::TransportCapabilityResponseClassification::kImplemented);
    assert(Policy::ClassifyTransportCapabilityResponse(
               Policy::DeckCommand::kFastForward, notImplementedFastForward) ==
           Policy::TransportCapabilityResponseClassification::kNotImplemented);
    assert(Policy::ClassifyTransportCapabilityResponse(
               Policy::DeckCommand::kFastForward, acceptedInvalidFastForward) ==
           Policy::TransportCapabilityResponseClassification::kUnexpectedTerminal);
    assert(Policy::ClassifyTransportCapabilityResponse(
               Policy::DeckCommand::kFastForward, interimInvalidFastForward) ==
           Policy::TransportCapabilityResponseClassification::kUnexpectedTerminal);
    auto wrongCapabilityOperand = implementedFastForward;
    wrongCapabilityOperand[3] = 0x65;
    assert(Policy::ClassifyTransportCapabilityResponse(
               Policy::DeckCommand::kFastForward, wrongCapabilityOperand) ==
           Policy::TransportCapabilityResponseClassification::kMismatch);

    Policy::TransportCapabilityResultWire proofCandidate{};
    proofCandidate.command = static_cast<uint32_t>(Policy::DeckCommand::kFastForward);
    proofCandidate.stageFlags =
        Policy::kTransportCapabilityStageAdmitted |
        Policy::kTransportCapabilityStageRouteBound |
        Policy::kTransportCapabilityStageFCPTransportAccepted |
        Policy::kTransportCapabilityStageResponseReceived |
        Policy::kTransportCapabilityStageResponseCorrelated |
        Policy::kTransportCapabilityStageCompleted |
        Policy::kTransportCapabilityStageTerminalImplemented;
    proofCandidate.terminalStatus = 0;
    proofCandidate.terminalClassification = static_cast<uint32_t>(
        Policy::TransportCapabilityResponseClassification::kImplemented);
    proofCandidate.supportState = static_cast<uint32_t>(
        Policy::TransportCapabilitySupportState::kImplemented);
    proofCandidate.routeState = static_cast<uint32_t>(
        Policy::RouteEvidenceState::kBoundCurrentAtSubmission);
    proofCandidate.fcpAttemptID = 7;
    proofCandidate.asyncTransportHandle = 8;
    proofCandidate.generation = 11;
    proofCandidate.nodeID = 3;
    proofCandidate.requestLength = 4;
    proofCandidate.request = fastForwardInquiry;
    proofCandidate.responseEventCount = 1;
    proofCandidate.responseEvents[0].timestampNs = 12;
    proofCandidate.responseEvents[0].fcpAttemptID = 7;
    proofCandidate.responseEvents[0].generation = 11;
    // The raw responder identity may retain bus bits; correlation is node-low-6.
    proofCandidate.responseEvents[0].sourceNodeID = 0xFFC3;
    proofCandidate.responseEvents[0].classification = static_cast<uint32_t>(
        Policy::TransportCapabilityResponseClassification::kImplemented);
    proofCandidate.responseEvents[0].length = 4;
    std::copy(implementedFastForward.begin(), implementedFastForward.end(),
              proofCandidate.responseEvents[0].bytes.begin());
    proofCandidate.admittedTimestampNs = 10;
    proofCandidate.routeBoundTimestampNs = 11;
    // A response may complete before WriteBlock returns this handle.
    proofCandidate.completedTimestampNs = 12;
    proofCandidate.asyncTransportAcceptedTimestampNs = 13;
    assert(Policy::ShouldInstallConditionalDeckAuthorization(proofCandidate));
    auto shuttleProof = proofCandidate;
    shuttleProof.command = static_cast<uint32_t>(Policy::DeckCommand::kShuttleForward);
    shuttleProof.request = Policy::TransportCapabilityInquiryFrame(
        Policy::DeckCommand::kShuttleForward);
    constexpr std::array<uint8_t, 4> implementedShuttleForward{
        0x0C, 0x20, 0xC3, 0x3F};
    std::copy(implementedShuttleForward.begin(), implementedShuttleForward.end(),
              shuttleProof.responseEvents[0].bytes.begin());
    assert(Policy::ShouldInstallConditionalDeckAuthorization(shuttleProof));
    shuttleProof.command = static_cast<uint32_t>(Policy::DeckCommand::kShuttleReverse);
    shuttleProof.request = Policy::TransportCapabilityInquiryFrame(
        Policy::DeckCommand::kShuttleReverse);
    constexpr std::array<uint8_t, 4> implementedShuttleReverse{
        0x0C, 0x20, 0xC3, 0x4F};
    std::copy(implementedShuttleReverse.begin(), implementedShuttleReverse.end(),
              shuttleProof.responseEvents[0].bytes.begin());
    assert(Policy::ShouldInstallConditionalDeckAuthorization(shuttleProof));
    auto incompleteProof = proofCandidate;
    incompleteProof.stageFlags &=
        ~Policy::kTransportCapabilityStageFCPTransportAccepted;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.retryCount = 1;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.command = static_cast<uint32_t>(Policy::DeckCommand::kPlay);
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEventOverflow = 1;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEventCount = 0;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEventCount = 3;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].fcpAttemptID++;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].generation++;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].sourceNodeID = 4;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].classification = static_cast<uint32_t>(
        Policy::TransportCapabilityResponseClassification::kNotImplemented);
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].length = 3;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.responseEvents[0].bytes[3] = 0x65;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    incompleteProof = proofCandidate;
    incompleteProof.stageFlags |=
        Policy::kTransportCapabilityStageTerminalNotImplemented;
    assert(!Policy::ShouldInstallConditionalDeckAuthorization(incompleteProof));
    assert(Policy::ShouldObserveTransportCapabilityEvidence(false));
    assert(!Policy::ShouldObserveTransportCapabilityEvidence(true));
    Policy::TransportCapabilityResultWire publishedCapability = proofCandidate;
    publishedCapability.responseEventCount = 1;
    publishedCapability.responseEvents[0].bytes[0] = 0x0C;
    const auto publishedCapabilityBytes = publishedCapability;
    if (Policy::ShouldObserveTransportCapabilityEvidence(true)) {
        publishedCapability.asyncTransportHandle = 99;
        publishedCapability.responseEvents[0].bytes[0] = 0x08;
    }
    assert(std::memcmp(&publishedCapability, &publishedCapabilityBytes,
                       sizeof(publishedCapability)) == 0);
    // terminalObserved alone is not publication: a synchronous response may
    // still be followed by the transport-accepted observer before close.
    if (Policy::ShouldObserveTransportCapabilityEvidence(false)) {
        publishedCapability.asyncTransportAcceptedTimestampNs = 14;
    }
    assert(publishedCapability.asyncTransportAcceptedTimestampNs == 14);

    const auto inspectorCapabilities = Policy::InspectorCapabilities();
    assert(inspectorCapabilities.size == 40);
    assert(inspectorCapabilities.queryMask == 0x7F);
    assert(inspectorCapabilities.flags ==
           (Policy::kInspectorExactRouteRequired | Policy::kInspectorNoAutomaticRetry |
            Policy::kInspectorExclusiveWithReceiveAndControl |
            Policy::kInspectorBoundedOwnedEvidence | Policy::kInspectorRawResponsesRetained |
            Policy::kInspectorTapeTransportStateMayOverlapReceive |
            Policy::kInspectorTapeTimeCodeReceiveExcluded));
    assert(inspectorCapabilities.flags == 0x7F);
    assert(inspectorCapabilities.maximumSubunitPage == 7);
    assert(inspectorCapabilities.maximumConcurrentProbes == 1);
    assert(inspectorCapabilities.maximumRetainedResults == 128);
    assert(inspectorCapabilities.maximumResponseBytes == 512);
    assert(inspectorCapabilities.maximumResponseEvents == 2);
    assert(Policy::ShouldObserveInspectorEvidence(false));
    assert(!Policy::ShouldObserveInspectorEvidence(true));
    Policy::InspectorResultWire published{};
    published.requestID = 44;
    published.stageFlags = Policy::kInspectorStageCompleted;
    published.responseEventCount = 1;
    published.responseEvents[0].bytes[0] = 0x0C;
    const auto publishedBytes = published;
    // Model both a late response and late attempt trying to append after the
    // publication fence. The ready predicate keeps the entire wire byte exact.
    if (Policy::ShouldObserveInspectorEvidence(true)) {
        published.stageFlags |= Policy::kInspectorStageFCPTransportAccepted;
        published.asyncTransportHandle = 99;
        published.responseEvents[0].bytes[0] = 0x08;
    }
    assert(std::memcmp(&published, &publishedBytes, sizeof(published)) == 0);
    // terminalObserved without ready must not suppress the synchronous
    // response-before-write-return attempt evidence before submission closes.
    if (Policy::ShouldObserveInspectorEvidence(false)) {
        published.asyncTransportHandle = 99;
    }
    assert(published.asyncTransportHandle == 99);

    Policy::InspectorRequestWire inspector{};
    inspector.operationID = 10;
    inspector.attemptID = 11;
    inspector.guid = request.guid;
    inspector.driverInstanceID = request.driverInstanceID;
    inspector.deviceIncarnation = request.deviceIncarnation;
    inspector.routeEpoch = request.routeEpoch;
    inspector.generation = request.generation;
    inspector.nodeID = request.nodeID;
    inspector.query = static_cast<uint8_t>(Policy::InspectorQuery::kUnitInfo);
    assert(Policy::IsValidInspectorRequest(inspector));
    auto invalidInspector = inspector;
    invalidInspector.subunitPage = 1;
    assert(!Policy::IsValidInspectorRequest(invalidInspector));
    invalidInspector = inspector;
    invalidInspector.reserved[7] = 1;
    assert(!Policy::IsValidInspectorRequest(invalidInspector));
    invalidInspector = inspector;
    invalidInspector.query = 0;
    assert(!Policy::IsValidInspectorRequest(invalidInspector));
    inspector.query = static_cast<uint8_t>(Policy::InspectorQuery::kSubunitInfo);
    inspector.subunitPage = 7;
    assert(Policy::IsValidInspectorRequest(inspector));
    invalidInspector = inspector;
    invalidInspector.subunitPage = 8;
    assert(!Policy::IsValidInspectorRequest(invalidInspector));

    const auto unitInfo = Policy::InspectorCommandFrame(Policy::InspectorQuery::kUnitInfo, 0);
    const auto subunitInfo = Policy::InspectorCommandFrame(Policy::InspectorQuery::kSubunitInfo, 3);
    const auto unitPlugInfo =
        Policy::InspectorCommandFrame(Policy::InspectorQuery::kUnitPlugInfo, 0);
    assert((unitInfo == std::array<uint8_t, 8>{0x01, 0xFF, 0x30, 0xFF,
                                               0xFF, 0xFF, 0xFF, 0xFF}));
    assert((subunitInfo == std::array<uint8_t, 8>{0x01, 0xFF, 0x31, 0x37,
                                                  0xFF, 0xFF, 0xFF, 0xFF}));
    assert((unitPlugInfo == std::array<uint8_t, 8>{0x01, 0xFF, 0x02, 0x00,
                                                   0xFF, 0xFF, 0xFF, 0xFF}));
    assert((Policy::InspectorCommandFrame(Policy::InspectorQuery::kSubunitInfo, 8) ==
            std::array<uint8_t, 8>{}));

    constexpr std::array<uint8_t, 8> unitStable{
        0x0C, 0xFF, 0x30, 0x07, 0x27, 0x00, 0xA0, 0x2D};
    assert(Policy::ClassifyInspectorResponse(Policy::InspectorQuery::kUnitInfo, 0,
                                             unitStable) ==
           Policy::InspectorResponseClassification::kImplementedStable);
    const auto decodedUnit = Policy::DecodeInspectorResponse(
        Policy::InspectorQuery::kUnitInfo, 0, unitStable);
    assert(decodedUnit.validFields == Policy::kInspectorDecodedUnitInfo);
    assert(decodedUnit.unitType == 4 && decodedUnit.unitID == 7);
    assert((decodedUnit.companyID == std::array<uint8_t, 3>{0x00, 0xA0, 0x2D}));

    constexpr std::array<uint8_t, 8> subunitStable{
        0x0C, 0xFF, 0x31, 0x17, 0x20, 0x48, 0xFF, 0xFF};
    const auto decodedSubunits = Policy::DecodeInspectorResponse(
        Policy::InspectorQuery::kSubunitInfo, 1, subunitStable);
    assert(decodedSubunits.validFields == Policy::kInspectorDecodedSubunitInfo);
    assert(decodedSubunits.subunitCount == 2);
    assert(decodedSubunits.subunits[0].type == 4);
    assert(decodedSubunits.subunits[1].type == 9);
    auto invalidSubunits = subunitStable;
    invalidSubunits[6] = 0x20;
    assert(Policy::DecodeInspectorResponse(Policy::InspectorQuery::kSubunitInfo, 1,
                                           invalidSubunits).validFields == 0);
    invalidSubunits = subunitStable;
    invalidSubunits[4] = 0x25; // Extended subunit ID is not fixed-page decodable.
    assert(Policy::DecodeInspectorResponse(Policy::InspectorQuery::kSubunitInfo, 1,
                                           invalidSubunits).validFields == 0);

    constexpr std::array<uint8_t, 8> plugStable{
        0x0C, 0xFF, 0x02, 0x00, 0x01, 0x02, 0x03, 0x04};
    const auto decodedPlugs = Policy::DecodeInspectorResponse(
        Policy::InspectorQuery::kUnitPlugInfo, 0, plugStable);
    assert(decodedPlugs.validFields == Policy::kInspectorDecodedUnitPlugInfo);
    assert(decodedPlugs.serialBusIsochronousInputPlugs == 1);
    assert(decodedPlugs.externalOutputPlugs == 4);
    auto invalidPlugs = plugStable;
    invalidPlugs[7] = 32;
    assert(Policy::DecodeInspectorResponse(Policy::InspectorQuery::kUnitPlugInfo, 0,
                                           invalidPlugs).validFields == 0);

    for (const auto [responseCode, classification] :
         std::array<std::pair<uint8_t, Policy::InspectorResponseClassification>, 8>{
             {{0x0F, Policy::InspectorResponseClassification::kInterim},
              {0x0C, Policy::InspectorResponseClassification::kImplementedStable},
              {0x0A, Policy::InspectorResponseClassification::kRejected},
              {0x08, Policy::InspectorResponseClassification::kNotImplemented},
              {0x09, Policy::InspectorResponseClassification::kAcceptedInvalidForStatus},
              {0x0B, Policy::InspectorResponseClassification::kInTransitionInvalidForQuery},
              {0x0D, Policy::InspectorResponseClassification::kChangedInvalidForStatus},
              {0x07, Policy::InspectorResponseClassification::kOtherTerminal}}}) {
        auto response = unitStable;
        response[0] = responseCode;
        assert(Policy::ClassifyInspectorResponse(Policy::InspectorQuery::kUnitInfo, 0,
                                                 response) == classification);
    }
    auto wrongEcho = unitStable;
    wrongEcho[3] = 0xFF;
    assert(Policy::ClassifyInspectorResponse(Policy::InspectorQuery::kUnitInfo, 0,
                                             wrongEcho) ==
           Policy::InspectorResponseClassification::kMismatch);

    const uint64_t receiveToken = Policy::TryAcquireActivity(Policy::ActivityKind::kReceive);
    assert(receiveToken != 0);
    assert(Policy::IsActivityActive(Policy::ActivityKind::kReceive));
    // Preserve live receive + control overlap so STOP remains available.
    const uint64_t deckToken =
        Policy::TryAcquireActivity(Policy::ActivityKind::kDeckControl);
    assert(deckToken != 0);
    assert(Policy::IsActivityActive(Policy::ActivityKind::kDeckControl));
    assert(Policy::TryAcquireActivity(Policy::ActivityKind::kInspector) == 0);
    assert(Policy::TryAcquireActivity(
               Policy::ActivityKind::kLiveTapeTransportStateInspector) == 0);
    Policy::ReleaseActivity(deckToken);
    const uint64_t liveTapeStateToken = Policy::TryAcquireActivity(
        Policy::ActivityKind::kLiveTapeTransportStateInspector);
    assert(liveTapeStateToken != 0); // The narrow receive overlap.
    assert(Policy::TryAcquireActivity(
               Policy::ActivityKind::kLiveTapeTransportStateInspector) == 0);
    assert(Policy::TryAcquireActivity(Policy::ActivityKind::kInspector) == 0);
    assert(Policy::TryAcquireActivity(Policy::ActivityKind::kDeckControl) == 0);
    Policy::ReleaseActivity(liveTapeStateToken + 1); // Wrong owner cannot release.
    assert(Policy::IsActivityActive(
        Policy::ActivityKind::kLiveTapeTransportStateInspector));
    Policy::ReleaseActivity(liveTapeStateToken);
    Policy::ReleaseActivity(receiveToken + 1); // Wrong owner cannot release.
    assert(Policy::IsActivityActive(Policy::ActivityKind::kReceive));
    Policy::ReleaseActivity(receiveToken);
    const uint64_t inspectorToken = Policy::TryAcquireActivity(Policy::ActivityKind::kInspector);
    assert(inspectorToken != 0);
    assert(Policy::TryAcquireActivity(Policy::ActivityKind::kReceive) == 0);
    assert(Policy::TryAcquireActivity(Policy::ActivityKind::kDeckControl) == 0);
    Policy::ReleaseActivity(inspectorToken);
    assert(Policy::TryAcquireActivity(static_cast<Policy::ActivityKind>(0)) == 0);
    assert(Policy::TryAcquireActivity(static_cast<Policy::ActivityKind>(UINT8_MAX)) == 0);

    const uint64_t liveOnly = Policy::TryAcquireActivity(
        Policy::ActivityKind::kLiveTapeTransportStateInspector);
    assert(liveOnly != 0);
    const uint64_t overlappedReceive =
        Policy::TryAcquireActivity(Policy::ActivityKind::kReceive);
    assert(overlappedReceive != 0);
    Policy::ReleaseActivity(liveOnly);
    assert(Policy::IsActivityActive(Policy::ActivityKind::kReceive));
    Policy::ReleaseActivity(overlappedReceive);

    // Race generic and live inspectors. Exactly one can publish its activity;
    // releasing a loser or stale token must not disturb the winner.
    for (size_t iteration = 0; iteration < 128; ++iteration) {
        std::atomic<unsigned> ready{0};
        std::atomic<bool> go{false};
        std::array<uint64_t, 2> tokens{};
        std::thread generic([&] {
            ready.fetch_add(1, std::memory_order_release);
            while (!go.load(std::memory_order_acquire)) {}
            tokens[0] = Policy::TryAcquireActivity(Policy::ActivityKind::kInspector);
        });
        std::thread live([&] {
            ready.fetch_add(1, std::memory_order_release);
            while (!go.load(std::memory_order_acquire)) {}
            tokens[1] = Policy::TryAcquireActivity(
                Policy::ActivityKind::kLiveTapeTransportStateInspector);
        });
        while (ready.load(std::memory_order_acquire) != 2) {}
        go.store(true, std::memory_order_release);
        generic.join();
        live.join();
        assert((tokens[0] != 0) != (tokens[1] != 0));
        Policy::ReleaseActivity(tokens[0] + (tokens[0] != 0));
        Policy::ReleaseActivity(tokens[1] + (tokens[1] != 0));
        assert(Policy::IsActivityActive(tokens[0] != 0
            ? Policy::ActivityKind::kInspector
            : Policy::ActivityKind::kLiveTapeTransportStateInspector));
        Policy::ReleaseActivity(tokens[0]);
        Policy::ReleaseActivity(tokens[1]);
    }

    const auto raceActivities = [](Policy::ActivityKind first,
                                   Policy::ActivityKind second,
                                   size_t expectedWinners) {
        for (size_t iteration = 0; iteration < 128; ++iteration) {
            std::atomic<unsigned> ready{0};
            std::atomic<bool> go{false};
            std::array<uint64_t, 2> tokens{};
            std::thread a([&] {
                ready.fetch_add(1, std::memory_order_release);
                while (!go.load(std::memory_order_acquire)) {}
                tokens[0] = Policy::TryAcquireActivity(first);
            });
            std::thread b([&] {
                ready.fetch_add(1, std::memory_order_release);
                while (!go.load(std::memory_order_acquire)) {}
                tokens[1] = Policy::TryAcquireActivity(second);
            });
            while (ready.load(std::memory_order_acquire) != 2) {}
            go.store(true, std::memory_order_release);
            a.join();
            b.join();
            assert(static_cast<size_t>(tokens[0] != 0) +
                       static_cast<size_t>(tokens[1] != 0) == expectedWinners);
            Policy::ReleaseActivity(tokens[0]);
            Policy::ReleaseActivity(tokens[1]);
        }
    };
    // Receive and the typed status query may race and coexist. Every other
    // pairing involving that query remains non-queuing and exclusive.
    raceActivities(Policy::ActivityKind::kReceive,
                   Policy::ActivityKind::kLiveTapeTransportStateInspector, 2);
    raceActivities(Policy::ActivityKind::kDeckControl,
                   Policy::ActivityKind::kLiveTapeTransportStateInspector, 1);
    raceActivities(Policy::ActivityKind::kLiveTapeTransportStateInspector,
                   Policy::ActivityKind::kLiveTapeTransportStateInspector, 1);

    // Both sides race admission and hold any acquired token until the other
    // side has attempted. Exactly one side can win inspector exclusivity.
    for (size_t iteration = 0; iteration < 128; ++iteration) {
        std::atomic<unsigned> ready{0};
        std::atomic<bool> go{false};
        std::array<uint64_t, 2> tokens{};
        std::thread receive([&] {
            ready.fetch_add(1, std::memory_order_release);
            while (!go.load(std::memory_order_acquire)) {}
            tokens[0] = Policy::TryAcquireActivity(Policy::ActivityKind::kReceive);
        });
        std::thread inspectorThread([&] {
            ready.fetch_add(1, std::memory_order_release);
            while (!go.load(std::memory_order_acquire)) {}
            tokens[1] = Policy::TryAcquireActivity(Policy::ActivityKind::kInspector);
        });
        while (ready.load(std::memory_order_acquire) != 2) {}
        go.store(true, std::memory_order_release);
        receive.join();
        inspectorThread.join();
        assert((tokens[0] != 0) != (tokens[1] != 0));
        Policy::ReleaseActivity(tokens[0]);
        Policy::ReleaseActivity(tokens[1]);
    }
    return 0;
}
