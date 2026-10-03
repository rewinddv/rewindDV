// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace RewindDV::Foundation::DriverPolicy {

inline constexpr uint32_t kWireVersion = 1;
inline constexpr uint32_t kDeckCommandLength = 4;
inline constexpr uint32_t kInspectorCommandLength = 8;
// Product display budget for optional TIME CODE telemetry. This deliberately
// does not claim that a compliant deck must answer within this interval.
inline constexpr uint32_t kTapeTimeCodeResponseDeadlineMs = 250;
inline constexpr size_t kMaximumResponseEvents = 4;
inline constexpr size_t kMaximumInspectorResponseEvents = 2;
inline constexpr size_t kMaximumCapabilityResponseEvents = 2;
// Saturation is fail-closed for the rest of the driver lifetime. Consumed IDs
// are never evicted because that would permit a replay.
inline constexpr size_t kMaximumLifetimeAttempts = 4096;

// These selectors extend the pinned ASFireWire user-client ABI without
// repurposing an upstream selector. Keep the matching IIG enum values in sync.
inline constexpr uint64_t kMethodGetFoundationCapabilities = 64;
inline constexpr uint64_t kMethodSubmitDeckControl = 65;
inline constexpr uint64_t kMethodGetDeckControlResult = 66;
inline constexpr uint64_t kMethodGetFoundationRoute = 67;
inline constexpr uint64_t kMethodGetInspectorCapabilities = 72;
inline constexpr uint64_t kMethodSubmitInspectorProbe = 73;
inline constexpr uint64_t kMethodGetInspectorResult = 74;
inline constexpr uint64_t kMethodGetTransportCapabilityCatalog = 75;
inline constexpr uint64_t kMethodSubmitTransportCapabilityProbe = 76;
inline constexpr uint64_t kMethodGetTransportCapabilityResult = 77;

enum class ExternalMethodDisposition : uint8_t {
    kReject,
    kReadOnly,
    kBoundedControl,
};

enum class DeckCommand : uint32_t {
    kPlay = 1,
    kStop = 2,
    kRewind = 3,
    kFastForward = 4,
    kShuttleForward = 5,
    kShuttleReverse = 6,
};

enum TransportCapabilityCatalogFlag : uint32_t {
    kTransportCatalogExactRoute = 1u << 0,
    kTransportCatalogNoAutomaticRetry = 1u << 1,
    kTransportCatalogNoCallerFrames = 1u << 2,
    kTransportCatalogProbeExclusive = 1u << 3,
    kTransportCatalogBoundedOwnedEvidence = 1u << 4,
    kTransportCatalogConditionalControlProof = 1u << 5,
};

enum TransportCapabilityEntryFlag : uint32_t {
    kTransportEntryExactSpecificInquiry = 1u << 0,
    kTransportEntryBaselineControl = 1u << 1,
    kTransportEntryPositiveSameRouteProofRequired = 1u << 2,
    kTransportEntryStateChangingControl = 1u << 3,
};

enum TransportCapabilityStage : uint32_t {
    kTransportCapabilityStageAdmitted = 1u << 0,
    kTransportCapabilityStageRouteBound = 1u << 1,
    kTransportCapabilityStageFCPTransportAccepted = 1u << 2,
    kTransportCapabilityStageResponseReceived = 1u << 3,
    kTransportCapabilityStageResponseCorrelated = 1u << 4,
    kTransportCapabilityStageCompleted = 1u << 5,
    kTransportCapabilityStageTerminalImplemented = 1u << 6,
    kTransportCapabilityStageTerminalNotImplemented = 1u << 7,
    kTransportCapabilityStageConditionalAuthorizationInstalled = 1u << 8,
};

enum class TransportCapabilityResponseClassification : uint32_t {
    kUnknown = 0,
    kMismatch = 1,
    kImplemented = 2,
    kNotImplemented = 3,
    kUnexpectedTerminal = 4,
};

enum class TransportCapabilitySupportState : uint32_t {
    kUnknown = 0,
    kImplemented = 1,
    kNotImplemented = 2,
};

enum class TransportControlAuthorization : uint32_t {
    kNone = 0,
    kBaseline = 1,
    kExactRouteSpecificInquiry = 2,
};

enum class AttemptAdmission : uint8_t {
    kAdmit,
    kBusy,
    kReplay,
    kLifetimeLimit,
};

enum class DeckResponseClassification : uint32_t {
    kUnknown = 0,
    kMismatch = 1,
    kInterim = 2,
    kAccepted = 3,
    kRejected = 4,
    kNotImplemented = 5,
    kOtherTerminal = 6,
};

