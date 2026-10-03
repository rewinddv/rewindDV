// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
//
//  AVCHandler.cpp
//  ASFWDriver
//
//  Handler for AV/C Protocol API
//

#include "AVCHandler.hpp"
#include "../../Protocols/AVC/IAVCDiscovery.hpp"
#include "../../Protocols/AVC/AVCUnit.hpp"
#include "../../Protocols/AVC/Music/MusicSubunit.hpp"
#include "../../Protocols/AVC/Audio/AudioSubunit.hpp"
#include "../../Protocols/AVC/AVCDefs.hpp"
#include "../../Discovery/FWDevice.hpp"
#include "../../Logging/Logging.hpp"
#include "../../Shared/SharedDataModels.hpp"
#ifdef REWINDDV_FOUNDATION
#include "../../../Foundation/DriverPolicy/FoundationDriverPolicy.hpp"
#include "../../../Foundation/DriverPolicy/FoundationActivityGate.hpp"
#endif

#include <algorithm>
#include <array>
#include <cstring>
#include <optional>
#include <unordered_map>
#include <unordered_set>
#include <DriverKit/OSData.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/IOUserClient.h>

namespace ASFW::UserClient {

namespace {

using namespace ASFW::Shared;
constexpr size_t kMaxWireSize = 4096;  // DriverKit will drop larger structure outputs
using MusicSubunit = ASFW::Protocols::AVC::Music::MusicSubunit;
using MusicPlugInfo = MusicSubunit::PlugInfo;
using MusicPlugChannel = MusicSubunit::MusicPlugChannel;
using SubunitPtr = std::shared_ptr<ASFW::Protocols::AVC::Subunit>;

kern_return_t FCPStatusToIOReturn(ASFW::Protocols::AVC::FCPStatus status) {
    using ASFW::Protocols::AVC::FCPStatus;

    switch (status) {
        case FCPStatus::kOk:
            return kIOReturnSuccess;
        case FCPStatus::kTimeout:
            return kIOReturnTimeout;
        case FCPStatus::kBusReset:
            return kIOReturnAborted;
        case FCPStatus::kTransportError:
            return kIOReturnIOError;
        case FCPStatus::kInvalidPayload:
            return kIOReturnBadArgument;
        case FCPStatus::kResponseMismatch:
            return kIOReturnInvalid;
        case FCPStatus::kBusy:
            return kIOReturnBusy;
    }

    return kIOReturnError;
}

struct RawFCPResult {
    bool ready{false};
    kern_return_t status{kIOReturnNotReady};
    std::array<uint8_t, ASFW::Protocols::AVC::kAVCFrameMaxSize> response{};
    uint32_t responseLength{0};
};

struct RawFCPResultStore {
    IOLock* lock{IOLockAlloc()};
    uint64_t nextRequestID{1};
    std::unordered_map<uint64_t, RawFCPResult> results;
};

RawFCPResultStore& GetRawFCPResultStore() {
    static RawFCPResultStore store{};
    return store;
}

#ifdef REWINDDV_FOUNDATION
namespace FoundationPolicy = RewindDV::Foundation::DriverPolicy;

OSData* CastStructureInputToOSData(IOUserClientMethodArguments* args);

uint64_t FoundationMonotonicNowNs() noexcept {
#ifdef ASFW_HOST_TEST
    return ASFW::Testing::HostMonotonicNow();
#else
    static mach_timebase_info_data_t info{};
    if (info.denom == 0) {
        (void)mach_timebase_info(&info);
    }
    if (info.denom == 0) {
        return 0;
    }
    const __uint128_t nanos = static_cast<__uint128_t>(mach_absolute_time()) * info.numer;
    return static_cast<uint64_t>(nanos / info.denom);
#endif
}

struct FoundationTransportCapabilityRecord {
    FoundationPolicy::TransportCapabilityResultWire wire{};
    Discovery::DeviceRouteToken expectedRoute{};
    uint64_t activityToken{0};
    bool terminalObserved{false};
    bool submissionClosed{false};
    bool ready{false};
};

struct FoundationTransportCapabilityStore {
    static constexpr size_t kMaximumRetainedResults = 128;

    IOLock* lock{IOLockAlloc()};
    uint64_t nextRequestID{1};
    uint64_t activeRequestID{0};
    std::unordered_map<uint64_t, FoundationTransportCapabilityRecord> results;
    std::unordered_set<uint64_t> consumedAttemptIDs;
    std::unordered_map<uint32_t, FoundationPolicy::ConditionalDeckAuthorization>
        conditionalDeckProofs;
};

FoundationTransportCapabilityStore& GetFoundationTransportCapabilityStore() {
    static FoundationTransportCapabilityStore store{};
    return store;
}

void ReleaseFoundationTransportCapabilityActivity(
    FoundationTransportCapabilityRecord& record) noexcept {
    FoundationPolicy::ReleaseActivity(record.activityToken);
    record.activityToken = 0;
}

std::optional<FoundationPolicy::TransportCapabilityProbeRequestWire>
ParseFoundationTransportCapabilityProbeRequest(IOUserClientMethodArguments* args) {
    if (!args || args->scalarInputCount != 0 || !args->scalarOutput ||
        args->scalarOutputCount < 1 || !args->structureInput ||
        args->structureInputDescriptor) {
        return std::nullopt;
    }
    OSData* requestData = CastStructureInputToOSData(args);
    if (!requestData ||
        requestData->getLength() !=
            sizeof(FoundationPolicy::TransportCapabilityProbeRequestWire) ||
        !requestData->getBytesNoCopy()) {
        return std::nullopt;
    }
    FoundationPolicy::TransportCapabilityProbeRequestWire request{};
    std::memcpy(&request, requestData->getBytesNoCopy(), sizeof(request));
    if (!FoundationPolicy::IsValidTransportCapabilityProbeRequest(request)) {
        return std::nullopt;
    }
    return request;
}

bool HasFoundationConditionalDeckProof(
    const FoundationPolicy::DeckControlRequestWire& request,
    uint64_t currentDriverInstanceID) noexcept {
    const auto command = static_cast<FoundationPolicy::DeckCommand>(request.command);
    if (!FoundationPolicy::DeckCommandRequiresCapabilityProof(command)) {
        return FoundationPolicy::IsPermittedDeckCommand(command);
    }
    auto& store = GetFoundationTransportCapabilityStore();
    if (!store.lock) {
        return false;
    }
    IOLockLock(store.lock);
    const auto proof = store.conditionalDeckProofs.find(request.command);
    const bool matches = proof != store.conditionalDeckProofs.end() &&
                         FoundationPolicy::MatchesConditionalDeckAuthorization(
                             proof->second, request, currentDriverInstanceID);
    IOLockUnlock(store.lock);
    return matches;
}

kern_return_t ReserveFoundationTransportCapabilityProbe(
    FoundationTransportCapabilityStore& store,
    const FoundationPolicy::TransportCapabilityProbeRequestWire& request,
    uint64_t currentDriverInstanceID,
    uint64_t& requestID) {
    IOLockLock(store.lock);
    if (!FoundationPolicy::IsCurrentDriverInstance(request.driverInstanceID,
                                                   currentDriverInstanceID)) {
        IOLockUnlock(store.lock);
        return kIOReturnNotAttached;
    }
    const auto admission = FoundationPolicy::ClassifyAttemptAdmission(
        store.activeRequestID, store.consumedAttemptIDs.contains(request.attemptID),
        store.consumedAttemptIDs.size(), FoundationPolicy::kMaximumLifetimeAttempts);
    if (admission != FoundationPolicy::AttemptAdmission::kAdmit) {
        IOLockUnlock(store.lock);
        switch (admission) {
        case FoundationPolicy::AttemptAdmission::kBusy:
            return kIOReturnBusy;
        case FoundationPolicy::AttemptAdmission::kReplay:
            return kIOReturnUnsupported;
        case FoundationPolicy::AttemptAdmission::kLifetimeLimit:
            return kIOReturnNoResources;
        case FoundationPolicy::AttemptAdmission::kAdmit:
            break;
        }
    }
    if (!FoundationPolicy::HasResultStorageCapacity(
            store.results.size(),
            FoundationTransportCapabilityStore::kMaximumRetainedResults)) {
        IOLockUnlock(store.lock);
        return kIOReturnNoResources;
    }
    const uint64_t activityToken = FoundationPolicy::TryAcquireActivity(
        FoundationPolicy::ActivityKind::kInspector);
    if (!activityToken) {
        IOLockUnlock(store.lock);
        return kIOReturnBusy;
    }

    requestID = store.nextRequestID++;
    if (requestID == 0) {
        requestID = store.nextRequestID++;
    }
    const auto command = static_cast<FoundationPolicy::DeckCommand>(request.command);
    FoundationTransportCapabilityRecord record{};
    record.activityToken = activityToken;
    record.expectedRoute = Discovery::DeviceRouteToken{
        .guid = request.guid,
        .deviceIncarnation = request.deviceIncarnation,
        .routeEpoch = request.routeEpoch,
        .generation = FW::Generation{request.generation},
        .nodeId = request.nodeID,
    };
    auto& wire = record.wire;
    wire.requestID = requestID;
    wire.operationID = request.operationID;
    wire.attemptID = request.attemptID;
    wire.guid = request.guid;
    wire.driverInstanceID = currentDriverInstanceID;
    wire.command = request.command;
    wire.stageFlags = FoundationPolicy::kTransportCapabilityStageAdmitted;
    wire.terminalStatus = kIOReturnNotReady;
    wire.admittedTimestampNs = FoundationMonotonicNowNs();
    wire.requestLength = FoundationPolicy::kDeckCommandLength;
    wire.request = FoundationPolicy::TransportCapabilityInquiryFrame(command);
    if (FoundationPolicy::IsPermittedDeckCommand(command)) {
        wire.controlAuthorization = static_cast<uint32_t>(
            FoundationPolicy::TransportControlAuthorization::kBaseline);
    }

    // An explicit conditional-command reprobe revokes its prior route-bound proof at
    // admission. Only this attempt's fully published 0x0C result can reinstall it.
    if (FoundationPolicy::DeckCommandRequiresCapabilityProof(command)) {
        store.conditionalDeckProofs.erase(request.command);
    }
    store.consumedAttemptIDs.insert(request.attemptID);
    store.results.emplace(requestID, record);
    store.activeRequestID = requestID;
    IOLockUnlock(store.lock);
    return kIOReturnSuccess;
}

void ObserveFoundationTransportCapabilityAttempt(
    uint64_t requestID, const Protocols::AVC::FCPAttemptEvidence& evidence) {
    auto& store = GetFoundationTransportCapabilityStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() &&
        FoundationPolicy::ShouldObserveTransportCapabilityEvidence(
            result->second.ready)) {
        auto& record = result->second;
        auto& wire = record.wire;
        if (evidence.stage == Protocols::AVC::FCPAttemptStage::kRouteBound) {
            if (evidence.route != record.expectedRoute) {
                wire.terminalStatus = kIOReturnInvalid;
                wire.completedTimestampNs = FoundationMonotonicNowNs();
                wire.stageFlags |= FoundationPolicy::kTransportCapabilityStageCompleted;
                record.terminalObserved = true;
                record.ready = record.submissionClosed;
                if (record.ready) ReleaseFoundationTransportCapabilityActivity(record);
                IOLockUnlock(store.lock);
                return;
            }
            wire.guid = evidence.route.guid;
            wire.deviceIncarnation = evidence.route.deviceIncarnation;
            wire.routeEpoch = evidence.route.routeEpoch;
            wire.generation = evidence.route.generation.value;
            wire.nodeID = evidence.route.nodeId;
            if (wire.fcpAttemptID != 0 && wire.fcpAttemptID != evidence.attemptID &&
                wire.retryCount != UINT32_MAX) {
                ++wire.retryCount;
            }
            wire.fcpAttemptID = evidence.attemptID;
            wire.routeBoundTimestampNs = evidence.timestampNs;
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kBoundCurrentAtSubmission);
            wire.stageFlags |= FoundationPolicy::kTransportCapabilityStageRouteBound;
        } else if (evidence.stage ==
                   Protocols::AVC::FCPAttemptStage::kAsyncTransportAccepted) {
            wire.asyncTransportHandle = evidence.asyncHandle;
            wire.asyncTransportAcceptedTimestampNs = evidence.timestampNs;
            wire.stageFlags |=
                FoundationPolicy::kTransportCapabilityStageFCPTransportAccepted;
        }
    }
    IOLockUnlock(store.lock);
}

