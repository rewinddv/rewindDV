// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
#include "FoundationReceiveService.hpp"
#include "FoundationActivityGate.hpp"
#include "FoundationRawReceiveSink.hpp"
#include "../../ASFWDriver/Common/DriverKitOwnership.hpp"
#include "../../ASFWDriver/Async/FireWireBusImpl.hpp"
#include "../../ASFWDriver/Bus/IRM/IRMClient.hpp"
#include "../../ASFWDriver/Discovery/DeviceRegistry.hpp"
#include "../../ASFWDriver/Isoch/IsochService.hpp"
#include "../../ASFWDriver/Logging/Logging.hpp"
#include "../../ASFWDriver/Protocols/AVC/CMP/CMPClient.hpp"
#include "../../ASFWDriver/Protocols/DV/DVConnectionPlan.hpp"
#include <DriverKit/IOBufferMemoryDescriptor.h>
#ifndef ASFW_HOST_TEST
#include <DriverKit/IOMemoryMap.h>
#endif
#include <DriverKit/OSSharedPtr.h>
#include <DriverKit/IOUserClient.h>
#include <limits>
#include <algorithm>
#include <utility>

namespace RewindDV::Foundation::Receive {
#ifdef ASFW_HOST_TEST
namespace Testing {
static std::atomic<bool> failNextRingAllocation{false};
void FailNextRingAllocation() noexcept {
    failNextRingAllocation.store(true, std::memory_order_release);
}
}
#endif
namespace {
enum BudgetSpeedEvidence : uint32_t {
    kOMPRLimit = 1u << 0,
    kOPCRLimit = 1u << 1,
    kStoredPolicyLimit = 1u << 2,
    kTopologyPathLimit = 1u << 3,
    kS400PolicyLimit = 1u << 4,
    kConservativeFallback = 1u << 5,
    kSuccessfulProbeLimit = 1u << 6,
};

enum class AllocationRefusalStage : uint8_t {
    ResourceSnapshot = 1,
    RouteAndRegistry = 2,
    Budget = 3,
};

enum class AllocationRefusalReason : uint8_t {
    SnapshotReadFailed = 1,
    MalformedResourceSnapshot = 2,
    AllChannelsOccupied = 3,
    RegistryRecordUnavailable = 4,
    StaleSpeedDecision = 5,
    InvalidBandwidthBudget = 6,
};

struct AllocationPlanEvidence {
    uint32_t ompr{};
    uint32_t opcr{};
    uint32_t observedBandwidth{};
    uint32_t observedChannels31_0{};
    uint32_t observedChannels63_32{};
    uint32_t payloadQuadlets{};
    uint32_t packetUnits{};
    uint32_t plugOverheadUnits{};
    uint32_t totalUnits{};
    uint32_t speedEvidence{};
    uint8_t selectedSpeed{};
    uint8_t topologyCeiling{};
    uint8_t learnedCeiling{};
    uint8_t channel{0xFF};
};
static_assert(sizeof(AllocationPlanEvidence) == 44);

class Guard {
public:
    explicit Guard(IOLock* lock) : lock_(lock) { IOLockLock(lock_); }
    ~Guard() { IOLockUnlock(lock_); }
private: IOLock* lock_;
};
bool IsLive(State state) {
    return state == State::Preparing || state == State::Active || state == State::Quarantined;
}
[[nodiscard]] kern_return_t ToIOReturn(ASFW::IRM::AllocationStatus status) noexcept {
    using ASFW::IRM::AllocationStatus;
    switch (status) {
    case AllocationStatus::Success: return kIOReturnSuccess;
    case AllocationStatus::NoResources: return kIOReturnNoResources;
    case AllocationStatus::GenerationMismatch: return kIOReturnAborted;
    case AllocationStatus::Timeout: return kIOReturnTimeout;
    case AllocationStatus::NotFound: return kIOReturnNotFound;
    case AllocationStatus::Failed: return kIOReturnError;
    }
    return kIOReturnError;
}
class PendingActivity {
public:
    explicit PendingActivity(DriverPolicy::ActivityKind kind)
        : token_(DriverPolicy::TryAcquireActivity(kind)) {}
    ~PendingActivity() { DriverPolicy::ReleaseActivity(token_); }
    [[nodiscard]] uint64_t Token() const noexcept { return token_; }
    [[nodiscard]] uint64_t Transfer() noexcept { return std::exchange(token_, 0); }
private:
    uint64_t token_{};
};
}

// Each asynchronous step receives a retained owner explicitly. DriverKit libc++
// shared_from_this/shared_ptr counts are not atomic; never use them for this
// session or capture a reference to a caller-owned owner variable.
struct Service::Session {
    IOLock* lock{IOLockAlloc()};
    uint64_t owner{}, epoch{};
    ASFW::Discovery::DeviceRouteToken route{};
    ASFW::Driver::IsochService* isoch{};
    std::shared_ptr<ASFW::Driver::HardwareInterface> hardware;
    std::shared_ptr<ASFW::Discovery::DeviceRegistry> registry;
    std::shared_ptr<ASFW::CMP::CMPClient> cmp;
    std::shared_ptr<ASFW::IRM::IRMClient> irm;
    ASFW::Async::FireWireBusImpl::LinkSpeedDecision speedDecision{};
    std::function<void()> quarantine;
    OSSharedPtr<IOBufferMemoryDescriptor> memory;
    OSSharedPtr<IOMemoryMap> mapping;
    RawSink sink;
    bool armed{};
    uint8_t plugCount{};
    uint32_t ompr{};
    uint8_t managedPlug{0xff};
    uint8_t managedChannel{0xff};
    uint32_t managedBandwidth{};
    uint32_t managedBandwidthCeiling{};
    AllocationPlanEvidence allocationPlan{};
    bool resourcesOwned{};
    bool connectionOwned{};
    bool allocationInFlight{};
    bool connectInFlight{};
    bool cleanupRequested{};
    bool cleanupStarted{};
    bool generationInvalidated{};
    State terminalTarget{State::Stopped};
    int32_t terminalStatus{};
    uint64_t activityToken{};