enum class InspectorQuery : uint8_t {
    kUnitInfo = 1,
    kSubunitInfo = 2,
    kUnitPlugInfo = 3,
    kTapeMediumInfo = 4,
    kTapeTransportState = 5,
    kTapeAbsoluteTrackNumber = 6,
    kTapeTimeCode = 7,
};

enum class InspectorResponseClassification : uint32_t {
    kUnknown = 0,
    kMismatch = 1,
    kInterim = 2,
    kImplementedStable = 3,
    kRejected = 4,
    kNotImplemented = 5,
    kAcceptedInvalidForStatus = 6,
    kInTransitionInvalidForQuery = 7,
    kChangedInvalidForStatus = 8,
    kOtherTerminal = 9,
};

enum InspectorCapability : uint32_t {
    kInspectorExactRouteRequired = 1u << 0,
    kInspectorNoAutomaticRetry = 1u << 1,
    // Generic inspector policy. The typed exception is advertised separately.
    kInspectorExclusiveWithReceiveAndControl = 1u << 2,
    kInspectorBoundedOwnedEvidence = 1u << 3,
    kInspectorRawResponsesRetained = 1u << 4,
    kInspectorTapeTransportStateMayOverlapReceive = 1u << 5,
    kInspectorTapeTimeCodeReceiveExcluded = 1u << 6,
};

enum InspectorQueryCapability : uint32_t {
    kInspectorUnitInfo = 1u << 0,
    kInspectorSubunitInfo = 1u << 1,
    kInspectorUnitPlugInfo = 1u << 2,
    kInspectorTapeMediumInfo = 1u << 3,
    kInspectorTapeTransportState = 1u << 4,
    kInspectorTapeAbsoluteTrackNumber = 1u << 5,
    kInspectorTapeTimeCode = 1u << 6,
};

enum InspectorStage : uint32_t {
    kInspectorStageAdmitted = 1u << 0,
    kInspectorStageRouteBound = 1u << 1,
    kInspectorStageFCPTransportAccepted = 1u << 2,
    kInspectorStageResponseReceived = 1u << 3,
    kInspectorStageResponseCorrelated = 1u << 4,
    kInspectorStageCompleted = 1u << 5,
    kInspectorStageTerminalImplementedStable = 1u << 6,
    kInspectorStageTerminalRejected = 1u << 7,
};

enum InspectorDecodedField : uint32_t {
    kInspectorDecodedUnitInfo = 1u << 0,
    kInspectorDecodedSubunitInfo = 1u << 1,
    kInspectorDecodedUnitPlugInfo = 1u << 2,
};

enum Capability : uint32_t {
    kReadOnlyIdentityHealthLog = 1u << 0,
    kBoundedDeckControl = 1u << 1,
    kSingleMutatingCommand = 1u << 2,
    kNoControlReplay = 1u << 3,
    kRawCSRUnavailable = 1u << 4,
    kRawFCPUnavailable = 1u << 5,
    kIsochTransmitUnavailable = 1u << 6,
    kRecordEraseUnavailable = 1u << 7,
    kArchivalCaptureUnavailable = 1u << 8,
    kRawReceivePreview = 1u << 9,
};

enum ControlStage : uint32_t {
    kStageAdmitted = 1u << 0,
    // The public FCP API returned a valid handle. This does not prove that the
    // async write reached descriptor publication or the wire.
    kStageFCPTransportAccepted = 1u << 1,
    kStageResponseReceived = 1u << 2,
    kStageResponseCorrelated = 1u << 3,
    kStageCompleted = 1u << 4,
    // Reserved truth stages. This adapter cannot currently observe them, so it
    // must leave both clear rather than infer them from an FCP handle.
    kStagePrepared = 1u << 5,
    kStageOutboundWriteSubmitted = 1u << 6,
    kStageTerminalAccepted = 1u << 7,
    kStageTerminalRejected = 1u << 8,
};

enum class RouteEvidenceState : uint32_t {
    kUnknown = 0,
    kBoundCurrentAtSubmission = 1,
    kInvalidatedByObservedBusReset = 2,
};

struct FoundationCapabilitiesWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(FoundationCapabilitiesWire)};
    uint32_t capabilities{0};
    uint32_t permittedDeckCommands{0};
    uint32_t maximumMutatingCommands{1};
    uint32_t deckCommandLength{kDeckCommandLength};
};

static_assert(sizeof(FoundationCapabilitiesWire) == 24);