void ObserveFoundationTransportCapabilityResponse(
    uint64_t requestID, const Protocols::AVC::FCPResponseEvidence& evidence) {
    auto& store = GetFoundationTransportCapabilityStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() &&
        FoundationPolicy::ShouldObserveTransportCapabilityEvidence(
            result->second.ready)) {
        auto& wire = result->second.wire;
        using CapabilityClass =
            FoundationPolicy::TransportCapabilityResponseClassification;
        using FCPClass = Protocols::AVC::FCPResponseClassification;
        auto classification = FoundationPolicy::ClassifyTransportCapabilityResponse(
            static_cast<FoundationPolicy::DeckCommand>(wire.command),
            evidence.response.Payload());
        const bool transportAndPayloadAgree = [&] {
            switch (evidence.classification) {
            case FCPClass::kMismatch:
                return classification == CapabilityClass::kMismatch;
            case FCPClass::kAccepted:
                return classification == CapabilityClass::kImplemented;
            case FCPClass::kTerminalRejected:
                return classification == CapabilityClass::kNotImplemented;
            case FCPClass::kOtherTerminal:
                return classification == CapabilityClass::kUnexpectedTerminal;
            case FCPClass::kInterim:
                return false;
            }
            return false;
        }();
        if (evidence.classification == FCPClass::kMismatch ||
            !transportAndPayloadAgree) {
            classification = CapabilityClass::kMismatch;
        }

        wire.stageFlags |= FoundationPolicy::kTransportCapabilityStageResponseReceived;
        if (classification != CapabilityClass::kMismatch) {
            wire.stageFlags |= FoundationPolicy::kTransportCapabilityStageResponseCorrelated;
            wire.terminalClassification = static_cast<uint32_t>(classification);
        }
        if (classification == CapabilityClass::kImplemented) {
            wire.stageFlags |=
                FoundationPolicy::kTransportCapabilityStageTerminalImplemented;
            wire.supportState = static_cast<uint32_t>(
                FoundationPolicy::TransportCapabilitySupportState::kImplemented);
        } else if (classification == CapabilityClass::kNotImplemented) {
            wire.stageFlags |=
                FoundationPolicy::kTransportCapabilityStageTerminalNotImplemented;
            wire.supportState = static_cast<uint32_t>(
                FoundationPolicy::TransportCapabilitySupportState::kNotImplemented);
        }

        FoundationPolicy::TransportCapabilityResponseEventWire event{};
        event.timestampNs = evidence.timestampNs;
        event.fcpAttemptID = evidence.attemptID;
        event.generation = evidence.generation;
        event.sourceNodeID = evidence.sourceNodeID;
        event.classification = static_cast<uint32_t>(classification);
        event.length = static_cast<uint32_t>(evidence.response.length);
        if (evidence.response.length != 0) {
            std::memcpy(event.bytes.data(), evidence.response.data.data(),
                        evidence.response.length);
        }
        if (wire.responseEventCount < FoundationPolicy::kMaximumCapabilityResponseEvents) {
            wire.responseEvents[wire.responseEventCount++] = event;
        } else {
            if (wire.responseEventOverflow != UINT32_MAX) ++wire.responseEventOverflow;
            wire.responseEvents[FoundationPolicy::kMaximumCapabilityResponseEvents - 1] = event;
        }
    }
    IOLockUnlock(store.lock);
}

bool IsPublishableConditionalDeckProof(
    const FoundationTransportCapabilityRecord& record) noexcept;

void PublishConditionalDeckProofIfEligible(
    FoundationTransportCapabilityStore& store,
    FoundationTransportCapabilityRecord& record) noexcept;

void CompleteFoundationTransportCapability(
    uint64_t requestID, Protocols::AVC::FCPStatus status,
    const Protocols::AVC::FCPFrame&) {
    auto& store = GetFoundationTransportCapabilityStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() && !result->second.terminalObserved) {
        auto& record = result->second;
        auto& wire = record.wire;
        wire.terminalStatus = FCPStatusToIOReturn(status);
        wire.completedTimestampNs = FoundationMonotonicNowNs();
        wire.stageFlags |= FoundationPolicy::kTransportCapabilityStageCompleted;
        if (status == Protocols::AVC::FCPStatus::kBusReset) {
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kInvalidatedByObservedBusReset);
        }
        record.terminalObserved = true;
        record.ready = record.submissionClosed;
        if (record.ready) {
            PublishConditionalDeckProofIfEligible(store, record);
            ReleaseFoundationTransportCapabilityActivity(record);
        }
    }
    if (result != store.results.end() && result->second.submissionClosed &&
        store.activeRequestID == requestID) {
        store.activeRequestID = 0;
    }
    IOLockUnlock(store.lock);
}

bool IsPublishableConditionalDeckProof(
    const FoundationTransportCapabilityRecord& record) noexcept {
    const auto& wire = record.wire;
    return FoundationPolicy::ShouldInstallConditionalDeckAuthorization(wire) &&
           record.expectedRoute.guid == wire.guid &&
           record.expectedRoute.deviceIncarnation == wire.deviceIncarnation &&
           record.expectedRoute.routeEpoch == wire.routeEpoch &&
           record.expectedRoute.generation.value == wire.generation &&
           record.expectedRoute.nodeId == wire.nodeID;
}

void PublishConditionalDeckProofIfEligible(
    FoundationTransportCapabilityStore& store,
    FoundationTransportCapabilityRecord& record) noexcept {
    if (!IsPublishableConditionalDeckProof(record)) {
        return;
    }
    const auto command = static_cast<FoundationPolicy::DeckCommand>(record.wire.command);
    store.conditionalDeckProofs[record.wire.command] =
        FoundationPolicy::ConditionalDeckAuthorization{
        .driverInstanceID = record.wire.driverInstanceID,
        .guid = record.expectedRoute.guid,
        .deviceIncarnation = record.expectedRoute.deviceIncarnation,
        .routeEpoch = record.expectedRoute.routeEpoch,
        .generation = record.expectedRoute.generation.value,
        .nodeID = record.expectedRoute.nodeId,
        .reserved = 0,
        .command = static_cast<uint32_t>(command),
    };
    record.wire.controlAuthorization = static_cast<uint32_t>(
        FoundationPolicy::TransportControlAuthorization::kExactRouteSpecificInquiry);
    record.wire.stageFlags |= FoundationPolicy::
        kTransportCapabilityStageConditionalAuthorizationInstalled;
}

void CloseFoundationTransportCapabilitySubmission(uint64_t requestID) {
    auto& store = GetFoundationTransportCapabilityStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end()) {
        auto& record = result->second;
        record.submissionClosed = true;
        if (record.terminalObserved) {
            PublishConditionalDeckProofIfEligible(store, record);
        }
        record.ready = record.terminalObserved;
        if (record.ready) {
            if (store.activeRequestID == requestID) store.activeRequestID = 0;
            ReleaseFoundationTransportCapabilityActivity(record);
        }
    }
    IOLockUnlock(store.lock);
}

void FailFoundationTransportCapabilityIfPending(uint64_t requestID) {
    CompleteFoundationTransportCapability(
        requestID, Protocols::AVC::FCPStatus::kTransportError, {});
}

struct FoundationDeckControlRecord {
    FoundationPolicy::DeckControlResultWire wire{};
    uint64_t activityToken{0};
    bool terminalObserved{false};
    bool submissionClosed{false};
    bool ready{false};
};

void ReleaseFoundationDeckActivity(FoundationDeckControlRecord& record) noexcept {
    FoundationPolicy::ReleaseActivity(record.activityToken);
    record.activityToken = 0;
}

struct FoundationDeckControlStore {
    static constexpr size_t kMaximumRetainedResults = 256;

    IOLock* lock{IOLockAlloc()};
    uint64_t nextRequestID{1};
    uint64_t activeRequestID{0};
    std::unordered_map<uint64_t, FoundationDeckControlRecord> results;
    std::unordered_set<uint64_t> consumedAttemptIDs;
};

FoundationDeckControlStore& GetFoundationDeckControlStore() {
    static FoundationDeckControlStore store{};
    return store;
}

std::optional<FoundationPolicy::DeckControlRequestWire>
ParseFoundationDeckControlRequest(IOUserClientMethodArguments* args) {
    if (!args || !args->scalarOutput || args->scalarOutputCount < 1 || !args->structureInput) {
        return std::nullopt;
    }

    OSData* requestData = CastStructureInputToOSData(args);
    if (!requestData || requestData->getLength() != sizeof(FoundationPolicy::DeckControlRequestWire) ||
        !requestData->getBytesNoCopy()) {
        return std::nullopt;
    }

    FoundationPolicy::DeckControlRequestWire request{};
    std::memcpy(&request, requestData->getBytesNoCopy(), sizeof(request));
    if (!FoundationPolicy::IsValidRequest(request)) {
        return std::nullopt;
    }
    return request;
}

