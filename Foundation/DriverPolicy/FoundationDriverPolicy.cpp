// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "FoundationDriverPolicy.hpp"
#include "FoundationReceiveWire.hpp"

#include <algorithm>

namespace RewindDV::Foundation::DriverPolicy {

namespace {

constexpr std::array<uint8_t, kDeckCommandLength> kPlay{0x00, 0x20, 0xC3, 0x75};
constexpr std::array<uint8_t, kDeckCommandLength> kStop{0x00, 0x20, 0xC4, 0x60};
constexpr std::array<uint8_t, kDeckCommandLength> kRewind{0x00, 0x20, 0xC4, 0x65};
constexpr std::array<uint8_t, kDeckCommandLength> kFastForward{0x00, 0x20, 0xC4, 0x75};
// 1394 TA Tape Recorder/Player 2.4 PLAY fastest picture-search operands:
// FASTEST FORWARD (CUE) 0x3F and FASTEST REVERSE (REVIEW) 0x4F.
constexpr std::array<uint8_t, kDeckCommandLength> kShuttleForward{0x00, 0x20, 0xC3, 0x3F};
constexpr std::array<uint8_t, kDeckCommandLength> kShuttleReverse{0x00, 0x20, 0xC3, 0x4F};

constexpr std::array<uint8_t, kDeckCommandLength> SpecificInquiryFor(
    const std::array<uint8_t, kDeckCommandLength>& control) noexcept {
    auto inquiry = control;
    inquiry[0] = 0x02;
    return inquiry;
}

constexpr uint32_t CommandBit(DeckCommand command) noexcept {
    return 1u << (static_cast<uint32_t>(command) - 1u);
}

} // namespace

ExternalMethodDisposition ClassifyExternalMethod(uint64_t selector) noexcept {
    switch (selector) {
    // Read-only identity, health, status, and retained evidence.
    case 0:    // GetBusResetCount
    case 1:    // GetBusResetHistory
    case 2:    // GetControllerStatus
    case 3:    // GetMetricsSnapshot
    case 5:    // GetSelfIDCapture
    case 7:    // Ping
    case 10:   // RegisterStatusListener
    case 11:   // CopyStatusSnapshot
    case 14:   // ExportConfigROM
    case 16:   // GetDiscoveredDevices
    case 18:   // GetDriverVersion
    case 21:   // GetLogConfig
    case 34:   // GetIsochRxMetrics
    case 1000: // DiagGetBusContract
    case 1001: // DiagGetTopology
    case 1002: // DiagGetRoleCoordinator
    case 1003: // DiagGetOHCI
    case 1004: // DiagGetPHY
    case 1005: // DiagGetCSRContract
    case 1006: // DiagGetAsyncTrace
    case 1007: // DiagGetInboundCSRStats
    case 1009: // DiagGetBusManager
    case 1010: // DiagGetPostResetTiming
    case 1011: // DiagGetLogRecords
    case 1012: // DiagGetLogStats
    case 1013: // DiagGetAudioTelemetry
    case 1014: // DiagGetLogCatalog
    case kMethodGetFoundationCapabilities:
    case kMethodGetDeckControlResult:
    case kMethodGetFoundationRoute:
    case kMethodGetInspectorCapabilities:
    case kMethodGetInspectorResult:
    case kMethodGetTransportCapabilityCatalog:
    case kMethodGetTransportCapabilityResult:
    case Receive::kStatus:
        return ExternalMethodDisposition::kReadOnly;

    case kMethodSubmitDeckControl:
    case kMethodSubmitInspectorProbe:
    case kMethodSubmitTransportCapabilityProbe:
    case Receive::kStart:
    case Receive::kStop:
    case Receive::kAcknowledge:
        return ExternalMethodDisposition::kBoundedControl;

    default:
        return ExternalMethodDisposition::kReject;
    }
}

bool IsAllowedClientMemoryType(uint64_t type) noexcept {
    // Type 0 is the read-only shared status page. Type 1 is the inherited,
    // filtered DV ring and must not masquerade as the archival receive seam.
    return type == 0 || type == Receive::kMemoryType;
}

AttemptAdmission ClassifyAttemptAdmission(uint64_t activeRequestID,
                                          bool attemptAlreadyConsumed,
                                          size_t consumedAttemptCount,
                                          size_t maximumLifetimeAttempts) noexcept {
    if (activeRequestID != 0) {
        return AttemptAdmission::kBusy;
    }
    if (attemptAlreadyConsumed) {
        return AttemptAdmission::kReplay;
    }
    if (consumedAttemptCount >= maximumLifetimeAttempts) {
        return AttemptAdmission::kLifetimeLimit;
    }
    return AttemptAdmission::kAdmit;
}

AttemptAdmission ClassifyMonotonicInspectorAttemptAdmission(
    uint64_t activeRequestID,
    uint64_t attemptID,
    uint64_t admittedAttemptHighWater) noexcept {
    if (activeRequestID != 0) {
        return AttemptAdmission::kBusy;
    }
    // All closed inspector query types share this high-water mark. Comparison,
    // rather than incrementing it, rejects zero, cross-query replay,
    // process-restart regression, and UInt64 wrap without overflow.
    if (attemptID == 0 || attemptID <= admittedAttemptHighWater) {
        return AttemptAdmission::kReplay;
    }
    return AttemptAdmission::kAdmit;
}

bool HasResultStorageCapacity(size_t retainedResultCount,
                              size_t maximumRetainedResults) noexcept {
    return retainedResultCount < maximumRetainedResults;
}

bool IsCurrentDriverInstance(uint64_t requestedDriverInstanceID,
                             uint64_t currentDriverInstanceID) noexcept {
    return requestedDriverInstanceID != 0 &&
           requestedDriverInstanceID == currentDriverInstanceID;
}

bool IsPermittedDeckCommand(DeckCommand command) noexcept {
    return command == DeckCommand::kPlay || command == DeckCommand::kStop ||
           command == DeckCommand::kRewind;
}

bool IsCatalogDeckCommand(DeckCommand command) noexcept {
    return IsPermittedDeckCommand(command) ||
           command == DeckCommand::kFastForward ||
           command == DeckCommand::kShuttleForward ||
           command == DeckCommand::kShuttleReverse;
}

bool DeckCommandRequiresCapabilityProof(DeckCommand command) noexcept {
    return command == DeckCommand::kFastForward ||
           command == DeckCommand::kShuttleForward ||
           command == DeckCommand::kShuttleReverse;
}

bool CanAdmitDeckCommand(DeckCommand command, bool exactRouteProofAvailable) noexcept {
    return IsPermittedDeckCommand(command) ||
           (DeckCommandRequiresCapabilityProof(command) && exactRouteProofAvailable);
}

bool MatchesConditionalDeckAuthorization(
    const ConditionalDeckAuthorization& authorization,
    const DeckControlRequestWire& request,
    uint64_t currentDriverInstanceID) noexcept {
    return currentDriverInstanceID != 0 &&
           authorization.driverInstanceID == currentDriverInstanceID &&
           request.driverInstanceID == currentDriverInstanceID &&
           authorization.command == request.command &&
           DeckCommandRequiresCapabilityProof(
               static_cast<DeckCommand>(request.command)) &&
           authorization.guid == request.guid &&
           authorization.deviceIncarnation == request.deviceIncarnation &&
           authorization.routeEpoch == request.routeEpoch &&
           authorization.generation == request.generation &&
           authorization.nodeID == request.nodeID && authorization.reserved == 0;
}

bool IsValidRequest(const DeckControlRequestWire& request) noexcept {
    const auto command = static_cast<DeckCommand>(request.command);
    return request.version == kWireVersion && request.size == sizeof(request) &&
           request.operationID != 0 && request.attemptID != 0 && request.guid != 0 &&
           request.reserved == 0 && request.driverInstanceID != 0 &&
           request.deviceIncarnation != 0 && request.routeEpoch != 0 &&
           request.nodeID <= 0xFF && request.routeReserved == 0 &&
           IsCatalogDeckCommand(command);
}

std::array<uint8_t, kDeckCommandLength> CommandFrame(DeckCommand command) noexcept {
    switch (command) {
    case DeckCommand::kPlay:
        return kPlay;
    case DeckCommand::kStop:
        return kStop;
    case DeckCommand::kRewind:
        return kRewind;
    case DeckCommand::kFastForward:
        return kFastForward;
    case DeckCommand::kShuttleForward:
        return kShuttleForward;
    case DeckCommand::kShuttleReverse:
        return kShuttleReverse;
    }
    return {};
}

bool IsExactPermittedFrame(std::span<const uint8_t> frame) noexcept {
    return frame.size() == kDeckCommandLength &&
           (std::equal(frame.begin(), frame.end(), kPlay.begin()) ||
            std::equal(frame.begin(), frame.end(), kStop.begin()) ||
            std::equal(frame.begin(), frame.end(), kRewind.begin()));
}

bool IsExactCatalogFrame(std::span<const uint8_t> frame) noexcept {
    return IsExactPermittedFrame(frame) ||
           (frame.size() == kDeckCommandLength &&
            (std::equal(frame.begin(), frame.end(), kFastForward.begin()) ||
             std::equal(frame.begin(), frame.end(), kShuttleForward.begin()) ||
             std::equal(frame.begin(), frame.end(), kShuttleReverse.begin())));
}

DeckResponseClassification ClassifyDeckResponse(std::span<const uint8_t> command,
                                                 std::span<const uint8_t> response) noexcept {
    if (!IsExactCatalogFrame(command) || response.size() != kDeckCommandLength ||
        response[1] != command[1] || response[2] != command[2] ||
        response[3] != command[3]) {
        return DeckResponseClassification::kMismatch;
    }

    switch (response[0]) {
    case 0x0F:
        return DeckResponseClassification::kInterim;
    case 0x09:
        return DeckResponseClassification::kAccepted;
    case 0x0A:
        return DeckResponseClassification::kRejected;
    case 0x08:
        return DeckResponseClassification::kNotImplemented;
    default:
        return DeckResponseClassification::kOtherTerminal;
    }
}

bool IsCorrelatedDeckResponse(std::span<const uint8_t> command,
                              std::span<const uint8_t> response) noexcept {
    // The retained Sony fixtures are four-byte terminal responses. Byte zero is
    // the response type; address, opcode, and operand must identify the exact
    // request so a late STOP cannot complete REWIND (both use opcode 0xC4).
    return ClassifyDeckResponse(command, response) != DeckResponseClassification::kMismatch;
}

FoundationCapabilitiesWire Capabilities() noexcept {
    FoundationCapabilitiesWire result{};
    result.capabilities = kReadOnlyIdentityHealthLog | kBoundedDeckControl |
                          kSingleMutatingCommand | kNoControlReplay |
                          kRawCSRUnavailable | kRawFCPUnavailable |
                          kIsochTransmitUnavailable | kRecordEraseUnavailable |
                          kArchivalCaptureUnavailable | kRawReceivePreview;
    result.permittedDeckCommands = CommandBit(DeckCommand::kPlay) |
                                   CommandBit(DeckCommand::kStop) |
                                   CommandBit(DeckCommand::kRewind);
    return result;
}

TransportCapabilityCatalogWire TransportCapabilityCatalog() noexcept {
    TransportCapabilityCatalogWire result{};
    result.flags = kTransportCatalogExactRoute | kTransportCatalogNoAutomaticRetry |
                   kTransportCatalogNoCallerFrames | kTransportCatalogProbeExclusive |
                   kTransportCatalogBoundedOwnedEvidence |
                   kTransportCatalogConditionalControlProof;

    constexpr std::array<DeckCommand, 6> commands{
        DeckCommand::kPlay,
        DeckCommand::kStop,
        DeckCommand::kRewind,
        DeckCommand::kFastForward,
        DeckCommand::kShuttleForward,
        DeckCommand::kShuttleReverse,
    };
    for (size_t index = 0; index < commands.size(); ++index) {
        const auto command = commands[index];
        auto& entry = result.entries[index];
        entry.command = static_cast<uint32_t>(command);
        entry.flags = kTransportEntryExactSpecificInquiry |
                      kTransportEntryStateChangingControl;
        if (IsPermittedDeckCommand(command)) {
            entry.flags |= kTransportEntryBaselineControl;
        } else {
            entry.flags |= kTransportEntryPositiveSameRouteProofRequired;
        }
        entry.control = CommandFrame(command);
        entry.inquiry = SpecificInquiryFor(entry.control);
    }
    return result;
}

bool IsValidTransportCapabilityProbeRequest(
    const TransportCapabilityProbeRequestWire& request) noexcept {
    return request.version == kWireVersion && request.size == sizeof(request) &&
           request.operationID != 0 && request.attemptID != 0 && request.guid != 0 &&
           request.driverInstanceID != 0 && request.deviceIncarnation != 0 &&
           request.routeEpoch != 0 && request.nodeID <= 0xFF && request.reserved16 == 0 &&
           request.reserved32 == 0 &&
           IsCatalogDeckCommand(static_cast<DeckCommand>(request.command));
}

std::array<uint8_t, kDeckCommandLength> TransportCapabilityInquiryFrame(
    DeckCommand command) noexcept {
    if (!IsCatalogDeckCommand(command)) {
        return {};
    }
    return SpecificInquiryFor(CommandFrame(command));
}

TransportCapabilityResponseClassification ClassifyTransportCapabilityResponse(
    DeckCommand command, std::span<const uint8_t> response) noexcept {
    const auto inquiry = TransportCapabilityInquiryFrame(command);
    if (!IsCatalogDeckCommand(command) || response.size() != inquiry.size() ||
        response[1] != inquiry[1] || response[2] != inquiry[2] ||
        response[3] != inquiry[3]) {
        return TransportCapabilityResponseClassification::kMismatch;
    }
    if (response[0] == 0x0C) {
        return TransportCapabilityResponseClassification::kImplemented;
    }
    if (response[0] == 0x08) {
        return TransportCapabilityResponseClassification::kNotImplemented;
    }
    return TransportCapabilityResponseClassification::kUnexpectedTerminal;
}

bool ShouldInstallConditionalDeckAuthorization(
    const TransportCapabilityResultWire& result) noexcept {
    constexpr uint32_t requiredStages =
        kTransportCapabilityStageAdmitted |
        kTransportCapabilityStageRouteBound |
        kTransportCapabilityStageFCPTransportAccepted |
        kTransportCapabilityStageResponseReceived |
        kTransportCapabilityStageResponseCorrelated |
        kTransportCapabilityStageCompleted |
        kTransportCapabilityStageTerminalImplemented;
    const auto command = static_cast<DeckCommand>(result.command);
    if (!DeckCommandRequiresCapabilityProof(command) || result.stageFlags != requiredStages ||
        result.responseEventOverflow != 0 || result.responseEventCount == 0 ||
        result.responseEventCount > kMaximumCapabilityResponseEvents ||
        result.requestLength != kDeckCommandLength ||
        result.request != TransportCapabilityInquiryFrame(command)) {
        return false;
    }
    const auto& terminal = result.responseEvents[result.responseEventCount - 1];
    const auto terminalPayload = std::span<const uint8_t>(
        terminal.bytes.data(), terminal.length <= terminal.bytes.size() ? terminal.length : 0);
    return terminal.length == kDeckCommandLength && terminal.timestampNs != 0 &&
           terminal.fcpAttemptID == result.fcpAttemptID &&
           terminal.generation == result.generation &&
           (terminal.sourceNodeID & 0x3Fu) == (result.nodeID & 0x3Fu) &&
           terminal.reserved == 0 &&
           terminal.classification == static_cast<uint32_t>(
               TransportCapabilityResponseClassification::kImplemented) &&
           ClassifyTransportCapabilityResponse(command, terminalPayload) ==
               TransportCapabilityResponseClassification::kImplemented &&
           result.terminalStatus == 0 && result.retryCount == 0 &&
           result.terminalClassification == static_cast<uint32_t>(
               TransportCapabilityResponseClassification::kImplemented) &&
           result.supportState == static_cast<uint32_t>(
               TransportCapabilitySupportState::kImplemented) &&
           result.routeState == static_cast<uint32_t>(
               RouteEvidenceState::kBoundCurrentAtSubmission) &&
           result.fcpAttemptID != 0 && result.asyncTransportHandle != 0 &&
           result.admittedTimestampNs != 0 && result.routeBoundTimestampNs != 0 &&
           result.asyncTransportAcceptedTimestampNs != 0 &&
           result.completedTimestampNs != 0;
}

bool ShouldObserveTransportCapabilityEvidence(bool resultReady) noexcept {
    return !resultReady;
}

InspectorCapabilitiesWire InspectorCapabilities() noexcept {
    InspectorCapabilitiesWire result{};
    result.queryMask = kInspectorUnitInfo | kInspectorSubunitInfo | kInspectorUnitPlugInfo |
                       kInspectorTapeMediumInfo | kInspectorTapeTransportState |
                       kInspectorTapeAbsoluteTrackNumber | kInspectorTapeTimeCode;
    result.flags = kInspectorExactRouteRequired | kInspectorNoAutomaticRetry |
                   kInspectorExclusiveWithReceiveAndControl |
                   kInspectorBoundedOwnedEvidence | kInspectorRawResponsesRetained |
                   kInspectorTapeTransportStateMayOverlapReceive |
                   kInspectorTapeTimeCodeReceiveExcluded;
    return result;
}

bool IsValidInspectorRequest(const InspectorRequestWire& request) noexcept {
    if (request.version != kWireVersion || request.size != sizeof(request) ||
        request.operationID == 0 || request.attemptID == 0 || request.guid == 0 ||
        request.driverInstanceID == 0 || request.deviceIncarnation == 0 ||
        request.routeEpoch == 0 || request.nodeID > 0xFF ||
        std::any_of(request.reserved.begin(), request.reserved.end(),
                    [](uint8_t byte) { return byte != 0; })) {
        return false;
    }
    const auto query = static_cast<InspectorQuery>(request.query);
    if (query == InspectorQuery::kSubunitInfo) {
        return request.subunitPage <= 7;
    }
    return request.subunitPage == 0 &&
           (query == InspectorQuery::kUnitInfo || query == InspectorQuery::kUnitPlugInfo ||
            query == InspectorQuery::kTapeMediumInfo || query == InspectorQuery::kTapeTransportState ||
            query == InspectorQuery::kTapeAbsoluteTrackNumber ||
            query == InspectorQuery::kTapeTimeCode);
}

bool MayInspectorQueryOverlapReceive(InspectorQuery query) noexcept {
    return query == InspectorQuery::kTapeTransportState;
}

size_t InspectorCommandLength(InspectorQuery query) noexcept {
    switch (query) {
    case InspectorQuery::kTapeMediumInfo: return 5;
    case InspectorQuery::kTapeTransportState: return 4;
    case InspectorQuery::kTapeAbsoluteTrackNumber: return 8;
    case InspectorQuery::kTapeTimeCode: return 8;
    case InspectorQuery::kUnitInfo:
    case InspectorQuery::kSubunitInfo:
    case InspectorQuery::kUnitPlugInfo: return kInspectorCommandLength;
    }
    return 0;
}

std::array<uint8_t, kInspectorCommandLength> InspectorCommandFrame(
    InspectorQuery query, uint8_t subunitPage) noexcept {
    switch (query) {
    case InspectorQuery::kUnitInfo:
        return {0x01, 0xFF, 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    case InspectorQuery::kSubunitInfo:
        if (subunitPage <= 7) {
            return {0x01, 0xFF, 0x31,
                    static_cast<uint8_t>((subunitPage << 4u) | 0x07u),
                    0xFF, 0xFF, 0xFF, 0xFF};
        }
        return {};
    case InspectorQuery::kUnitPlugInfo:
        return {0x01, 0xFF, 0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF};
    // Apple AVCVideoServices TapeSubunitController.cpp:275-299,338-363,
    // mirrored in tapecap 826b9a2a. Typed STATUS only; no caller-supplied bytes.
    case InspectorQuery::kTapeMediumInfo:
        return {0x01, 0x20, 0xDA, 0x7F, 0x7F, 0, 0, 0};
    case InspectorQuery::kTapeTransportState:
        return {0x01, 0x20, 0xD0, 0x7F, 0, 0, 0, 0};
    // TA 2004005 section 4.3 figure 14. STATUS only, never ATN CONTROL/search.
    case InspectorQuery::kTapeAbsoluteTrackNumber:
        return {0x01, 0x20, 0x52, 0x71, 0xFF, 0xFF, 0xFF, 0xFF};
    // TA 2004005 section 4.28 (printed pages 65-66), TIME CODE STATUS.
    // Telemetry only: no TIME CODE CONTROL or search command is admitted.
    case InspectorQuery::kTapeTimeCode:
        return {0x01, 0x20, 0x51, 0x71, 0xFF, 0xFF, 0xFF, 0xFF};
    }
    return {};
}

InspectorResponseClassification ClassifyInspectorResponse(
    InspectorQuery query,
    uint8_t subunitPage,
    std::span<const uint8_t> response) noexcept {
    const bool tape = query == InspectorQuery::kTapeMediumInfo ||
                      query == InspectorQuery::kTapeTransportState ||
                      query == InspectorQuery::kTapeAbsoluteTrackNumber ||
                      query == InspectorQuery::kTapeTimeCode;
    const auto length = InspectorCommandLength(query);
    if (length == 0 || response.size() != length || response[1] != (tape ? 0x20 : 0xFF)) {
        return InspectorResponseClassification::kMismatch;
    }
    switch (query) {
    case InspectorQuery::kUnitInfo:
        if (response[2] != 0x30 || response[3] != 0x07) {
            return InspectorResponseClassification::kMismatch;
        }
        break;
    case InspectorQuery::kSubunitInfo:
        if (subunitPage > 7 || response[2] != 0x31 ||
            response[3] != static_cast<uint8_t>((subunitPage << 4u) | 0x07u)) {
            return InspectorResponseClassification::kMismatch;
        }
        break;
    case InspectorQuery::kUnitPlugInfo:
        if (response[2] != 0x02 || response[3] != 0x00) {
            return InspectorResponseClassification::kMismatch;
        }
        break;
    case InspectorQuery::kTapeMediumInfo:
        if (response[2] != 0xDA) return InspectorResponseClassification::kMismatch;
        break;
    case InspectorQuery::kTapeAbsoluteTrackNumber:
        if (response[2] != 0x52 || response[3] != 0x71) return InspectorResponseClassification::kMismatch;
        break;
    case InspectorQuery::kTapeTimeCode:
        if (response[2] != 0x51 || response[3] != 0x71) {
            return InspectorResponseClassification::kMismatch;
        }
        if (response[0] == 0x0C && response[4] != 0x7F) {
            const auto isPackedBCD = [](uint8_t value) {
                return (value & 0x0Fu) <= 9 && ((value >> 4u) & 0x0Fu) <= 9;
            };
            if (!isPackedBCD(response[4]) || !isPackedBCD(response[5]) ||
                !isPackedBCD(response[6]) || !isPackedBCD(response[7])) {
                return InspectorResponseClassification::kOtherTerminal;
            }
        }
        break;
    case InspectorQuery::kTapeTransportState: {
        // STATUS reports transport MODE in the opcode field. This never adds
        // any CONTROL command (including RECORD) to the outbound allowlist.
        const bool reportsMode = response[0] == 0x0C || response[0] == 0x0B;
        if (reportsMode ? (response[2] < 0xC1 || response[2] > 0xC4) : response[2] != 0xD0) {
            return InspectorResponseClassification::kMismatch;
        }
        break;
    }
    default:
        return InspectorResponseClassification::kMismatch;
    }

    switch (response[0]) {
    case 0x0F:
        return InspectorResponseClassification::kInterim;
    case 0x0C:
        return InspectorResponseClassification::kImplementedStable;
    case 0x0A:
        return InspectorResponseClassification::kRejected;
    case 0x08:
        return InspectorResponseClassification::kNotImplemented;
    case 0x09:
        return InspectorResponseClassification::kAcceptedInvalidForStatus;
    case 0x0B:
        return InspectorResponseClassification::kInTransitionInvalidForQuery;
    case 0x0D:
        return InspectorResponseClassification::kChangedInvalidForStatus;
    default:
        return InspectorResponseClassification::kOtherTerminal;
    }
}

InspectorDecodedWire DecodeInspectorResponse(InspectorQuery query,
                                              uint8_t subunitPage,
                                              std::span<const uint8_t> response) noexcept {
    InspectorDecodedWire result{};
    if (ClassifyInspectorResponse(query, subunitPage, response) !=
        InspectorResponseClassification::kImplementedStable) {
        return result;
    }

    switch (query) {
    case InspectorQuery::kUnitInfo: {
        const uint8_t unitType = static_cast<uint8_t>(response[4] >> 3u);
        // Extended unit types insert bytes before company_ID and therefore do
        // not fit this deliberately fixed-width eight-byte inspector page.
        if (unitType == 0x1E) {
            return result;
        }
        result.unitType = unitType;
        result.unitID = static_cast<uint8_t>(response[4] & 0x07u);
        std::copy_n(response.begin() + 5, result.companyID.size(), result.companyID.begin());
        result.validFields = kInspectorDecodedUnitInfo;
        return result;
    }
    case InspectorQuery::kSubunitInfo: {
        std::array<bool, 32> seenTypes{};
        bool sawTerminator = false;
        for (size_t index = 0; index < result.subunits.size(); ++index) {
            const uint8_t value = response[4 + index];
            if (value == 0xFF) {
                sawTerminator = true;
                continue;
            }
            const uint8_t type = static_cast<uint8_t>(value >> 3u);
            const uint8_t maximumID = static_cast<uint8_t>(value & 0x07u);
            // Values 5 and above introduce an extended subunit_ID; type 1E
            // introduces an extended type. Neither can be represented by the
            // fixed four-entry page without consuming following bytes.
            if (sawTerminator || maximumID > 4 || type == 0x1E || seenTypes[type]) {
                return {};
            }
            seenTypes[type] = true;
            result.subunits[result.subunitCount++] = {type, maximumID};
        }
        result.validFields = kInspectorDecodedSubunitInfo;
        return result;
    }
    case InspectorQuery::kUnitPlugInfo:
        if (std::any_of(response.begin() + 4, response.end(),
                        [](uint8_t count) { return count > 31; })) {
            return result;
        }
        result.serialBusIsochronousInputPlugs = response[4];
        result.serialBusIsochronousOutputPlugs = response[5];
        result.externalInputPlugs = response[6];
        result.externalOutputPlugs = response[7];
        result.validFields = kInspectorDecodedUnitPlugInfo;
        return result;
    case InspectorQuery::kTapeMediumInfo:
    case InspectorQuery::kTapeTransportState:
    case InspectorQuery::kTapeAbsoluteTrackNumber:
    case InspectorQuery::kTapeTimeCode:
        // Raw fields interpreted by the app. Do not repurpose inventory fields
        // or claim medium presence/BOT/EOT from an unqualified status code.
        return result;
    }
    return result;
}

bool ShouldObserveInspectorEvidence(bool resultReady) noexcept {
    return !resultReady;
}

} // namespace RewindDV::Foundation::DriverPolicy