// Same-host DriverKit wire format. Every field is fixed width and every byte,
// including reserved bytes, is validated before a command is admitted.
struct DeckControlRequestWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(DeckControlRequestWire)};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint32_t command{0};
    uint32_t reserved{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint16_t routeReserved{0};
} __attribute__((packed));

static_assert(sizeof(DeckControlRequestWire) == 72);

struct FoundationRouteWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(FoundationRouteWire)};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint16_t reserved{0};
} __attribute__((packed));

static_assert(sizeof(FoundationRouteWire) == 48);

// Driver-internal authorization key. This is not exported as a separate wire
// message; every field is copied from an exact, positively proven route.
struct ConditionalDeckAuthorization final {
    uint64_t driverInstanceID{0};
    uint64_t guid{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint16_t reserved{0};
    uint32_t command{0};
};

struct TransportCapabilityCatalogEntryWire final {
    uint32_t command{0};
    uint32_t flags{0};
    uint32_t inquiryLength{kDeckCommandLength};
    uint32_t controlLength{kDeckCommandLength};
    std::array<uint8_t, kDeckCommandLength> inquiry{};
    std::array<uint8_t, kDeckCommandLength> control{};
} __attribute__((packed));

static_assert(sizeof(TransportCapabilityCatalogEntryWire) == 24);

struct TransportCapabilityCatalogWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(TransportCapabilityCatalogWire)};
    uint32_t entryCount{6};
    uint32_t flags{0};
    uint32_t maximumConcurrentProbes{1};
    uint32_t maximumRetainedResults{128};
    uint32_t maximumResponseBytes{512};
    uint32_t maximumResponseEvents{kMaximumCapabilityResponseEvents};
    std::array<TransportCapabilityCatalogEntryWire, 6> entries{};
} __attribute__((packed));

static_assert(sizeof(TransportCapabilityCatalogWire) == 176);

struct TransportCapabilityProbeRequestWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(TransportCapabilityProbeRequestWire)};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint16_t reserved16{0};
    uint32_t command{0};
    uint32_t reserved32{0};
} __attribute__((packed));

static_assert(sizeof(TransportCapabilityProbeRequestWire) == 72);

struct InspectorCapabilitiesWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(InspectorCapabilitiesWire)};
    uint32_t queryMask{0};
    uint32_t flags{0};
    uint32_t maximumSubunitPage{7};
    uint32_t maximumConcurrentProbes{1};
    uint32_t maximumRetainedResults{128};
    uint32_t maximumResponseBytes{512};
    uint32_t maximumResponseEvents{kMaximumInspectorResponseEvents};
    uint32_t reserved{0};
} __attribute__((packed));

static_assert(sizeof(InspectorCapabilitiesWire) == 40);

struct InspectorRequestWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(InspectorRequestWire)};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint8_t query{0};
    uint8_t subunitPage{0};
    std::array<uint8_t, 8> reserved{};
} __attribute__((packed));

static_assert(sizeof(InspectorRequestWire) == 72);

struct InspectorSubunitEntryWire final {
    uint8_t type{0};
    uint8_t maximumID{0};
} __attribute__((packed));

static_assert(sizeof(InspectorSubunitEntryWire) == 2);

struct InspectorDecodedWire final {
    uint32_t validFields{0};
    uint8_t unitType{0};
    uint8_t unitID{0};
    std::array<uint8_t, 3> companyID{};
    uint8_t subunitCount{0};
    std::array<InspectorSubunitEntryWire, 4> subunits{};
    uint8_t serialBusIsochronousInputPlugs{0};
    uint8_t serialBusIsochronousOutputPlugs{0};
    uint8_t externalInputPlugs{0};
    uint8_t externalOutputPlugs{0};
    std::array<uint8_t, 10> reserved{};
} __attribute__((packed));

static_assert(sizeof(InspectorDecodedWire) == 32);

struct DeckResponseEventWire final {
    uint64_t timestampNs{0};
    uint64_t fcpAttemptID{0};
    uint32_t generation{0};
    uint16_t sourceNodeID{0};
    uint16_t reserved{0};
    uint32_t classification{0};
    uint32_t length{0};
    std::array<uint8_t, 512> bytes{};
} __attribute__((packed));

static_assert(sizeof(DeckResponseEventWire) == 544);

using InspectorResponseEventWire = DeckResponseEventWire;
using TransportCapabilityResponseEventWire = DeckResponseEventWire;