kern_return_t ReserveFoundationDeckControl(
    FoundationDeckControlStore& store,
    const FoundationPolicy::DeckControlRequestWire& request,
    uint64_t currentDriverInstanceID,
    bool conditionalProofAvailable,
    uint64_t& requestID) {
    IOLockLock(store.lock);

    if (!FoundationPolicy::IsCurrentDriverInstance(request.driverInstanceID,
                                                   currentDriverInstanceID)) {
        IOLockUnlock(store.lock);
        return kIOReturnNotAttached;
    }

    if (!FoundationPolicy::CanAdmitDeckCommand(
            static_cast<FoundationPolicy::DeckCommand>(request.command),
            conditionalProofAvailable)) {
        IOLockUnlock(store.lock);
        return kIOReturnUnsupported;
    }

    const auto admission = FoundationPolicy::ClassifyAttemptAdmission(
        store.activeRequestID,
        store.consumedAttemptIDs.contains(request.attemptID),
        store.consumedAttemptIDs.size(),
        FoundationPolicy::kMaximumLifetimeAttempts);
    if (admission != FoundationPolicy::AttemptAdmission::kAdmit) {
        IOLockUnlock(store.lock);
        switch (admission) {
        case FoundationPolicy::AttemptAdmission::kBusy:
            return kIOReturnBusy;
        case FoundationPolicy::AttemptAdmission::kReplay:
            return kIOReturnUnsupported;
        case FoundationPolicy::AttemptAdmission::kLifetimeLimit:
            return kIOReturnNoResources;
        case FoundationPolicy::AttemptAdmission::kAdmit:
            break;
        }
    }

    // Evidence is never evicted implicitly. The caller must explicitly consume
    // a result before another mutation can use its bounded storage slot.
    if (!FoundationPolicy::HasResultStorageCapacity(
            store.results.size(), FoundationDeckControlStore::kMaximumRetainedResults)) {
        IOLockUnlock(store.lock);
        return kIOReturnNoResources;
    }

    const uint64_t activityToken = FoundationPolicy::TryAcquireActivity(
        FoundationPolicy::ActivityKind::kDeckControl);
    if (!activityToken) {
        IOLockUnlock(store.lock);
        return kIOReturnBusy;
    }

    requestID = store.nextRequestID++;
    if (requestID == 0) {
        requestID = store.nextRequestID++;
    }

    FoundationDeckControlRecord record{};
    record.activityToken = activityToken;
    record.wire.requestID = requestID;
    record.wire.operationID = request.operationID;
    record.wire.attemptID = request.attemptID;
    record.wire.guid = request.guid;
    record.wire.driverInstanceID = currentDriverInstanceID;
    record.wire.command = request.command;
    record.wire.stageFlags = FoundationPolicy::kStageAdmitted;
    record.wire.terminalStatus = kIOReturnNotReady;
    record.wire.retryCount = 0;
    record.wire.admittedTimestampNs = FoundationMonotonicNowNs();
    record.wire.requestLength = FoundationPolicy::kDeckCommandLength;
    record.wire.request = FoundationPolicy::CommandFrame(
        static_cast<FoundationPolicy::DeckCommand>(request.command));

    store.consumedAttemptIDs.insert(request.attemptID);
    store.results.emplace(requestID, record);
    store.activeRequestID = requestID;
    IOLockUnlock(store.lock);
    return kIOReturnSuccess;
}

void ObserveFoundationFCPAttempt(
    uint64_t requestID,
    const Protocols::AVC::FCPAttemptEvidence& evidence) {
    auto& store = GetFoundationDeckControlStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end()) {
        auto& wire = result->second.wire;
        if (evidence.stage == Protocols::AVC::FCPAttemptStage::kRouteBound) {
            if (evidence.route.guid != wire.guid) {
                wire.terminalStatus = kIOReturnInvalid;
                wire.stageFlags |= FoundationPolicy::kStageCompleted;
                result->second.terminalObserved = true;
                result->second.ready = result->second.submissionClosed;
                if (result->second.ready) {
                    ReleaseFoundationDeckActivity(result->second);
                }
                IOLockUnlock(store.lock);
                return;
            }
            if (wire.fcpAttemptID != 0 && wire.fcpAttemptID != evidence.attemptID) {
                ++wire.retryCount;
            }
            wire.fcpAttemptID = evidence.attemptID;
            wire.deviceIncarnation = evidence.route.deviceIncarnation;
            wire.routeEpoch = evidence.route.routeEpoch;
            wire.generation = evidence.route.generation.value;
            wire.nodeID = evidence.route.nodeId;
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kBoundCurrentAtSubmission);
            wire.routeBoundTimestampNs = evidence.timestampNs;
        } else if (evidence.stage == Protocols::AVC::FCPAttemptStage::kAsyncTransportAccepted) {
            wire.stageFlags |= FoundationPolicy::kStageFCPTransportAccepted;
            wire.asyncTransportHandle = evidence.asyncHandle;
            wire.asyncTransportAcceptedTimestampNs = evidence.timestampNs;
        }
    }
    IOLockUnlock(store.lock);
}

FoundationPolicy::DeckResponseClassification ToFoundationClassification(
    Protocols::AVC::FCPResponseClassification classification,
    std::span<const uint8_t> response) noexcept {
    using FCPClass = Protocols::AVC::FCPResponseClassification;
    switch (classification) {
    case FCPClass::kMismatch:
        return FoundationPolicy::DeckResponseClassification::kMismatch;
    case FCPClass::kInterim:
        return FoundationPolicy::DeckResponseClassification::kInterim;
    case FCPClass::kAccepted:
        return FoundationPolicy::DeckResponseClassification::kAccepted;
    case FCPClass::kTerminalRejected:
        if (!response.empty() && response[0] == 0x08) {
            return FoundationPolicy::DeckResponseClassification::kNotImplemented;
        }
        return FoundationPolicy::DeckResponseClassification::kRejected;
    case FCPClass::kOtherTerminal:
        return FoundationPolicy::DeckResponseClassification::kOtherTerminal;
    }
    return FoundationPolicy::DeckResponseClassification::kUnknown;
}

void ObserveFoundationFCPResponse(
    uint64_t requestID,
    const Protocols::AVC::FCPResponseEvidence& evidence) {
    auto& store = GetFoundationDeckControlStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end()) {
        auto& wire = result->second.wire;
        wire.stageFlags |= FoundationPolicy::kStageResponseReceived;
        if (evidence.classification != Protocols::AVC::FCPResponseClassification::kMismatch) {
            wire.stageFlags |= FoundationPolicy::kStageResponseCorrelated;
        }
        if (evidence.classification == Protocols::AVC::FCPResponseClassification::kAccepted) {
            wire.stageFlags |= FoundationPolicy::kStageTerminalAccepted;
        } else if (evidence.classification ==
                   Protocols::AVC::FCPResponseClassification::kTerminalRejected ||
                   evidence.classification ==
                       Protocols::AVC::FCPResponseClassification::kOtherTerminal) {
            wire.stageFlags |= FoundationPolicy::kStageTerminalRejected;
        }

        FoundationPolicy::DeckResponseEventWire event{};
        event.timestampNs = evidence.timestampNs;
        event.fcpAttemptID = evidence.attemptID;
        event.generation = evidence.generation;
        event.sourceNodeID = evidence.sourceNodeID;
        event.classification = static_cast<uint32_t>(
            ToFoundationClassification(evidence.classification, evidence.response.Payload()));
        event.length = static_cast<uint32_t>(evidence.response.length);
        if (evidence.response.length != 0) {
            std::memcpy(event.bytes.data(), evidence.response.data.data(), evidence.response.length);
        }

        if (wire.responseEventCount < FoundationPolicy::kMaximumResponseEvents) {
            wire.responseEvents[wire.responseEventCount++] = event;
        } else {
            if (wire.responseEventOverflow != UINT32_MAX) {
                ++wire.responseEventOverflow;
            }
            // Preserve the first three observations and the latest terminal or
            // mismatch event. The overflow counter makes this loss explicit.
            wire.responseEvents[FoundationPolicy::kMaximumResponseEvents - 1] = event;
        }
    }
    IOLockUnlock(store.lock);
}

void CompleteFoundationDeckControl(uint64_t requestID,
                                   Protocols::AVC::FCPStatus status,
                                   const Protocols::AVC::FCPFrame& response) {
    (void)response;
    auto& store = GetFoundationDeckControlStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() && !result->second.terminalObserved) {
        auto& wire = result->second.wire;
        wire.terminalStatus = FCPStatusToIOReturn(status);
        if (status == Protocols::AVC::FCPStatus::kBusReset) {
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kInvalidatedByObservedBusReset);
        }
        wire.stageFlags |= FoundationPolicy::kStageCompleted;
        result->second.terminalObserved = true;
        result->second.ready = result->second.submissionClosed;
        if (result->second.ready) {
            ReleaseFoundationDeckActivity(result->second);
        }
    }
    if (store.activeRequestID == requestID && result != store.results.end() &&
        result->second.submissionClosed) {
        store.activeRequestID = 0;
    }
    IOLockUnlock(store.lock);
}

void CloseFoundationDeckControlSubmission(uint64_t requestID) {
    auto& store = GetFoundationDeckControlStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end()) {
        result->second.submissionClosed = true;
        result->second.ready = result->second.terminalObserved;
        if (result->second.terminalObserved && store.activeRequestID == requestID) {
            store.activeRequestID = 0;
        }
        if (result->second.ready) {
            ReleaseFoundationDeckActivity(result->second);
        }
    }
    IOLockUnlock(store.lock);
}

void FailFoundationDeckControlIfPending(uint64_t requestID) {
    CompleteFoundationDeckControl(requestID, Protocols::AVC::FCPStatus::kTransportError, {});
}

struct FoundationInspectorRecord {
    FoundationPolicy::InspectorResultWire wire{};
    Discovery::DeviceRouteToken expectedRoute{};
    uint64_t activityToken{0};
    bool terminalObserved{false};
    bool submissionClosed{false};
    bool ready{false};
};

struct FoundationInspectorStore {
    static constexpr size_t kMaximumRetainedResults = 128;

    IOLock* lock{IOLockAlloc()};
    uint64_t nextRequestID{1};
    uint64_t activeRequestID{0};
    uint64_t inspectorAttemptHighWater{0};
    std::unordered_map<uint64_t, FoundationInspectorRecord> results;
};

FoundationInspectorStore& GetFoundationInspectorStore() {
    static FoundationInspectorStore store{};
    return store;
}

void ReleaseFoundationInspectorActivity(FoundationInspectorRecord& record) noexcept {
    FoundationPolicy::ReleaseActivity(record.activityToken);
    record.activityToken = 0;
}

std::optional<FoundationPolicy::InspectorRequestWire>
ParseFoundationInspectorRequest(IOUserClientMethodArguments* args) {
    if (!args || args->scalarInputCount != 0 || !args->scalarOutput ||
        args->scalarOutputCount < 1 || !args->structureInput ||
        args->structureInputDescriptor) {
        return std::nullopt;
    }
    OSData* requestData = CastStructureInputToOSData(args);
    if (!requestData ||
        requestData->getLength() != sizeof(FoundationPolicy::InspectorRequestWire) ||
        !requestData->getBytesNoCopy()) {
        return std::nullopt;
    }
    FoundationPolicy::InspectorRequestWire request{};
    std::memcpy(&request, requestData->getBytesNoCopy(), sizeof(request));
    if (!FoundationPolicy::IsValidInspectorRequest(request)) {
        return std::nullopt;
    }
    return request;
}