    void LogAllocationRefusal(AllocationRefusalStage stage,
                              AllocationRefusalReason reason,
                              kern_return_t status,
                              bool resourceSnapshotObserved,
                              const ASFW::IRM::ResourceSnapshot& snapshot = {}) const {
        ASFW_LOG(Isoch,
                 "[FoundationRX] alloc-refusal epoch=%llu gen=%u guid=%llx "
                 "stage=%u reason=%u status=0x%08x observed=%u "
                 "bw=%u ch31=0x%08x ch63=0x%08x",
                 epoch, route.generation.value, route.guid,
                 static_cast<unsigned>(stage), static_cast<unsigned>(reason),
                 static_cast<uint32_t>(status), resourceSnapshotObserved ? 1u : 0u,
                 snapshot.bandwidthAvailable, snapshot.channelsAvailable31_0,
                 snapshot.channelsAvailable63_32);
    }

    ~Session() {
        // The terminal session and ring remain owner-retained for final
        // snapshot/acknowledgement. Keep inspector exclusion through that
        // drain and release only when the session is actually destroyed.
        DriverPolicy::ReleaseActivity(activityToken);
        if (lock) IOLockFree(lock);
    }

    kern_return_t StopLocked(State terminal) {
        const auto state = sink.GetState();
        if (state == State::Quarantined) return sink.Snapshot().lastStatus;
        if (state == State::CleanupPending) {
            if (terminal == State::BusReset) {
                generationInvalidated = true;
                sink.SetState(State::BusReset);
            }
            return kIOReturnSuccess;
        }
        if (!IsLive(state)) return kIOReturnSuccess;
        if (armed) {
            const auto result = isoch->StopPacketReceive(&sink);
            if (result != kIOReturnSuccess) {
                sink.SetState(State::Quarantined, result);
                return result;
            }
            armed = false;
        }
        // A pending read callback sees this terminal state before touching any
        // borrowed runtime object; no stale-generation PCR writes are issued.
        terminalTarget = terminal;
        terminalStatus = 0;
        if (terminal == State::BusReset) {
            generationInvalidated = true;
            sink.SetState(terminal);
        } else if (resourcesOwned || connectionOwned || allocationInFlight || connectInFlight) {
            sink.SetState(State::CleanupPending);
        } else sink.SetState(terminal);
        return kIOReturnSuccess;
    }
    bool CurrentLocked() const {
        return registry->IsCurrent(route) && hardware->IsAvailable();
    }
    void FailLocked(kern_return_t status) {
        sink.SetState(State::Failed, status);
    }