// The response is deliberately evidence-oriented. A successful transport
// result and an ACCEPTED (0x09) response do not assert physical tape motion.
struct DeckControlResultWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(DeckControlResultWire)};
    uint64_t requestID{0};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint32_t command{0};
    uint32_t stageFlags{0};
    int32_t terminalStatus{0};
    uint32_t retryCount{0};
    uint32_t routeState{static_cast<uint32_t>(RouteEvidenceState::kUnknown)};
    uint32_t requestLength{0};
    uint32_t responseEventCount{0};
    uint32_t responseEventOverflow{0};
    uint64_t fcpAttemptID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint64_t asyncTransportHandle{0};
    uint32_t generation{0};
    uint16_t nodeID{0xFFFF};
    uint16_t reserved{0};
    uint64_t admittedTimestampNs{0};
    uint64_t routeBoundTimestampNs{0};
    uint64_t asyncTransportAcceptedTimestampNs{0};
    std::array<uint8_t, kDeckCommandLength> request{};
    std::array<DeckResponseEventWire, kMaximumResponseEvents> responseEvents{};
} __attribute__((packed));

static_assert(sizeof(DeckControlResultWire) == 2324);

struct InspectorResultWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(InspectorResultWire)};
    uint64_t requestID{0};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint64_t fcpAttemptID{0};
    uint64_t asyncTransportHandle{0};
    uint64_t admittedTimestampNs{0};
    uint64_t routeBoundTimestampNs{0};
    uint64_t asyncTransportAcceptedTimestampNs{0};
    uint64_t completedTimestampNs{0};
    uint32_t generation{0};
    uint32_t query{0};
    uint32_t stageFlags{0};
    uint32_t terminalClassification{
        static_cast<uint32_t>(InspectorResponseClassification::kUnknown)};
    int32_t terminalStatus{0};
    uint32_t retryCount{0};
    uint32_t requestLength{0};
    uint32_t responseEventCount{0};
    uint32_t responseEventOverflow{0};
    uint16_t nodeID{0xFFFF};
    uint8_t subunitPage{0};
    uint8_t reserved{0};
    uint32_t routeState{static_cast<uint32_t>(RouteEvidenceState::kUnknown)};
    InspectorDecodedWire decoded{};
    std::array<uint8_t, kInspectorCommandLength> request{};
    std::array<InspectorResponseEventWire, kMaximumInspectorResponseEvents> responseEvents{};
} __attribute__((packed));

static_assert(sizeof(InspectorResultWire) == 1284);

struct TransportCapabilityResultWire final {
    uint32_t version{kWireVersion};
    uint32_t size{sizeof(TransportCapabilityResultWire)};
    uint64_t requestID{0};
    uint64_t operationID{0};
    uint64_t attemptID{0};
    uint64_t guid{0};
    uint64_t driverInstanceID{0};
    uint64_t deviceIncarnation{0};
    uint64_t routeEpoch{0};
    uint64_t fcpAttemptID{0};
    uint64_t asyncTransportHandle{0};
    uint64_t admittedTimestampNs{0};
    uint64_t routeBoundTimestampNs{0};
    uint64_t asyncTransportAcceptedTimestampNs{0};
    uint64_t completedTimestampNs{0};
    uint32_t generation{0};
    uint32_t command{0};
    uint32_t stageFlags{0};
    uint32_t terminalClassification{
        static_cast<uint32_t>(TransportCapabilityResponseClassification::kUnknown)};
    int32_t terminalStatus{0};
    uint32_t retryCount{0};
    uint32_t requestLength{0};
    uint32_t responseEventCount{0};
    uint32_t responseEventOverflow{0};
    uint16_t nodeID{0xFFFF};
    uint16_t reserved16{0};
    uint32_t routeState{static_cast<uint32_t>(RouteEvidenceState::kUnknown)};
    uint32_t supportState{
        static_cast<uint32_t>(TransportCapabilitySupportState::kUnknown)};
    uint32_t controlAuthorization{
        static_cast<uint32_t>(TransportControlAuthorization::kNone)};
    uint32_t reserved32{0};
    std::array<uint8_t, kDeckCommandLength> request{};
    std::array<uint8_t, 4> reservedBytes{};
    std::array<TransportCapabilityResponseEventWire,
               kMaximumCapabilityResponseEvents> responseEvents{};
} __attribute__((packed));

static_assert(sizeof(TransportCapabilityResultWire) == 1264);