kern_return_t ReserveFoundationInspector(
    FoundationInspectorStore& store,
    const FoundationPolicy::InspectorRequestWire& request,
    uint64_t currentDriverInstanceID,
    uint64_t& requestID) {
    IOLockLock(store.lock);
    if (!FoundationPolicy::IsCurrentDriverInstance(request.driverInstanceID,
                                                   currentDriverInstanceID)) {
        IOLockUnlock(store.lock);
        return kIOReturnNotAttached;
    }
    const auto query = static_cast<FoundationPolicy::InspectorQuery>(request.query);
    const bool isLiveTapeTransportState =
        FoundationPolicy::MayInspectorQueryOverlapReceive(query);
    const auto admission = FoundationPolicy::ClassifyMonotonicInspectorAttemptAdmission(
        store.activeRequestID, request.attemptID, store.inspectorAttemptHighWater);
    if (admission != FoundationPolicy::AttemptAdmission::kAdmit) {
        IOLockUnlock(store.lock);
        switch (admission) {
        case FoundationPolicy::AttemptAdmission::kBusy:
            return kIOReturnBusy;
        case FoundationPolicy::AttemptAdmission::kReplay:
            return kIOReturnUnsupported;
        case FoundationPolicy::AttemptAdmission::kLifetimeLimit:
            return kIOReturnNoResources;
        case FoundationPolicy::AttemptAdmission::kAdmit:
            break;
        }
    }
    if (!FoundationPolicy::HasResultStorageCapacity(
            store.results.size(), FoundationInspectorStore::kMaximumRetainedResults)) {
        IOLockUnlock(store.lock);
        return kIOReturnNoResources;
    }
    const auto activityKind = isLiveTapeTransportState
                                  ? FoundationPolicy::ActivityKind::kLiveTapeTransportStateInspector
                                  : FoundationPolicy::ActivityKind::kInspector;
    const uint64_t activityToken = FoundationPolicy::TryAcquireActivity(activityKind);
    if (!activityToken) {
        IOLockUnlock(store.lock);
        return kIOReturnBusy;
    }

    requestID = store.nextRequestID++;
    if (requestID == 0) {
        requestID = store.nextRequestID++;
    }
    FoundationInspectorRecord record{};
    record.activityToken = activityToken;
    record.expectedRoute = Discovery::DeviceRouteToken{
        .guid = request.guid,
        .deviceIncarnation = request.deviceIncarnation,
        .routeEpoch = request.routeEpoch,
        .generation = FW::Generation{request.generation},
        .nodeId = request.nodeID,
    };
    auto& wire = record.wire;
    wire.requestID = requestID;
    wire.operationID = request.operationID;
    wire.attemptID = request.attemptID;
    wire.guid = request.guid;
    wire.driverInstanceID = currentDriverInstanceID;
    wire.query = request.query;
    wire.subunitPage = request.subunitPage;
    wire.stageFlags = FoundationPolicy::kInspectorStageAdmitted;
    wire.terminalStatus = kIOReturnNotReady;
    wire.admittedTimestampNs = FoundationMonotonicNowNs();
    wire.requestLength = FoundationPolicy::InspectorCommandLength(
        static_cast<FoundationPolicy::InspectorQuery>(request.query));
    wire.request = FoundationPolicy::InspectorCommandFrame(
        static_cast<FoundationPolicy::InspectorQuery>(request.query), request.subunitPage);

    const auto [storedResult, inserted] = store.results.emplace(requestID, record);
    (void)storedResult;
    if (!inserted) {
        FoundationPolicy::ReleaseActivity(activityToken);
        IOLockUnlock(store.lock);
        return kIOReturnNoResources;
    }
    // Consume the shared inspector replay identity only after every admission
    // check and owned-result reservation succeeds. Holding store.lock makes
    // lower concurrent IDs wait, observe this high-water mark, and fail closed.
    store.inspectorAttemptHighWater = request.attemptID;
    store.activeRequestID = requestID;
    IOLockUnlock(store.lock);
    return kIOReturnSuccess;
}

bool InspectorRouteMatches(const Discovery::DeviceRouteToken& expected,
                           const Discovery::DeviceRouteToken& route) noexcept {
    return route == expected;
}

void ObserveFoundationInspectorAttempt(
    uint64_t requestID, const Protocols::AVC::FCPAttemptEvidence& evidence) {
    auto& store = GetFoundationInspectorStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() &&
        FoundationPolicy::ShouldObserveInspectorEvidence(result->second.ready)) {
        auto& record = result->second;
        auto& wire = record.wire;
        if (evidence.stage == Protocols::AVC::FCPAttemptStage::kRouteBound) {
            if (!InspectorRouteMatches(record.expectedRoute, evidence.route)) {
                wire.terminalStatus = kIOReturnInvalid;
                wire.completedTimestampNs = FoundationMonotonicNowNs();
                wire.stageFlags |= FoundationPolicy::kInspectorStageCompleted;
                record.terminalObserved = true;
                record.ready = record.submissionClosed;
                if (record.ready) ReleaseFoundationInspectorActivity(record);
                IOLockUnlock(store.lock);
                return;
            }
            wire.guid = evidence.route.guid;
            wire.deviceIncarnation = evidence.route.deviceIncarnation;
            wire.routeEpoch = evidence.route.routeEpoch;
            wire.generation = evidence.route.generation.value;
            wire.nodeID = evidence.route.nodeId;
            if (wire.fcpAttemptID != 0 && wire.fcpAttemptID != evidence.attemptID &&
                wire.retryCount != UINT32_MAX) {
                ++wire.retryCount;
            }
            wire.fcpAttemptID = evidence.attemptID;
            wire.routeBoundTimestampNs = evidence.timestampNs;
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kBoundCurrentAtSubmission);
            wire.stageFlags |= FoundationPolicy::kInspectorStageRouteBound;
        } else if (evidence.stage ==
                   Protocols::AVC::FCPAttemptStage::kAsyncTransportAccepted) {
            wire.asyncTransportHandle = evidence.asyncHandle;
            wire.asyncTransportAcceptedTimestampNs = evidence.timestampNs;
            wire.stageFlags |= FoundationPolicy::kInspectorStageFCPTransportAccepted;
        }
    }
    IOLockUnlock(store.lock);
}

void ObserveFoundationInspectorResponse(
    uint64_t requestID, const Protocols::AVC::FCPResponseEvidence& evidence) {
    auto& store = GetFoundationInspectorStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() &&
        FoundationPolicy::ShouldObserveInspectorEvidence(result->second.ready)) {
        auto& wire = result->second.wire;
        auto classification = FoundationPolicy::ClassifyInspectorResponse(
            static_cast<FoundationPolicy::InspectorQuery>(wire.query), wire.subunitPage,
            evidence.response.Payload());
        // Source node/generation correlation belongs to FCPTransport and is
        // not recoverable from the raw AV/C bytes. Its mismatch verdict is
        // authoritative even when the payload itself is well formed.
        using FCPClass = Protocols::AVC::FCPResponseClassification;
        using InspectorClass = FoundationPolicy::InspectorResponseClassification;
        const bool transportAndPayloadAgree = [&] {
            switch (evidence.classification) {
            case FCPClass::kMismatch:
                return classification == InspectorClass::kMismatch;
            case FCPClass::kInterim:
                return classification == InspectorClass::kInterim;
            case FCPClass::kAccepted:
                return classification == InspectorClass::kImplementedStable;
            case FCPClass::kTerminalRejected:
                return classification == InspectorClass::kRejected ||
                       classification == InspectorClass::kNotImplemented;
            case FCPClass::kOtherTerminal:
                return classification == InspectorClass::kAcceptedInvalidForStatus ||
                       classification == InspectorClass::kInTransitionInvalidForQuery ||
                       classification == InspectorClass::kChangedInvalidForStatus ||
                       classification == InspectorClass::kOtherTerminal;
            }
            return false;
        }();
        if (evidence.classification == FCPClass::kMismatch || !transportAndPayloadAgree) {
            classification = InspectorClass::kMismatch;
        }
        wire.stageFlags |= FoundationPolicy::kInspectorStageResponseReceived;
        if (classification != FoundationPolicy::InspectorResponseClassification::kMismatch) {
            wire.stageFlags |= FoundationPolicy::kInspectorStageResponseCorrelated;
        }
        if (classification ==
            FoundationPolicy::InspectorResponseClassification::kImplementedStable) {
            wire.stageFlags |= FoundationPolicy::kInspectorStageTerminalImplementedStable;
            wire.terminalClassification = static_cast<uint32_t>(classification);
            wire.decoded = FoundationPolicy::DecodeInspectorResponse(
                static_cast<FoundationPolicy::InspectorQuery>(wire.query), wire.subunitPage,
                evidence.response.Payload());
        } else if (classification != FoundationPolicy::InspectorResponseClassification::kMismatch &&
                   classification != FoundationPolicy::InspectorResponseClassification::kInterim) {
            wire.stageFlags |= FoundationPolicy::kInspectorStageTerminalRejected;
            wire.terminalClassification = static_cast<uint32_t>(classification);
        }

        FoundationPolicy::InspectorResponseEventWire event{};
        event.timestampNs = evidence.timestampNs;
        event.fcpAttemptID = evidence.attemptID;
        event.generation = evidence.generation;
        event.sourceNodeID = evidence.sourceNodeID;
        event.classification = static_cast<uint32_t>(classification);
        event.length = static_cast<uint32_t>(evidence.response.length);
        if (evidence.response.length != 0) {
            std::memcpy(event.bytes.data(), evidence.response.data.data(), evidence.response.length);
        }
        if (wire.responseEventCount < FoundationPolicy::kMaximumInspectorResponseEvents) {
            wire.responseEvents[wire.responseEventCount++] = event;
        } else {
            if (wire.responseEventOverflow != UINT32_MAX) ++wire.responseEventOverflow;
            // Preserve the first observation and reserve the final slot for
            // the latest event, including terminal truth.
            wire.responseEvents[FoundationPolicy::kMaximumInspectorResponseEvents - 1] = event;
        }
    }
    IOLockUnlock(store.lock);
}

void CompleteFoundationInspector(uint64_t requestID,
                                 Protocols::AVC::FCPStatus status,
                                 const Protocols::AVC::FCPFrame&) {
    auto& store = GetFoundationInspectorStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() && !result->second.terminalObserved) {
        auto& record = result->second;
        auto& wire = record.wire;
        wire.terminalStatus = FCPStatusToIOReturn(status);
        wire.completedTimestampNs = FoundationMonotonicNowNs();
        wire.stageFlags |= FoundationPolicy::kInspectorStageCompleted;
        if (status == Protocols::AVC::FCPStatus::kBusReset) {
            wire.routeState = static_cast<uint32_t>(
                FoundationPolicy::RouteEvidenceState::kInvalidatedByObservedBusReset);
        }
        record.terminalObserved = true;
        record.ready = record.submissionClosed;
        if (record.ready) ReleaseFoundationInspectorActivity(record);
    }
    if (result != store.results.end() && result->second.submissionClosed &&
        store.activeRequestID == requestID) {
        store.activeRequestID = 0;
    }
    IOLockUnlock(store.lock);
}