    void BeginCleanup(SessionOwner self) {
        bool disconnect = false, release = false;
        uint8_t plug = 0xff, channel = 0xff;
        uint32_t bandwidth = 0;
        {
            Guard guard(lock);
            cleanupRequested = true;
            if (!registry->IsCurrent(route) || irm->GetGeneration() != route.generation)
                generationInvalidated = true;
            if (generationInvalidated) {
                cmp->InvalidateRoute(route);
                connectionOwned = false;
                resourcesOwned = false;
                cleanupStarted = true;
                sink.SetState(State::BusReset);
                return;
            }
            const auto current = sink.GetState();
            if (current == State::Failed) {
                terminalTarget = State::Failed;
                terminalStatus = sink.Snapshot().lastStatus;
            }
            if (cleanupStarted) return;
            if (allocationInFlight || connectInFlight) return;
            if (!connectionOwned && !resourcesOwned) {
                sink.SetState(terminalTarget, terminalStatus);
                return;
            }
            sink.SetState(State::CleanupPending, terminalStatus);
            cleanupStarted = true;
            if (connectionOwned) { disconnect = true; plug = managedPlug; }
            else if (resourcesOwned) {
                release = true; channel = managedChannel; bandwidth = managedBandwidth;
            }
        }
        if (disconnect) {
            cmp->DisconnectOPCR({.route = route}, plug, [self](ASFW::CMP::CMPStatus status) {
                ASFW_LOG(Isoch, "[FoundationRX] disconnect guid=0x%llx gen=%u plug=%u status=%u",
                         self->route.guid, self->route.generation.value, self->managedPlug,
                         static_cast<unsigned>(status));
                bool releaseResources = false, mustQuarantine = false;
                uint8_t channel = 0xff;
                uint32_t bandwidth = 0;
                {
                    Guard guard(self->lock);
                    self->connectionOwned = false;
                    if (self->generationInvalidated || !self->registry->IsCurrent(self->route) ||
                        self->irm->GetGeneration() != self->route.generation) {
                        self->generationInvalidated = true;
                        self->connectionOwned = false;
                        self->resourcesOwned = false;
                        self->sink.SetState(State::BusReset);
                    } else if (status == ASFW::CMP::CMPStatus::Success) {
                        releaseResources = self->resourcesOwned;
                        channel = self->managedChannel;
                        bandwidth = self->managedBandwidth;
                        if (!releaseResources)
                            self->sink.SetState(self->terminalTarget, self->terminalStatus);
                    } else {
                        self->sink.SetState(State::Quarantined, ToIOReturn(status));
                        mustQuarantine = true;
                    }
                }
                if (mustQuarantine) self->quarantine();
                if (releaseResources) {
                    self->irm->ReleaseResourcesForGeneration(channel, bandwidth,
                        self->managedBandwidthCeiling,
                        self->route.generation,
                        [self](ASFW::IRM::AllocationStatus releaseStatus,
                               ASFW::IRM::ResourceOwnership ownership) {
                            ASFW_LOG(Isoch, "[FoundationRX] release guid=0x%llx gen=%u ch=%u bw=%u ceiling=%u status=%u ownership=%u",
                                     self->route.guid, self->route.generation.value,
                                     self->managedChannel, self->managedBandwidth,
                                     self->managedBandwidthCeiling, static_cast<unsigned>(releaseStatus),
                                     static_cast<unsigned>(ownership));
                            bool mustQuarantine = false;
                            {
                                Guard guard(self->lock);
                                if (self->generationInvalidated) {
                                    self->resourcesOwned = false;
                                } else if (releaseStatus == ASFW::IRM::AllocationStatus::Success &&
                                           ownership == ASFW::IRM::ResourceOwnership::None)
                                {
                                    self->resourcesOwned = false;
                                    self->sink.SetState(self->terminalTarget, self->terminalStatus);
                                }
                                else {
                                    self->sink.SetState(State::Quarantined, ToIOReturn(releaseStatus));
                                    mustQuarantine = true;
                                }
                            }
                            if (mustQuarantine) self->quarantine();
                        });
                }
            });
        } else if (release) {
            irm->ReleaseResourcesForGeneration(channel, bandwidth, managedBandwidthCeiling,
                route.generation,
                [self](ASFW::IRM::AllocationStatus status,
                       ASFW::IRM::ResourceOwnership ownership) {
                ASFW_LOG(Isoch, "[FoundationRX] rollback guid=0x%llx gen=%u ch=%u bw=%u ceiling=%u status=%u ownership=%u",
                         self->route.guid, self->route.generation.value,
                         self->managedChannel, self->managedBandwidth,
                         self->managedBandwidthCeiling, static_cast<unsigned>(status),
                         static_cast<unsigned>(ownership));
                bool mustQuarantine = false;
                {
                    Guard guard(self->lock);
                    if (self->generationInvalidated) {
                        self->resourcesOwned = false;
                    } else if (status == ASFW::IRM::AllocationStatus::Success &&
                               ownership == ASFW::IRM::ResourceOwnership::None) {
                        self->resourcesOwned = false;
                        self->sink.SetState(self->terminalTarget, self->terminalStatus);
                    }
                    else {
                        self->sink.SetState(State::Quarantined, ToIOReturn(status));
                        mustQuarantine = true;
                    }
                }
                if (mustQuarantine) self->quarantine();
            });
        }
    }