[[nodiscard]] ExternalMethodDisposition ClassifyExternalMethod(uint64_t selector) noexcept;
[[nodiscard]] bool IsAllowedClientMemoryType(uint64_t type) noexcept;
[[nodiscard]] AttemptAdmission ClassifyAttemptAdmission(
    uint64_t activeRequestID,
    bool attemptAlreadyConsumed,
    size_t consumedAttemptCount,
    size_t maximumLifetimeAttempts) noexcept;
[[nodiscard]] AttemptAdmission ClassifyMonotonicInspectorAttemptAdmission(
    uint64_t activeRequestID,
    uint64_t attemptID,
    uint64_t admittedAttemptHighWater) noexcept;
[[nodiscard]] bool HasResultStorageCapacity(size_t retainedResultCount,
                                            size_t maximumRetainedResults) noexcept;
[[nodiscard]] bool IsCurrentDriverInstance(uint64_t requestedDriverInstanceID,
                                           uint64_t currentDriverInstanceID) noexcept;
[[nodiscard]] bool IsPermittedDeckCommand(DeckCommand command) noexcept;
[[nodiscard]] bool IsCatalogDeckCommand(DeckCommand command) noexcept;
[[nodiscard]] bool DeckCommandRequiresCapabilityProof(DeckCommand command) noexcept;
[[nodiscard]] bool CanAdmitDeckCommand(DeckCommand command,
                                       bool exactRouteProofAvailable) noexcept;
[[nodiscard]] bool MatchesConditionalDeckAuthorization(
    const ConditionalDeckAuthorization& authorization,
    const DeckControlRequestWire& request,
    uint64_t currentDriverInstanceID) noexcept;
[[nodiscard]] bool IsValidRequest(const DeckControlRequestWire& request) noexcept;
[[nodiscard]] std::array<uint8_t, kDeckCommandLength> CommandFrame(DeckCommand command) noexcept;
[[nodiscard]] bool IsExactPermittedFrame(std::span<const uint8_t> frame) noexcept;
[[nodiscard]] bool IsExactCatalogFrame(std::span<const uint8_t> frame) noexcept;
[[nodiscard]] DeckResponseClassification ClassifyDeckResponse(
    std::span<const uint8_t> command,
    std::span<const uint8_t> response) noexcept;
[[nodiscard]] bool IsCorrelatedDeckResponse(std::span<const uint8_t> command,
                                            std::span<const uint8_t> response) noexcept;
[[nodiscard]] FoundationCapabilitiesWire Capabilities() noexcept;
[[nodiscard]] TransportCapabilityCatalogWire TransportCapabilityCatalog() noexcept;
[[nodiscard]] bool IsValidTransportCapabilityProbeRequest(
    const TransportCapabilityProbeRequestWire& request) noexcept;
[[nodiscard]] std::array<uint8_t, kDeckCommandLength> TransportCapabilityInquiryFrame(
    DeckCommand command) noexcept;
[[nodiscard]] TransportCapabilityResponseClassification ClassifyTransportCapabilityResponse(
    DeckCommand command, std::span<const uint8_t> response) noexcept;
[[nodiscard]] bool ShouldInstallConditionalDeckAuthorization(
    const TransportCapabilityResultWire& result) noexcept;
[[nodiscard]] bool ShouldObserveTransportCapabilityEvidence(bool resultReady) noexcept;
[[nodiscard]] InspectorCapabilitiesWire InspectorCapabilities() noexcept;
[[nodiscard]] bool IsValidInspectorRequest(const InspectorRequestWire& request) noexcept;
[[nodiscard]] bool MayInspectorQueryOverlapReceive(InspectorQuery query) noexcept;
[[nodiscard]] std::array<uint8_t, kInspectorCommandLength> InspectorCommandFrame(
    InspectorQuery query, uint8_t subunitPage) noexcept;
[[nodiscard]] size_t InspectorCommandLength(InspectorQuery query) noexcept;
[[nodiscard]] InspectorResponseClassification ClassifyInspectorResponse(
    InspectorQuery query,
    uint8_t subunitPage,
    std::span<const uint8_t> response) noexcept;
[[nodiscard]] InspectorDecodedWire DecodeInspectorResponse(
    InspectorQuery query,
    uint8_t subunitPage,
    std::span<const uint8_t> response) noexcept;
// A ready result is immutable and may already be copied for consumption.
// terminalObserved alone is intentionally not a fence: response-before-write-
// return can still deliver synchronous attempt evidence before publication.
[[nodiscard]] bool ShouldObserveInspectorEvidence(bool resultReady) noexcept;

} // namespace RewindDV::Foundation::DriverPolicy