void CloseFoundationInspectorSubmission(uint64_t requestID) {
    auto& store = GetFoundationInspectorStore();
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end()) {
        auto& record = result->second;
        record.submissionClosed = true;
        record.ready = record.terminalObserved;
        if (record.ready) {
            if (store.activeRequestID == requestID) store.activeRequestID = 0;
            ReleaseFoundationInspectorActivity(record);
        }
    }
    IOLockUnlock(store.lock);
}

void FailFoundationInspectorIfPending(uint64_t requestID) {
    CompleteFoundationInspector(requestID, Protocols::AVC::FCPStatus::kTransportError, {});
}
#endif

#ifdef ASFW_HOST_TEST
OSData* CastStructureInputToOSData(IOUserClientMethodArguments* args) {
    return static_cast<OSData*>(args->structureInput);
}
#else
OSData* CastStructureInputToOSData(IOUserClientMethodArguments* args) {
    return OSDynamicCast(OSData, args->structureInput);
}
#endif

struct SubunitLookupRequest {
    uint64_t guid{0};
    uint8_t type{0};
    uint8_t id{0};
};

struct RawFCPSubmissionRequest {
    uint64_t guid{0};
    OSData* commandData{nullptr};
    size_t commandLength{0};
};

struct PlugSerializeInfo {
    size_t plugSize{sizeof(PlugInfoWire)};
    uint8_t numBlocks{0};
    std::vector<uint8_t> channelCounts;
    uint8_t numSupportedFormats{0};
};

struct MusicRateSummary {
    uint8_t currentRate{0xFF};
    uint32_t supportedMask{0};
};

struct MusicSerializationPlan {
    MusicRateSummary rates{};
    size_t totalSize{sizeof(AVCMusicCapabilitiesWire)};
    size_t numPlugsToSerialize{0};
    std::vector<PlugSerializeInfo> plugInfos;
};

bool IsMusicSubunitType(ASFW::Protocols::AVC::AVCSubunitType type) noexcept {
    using ASFW::Protocols::AVC::AVCSubunitType;
    return type == AVCSubunitType::kMusic || type == AVCSubunitType::kMusic0C;
}

std::optional<SubunitLookupRequest>
ParseSubunitLookupRequest(IOUserClientMethodArguments* args, const char* operation) {
    if (!args) {
        ASFW_LOG(UserClient, "%{public}s: null arguments", operation);
        return std::nullopt;
    }
    if (args->scalarInputCount < 4) {
        ASFW_LOG(UserClient, "%{public}s: missing inputs", operation);
        return std::nullopt;
    }

    return SubunitLookupRequest{
        .guid = (static_cast<uint64_t>(args->scalarInput[0]) << 32) | args->scalarInput[1],
        .type = static_cast<uint8_t>(args->scalarInput[2]),
        .id = static_cast<uint8_t>(args->scalarInput[3]),
    };
}

SubunitPtr FindRequestedSubunit(Protocols::AVC::IAVCDiscovery& discovery,
                                const SubunitLookupRequest& request) {
    const auto allUnits = discovery.AcquireAllAVCUnits();
    for (const auto& unit : allUnits) {
        if (!unit) {
            continue;
        }

        auto device = unit->GetDevice();
        if (!device || device->GetGUID() != request.guid) {
            continue;
        }

        for (const auto& subunit : unit->GetSubunits()) {
            if (!subunit) {
                continue;
            }
            if (static_cast<uint8_t>(subunit->GetType()) == request.type &&
                subunit->GetID() == request.id) {
                return subunit;
            }
        }
    }

    return {};
}

MusicRateSummary CollectMusicRateSummary(const std::vector<MusicPlugInfo>& plugs) {
    using SampleRate = ASFW::Protocols::AVC::StreamFormats::SampleRate;

    MusicRateSummary summary{};
    for (const auto& plug : plugs) {
        if (plug.currentFormat && plug.currentFormat->sampleRate != SampleRate::kUnknown &&
            summary.currentRate == 0xFF) {
            summary.currentRate = static_cast<uint8_t>(plug.currentFormat->sampleRate);
        }

        for (const auto& fmt : plug.supportedFormats) {
            if (fmt.sampleRate == SampleRate::kUnknown) {
                continue;
            }
            const uint8_t rate = static_cast<uint8_t>(fmt.sampleRate);
            if (rate < 32) {
                summary.supportedMask |= (1u << rate);
            }
        }
    }

    return summary;
}

PlugSerializeInfo BuildPlugSerializeInfo(const MusicPlugInfo& plug) {
    PlugSerializeInfo info{};

    if (plug.currentFormat) {
        if (plug.currentFormat->IsCompound()) {
            info.numBlocks = static_cast<uint8_t>(
                std::min(plug.currentFormat->channelFormats.size(), size_t(255)));
            for (size_t b = 0; b < info.numBlocks; ++b) {
                const auto& block = plug.currentFormat->channelFormats[b];
                const uint8_t numChannelDetails = static_cast<uint8_t>(
                    std::min(block.channels.size(), size_t(255)));
                info.channelCounts.push_back(numChannelDetails);
                info.plugSize += sizeof(SignalBlockWire) +
                    numChannelDetails * sizeof(ChannelDetailWire);
            }
        } else if (plug.currentFormat->totalChannels > 0) {
            info.numBlocks = 1;
            info.channelCounts.push_back(0);
            info.plugSize += sizeof(SignalBlockWire);
        }
    }

    info.numSupportedFormats = static_cast<uint8_t>(
        std::min(plug.supportedFormats.size(), size_t(32)));
    info.plugSize += info.numSupportedFormats * sizeof(SupportedFormatWire);
    return info;
}

MusicSerializationPlan BuildMusicSerializationPlan(const std::vector<MusicPlugInfo>& plugs) {
    MusicSerializationPlan plan{};
    plan.rates = CollectMusicRateSummary(plugs);
    plan.plugInfos.reserve(plugs.size());

    for (const auto& plug : plugs) {
        const auto info = BuildPlugSerializeInfo(plug);
        if (plan.totalSize + info.plugSize > kMaxWireSize) {
            break;
        }

        plan.totalSize += info.plugSize;
        plan.plugInfos.push_back(info);
        ++plan.numPlugsToSerialize;
    }

    return plan;
}

std::unordered_map<uint16_t, std::string>
BuildChannelNameLookup(const std::vector<MusicPlugChannel>& channels) {
    std::unordered_map<uint16_t, std::string> lookup;
    for (const auto& channel : channels) {
        lookup[channel.musicPlugID] = channel.name;
    }
    return lookup;
}

std::string ResolveChannelName(
    const std::string& channelName,
    uint16_t musicPlugID,
    const std::unordered_map<uint16_t, std::string>& channelNameLookup) {
    if (!channelName.empty()) {
        return channelName;
    }

    const auto it = channelNameLookup.find(musicPlugID);
    if (it != channelNameLookup.end()) {
        return it->second;
    }

    return {};
}

bool AppendMusicCapabilitiesHeader(
    OSData* data,
    const ASFW::Protocols::AVC::Music::MusicSubunitCapabilities& caps,
    const MusicSerializationPlan& plan) {
    AVCMusicCapabilitiesWire wire{};
    wire.hasAudio = caps.hasAudioCapability ? 1 : 0;
    wire.hasMIDI = caps.hasMidiCapability ? 1 : 0;
    wire.hasSMPTE = caps.hasSmpteTimeCodeCapability ? 1 : 0;
    wire.audioInputPorts = caps.maxAudioInputChannels.value_or(0);
    wire.audioOutputPorts = caps.maxAudioOutputChannels.value_or(0);
    wire.midiInputPorts = caps.maxMidiInputPorts.value_or(0);
    wire.midiOutputPorts = caps.maxMidiOutputPorts.value_or(0);
    wire.smpteInputPorts = 0;
    wire.smpteOutputPorts = 0;
    wire.currentRate = plan.rates.currentRate;
    wire.supportedRatesMask = plan.rates.supportedMask;
    wire.numPlugs = static_cast<uint8_t>(plan.numPlugsToSerialize);
    wire._reserved = 0;
    return data->appendBytes(&wire, sizeof(wire));
}

bool AppendCompoundSignalBlocks(
    OSData* data,
    const MusicPlugInfo& plug,
    const PlugSerializeInfo& info,
    const std::unordered_map<uint16_t, std::string>& channelNameLookup) {
    for (size_t b = 0; b < info.numBlocks; ++b) {
        if (b >= plug.currentFormat->channelFormats.size()) {
            break;
        }

        const auto& block = plug.currentFormat->channelFormats[b];
        const uint8_t numChannelDetails =
            (b < info.channelCounts.size()) ? info.channelCounts[b] : 0;

        SignalBlockWire blockWire{};
        blockWire.formatCode = static_cast<uint8_t>(block.formatCode);
        blockWire.channelCount = block.channelCount;
        blockWire.numChannelDetails = numChannelDetails;
        blockWire._padding = 0;
        if (!data->appendBytes(&blockWire, sizeof(blockWire))) {
            return false;
        }

        for (size_t c = 0; c < blockWire.numChannelDetails; ++c) {
            if (c >= block.channels.size()) {
                break;
            }

            const auto& channel = block.channels[c];
            ChannelDetailWire channelWire{};
            channelWire.musicPlugID = channel.musicPlugID;
            channelWire.position = channel.position;
            const std::string channelName =
                ResolveChannelName(channel.name, channel.musicPlugID, channelNameLookup);

            const size_t nameCopyLen = std::min(channelName.length(), sizeof(channelWire.name) - 1);
            std::memcpy(channelWire.name, channelName.c_str(), nameCopyLen);
            channelWire.name[nameCopyLen] = '\0';
            channelWire.nameLength = static_cast<uint8_t>(nameCopyLen);
            if (!data->appendBytes(&channelWire, sizeof(channelWire))) {
                return false;
            }
        }
    }

    return true;
}

bool AppendSignalBlocks(OSData* data,
                        const MusicPlugInfo& plug,
                        const PlugSerializeInfo& info,
                        const std::unordered_map<uint16_t, std::string>& channelNameLookup) {
    if (info.numBlocks == 0 || !plug.currentFormat) {
        return true;
    }

    if (plug.currentFormat->IsCompound()) {
        return AppendCompoundSignalBlocks(data, plug, info, channelNameLookup);
    }

    SignalBlockWire blockWire{};
    blockWire.formatCode = 0x06;
    blockWire.channelCount = plug.currentFormat->totalChannels;
    blockWire.numChannelDetails = 0;
    blockWire._padding = 0;
    return data->appendBytes(&blockWire, sizeof(blockWire));
}

bool AppendSupportedFormats(OSData* data,
                            const MusicPlugInfo& plug,
                            uint8_t numSupportedFormats) {
    using StreamFormatCode = ASFW::Protocols::AVC::StreamFormats::StreamFormatCode;

    for (size_t s = 0; s < numSupportedFormats; ++s) {
        if (s >= plug.supportedFormats.size()) {
            break;
        }

        const auto& fmt = plug.supportedFormats[s];
        SupportedFormatWire formatWire{};
        formatWire.sampleRateCode = static_cast<uint8_t>(fmt.sampleRate);
        formatWire.formatCode = static_cast<uint8_t>(
            fmt.channelFormats.empty() ? StreamFormatCode::kMBLA : fmt.channelFormats[0].formatCode);
        formatWire.channelCount = fmt.totalChannels;
        formatWire._padding = 0;
        if (!data->appendBytes(&formatWire, sizeof(formatWire))) {
            return false;
        }
    }

    return true;
}