    void StartReceiveOnManagedChannel(SessionOwner self) {
        bool cleanup = false, mustQuarantine = false;
        {
            Guard guard(lock);
            if (sink.GetState() != State::Preparing || !CurrentLocked()) cleanup = true;
            else {
                sink.SetChannel(managedChannel, ChannelEvidence::OwnedManagedP2P);
                const auto result = isoch->StartPacketReceive(managedChannel, *hardware, &sink);
                if (result != kIOReturnSuccess) { FailLocked(result); cleanup = true; }
                else {
                    armed = true;
                    if (!CurrentLocked()) {
                        const auto stopped = StopLocked(State::BusReset);
                        generationInvalidated = true;
                        cleanup = true;
                        mustQuarantine = stopped != kIOReturnSuccess;
                    } else sink.SetState(State::Active);
                    ASFW_LOG(Isoch, "[FoundationRX] active guid=0x%llx gen=%u ch=%u plug=%u",
                             route.guid, route.generation.value, managedChannel, managedPlug);
                }
            }
        }
        if (mustQuarantine) quarantine();
        if (cleanup) BeginCleanup(self);
    }

    void ConnectManaged(SessionOwner self) {
        cmp->ConnectOPCRWithOwnership({.route = route}, managedPlug, managedChannel,
            [self](ASFW::CMP::CMPStatus status, ASFW::CMP::MutationOwnership ownership) {
                ASFW_LOG(Isoch, "[FoundationRX] connect guid=0x%llx gen=%u plug=%u ch=%u status=%u ownership=%u",
                         self->route.guid, self->route.generation.value, self->managedPlug,
                         self->managedChannel, static_cast<unsigned>(status),
                         static_cast<unsigned>(ownership));
                bool start = false, cleanup = false, mustQuarantine = false;
                {
                    Guard guard(self->lock);
                    self->connectInFlight = false;
                    if (status == ASFW::CMP::CMPStatus::Success &&
                        ownership == ASFW::CMP::MutationOwnership::Owned) {
                        self->connectionOwned = true;
                        start = self->sink.GetState() == State::Preparing && self->CurrentLocked() &&
                                !self->cleanupRequested;
                        cleanup = !start;
                    } else {
                        if (!self->registry->IsCurrent(self->route) ||
                            self->irm->GetGeneration() != self->route.generation) {
                            self->generationInvalidated = true;
                            self->connectionOwned = false;
                            self->resourcesOwned = false;
                            self->sink.SetState(State::BusReset);
                        } else if (ownership == ASFW::CMP::MutationOwnership::Uncertain) {
                            // Once a connect CAS was submitted, transport failure
                            // cannot prove whether the remote p2p count changed.
                            // Retain the IRM reservation and forbid a new session.
                            self->sink.SetState(State::Quarantined, ToIOReturn(status));
                            mustQuarantine = true;
                        } else {
                            self->FailLocked(ToIOReturn(status));
                            cleanup = true;
                        }
                    }
                }
                if (start) self->StartReceiveOnManagedChannel(self);
                if (cleanup) self->BeginCleanup(self);
                if (mustQuarantine) self->quarantine();
            });
    }