bool AppendMusicPlug(OSData* data,
                     const MusicPlugInfo& plug,
                     const PlugSerializeInfo& info,
                     const std::unordered_map<uint16_t, std::string>& channelNameLookup) {
    PlugInfoWire plugWire{};
    plugWire.plugID = plug.plugID;
    plugWire.isInput = plug.IsInput() ? 1 : 0;
    plugWire.type = static_cast<uint8_t>(plug.type);
    plugWire.numSignalBlocks = info.numBlocks;
    plugWire.numSupportedFormats = info.numSupportedFormats;

    const size_t copyLen = std::min(plug.name.length(), sizeof(plugWire.name) - 1);
    std::memcpy(plugWire.name, plug.name.c_str(), copyLen);
    plugWire.name[copyLen] = '\0';
    plugWire.nameLength = static_cast<uint8_t>(copyLen);
    if (!data->appendBytes(&plugWire, sizeof(plugWire))) {
        return false;
    }

    if (!AppendSignalBlocks(data, plug, info, channelNameLookup)) {
        return false;
    }

    return AppendSupportedFormats(data, plug, info.numSupportedFormats);
}

std::optional<RawFCPSubmissionRequest>
ParseRawFCPSubmissionRequest(IOUserClientMethodArguments* args) {
    if (!args) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: null arguments");
        return std::nullopt;
    }
    if (!args->scalarInput || args->scalarInputCount < 2) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: missing scalar inputs");
        return std::nullopt;
    }
    if (!args->scalarOutput || args->scalarOutputCount < 1) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: missing scalar output buffer");
        return std::nullopt;
    }
    if (!args->structureInput) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: missing command payload");
        return std::nullopt;
    }

    OSData* commandData = CastStructureInputToOSData(args);
    if (!commandData) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: structureInput is not OSData");
        return std::nullopt;
    }

    const size_t commandLength = static_cast<size_t>(commandData->getLength());
    if (commandLength < ASFW::Protocols::AVC::kAVCFrameMinSize ||
        commandLength > ASFW::Protocols::AVC::kAVCFrameMaxSize) {
        ASFW_LOG(UserClient,
                 "SendRawFCPCommand: invalid payload size=%llu",
                 static_cast<unsigned long long>(commandLength));
        return std::nullopt;
    }

    return RawFCPSubmissionRequest{
        .guid = (static_cast<uint64_t>(args->scalarInput[0]) << 32) | args->scalarInput[1],
        .commandData = commandData,
        .commandLength = commandLength,
    };
}

uint64_t ReserveRawFCPRequestSlot(RawFCPResultStore& store) {
    IOLockLock(store.lock);
    if (store.results.size() > 256) {
        for (auto it = store.results.begin(); it != store.results.end();) {
            if (it->second.ready) {
                it = store.results.erase(it);
            } else {
                ++it;
            }
        }
    }

    const uint64_t requestID = store.nextRequestID++;
    store.results.emplace(requestID, RawFCPResult{});
    IOLockUnlock(store.lock);
    return requestID;
}

void StoreRawFCPCompletion(uint64_t requestID,
                           Protocols::AVC::FCPStatus status,
                           const Protocols::AVC::FCPFrame& response) {
    auto& resultStore = GetRawFCPResultStore();
    if (!resultStore.lock) {
        return;
    }

    IOLockLock(resultStore.lock);
    const auto it = resultStore.results.find(requestID);
    if (it != resultStore.results.end()) {
        it->second.ready = true;
        it->second.status = FCPStatusToIOReturn(status);
        if (status == Protocols::AVC::FCPStatus::kOk && response.IsValid()) {
            it->second.responseLength = static_cast<uint32_t>(response.length);
            std::memcpy(it->second.response.data(), response.data.data(), response.length);
        } else {
            it->second.responseLength = 0;
        }
    }
    IOLockUnlock(resultStore.lock);
}

void MarkRawFCPRequestFailed(RawFCPResultStore& store, uint64_t requestID) {
    IOLockLock(store.lock);
    const auto it = store.results.find(requestID);
    if (it != store.results.end()) {
        it->second.ready = true;
        if (it->second.status == kIOReturnNotReady) {
            it->second.status = kIOReturnIOError;
        }
    }
    IOLockUnlock(store.lock);
}

} // anonymous namespace

AVCHandler::AVCHandler(Protocols::AVC::IAVCDiscovery* discovery)
    : discovery_(discovery)
{
}

kern_return_t AVCHandler::GetAVCUnits(IOUserClientMethodArguments* args) {
    if (!args) {
        ASFW_LOG(UserClient, "GetAVCUnits: null arguments");
        return kIOReturnBadArgument;
    }

    if (!discovery_) {
        ASFW_LOG(UserClient, "GetAVCUnits: discovery not available");
        return kIOReturnNotReady;
    }

    // Get all AV/C units
    auto allUnits = discovery_->AcquireAllAVCUnits();

    ASFW_LOG(UserClient, "GetAVCUnits: found %zu AV/C units", allUnits.size());

    // Calculate total size
    // We send an OSData containing a sequence of AVCUnitInfoWire structures.
    // Each AVCUnitInfoWire is followed by N * AVCSubunitInfoWire.
    size_t totalSize = 0;
    
    // Add header size (count of units)? 
    // The previous implementation had a header. The new spec doesn't explicitly define a top-level header,
    // but usually we send an array.
    // Let's assume the UI expects just the sequence of units, or we can add a simple count at the start.
    // The proposed AVCUnitInfoWire doesn't have a "next" pointer, so we rely on the buffer size or a count.
    // Let's prepend a uint32_t count for safety/easier parsing.
    totalSize += sizeof(uint32_t);

    for (const auto& avcUnit : allUnits) {
        if (avcUnit) {
            totalSize += sizeof(AVCUnitInfoWire);
            totalSize += avcUnit->GetSubunits().size() * sizeof(AVCSubunitInfoWire);
        }
    }

    ASFW_LOG(UserClient, "GetAVCUnits: total wire format size=%zu bytes", totalSize);

    // Create OSData buffer
    OSData* data = OSData::withCapacity(static_cast<uint32_t>(totalSize));
    if (!data) {
        ASFW_LOG(UserClient, "GetAVCUnits: failed to allocate OSData");
        return kIOReturnNoMemory;
    }

    // Write unit count
    uint32_t unitCount = static_cast<uint32_t>(allUnits.size());
    if (!data->appendBytes(&unitCount, sizeof(unitCount))) {
        data->release();
        return kIOReturnNoMemory;
    }

    // Write each AV/C unit + its subunits
    for (const auto& avcUnit : allUnits) {
        if (!avcUnit) continue;

        AVCUnitInfoWire unitWire{};
        
        // Get device from AVCUnit
        auto device = avcUnit->GetDevice();
        if (device) {
            unitWire.guid = device->GetGUID();
            unitWire.nodeID = device->GetNodeID();
            unitWire.vendorID = device->GetVendorID();
            unitWire.modelID = device->GetModelID();
        } else {
            unitWire.guid = 0;
            unitWire.nodeID = 0xFFFF;
            unitWire.vendorID = 0;
            unitWire.modelID = 0;
        }

        const auto& subunits = avcUnit->GetSubunits();
        unitWire.subunitCount = static_cast<uint8_t>(subunits.size());
        
        // Populate unit-level plug counts from AVCUnitPlugInfoCommand results
        const auto& plugCounts = avcUnit->GetCachedPlugCounts();
        unitWire.isoInputPlugs = plugCounts.isoInputPlugs;
        unitWire.isoOutputPlugs = plugCounts.isoOutputPlugs;
        unitWire.extInputPlugs = plugCounts.extInputPlugs;
        unitWire.extOutputPlugs = plugCounts.extOutputPlugs;
        // unitWire._reserved is zero-init

        if (!data->appendBytes(&unitWire, sizeof(unitWire))) {
            data->release();
            return kIOReturnNoMemory;
        }

        // Write subunits for this unit
        for (const auto& subunitPtr : subunits) {
            if (!subunitPtr) continue;

            AVCSubunitInfoWire subunitWire{};
            subunitWire.type = static_cast<uint8_t>(subunitPtr->GetType());
            subunitWire.subunitID = subunitPtr->GetID();
            subunitWire.numDestPlugs = subunitPtr->GetNumDestPlugs();
            subunitWire.numSrcPlugs = subunitPtr->GetNumSrcPlugs();

            if (!data->appendBytes(&subunitWire, sizeof(subunitWire))) {
                data->release();
                return kIOReturnNoMemory;
            }
        }
    }

    // Return data through structureOutput
    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;

    ASFW_LOG(UserClient, "GetAVCUnits: returning %zu units in %zu bytes",
             allUnits.size(), data->getLength());
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetSubunitCapabilities(IOUserClientMethodArguments* args) {
    if (!discovery_) {
        return kIOReturnNotReady;
    }

    const auto request = ParseSubunitLookupRequest(args, "GetSubunitCapabilities");
    if (!request) {
        return kIOReturnBadArgument;
    }

    const auto subunit = FindRequestedSubunit(*discovery_, *request);
    if (!subunit) {
        return kIOReturnNotFound;
    }
    if (!IsMusicSubunitType(subunit->GetType())) {
        ASFW_LOG(UserClient,
                 "GetSubunitCapabilities: not implemented for subunit type 0x%02x",
                 static_cast<uint8_t>(subunit->GetType()));
        return kIOReturnUnsupported;
    }

    const auto musicSubunit = std::static_pointer_cast<MusicSubunit>(subunit);
    return SerializeMusicCapabilities(musicSubunit->GetCapabilities(),
                                      musicSubunit->GetPlugs(),
                                      musicSubunit->GetMusicChannels(),
                                      args);
}

kern_return_t AVCHandler::SerializeMusicCapabilities(
    const ASFW::Protocols::AVC::Music::MusicSubunitCapabilities& caps,
    const std::vector<ASFW::Protocols::AVC::Music::MusicSubunit::PlugInfo>& plugs,
    const std::vector<ASFW::Protocols::AVC::Music::MusicSubunit::MusicPlugChannel>& channels,
    IOUserClientMethodArguments* args) 
{
    const auto channelNameLookup = BuildChannelNameLookup(channels);
    const auto plan = BuildMusicSerializationPlan(plugs);

    OSData* data = OSData::withCapacity(static_cast<uint32_t>(plan.totalSize));
    if (!data) return kIOReturnNoMemory;

    if (!AppendMusicCapabilitiesHeader(data, caps, plan)) {
        data->release();
        return kIOReturnNoMemory;
    }

    for (size_t i = 0; i < plan.numPlugsToSerialize; ++i) {
        if (!AppendMusicPlug(data, plugs[i], plan.plugInfos[i], channelNameLookup)) {
            data->release();
            return kIOReturnNoMemory;
        }
    }

    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetSubunitDescriptor(IOUserClientMethodArguments* args) {
    if (!discovery_) {
        return kIOReturnNotReady;
    }

    const auto request = ParseSubunitLookupRequest(args, "GetSubunitDescriptor");
    if (!request) {
        return kIOReturnBadArgument;
    }

    const auto subunit = FindRequestedSubunit(*discovery_, *request);
    if (!subunit) {
        ASFW_LOG(UserClient,
                 "GetSubunitDescriptor: subunit not found (GUID=0x%llx type=0x%02x id=%d)",
                 request->guid,
                 request->type,
                 request->id);
        return kIOReturnNotFound;
    }
    if (!IsMusicSubunitType(subunit->GetType())) {
        ASFW_LOG(UserClient,
                 "GetSubunitDescriptor: not implemented for subunit type 0x%02x",
                 static_cast<uint8_t>(subunit->GetType()));
        return kIOReturnUnsupported;
    }

    const auto musicSubunit = std::static_pointer_cast<MusicSubunit>(subunit);
    const auto& descriptorData = musicSubunit->GetStatusDescriptorData();
    if (!descriptorData) {
        ASFW_LOG(UserClient, "GetSubunitDescriptor: descriptor data not available");
        return kIOReturnNotFound;
    }

    const auto& dataVec = descriptorData.value();
    if (dataVec.size() > kMaxWireSize) {
        ASFW_LOG_ERROR(UserClient,
                       "GetSubunitDescriptor: descriptor size %zu exceeds wire limit %zu",
                       dataVec.size(),
                       kMaxWireSize);
        return kIOReturnMessageTooLarge;
    }

    OSData* osData = OSData::withBytes(dataVec.data(), static_cast<uint32_t>(dataVec.size()));
    if (!osData) {
        return kIOReturnNoMemory;
    }

    args->structureOutput = osData;
    args->structureOutputDescriptor = nullptr;
    ASFW_LOG(UserClient, "GetSubunitDescriptor: returning %zu bytes", dataVec.size());
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::SendRawFCPCommand(IOUserClientMethodArguments* args) {
    if (!discovery_) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: discovery not available");
        return kIOReturnNotReady;
    }

    const auto request = ParseRawFCPSubmissionRequest(args);
    if (!request) {
        return kIOReturnBadArgument;
    }

    auto lease = discovery_->AcquireFCPControlLeaseForGuid(request->guid);
    if (!lease) {
        ASFW_LOG(UserClient,
                 "SendRawFCPCommand: target unit not found (guid=0x%llx)",
                 request->guid);
        return kIOReturnNotFound;
    }

    Protocols::AVC::FCPFrame command{};
    command.length = request->commandLength;
    std::memcpy(command.data.data(), request->commandData->getBytesNoCopy(), command.length);

    auto& store = GetRawFCPResultStore();
    if (!store.lock) {
        ASFW_LOG(UserClient, "SendRawFCPCommand: result store lock unavailable");
        return kIOReturnNoMemory;
    }

    const uint64_t requestID = ReserveRawFCPRequestSlot(store);

    const auto handle = lease.transport->SubmitCommand(
        command,
        [requestID](Protocols::AVC::FCPStatus status, const Protocols::AVC::FCPFrame& response) {
            StoreRawFCPCompletion(requestID, status, response);
        }
    );

    if (!handle.IsValid()) {
        MarkRawFCPRequestFailed(store, requestID);
    }

    args->scalarOutput[0] = requestID;
    args->scalarOutputCount = 1;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetRawFCPCommandResult(IOUserClientMethodArguments* args) {
    if (!args || !args->scalarInput || args->scalarInputCount < 1) {
        return kIOReturnBadArgument;
    }

    auto& store = GetRawFCPResultStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }

    const uint64_t requestID = args->scalarInput[0];
    RawFCPResult result{};
    bool found = false;

    IOLockLock(store.lock);
    auto it = store.results.find(requestID);
    if (it != store.results.end()) {
        found = true;
        if (it->second.ready) {
            result = it->second;
            store.results.erase(it);
        }
    }
    IOLockUnlock(store.lock);

    if (!found) {
        return kIOReturnNotFound;
    }

    if (!result.ready) {
        return kIOReturnNotReady;
    }

    if (result.status != kIOReturnSuccess) {
        return result.status;
    }

    OSData* response = OSData::withBytes(result.response.data(), result.responseLength);
    if (!response) {
        return kIOReturnNoMemory;
    }

    args->structureOutput = response;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

#ifdef REWINDDV_FOUNDATION
kern_return_t AVCHandler::SubmitDeckControl(IOUserClientMethodArguments* args) {
    if (!discovery_) {
        return kIOReturnNotReady;
    }

    const auto request = ParseFoundationDeckControlRequest(args);
    if (!request) {
        return kIOReturnBadArgument;
    }

    auto lease = discovery_->AcquireFCPControlLeaseForGuid(request->guid);
    if (!lease) {
        return kIOReturnNotFound;
    }

    auto& store = GetFoundationDeckControlStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }

    uint64_t requestID = 0;
    const uint64_t currentDriverInstanceID = discovery_->GetFoundationDriverInstanceID();
    const bool conditionalProofAvailable =
        HasFoundationConditionalDeckProof(*request, currentDriverInstanceID);
    const kern_return_t admission =
        ReserveFoundationDeckControl(store, *request, currentDriverInstanceID,
                                     conditionalProofAvailable, requestID);
    if (admission != kIOReturnSuccess) {
        return admission;
    }

    Protocols::AVC::FCPFrame command{};
    const auto commandBytes = FoundationPolicy::CommandFrame(
        static_cast<FoundationPolicy::DeckCommand>(request->command));
    command.length = commandBytes.size();
    std::copy(commandBytes.begin(), commandBytes.end(), command.data.begin());

    Protocols::AVC::FCPCommandPolicy policy{};
    policy.retryClass = Protocols::AVC::FCPRetryClass::kNever;
    policy.queuePolicy = Protocols::AVC::FCPQueuePolicy::kReject;
    policy.maximumInterimResponses = 1;
    policy.expectedRoute = Discovery::DeviceRouteToken{
        .guid = request->guid,
        .deviceIncarnation = request->deviceIncarnation,
        .routeEpoch = request->routeEpoch,
        .generation = FW::Generation{request->generation},
        .nodeId = request->nodeID,
    };
    policy.responseClassifier = [](std::span<const uint8_t> requestBytes,
                                   std::span<const uint8_t> responseBytes) {
        using Class = FoundationPolicy::DeckResponseClassification;
        switch (FoundationPolicy::ClassifyDeckResponse(requestBytes, responseBytes)) {
        case Class::kMismatch:
        case Class::kUnknown:
            return Protocols::AVC::FCPResponseClassification::kMismatch;
        case Class::kInterim:
            return Protocols::AVC::FCPResponseClassification::kInterim;
        case Class::kAccepted:
            return Protocols::AVC::FCPResponseClassification::kAccepted;
        case Class::kRejected:
        case Class::kNotImplemented:
            return Protocols::AVC::FCPResponseClassification::kTerminalRejected;
        case Class::kOtherTerminal:
            return Protocols::AVC::FCPResponseClassification::kOtherTerminal;
        }
        return Protocols::AVC::FCPResponseClassification::kMismatch;
    };
    policy.attemptObserver = [requestID](Protocols::AVC::FCPAttemptEvidence evidence) {
        ObserveFoundationFCPAttempt(requestID, evidence);
    };
    policy.responseObserver = [requestID](Protocols::AVC::FCPResponseEvidence evidence) {
        ObserveFoundationFCPResponse(requestID, evidence);
    };
    const auto handle = lease.transport->SubmitCommand(
        command,
        [requestID](Protocols::AVC::FCPStatus status,
                    const Protocols::AVC::FCPFrame& response) {
            CompleteFoundationDeckControl(requestID, status, response);
        },
        std::move(policy));

    if (!handle.IsValid()) {
        FailFoundationDeckControlIfPending(requestID);
    }
    // A response may be delivered synchronously from WriteBlock. Publish only
    // after all attempt observers reachable from SubmitCommand have returned.
    CloseFoundationDeckControlSubmission(requestID);

    args->scalarOutput[0] = requestID;
    args->scalarOutputCount = 1;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetDeckControlResult(IOUserClientMethodArguments* args) {
    if (!args || !args->scalarInput || args->scalarInputCount < 3) {
        return kIOReturnBadArgument;
    }

    auto& store = GetFoundationDeckControlStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }

    FoundationPolicy::DeckControlResultWire resultWire{};
    const uint64_t requestID = args->scalarInput[0];
    const uint64_t operationID = args->scalarInput[1];
    const uint64_t attemptID = args->scalarInput[2];
    bool found = false;
    bool ready = false;

    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() && result->second.wire.operationID == operationID &&
        result->second.wire.attemptID == attemptID) {
        found = true;
        ready = result->second.ready;
        if (ready) {
            resultWire = result->second.wire;
        }
    }
    IOLockUnlock(store.lock);

    if (!found) {
        return kIOReturnNotFound;
    }
    if (!ready) {
        return kIOReturnNotReady;
    }

    OSData* data = OSData::withBytes(&resultWire, sizeof(resultWire));
    if (!data) {
        return kIOReturnNoMemory;
    }
    // Allocation succeeded. Recheck and atomically consume the same immutable
    // result so an allocation failure never destroys the only evidence copy.
    IOLockLock(store.lock);
    const auto consume = store.results.find(requestID);
    if (consume == store.results.end() || !consume->second.ready ||
        consume->second.wire.operationID != operationID ||
        consume->second.wire.attemptID != attemptID) {
        IOLockUnlock(store.lock);
        data->release();
        return kIOReturnNotFound;
    }
    store.results.erase(consume);
    IOLockUnlock(store.lock);

    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetFoundationRoute(IOUserClientMethodArguments* args) {
    if (!args || !args->scalarInput || args->scalarInputCount < 1) {
        return kIOReturnBadArgument;
    }
    if (!discovery_) {
        return kIOReturnNotReady;
    }
    const uint64_t guid = args->scalarInput[0];
    if (guid == 0) {
        return kIOReturnBadArgument;
    }
    const auto route = discovery_->CopyCurrentRouteForGuid(guid);
    if (!route.has_value() || !*route || route->guid != guid) {
        return kIOReturnNotFound;
    }

    auto& store = GetFoundationDeckControlStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }
    const uint64_t driverInstanceID = discovery_->GetFoundationDriverInstanceID();
    if (driverInstanceID == 0) {
        return kIOReturnNotReady;
    }

    FoundationPolicy::FoundationRouteWire wire{};
    wire.guid = route->guid;
    wire.driverInstanceID = driverInstanceID;
    wire.deviceIncarnation = route->deviceIncarnation;
    wire.routeEpoch = route->routeEpoch;
    wire.generation = route->generation.value;
    wire.nodeID = route->nodeId;
    OSData* data = OSData::withBytes(&wire, sizeof(wire));
    if (!data) {
        return kIOReturnNoMemory;
    }
    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::SubmitInspectorProbe(IOUserClientMethodArguments* args) {
    if (!discovery_) {
        return kIOReturnNotReady;
    }
    const auto request = ParseFoundationInspectorRequest(args);
    if (!request) {
        return kIOReturnBadArgument;
    }
    auto lease = discovery_->AcquireFCPControlLeaseForGuid(request->guid);
    if (!lease) {
        return kIOReturnNotFound;
    }
    auto& store = GetFoundationInspectorStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }
    uint64_t requestID = 0;
    const auto admission = ReserveFoundationInspector(
        store, *request, discovery_->GetFoundationDriverInstanceID(), requestID);
    if (admission != kIOReturnSuccess) {
        return admission;
    }

    const auto query = static_cast<FoundationPolicy::InspectorQuery>(request->query);
    const auto commandBytes = FoundationPolicy::InspectorCommandFrame(
        query, request->subunitPage);
    Protocols::AVC::FCPFrame command{};
    command.length = FoundationPolicy::InspectorCommandLength(query);
    std::copy_n(commandBytes.begin(), command.length, command.data.begin());

    Protocols::AVC::FCPCommandPolicy policy{};
    policy.retryClass = Protocols::AVC::FCPRetryClass::kNever;
    policy.queuePolicy = Protocols::AVC::FCPQueuePolicy::kReject;
    policy.maximumInterimResponses = 0;
    if (query == FoundationPolicy::InspectorQuery::kTapeTimeCode) {
        policy.responseTimeoutMs = FoundationPolicy::kTapeTimeCodeResponseDeadlineMs;
    }
    policy.expectedRoute = Discovery::DeviceRouteToken{
        .guid = request->guid,
        .deviceIncarnation = request->deviceIncarnation,
        .routeEpoch = request->routeEpoch,
        .generation = FW::Generation{request->generation},
        .nodeId = request->nodeID,
    };
    policy.responseClassifier = [query, page = request->subunitPage](
                                    std::span<const uint8_t>,
                                    std::span<const uint8_t> responseBytes) {
        using Class = FoundationPolicy::InspectorResponseClassification;
        switch (FoundationPolicy::ClassifyInspectorResponse(query, page, responseBytes)) {
        case Class::kMismatch:
        case Class::kUnknown:
            return Protocols::AVC::FCPResponseClassification::kMismatch;
        case Class::kInterim:
            return Protocols::AVC::FCPResponseClassification::kInterim;
        case Class::kImplementedStable:
            return Protocols::AVC::FCPResponseClassification::kAccepted;
        case Class::kRejected:
        case Class::kNotImplemented:
            return Protocols::AVC::FCPResponseClassification::kTerminalRejected;
        case Class::kAcceptedInvalidForStatus:
        case Class::kInTransitionInvalidForQuery:
        case Class::kChangedInvalidForStatus:
        case Class::kOtherTerminal:
            return Protocols::AVC::FCPResponseClassification::kOtherTerminal;
        }
        return Protocols::AVC::FCPResponseClassification::kMismatch;
    };
    policy.attemptObserver = [requestID](Protocols::AVC::FCPAttemptEvidence evidence) {
        ObserveFoundationInspectorAttempt(requestID, evidence);
    };
    policy.responseObserver = [requestID](Protocols::AVC::FCPResponseEvidence evidence) {
        ObserveFoundationInspectorResponse(requestID, evidence);
    };
    const auto handle = lease.transport->SubmitCommand(
        command,
        [requestID](Protocols::AVC::FCPStatus status,
                    const Protocols::AVC::FCPFrame& response) {
            CompleteFoundationInspector(requestID, status, response);
        },
        std::move(policy));
    if (!handle.IsValid()) {
        FailFoundationInspectorIfPending(requestID);
    }
    // A response is permitted before WriteBlock returns. Do not publish a
    // terminal result until every synchronous attempt observer has closed.
    CloseFoundationInspectorSubmission(requestID);

    args->scalarOutput[0] = requestID;
    args->scalarOutputCount = 1;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetInspectorResult(IOUserClientMethodArguments* args) {
    if (!args || !args->scalarInput || args->scalarInputCount != 3 ||
        args->structureInput || args->structureInputDescriptor) {
        return kIOReturnBadArgument;
    }
    auto& store = GetFoundationInspectorStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }
    const uint64_t requestID = args->scalarInput[0];
    const uint64_t operationID = args->scalarInput[1];
    const uint64_t attemptID = args->scalarInput[2];
    FoundationPolicy::InspectorResultWire resultWire{};
    bool found = false;
    bool ready = false;
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() && result->second.wire.operationID == operationID &&
        result->second.wire.attemptID == attemptID) {
        found = true;
        ready = result->second.ready;
        if (ready) resultWire = result->second.wire;
    }
    IOLockUnlock(store.lock);
    if (!found) return kIOReturnNotFound;
    if (!ready) return kIOReturnNotReady;

    OSData* data = OSData::withBytes(&resultWire, sizeof(resultWire));
    if (!data) return kIOReturnNoMemory;
    IOLockLock(store.lock);
    const auto consume = store.results.find(requestID);
    if (consume == store.results.end() || !consume->second.ready ||
        consume->second.wire.operationID != operationID ||
        consume->second.wire.attemptID != attemptID) {
        IOLockUnlock(store.lock);
        data->release();
        return kIOReturnNotFound;
    }
    store.results.erase(consume);
    IOLockUnlock(store.lock);
    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::SubmitTransportCapabilityProbe(
    IOUserClientMethodArguments* args) {
    if (!discovery_) {
        return kIOReturnNotReady;
    }
    const auto request = ParseFoundationTransportCapabilityProbeRequest(args);
    if (!request) {
        return kIOReturnBadArgument;
    }
    auto lease = discovery_->AcquireFCPControlLeaseForGuid(request->guid);
    if (!lease) {
        return kIOReturnNotFound;
    }
    auto& store = GetFoundationTransportCapabilityStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }
    uint64_t requestID = 0;
    const auto admission = ReserveFoundationTransportCapabilityProbe(
        store, *request, discovery_->GetFoundationDriverInstanceID(), requestID);
    if (admission != kIOReturnSuccess) {
        return admission;
    }

    const auto deckCommand = static_cast<FoundationPolicy::DeckCommand>(request->command);
    const auto commandBytes =
        FoundationPolicy::TransportCapabilityInquiryFrame(deckCommand);
    Protocols::AVC::FCPFrame command{};
    command.length = commandBytes.size();
    std::copy(commandBytes.begin(), commandBytes.end(), command.data.begin());

    Protocols::AVC::FCPCommandPolicy policy{};
    policy.retryClass = Protocols::AVC::FCPRetryClass::kNever;
    policy.queuePolicy = Protocols::AVC::FCPQueuePolicy::kReject;
    policy.maximumInterimResponses = 0;
    policy.expectedRoute = Discovery::DeviceRouteToken{
        .guid = request->guid,
        .deviceIncarnation = request->deviceIncarnation,
        .routeEpoch = request->routeEpoch,
        .generation = FW::Generation{request->generation},
        .nodeId = request->nodeID,
    };
    policy.responseClassifier = [deckCommand](
                                    std::span<const uint8_t>,
                                    std::span<const uint8_t> responseBytes) {
        using Class = FoundationPolicy::TransportCapabilityResponseClassification;
        switch (FoundationPolicy::ClassifyTransportCapabilityResponse(
            deckCommand, responseBytes)) {
        case Class::kMismatch:
        case Class::kUnknown:
            return Protocols::AVC::FCPResponseClassification::kMismatch;
        case Class::kImplemented:
            return Protocols::AVC::FCPResponseClassification::kAccepted;
        case Class::kNotImplemented:
            return Protocols::AVC::FCPResponseClassification::kTerminalRejected;
        case Class::kUnexpectedTerminal:
            return Protocols::AVC::FCPResponseClassification::kOtherTerminal;
        }
        return Protocols::AVC::FCPResponseClassification::kMismatch;
    };
    policy.attemptObserver = [requestID](Protocols::AVC::FCPAttemptEvidence evidence) {
        ObserveFoundationTransportCapabilityAttempt(requestID, evidence);
    };
    policy.responseObserver = [requestID](Protocols::AVC::FCPResponseEvidence evidence) {
        ObserveFoundationTransportCapabilityResponse(requestID, evidence);
    };
    const auto handle = lease.transport->SubmitCommand(
        command,
        [requestID](Protocols::AVC::FCPStatus status,
                    const Protocols::AVC::FCPFrame& response) {
            CompleteFoundationTransportCapability(requestID, status, response);
        },
        std::move(policy));
    if (!handle.IsValid()) {
        FailFoundationTransportCapabilityIfPending(requestID);
    }
    // Responses may precede WriteBlock return. Authorization and result
    // publication wait until every synchronous attempt observer has closed.
    CloseFoundationTransportCapabilitySubmission(requestID);

    args->scalarOutput[0] = requestID;
    args->scalarOutputCount = 1;
    return kIOReturnSuccess;
}