    void AllocateManaged(SessionOwner self, uint32_t pcr) {
        irm->ReadResourcesSnapshot([self, pcr](ASFW::IRM::AllocationStatus status,
                                               ASFW::IRM::ResourceSnapshot snapshot) {
            ASFW_LOG(Isoch, "[FoundationRX] resources guid=0x%llx gen=%u status=%u observed=%u bw=%u hi=0x%08x lo=0x%08x",
                     self->route.guid, self->route.generation.value, static_cast<unsigned>(status),
                     status == ASFW::IRM::AllocationStatus::Success ? 1u : 0u,
                     snapshot.bandwidthAvailable, snapshot.channelsAvailable31_0,
                     snapshot.channelsAvailable63_32);
            if (status != ASFW::IRM::AllocationStatus::Success) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::ResourceSnapshot,
                    AllocationRefusalReason::SnapshotReadFailed,
                    ToIOReturn(status), false);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing) self->FailLocked(ToIOReturn(status));
                return;
            }
            if (snapshot.bandwidthAvailable > ASFW::IRM::kBandwidthAvailableValueMask) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::ResourceSnapshot,
                    AllocationRefusalReason::MalformedResourceSnapshot,
                    kIOReturnBadArgument, true, snapshot);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing)
                    self->FailLocked(kIOReturnBadArgument);
                return;
            }
            const auto channel = ASFW::Protocols::DV::FirstAvailableChannel(snapshot);
            const auto record = self->registry->SnapshotByGuid(self->route.guid);
            if (!channel) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::ResourceSnapshot,
                    AllocationRefusalReason::AllChannelsOccupied,
                    kIOReturnNoResources, true, snapshot);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing) self->FailLocked(kIOReturnNoResources);
                return;
            }
            if (!record) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::RouteAndRegistry,
                    AllocationRefusalReason::RegistryRecordUnavailable,
                    kIOReturnNoResources, true, snapshot);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing) self->FailLocked(kIOReturnNoResources);
                return;
            }
            if (self->speedDecision.topologyValid &&
                (self->speedDecision.generation8 != self->route.generation.value ||
                 self->speedDecision.targetNodeId != self->route.nodeId)) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::RouteAndRegistry,
                    AllocationRefusalReason::StaleSpeedDecision,
                    kIOReturnAborted, true, snapshot);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing)
                    self->FailLocked(kIOReturnAborted);
                return;
            }
            const uint8_t omprSpeed = ASFW::CMP::MPRBits::GetDataRate(self->ompr);
            const uint8_t opcrSpeed = ASFW::CMP::PCRBits::GetDataRate(pcr);
            const uint8_t learnedPolicySpeed =
                static_cast<uint8_t>(record->link.localToNode);
            const uint8_t pathSpeed = static_cast<uint8_t>(self->speedDecision.selected);
            const uint8_t speed = static_cast<uint8_t>(std::min(
                {omprSpeed, opcrSpeed, learnedPolicySpeed, pathSpeed, uint8_t{2}}));
            const auto bandwidth = ASFW::Protocols::DV::CalculateBandwidthUnits(pcr, speed);
            if (!bandwidth) {
                self->LogAllocationRefusal(
                    AllocationRefusalStage::Budget,
                    AllocationRefusalReason::InvalidBandwidthBudget,
                    kIOReturnBadArgument, true, snapshot);
                Guard guard(self->lock);
                if (self->sink.GetState() == State::Preparing) self->FailLocked(kIOReturnBadArgument);
                return;
            }
            AllocationPlanEvidence plan{};
            plan.ompr = self->ompr;
            plan.opcr = pcr;
            plan.observedBandwidth = snapshot.bandwidthAvailable;
            plan.observedChannels31_0 = snapshot.channelsAvailable31_0;
            plan.observedChannels63_32 = snapshot.channelsAvailable63_32;
            plan.payloadQuadlets = ASFW::CMP::PCRBits::GetPayload(pcr);
            const uint32_t rawOverhead = ASFW::CMP::PCRBits::GetOverhead(pcr);
            plan.plugOverheadUnits = rawOverhead > 0 ? rawOverhead * 32u : 512u;
            plan.packetUnits =
                (plan.payloadQuadlets + 3u) * (1u << (2u - speed)) * 4u;
            plan.totalUnits = *bandwidth;
            plan.selectedSpeed = speed;
            plan.topologyCeiling = self->speedDecision.topologyValid
                                       ? static_cast<uint8_t>(
                                             self->speedDecision.topologyCeiling)
                                       : uint8_t{0xFF};
            plan.learnedCeiling = self->speedDecision.learnedSuccess
                                      ? static_cast<uint8_t>(
                                            self->speedDecision.learnedCeiling)
                                      : uint8_t{0xFF};
            plan.channel = *channel;
            if (omprSpeed == speed) plan.speedEvidence |= kOMPRLimit;
            if (opcrSpeed == speed) plan.speedEvidence |= kOPCRLimit;
            if (learnedPolicySpeed == speed) plan.speedEvidence |= kStoredPolicyLimit;
            if (self->speedDecision.topologyValid &&
                static_cast<uint8_t>(self->speedDecision.topologyCeiling) == speed)
                plan.speedEvidence |= kTopologyPathLimit;
            if (speed == 2) plan.speedEvidence |= kS400PolicyLimit;
            if (!self->speedDecision.topologyValid)
                plan.speedEvidence |= kConservativeFallback;
            if (self->speedDecision.learnedSuccess &&
                static_cast<uint8_t>(self->speedDecision.learnedCeiling) == speed)
                plan.speedEvidence |= kSuccessfulProbeLimit;
            {
                Guard guard(self->lock);
                if (self->sink.GetState() != State::Preparing || !self->CurrentLocked()) return;
                self->managedChannel = *channel;
                self->managedBandwidth = *bandwidth;
                self->managedBandwidthCeiling = snapshot.bandwidthAvailable;
                self->allocationPlan = plan;
                self->allocationInFlight = true;
            }
            ASFW_LOG(Isoch,
                     "[FoundationRX] alloc-input epoch=%llu gen=%u guid=%llx "
                     "ompr=0x%08x opcr=0x%08x "
                     "observed_bw=%u ch31=0x%08x ch63=0x%08x topo=%u learned=%u",
                     self->epoch, self->route.generation.value, self->route.guid,
                     plan.ompr, plan.opcr,
                     plan.observedBandwidth, plan.observedChannels31_0,
                     plan.observedChannels63_32, plan.topologyCeiling,
                     plan.learnedCeiling);
            ASFW_LOG(Isoch,
                     "[FoundationRX] alloc-plan epoch=%llu gen=%u ch=%u speed=%u src=0x%x "
                     "payload=%u packet=%u overhead=%u total=%u observed_bw=%u",
                     self->epoch, self->route.generation.value, plan.channel, plan.selectedSpeed,
                     plan.speedEvidence, plan.payloadQuadlets, plan.packetUnits,
                     plan.plugOverheadUnits, plan.totalUnits, plan.observedBandwidth);
            self->irm->AllocateResourcesDetailedForGeneration(
                *channel, *bandwidth, self->route.generation,
                [self](ASFW::IRM::AllocationStatus allocationStatus,
                       ASFW::IRM::ResourceOwnership ownership,
                       ASFW::IRM::ResourceOperationEvidence evidence) {
                    ASFW_LOG(Isoch,
                             "[FoundationRX] alloc-result epoch=%llu gen=%u ch=%u status=%u own=%u "
                             "cause=%u cleanup=%u fail_stage=%u terminal_stage=%u valid=0x%x",
                             self->epoch, self->route.generation.value, self->managedChannel,
                             static_cast<unsigned>(allocationStatus),
                             static_cast<unsigned>(ownership),
                             static_cast<unsigned>(evidence.cause),
                             static_cast<unsigned>(evidence.cleanupCause),
                             static_cast<unsigned>(evidence.failureStage),
                             static_cast<unsigned>(evidence.terminalStage),
                             evidence.validFields);
                    ASFW_LOG(Isoch,
                             "[FoundationRX] alloc-cas epoch=%llu gen=%u ch=0x%08x "
                             "bw=%u expected=0x%08x desired=0x%08x "
                             "observed=0x%08x cmp_stage=%u retries=%u valid=0x%x",
                             self->epoch, self->route.generation.value,
                             evidence.observedChannelRegister,
                             evidence.observedBandwidthAvailable,
                             evidence.compareExpected, evidence.compareDesired,
                             evidence.compareObserved,
                             static_cast<unsigned>(evidence.compareStage),
                             evidence.contentionRetriesUsed,
                             evidence.validFields);
                    bool connect = false, cleanup = false;
                    {
                        Guard guard(self->lock);
                        self->allocationInFlight = false;
                        if (allocationStatus == ASFW::IRM::AllocationStatus::Success &&
                            ownership == ASFW::IRM::ResourceOwnership::Owned) {
                            self->resourcesOwned = true;
                            connect = self->sink.GetState() == State::Preparing && self->CurrentLocked() &&
                                      !self->cleanupRequested;
                            cleanup = !connect;
                            if (connect && !cleanup) self->connectInFlight = true;
                        } else if (ownership == ASFW::IRM::ResourceOwnership::Uncertain) {
                            self->sink.SetState(State::Quarantined, ToIOReturn(allocationStatus));
                            cleanup = false;
                        } else if (self->sink.GetState() == State::Preparing)
                            self->FailLocked(ToIOReturn(allocationStatus));
                    }
                    if (connect) self->ConnectManaged(self);
                    if (cleanup) self->BeginCleanup(self);
                    if (ownership == ASFW::IRM::ResourceOwnership::Uncertain)
                        self->quarantine();
                });
        });
    }

    void BeginDiscovery(SessionOwner self) {
        // Keep CMPClient alive through its internal raw-this completion. The
        // session's terminal state fences the borrowed runtime after Stop.
        cmp->ReadOMPR({.route = route}, [self](bool success, uint32_t value) {
            bool readPlug = false;
            {
                Guard guard(self->lock);
                if (self->sink.GetState() != State::Preparing) return;
                if (!success || !self->CurrentLocked()) {
                    self->FailLocked(success ? kIOReturnAborted : kIOReturnNotReady);
                    return;
                }
                self->ompr = value;
                ASFW_LOG(Isoch, "[FoundationRX] oMPR guid=0x%llx gen=%u raw=0x%08x",
                         self->route.guid, self->route.generation.value, value);
                self->plugCount = ASFW::CMP::MPRBits::GetPlugCount(value);
                if (!self->plugCount || self->plugCount > 31) {
                    self->FailLocked(kIOReturnNotFound);
                    return;
                }
                readPlug = true;
            }
            if (readPlug) self->ReadPlug(self, 0);
        });
    }
    void ReadPlug(SessionOwner self, uint8_t plug) {
        // Revalidate under the session lock, then issue only this fixed CMP
        // read. CMPClient independently validates the route at submission.
        {
            Guard guard(lock);
            if (sink.GetState() != State::Preparing) return;
            if (!CurrentLocked()) { FailLocked(kIOReturnAborted); return; }
        }
        cmp->ReadOPCR({.route = route}, plug, [self, plug](bool success, uint32_t pcr) {
            bool next = false, managed = false, mustQuarantine = false;
            {
                Guard guard(self->lock);
                if (self->sink.GetState() != State::Preparing) return;
                if (!self->CurrentLocked()) { self->FailLocked(kIOReturnAborted); return; }
                if (!success) { self->FailLocked(kIOReturnNotReady); return; }
                ASFW_LOG(Isoch, "[FoundationRX] oPCR guid=0x%llx gen=%u plug=%u raw=0x%08x",
                         self->route.guid, self->route.generation.value, plug, pcr);
                const bool online = ASFW::CMP::PCRBits::IsOnline(pcr);
                const bool broadcast = ASFW::CMP::PCRBits::IsBroadcast(pcr);
                const bool connected = ASFW::CMP::PCRBits::GetP2P(pcr) > 0;
                if (online && (broadcast || connected)) {
                    const auto channel = ASFW::CMP::PCRBits::GetChannel(pcr);
                    const auto channelEvidence = broadcast ? ChannelEvidence::BroadcastOPCR
                                                           : ChannelEvidence::ExistingP2POPCR;
                    self->sink.SetChannel(channel, channelEvidence);
                    ASFW_LOG(Isoch,
                             "[FoundationRX] observed-stream epoch=%llu gen=%u guid=%llx "
                             "ch=%u evidence=%u resource_owner=unverified not_allocated_here=1",
                             self->epoch, self->route.generation.value, self->route.guid,
                             channel, static_cast<unsigned>(channelEvidence));
                    // No remote connection change, guessed channel, FCP, or
                    // automatic tape motion. Receive only the observed stream.
                    if (!self->CurrentLocked()) { self->FailLocked(kIOReturnAborted); return; }
                    const auto result = self->isoch->StartPacketReceive(channel, *self->hardware, &self->sink);
                    if (result != kIOReturnSuccess) { self->FailLocked(result); return; }
                    self->armed = true;
                    if (!self->CurrentLocked()) {
                        const auto stopped = self->StopLocked(State::BusReset);
                        mustQuarantine = stopped != kIOReturnSuccess;
                    } else {
                        self->sink.SetState(State::Active);
                    }
                } else if (online) {
                    self->managedPlug = plug;
                    managed = true;
                } else if (plug + 1 < self->plugCount) {
                    next = true;
                } else {
                    self->FailLocked(kIOReturnNotReady);
                }
            }
            // Never acquire the runtime teardown path while holding our lock.
            if (mustQuarantine) self->quarantine();
            if (managed) self->AllocateManaged(self, pcr);
            if (next) self->ReadPlug(self, static_cast<uint8_t>(plug + 1));
        });
    }
};

Service::Service() : lock_(IOLockAlloc()) {}
Service::~Service() { if (lock_) IOLockFree(lock_); }

kern_return_t Service::Start(uint64_t owner, const DriverPolicy::FoundationRouteWire& wire,
    uint64_t driverInstance, ASFW::Driver::IsochService& isoch,
    std::shared_ptr<ASFW::Driver::HardwareInterface> hardware,
    std::shared_ptr<ASFW::Discovery::DeviceRegistry> registry,
    std::shared_ptr<ASFW::CMP::CMPClient> cmp,
    std::shared_ptr<ASFW::IRM::IRMClient> irm,
    ASFW::Async::FireWireBusImpl::LinkSpeedDecision speedDecision,
    std::function<void()> quarantine, SessionWire& output) {
    if (!lock_ || !owner || !hardware || !registry || !cmp || !irm || !quarantine)
        return kIOReturnNotReady;
    if (wire.version != DriverPolicy::kWireVersion || wire.size != sizeof(wire) || wire.reserved ||
        !driverInstance || wire.driverInstanceID != driverInstance) return kIOReturnBadArgument;
    const ASFW::Discovery::DeviceRouteToken route{wire.guid, wire.deviceIncarnation,
                                                  wire.routeEpoch, ASFW::FW::Generation{wire.generation}, wire.nodeID};
    if (!route || !registry->IsCurrent(route)) return kIOReturnNotReady;
    if (speedDecision.topologyValid &&
        (speedDecision.generation8 != route.generation.value ||
         speedDecision.targetNodeId != route.nodeId)) return kIOReturnNotReady;
    PendingActivity activity{DriverPolicy::ActivityKind::kReceive};
    if (!activity.Token()) return kIOReturnBusy;
    SessionOwner created;
    {
        Guard guard(lock_);
        // The original owner retains terminal status/ack identity until close,
        // allowing its final raw records and loss counters to be drained.
        if (session_) return kIOReturnBusy;
        if (!isoch.ReceiveContextsQuiesced() || nextEpoch_ == std::numeric_limits<uint64_t>::max())
            return kIOReturnBusy;
        created = SessionOwner(std::unique_ptr<Session>(new (std::nothrow) Session));
        if (!created || !created->lock) return kIOReturnNoResources;
        created->owner = owner;
        created->epoch = nextEpoch_++;
        created->route = route;
        created->isoch = &isoch;
        created->hardware = std::move(hardware);
        created->registry = std::move(registry);
        created->cmp = std::move(cmp);
        created->irm = std::move(irm);
        created->speedDecision = speedDecision;
        created->quarantine = std::move(quarantine);
        created->activityToken = activity.Token();
        IOBufferMemoryDescriptor* rawMemory = nullptr;
        const auto bytes = RawSink::RequiredBytes();
#ifdef ASFW_HOST_TEST
        if (Testing::failNextRingAllocation.exchange(false, std::memory_order_acq_rel))
            return kIOReturnNoMemory;
#endif
        auto result = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionOutIn, bytes, 64, &rawMemory);
        if (result != kIOReturnSuccess || !rawMemory) return result != kIOReturnSuccess ? result : kIOReturnNoMemory;
        created->memory = ASFW::Common::AdoptRetained(rawMemory);
        result = created->memory->SetLength(bytes);
        if (result != kIOReturnSuccess) return result;
        result = ASFW::Common::CreateSharedMapping(created->memory, created->mapping);
        if (result != kIOReturnSuccess) return result;
        if (!created->sink.Initialize(reinterpret_cast<void*>(created->mapping->GetAddress()),
                                      bytes, created->epoch, wire)) return kIOReturnInternalError;
        session_ = created;
        (void)activity.Transfer();
        output = {};
        output.epoch = created->epoch;
    }
    // Asynchronous read completion needs the default driver queue to run.
    created->BeginDiscovery(created);
    return kIOReturnSuccess;
}