kern_return_t AVCHandler::GetTransportCapabilityResult(
    IOUserClientMethodArguments* args) {
    if (!args || !args->scalarInput || args->scalarInputCount != 3 ||
        args->structureInput || args->structureInputDescriptor) {
        return kIOReturnBadArgument;
    }
    auto& store = GetFoundationTransportCapabilityStore();
    if (!store.lock) {
        return kIOReturnNoMemory;
    }
    const uint64_t requestID = args->scalarInput[0];
    const uint64_t operationID = args->scalarInput[1];
    const uint64_t attemptID = args->scalarInput[2];
    FoundationPolicy::TransportCapabilityResultWire resultWire{};
    bool found = false;
    bool ready = false;
    IOLockLock(store.lock);
    const auto result = store.results.find(requestID);
    if (result != store.results.end() &&
        result->second.wire.operationID == operationID &&
        result->second.wire.attemptID == attemptID) {
        found = true;
        ready = result->second.ready;
        if (ready) resultWire = result->second.wire;
    }
    IOLockUnlock(store.lock);
    if (!found) return kIOReturnNotFound;
    if (!ready) return kIOReturnNotReady;

    OSData* data = OSData::withBytes(&resultWire, sizeof(resultWire));
    if (!data) return kIOReturnNoMemory;
    IOLockLock(store.lock);
    const auto consume = store.results.find(requestID);
    if (consume == store.results.end() || !consume->second.ready ||
        consume->second.wire.operationID != operationID ||
        consume->second.wire.attemptID != attemptID) {
        IOLockUnlock(store.lock);
        data->release();
        return kIOReturnNotFound;
    }
    store.results.erase(consume);
    IOLockUnlock(store.lock);
    args->structureOutput = data;
    args->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}
#endif

kern_return_t AVCHandler::ReScanAVCUnits(IOUserClientMethodArguments* args) {
    (void)args; // Unused
    
    if (!discovery_) return kIOReturnNotReady;

    ASFW_LOG(UserClient, "ReScanAVCUnits: triggering re-scan");
    discovery_->ReScanAllUnits();
    
    return kIOReturnSuccess;
}

} // namespace ASFW::UserClient