kern_return_t Service::Stop(uint64_t owner, uint64_t epoch) {
    if (!lock_) return kIOReturnNotReady;
    SessionOwner target;
    kern_return_t result;
    {
        Guard guard(lock_);
        if (!session_) return kIOReturnNotReady;
        target = session_;
        Guard sessionGuard(target->lock);
        if (target->owner != owner || target->epoch != epoch) return kIOReturnNotPrivileged;
        result = target->StopLocked(State::Stopped);
    }
    if (result == kIOReturnSuccess) target->BeginCleanup(target);
    return result;
}
kern_return_t Service::StopAll(bool busReset) {
    if (!lock_) return kIOReturnNoResources;
    SessionOwner target;
    kern_return_t result;
    {
        Guard guard(lock_);
        if (!session_) return kIOReturnSuccess;
        target = session_;
        Guard sessionGuard(target->lock);
        result = target->StopLocked(busReset ? State::BusReset : State::Stopped);
    }
    if (result == kIOReturnSuccess) target->BeginCleanup(target);
    return result;
}
kern_return_t Service::ReleaseOwner(uint64_t owner) {
    if (!lock_) return kIOReturnNotReady;
    SessionOwner target;
    kern_return_t result;
    {
        Guard guard(lock_);
        if (!session_ || session_->owner != owner) return kIOReturnSuccess;
        target = session_;
        Guard sessionGuard(target->lock);
        result = target->StopLocked(State::Stopped);
        if (result == kIOReturnSuccess) session_.reset();
    }
    if (result == kIOReturnSuccess) target->BeginCleanup(target);
    return result;
}
kern_return_t Service::Snapshot(uint64_t owner, uint64_t epoch, StatusWire& output) const {
    if (!lock_) return kIOReturnNotReady;
    Guard guard(lock_);
    if (!session_) return kIOReturnNotReady;
    Guard sessionGuard(session_->lock);
    if (session_->owner != owner || session_->epoch != epoch) return kIOReturnNotPrivileged;
    output = session_->sink.Snapshot();
    return kIOReturnSuccess;
}
kern_return_t Service::Acknowledge(uint64_t owner, uint64_t epoch, uint64_t through) {
    if (!lock_) return kIOReturnNotReady;
    Guard guard(lock_);
    if (!session_) return kIOReturnNotReady;
    Guard sessionGuard(session_->lock);
    if (session_->owner != owner || session_->epoch != epoch) return kIOReturnNotPrivileged;
    return session_->sink.Acknowledge(through) ? kIOReturnSuccess : kIOReturnBadArgument;
}
kern_return_t Service::CopyMemory(uint64_t owner, uint64_t* options, IOMemoryDescriptor** memory) const {
    if (!lock_ || !memory || !options) return kIOReturnBadArgument;
    Guard guard(lock_);
    if (!session_) return kIOReturnNotReady;
    Guard sessionGuard(session_->lock);
    if (session_->owner != owner) return kIOReturnNotPrivileged;
    *options = kIOUserClientMemoryReadOnly;
    session_->memory->retain();
    *memory = session_->memory.get();
    return kIOReturnSuccess;
}
} // namespace RewindDV::Foundation::Receive
