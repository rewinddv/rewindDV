// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
// SPDX-License-Identifier: Apache-2.0
//
//  ASFWDriver.cpp
//  ASFWDriver
//
//  Created by Alexander Shabelnikov on 21.09.2025.
//

#define _LIBCPP_NO_ABI_TAG 1
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOInterruptDispatchSource.h>
#include <DriverKit/IOKitKeys.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOServiceNotificationDispatchSource.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSBoolean.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSSharedPtr.h>
#include <DriverKit/OSString.h>
#include <PCIDriverKit/IOPCIDevice.h>
#include <PCIDriverKit/IOPCIFamilyDefinitions.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <new>
#include <string>

#include "ASFWDriver.h"           // generated from .iig
#include "ASFWDriverUserClient.h" // generated from .iig

#include "Async/AsyncSubsystem.hpp"
#include "Async/DMAMemoryImpl.hpp"
#include "Async/Interfaces/IFireWireBus.hpp"
#include "Async/PacketHelpers.hpp"
#include "Async/ResponseCode.hpp"
#include "Audio/Core/AudioCoordinator.hpp"
#include "Audio/Core/AudioEndpointRuntime.hpp"
#include "Audio/Core/AudioRuntimeRegistry.hpp"
#include "Audio/Protocols/AVCStartReadiness.hpp"
#include "Audio/Protocols/IDeviceProtocol.hpp"
#include "Bus/BusResetCoordinator.hpp"
#include "Bus/SelfIDCapture.hpp"
#include "Common/DriverKitOwnership.hpp"
#include "ConfigROM/ConfigROMStager.hpp"
#include "ConfigROM/ROMReader.hpp"
#include "ConfigROM/ROMScanner.hpp"
#include "Controller/ControllerCore.hpp"
#include "Controller/ControllerStateMachine.hpp"
#include "Diagnostics/MetricsSink.hpp"
#include "Discovery/DeviceManager.hpp"
#include "Discovery/DeviceRegistry.hpp"
#include "Discovery/FWDevice.hpp"
#include "Hardware/HardwareInterface.hpp"
#include "Hardware/InterruptManager.hpp"
#include "Hardware/OHCIConstants.hpp"
#include "Hardware/RegisterMap.hpp"
#include "Bus/IRM/IRMClient.hpp"
#include "Isoch/Receive/IsochReceiveContext.hpp"
#include "Isoch/Transmit/IsochTransmitContext.hpp"
#include "Common/TimingUtils.hpp"
#include "Logging/LogConfig.hpp"
#include "Logging/Logging.hpp"
#include "Protocols/AVC/AVCDiscovery.hpp"
#include "Protocols/AVC/CMP/CMPClient.hpp"
#include "Protocols/AVC/FCPResponseRouter.hpp"
#include "Protocols/SBP2/Session/DriverKitSessionScheduler.hpp"
#include "Scheduling/Scheduler.hpp"
#include "Service/DriverContext.hpp"
#include "Service/LocalRequestWiring.hpp"
#include "SCSIController/SBP2BridgeHub.hpp"
#include "SCSIController/SBP2NubPublisher.hpp"
#include "SCSIController/SBP2TargetBridge.hpp"
#include "Shared/Memory/DMAMemoryManager.hpp"
#include "Shared/Completion/NativeSourceRetirement.hpp"
#include "ASFWAudioNub.h"

using namespace ASFW::Driver;

class ASFWDriverUserClient;

namespace {
constexpr uint64_t kAsyncWatchdogPeriodUsec = 1000; // 1 ms tick (hybrid: interrupt + timer backup)

[[nodiscard]] ASFW::IRM::IRMClient::LocalIRMAccess
MakeLocalIRMAccess(const std::shared_ptr<HardwareInterface>& hardware) {
    return ASFW::IRM::IRMClient::LocalIRMAccess{
        .read = [hardware](uint32_t selector) -> LocalCSRReadResult {
            if (!hardware) {
                return {LocalCSRLockResult::Status::HardwareUnavailable, 0};
            }
            return hardware->ReadLocalIRMResource(selector);
        },
        .compareSwap =
            [hardware](uint32_t selector,
                       uint32_t compareValue,
                       uint32_t newValue) -> LocalCSRLockResult {
            if (!hardware) {
                return {LocalCSRLockResult::Status::HardwareUnavailable, 0, false};
            }
            return hardware->CompareSwapLocalIRMResource(selector, compareValue, newValue);
        },
    };
}

#ifndef ASFW_HOST_TEST
void ArmProviderTerminationNotifications(ASFWDriver& driver, IOService* provider,
                                         ServiceContext& ctx) {
    uint64_t providerEntryId = 0;
    if (!provider || provider->GetRegistryEntryID(&providerEntryId) != kIOReturnSuccess ||
        providerEntryId == 0) {
        return;
    }

    auto matching = OSSharedPtr(OSDictionary::withCapacity(1), OSNoRetain);
    auto idNum = OSSharedPtr(OSNumber::withNumber(providerEntryId, 64), OSNoRetain);
    if (!matching || !idNum) {
        return;
    }

    matching->setObject(kIORegistryEntryIDKey, idNum.get());

    IOServiceNotificationDispatchSource* rawSource = nullptr;
    const kern_return_t notifyKr =
        IOServiceNotificationDispatchSource::Create(matching.get(), 0, ctx.workQueue.get(),
                                                   &rawSource);
    if (notifyKr != kIOReturnSuccess || rawSource == nullptr) {
        return;
    }

    auto source = OSSharedPtr(rawSource, OSNoRetain);

    OSAction* rawAction = nullptr;
    const kern_return_t actionKr = driver.CreateActionProviderNotificationReady(0, &rawAction);
    if (actionKr != kIOReturnSuccess || rawAction == nullptr) {
        return;
    }

    ctx.providerNotificationAction = OSSharedPtr(rawAction, OSNoRetain);
    ctx.providerNotifications = std::move(source);

    (void)ctx.providerNotifications->SetHandler(ctx.providerNotificationAction.get());
    (void)ctx.providerNotifications->SetEnableWithCompletion(true, nullptr);
    ASFW_LOG(Controller, "✅ Provider termination notifications armed (entryID=%llu)",
             providerEntryId);
}
#endif

// FCP / DICE / SBP-2 / CSR inbound request handlers are now registered centrally
// by ASFW::Service::WireLocalRequestDispatch (Service/LocalRequestWiring.cpp),
// which owns request tCodes 0x0/0x1/0x4/0x5 and routes by destination address.

void EnsureRomScanner(ServiceContext& ctx) {
    if (!ctx.deps.speedPolicy || !ctx.controller) {
        return;
    }

    if (!ctx.deps.romScanner) {
        OSSharedPtr<IODispatchQueue> discoveryQueue = nullptr;
        if (ctx.deps.scheduler) {
            discoveryQueue = ctx.deps.scheduler->Queue();
        }

        ASFW::Discovery::ROMScannerParams scannerParams{};
        ctx.deps.romScanner = std::make_shared<ASFW::Discovery::ROMScanner>(
            ctx.controller->Bus(), *ctx.deps.speedPolicy, scannerParams, discoveryQueue);
        ASFW_LOG(Controller, "✅ ROMScanner created");
    } else {
        ASFW_LOG(Controller, "Reusing existing ROMScanner instance");
    }

    if (ctx.deps.romScanner) {
        ctx.controller->AttachROMScanner(ctx.deps.romScanner);
    }
}

void QuarantineRuntime(ASFWDriver& service, ServiceContext& ctx, kern_return_t status) {
    ctx.receiveQuiesceFailure = status;
    ctx.receiveQuarantined.store(true, std::memory_order_release);
    if (!ctx.quarantineServiceRetained.exchange(true, std::memory_order_acq_rel)) {
        if (ctx.nativeDrainServiceRetained) ctx.nativeDrainServiceRetained = false;
        else service.retain();
    }
}

bool PrepareRuntimeTeardown(ASFWDriver& service, ServiceContext& ctx, const QuiescePlan& plan) {
    if (ctx.receiveQuarantined.load(std::memory_order_acquire)) {
        QuarantineRuntime(service, ctx, kIOReturnNotReady);
        return false;
    }
    const bool providerRevoked = plan.reason == QuiesceReason::kProviderRevoked ||
                                 (ctx.deps.hardware && ctx.deps.hardware->HardwareGone());

    // A provider notification can arrive while another quiesce is in progress.
    // Revoke first so no later software teardown can enter an OHCI MMIO scope.
    if (providerRevoked && ctx.deps.hardware) {
        ctx.deps.hardware->LatchProviderRevokedAndDrain();
        ASFW_LOG(Controller,
                 "[Lifecycle] runtime teardown mode=provider-revoked reason=%u",
                 static_cast<uint32_t>(plan.reason));
    }

    const bool resetWorkQuiesced = !ctx.deps.busReset || ctx.deps.busReset->RetireDeferredWork();
    const bool controllerWorkQuiesced = !ctx.controller || ctx.controller->RetireDeferredWork();
    const bool romWorkQuiesced = !ctx.deps.romScanner || ctx.deps.romScanner->RetireDeferredWork();
    const bool avcWorkQuiesced = !ctx.deps.avcDiscovery || ctx.deps.avcDiscovery->RetireDeferredWork();
    if (!resetWorkQuiesced || !controllerWorkQuiesced || !romWorkQuiesced || !avcWorkQuiesced) {
        QuarantineRuntime(service, ctx, kIOReturnBusy);
        ASFW_LOG_ERROR(Controller,
                       "[Lifecycle] CONTROLLER_CALLBACK_QUARANTINED; retaining runtime and service");
        return false;
    }

    // This is the first release gate. A failed receive stop must leave every
    // borrowed owner alive, including the service hosting DriverKit callbacks.
    // Revocation of MMIO access is deliberately not a DMA containment proof.
    kern_return_t captureStatus = kIOReturnSuccess;
#ifdef REWINDDV_FOUNDATION
    captureStatus = ctx.foundationReceive.StopAll();
#endif
    if (captureStatus == kIOReturnSuccess) captureStatus = ctx.dvCapture.StopAll(ctx.isoch);
    const kern_return_t isochStatus = captureStatus == kIOReturnSuccess
        ? ctx.isoch.StopAll() : captureStatus;
    if (isochStatus != kIOReturnSuccess) {
        QuarantineRuntime(service, ctx, isochStatus);
        ASFW_LOG_ERROR(Controller,
                       "[Lifecycle] RECEIVE_QUARANTINED kr=0x%x; retaining entire runtime and service; restart forbidden",
                       isochStatus);
        return false;
    }

    if (ctx.deps.asyncSubsystem) {
        ctx.deps.asyncSubsystem->BeginQuiesce();
        if (!ctx.deps.asyncSubsystem->RetirePostedWorkAndWait()) {
            QuarantineRuntime(service, ctx, kIOReturnBusy);
            ASFW_LOG_ERROR(Controller,
                           "[Lifecycle] ASYNC_CALLBACK_QUARANTINED; retaining entire runtime and service");
            return false;
        }
    }
    if (ctx.audioCoordinator) {
        ctx.audioCoordinator->BeginTeardown();
    }
    if (ctx.deps.avcDiscovery) {
        ctx.deps.avcDiscovery->Shutdown();
    }
    ASFW::Protocols::SBP2::SBP2BridgeHub::Clear();
    if (ctx.sbp2Bridge) {
        ctx.sbp2Bridge->Shutdown();
        ctx.sbp2Bridge.reset();
    }
    if (ctx.sbp2NubPublisher && plan.reason != QuiesceReason::kSystemSuspend &&
        plan.reason != QuiesceReason::kWakeRebuild) {
        ctx.sbp2NubPublisher->Shutdown();
        ctx.sbp2NubPublisher.reset();
    }

    ctx.watchdog.Stop();
    return true;
}

bool ExecuteRuntimeTeardown(ASFWDriver& service, ServiceContext& ctx, const QuiescePlan& plan) {
    // No callback-owned or borrowed graph may be released before every native
    // source has positively reported cancellation (disable for suspend IRQ).
    if (!ctx.nativeDrain || !ctx.nativeDrain->AllTerminal() ||
        ctx.nativeDrain->Quarantined() || ctx.receiveQuarantined.load(std::memory_order_acquire))
        return false;

    ctx.statusPublisher.BindListener(nullptr);
    ctx.statusPublisher.Publish(ctx.controller.get(), ctx.deps.asyncController.get(),
                                SharedStatusReason::Disconnect);

    // Async retirement is a release gate, just like isoch receive retirement.
    // Do not free other DMA buffers, detach PCI, reset the graph or call the
    // superclass Stop when a context's hardware ownership remains unknown.
    if (ctx.deps.asyncSubsystem && !ctx.deps.asyncSubsystem->Stop()) {
        QuarantineRuntime(service, ctx, kIOReturnNotReady);
        ASFW_LOG_ERROR(Controller,
                       "[Lifecycle] ASYNC_DMA_QUARANTINED; retaining entire runtime and service; restart forbidden");
        return false;
    }
    // Shutdown and Stop above can themselves cancel an issued request and
    // create wire uncertainty. Check only after those producers are terminal;
    // a fresh allocator after suspend/rebuild would otherwise erase the fence.
    // Neither a local soft reset nor a new Self-ID proves remote FCP retirement.
    if (ctx.deps.asyncSubsystem && ctx.deps.asyncSubsystem->HasUncertainWire()) {
        QuarantineRuntime(service, ctx, kIOReturnNotReady);
        ASFW_LOG_ERROR(Controller,
                       "[Lifecycle] ASYNC_WIRE_QUARANTINED; preserving runtime; automatic rebuild forbidden");
        return false;
    }
    const bool hardwareGone = ctx.deps.hardware && ctx.deps.hardware->HardwareGone();
    // Surprise removal skips all final register cleanup. The teardown calls
    // above are software-safe and their old direct-MMIO helpers are revoked.
    if (!hardwareGone && plan.completedStartStage >= StartStage::kProviderOpened) {
        if (ctx.deps.selfId && ctx.deps.hardware) {
            ctx.deps.selfId->Disarm(*ctx.deps.hardware);
        }
        if (ctx.deps.configRomStager && ctx.deps.hardware) {
            ctx.deps.configRomStager->Teardown(*ctx.deps.hardware);
        }
    } else if (hardwareGone) {
        ASFW_LOG(Controller,
                 "[Lifecycle] runtime teardown hardware-gone action=skip-final-mmio-cleanup");
    }
    if (ctx.deps.selfId) {
        ctx.deps.selfId->ReleaseBuffers();
    }
    if (ctx.controller) {
        ctx.controller->Stop();
    }
    if (ctx.deps.hardware) {
        ctx.deps.hardware->Detach();
    }
    return true;
}

void ReleaseQuiescedRuntime(ServiceContext& ctx, const QuiescePlan& plan) {
    if (!ctx.lifecycle || !plan.runTeardown ||
        ctx.receiveQuarantined.load(std::memory_order_acquire)) {
        return;
    }
    ctx.lifecycle->CompleteQuiesce(plan, "runtime teardown complete", mach_absolute_time());
    const auto finalState = ctx.lifecycle->CurrentState();
    // The native continuation runs on Default after the start/stop callback has
    // returned, so even failed-start resources have no live bring-up stack.
    ctx.Reset(finalState == ControllerState::kSuspended ? ServiceContext::ResetMode::ForSuspend
                                                         : ServiceContext::ResetMode::Full);
}
} // namespace

bool ASFWDriver::init() {
    if (!super::init())
        return false;
    if (!ivars) {
        ivars = IONewZero(ASFWDriver_IVars, 1);
        if (!ivars)
            return false;
    }
    if (!ivars->context) {
        ivars->context = IONew(ServiceContext, 1);
        if (!ivars->context)
            return false;
        // IONew is raw IOMalloc — it does NOT run constructors. Placement-new so
        // ServiceContext's members are actually initialized (config defaults,
        // OSSharedPtr/shared_ptr/atomics, StatusPublisher/IsochService/...) instead
        // of relying on zero-filled pages. Paired with ~ServiceContext() in free().
        new (ivars->context) ServiceContext();
    }
    return true;
}

void ASFWDriver::free() {
    if (ivars) {
        if (ivars->context) {
            // A failed Stop retains the service before free can be entered.
            // If the framework nevertheless reaches free, deliberately leak
            // the complete graph and service storage. Never resurrect refcount
            // zero here or destroy DMA-visible memory without proof.
            if (ivars->context->receiveQuarantined.load(std::memory_order_acquire) ||
                !ivars->context->isoch.ReceiveContextsQuiesced() ||
                (ivars->context->nativeDrain &&
                 (!ivars->context->nativeDrain->AllTerminal() ||
                  ivars->context->nativeDrain->Quarantined()))) {
                ASFW_LOG_ERROR(Controller,
                               "[Lifecycle] free containment backstop: preserving service/runtime storage");
                return;
            }
            ivars->context->Reset();
            if (ivars->context->receiveQuarantined.load(std::memory_order_acquire)) return;
            ivars->context->~ServiceContext(); // pair with placement-new in init()
            IOSafeDeleteNULL(ivars->context, ServiceContext, 1);
        }
        IODelete(ivars, ASFWDriver_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

kern_return_t IMPL(ASFWDriver, Start) {
    auto kr = Start(provider, SUPERDISPATCH);
    if (kr != kIOReturnSuccess)
        return kr;
    if (!ivars || !ivars->context)
        return kIOReturnNoMemory;
    ivars->powerProvider = provider;
    return StartRuntime(provider);
}

kern_return_t ASFWDriver::StartRuntime(IOService* provider) {
    if (!ivars || !ivars->context)
        return kIOReturnNoMemory;
    kern_return_t kr = kIOReturnSuccess;
    auto& ctx = *ivars->context;
    if (ctx.receiveQuarantined.load(std::memory_order_acquire)) return kIOReturnNotReady;
    if (ivars->stopCompleted) return kIOReturnNotReady;
    if (ctx.nativeDrain || ivars->stopPending) return kIOReturnBusy;
    DriverWiring::EnsureDeps(this, ctx);
    if (!ctx.lifecycle || !ctx.lifecycle->BeginStart("runtime start", mach_absolute_time())) {
        return kIOReturnBusy;
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kDependenciesReady);
    const auto failStart = [this, &ctx](kern_return_t status, const char* detail) {
        if (ctx.lifecycle) {
            if (const auto plan = ctx.lifecycle->BeginFailedStart(detail, mach_absolute_time())) {
                if (plan->runTeardown) {
                    if (PrepareRuntimeTeardown(*this, ctx, *plan)) {
                        ctx.nativeDrainPlan = *plan;
                        BeginNativeRuntimeDrain();
                    }
                }
            }
        }
        return status;
    };
    bool traceProperty = false;
    if (OSDictionary* serviceProperties = nullptr;
        CopyProperties(&serviceProperties) == kIOReturnSuccess && serviceProperties != nullptr) {
        if (auto property = serviceProperties->getObject("ASFWTraceDMACoherency")) {
            if (auto booleanProp = OSDynamicCast(OSBoolean, property)) {
                traceProperty = (booleanProp == kOSBooleanTrue);
            } else if (auto numberProp = OSDynamicCast(OSNumber, property)) {
                traceProperty = numberProp->unsigned32BitValue() != 0;
            } else if (auto stringProp = OSDynamicCast(OSString, property)) {
                traceProperty = stringProp->isEqualTo("1") || stringProp->isEqualTo("true") ||
                                stringProp->isEqualTo("TRUE");
            }
        }
        serviceProperties->release();
    }
    ASFW_LOG(Controller, "ASFWDriver::Start(): ASFWTraceDMACoherency property=%{public}s",
             traceProperty ? "true" : "false");
    if (auto statusKr = ctx.statusPublisher.Prepare(); statusKr != kIOReturnSuccess) {
        return failStart(statusKr, "status publisher prepare failed");
    }
    kr = DriverWiring::PrepareQueue(*this, ctx);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "dispatch queue prepare failed");
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kQueueReady);

    kr = ctx.deps.hardware->Attach(this, provider);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "provider attach failed");
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kProviderOpened);

#ifndef ASFW_HOST_TEST
    // Arm only after Attach succeeds. A revocation can then only fence an
    // already-open hardware incarnation; it cannot race a later Attach().
    ArmProviderTerminationNotifications(*this, provider, ctx);
#endif
    // A successful timebase query is required before timestamp consumers run.
    // Zero is a valid timestamp, so numeric conversion cannot signal failure.
    if (!ASFW::Timing::initializeHostTimebase()) {
        return failStart(kIOReturnNotReady, "host timebase unavailable");
    }

    kr = DriverWiring::PrepareInterrupts(*this, provider, ctx);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "interrupt preparation failed");
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kInterruptSourceReady);

    // Initialize AsyncSubsystem (requires hardware, workQueue, and a completion action)
    if (ctx.deps.asyncSubsystem && ctx.deps.hardware && ctx.workQueue && ctx.interruptAction) {
        kr = ctx.deps.asyncSubsystem->Start(*ctx.deps.hardware, this, ctx.workQueue.get(),
                                            ctx.interruptAction.get());
        if (kr != kIOReturnSuccess) {
            ASFW_LOG(Controller, "AsyncSubsystem::Start() failed: 0x%08x", kr);
            return failStart(kr, "async subsystem start failed");
        }
        const bool traceActive = ASFW::Shared::DMAMemoryManager::IsTracingEnabled();
        ASFW_LOG(Controller,
                 "ASFWDriver::Start(): DMA coherency tracing %{public}s (requested=%{public}s)",
                 traceActive ? "ENABLED" : "disabled", traceProperty ? "true" : "false");
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kAsyncReady);

    kr = DriverWiring::PrepareWatchdog(*this, ctx);
    if (kr != kIOReturnSuccess) {
        ASFW_LOG(Controller, "Failed to prepare async watchdog: 0x%08x", kr);
        return failStart(kr, "watchdog preparation failed");
    }
    ScheduleAsyncWatchdog(kAsyncWatchdogPeriodUsec);

    // ControllerCore takes its own Dependencies copy. The reset coordinator
    // must receive the prepared timer in that copy, not a later context update.
    kr = DriverWiring::PrepareControlTimer(*this, ctx);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "control timer preparation failed");
    }

    ctx.controller = std::make_shared<ControllerCore>(ctx.config, ctx.rolePolicy, ctx.deps);

    // FCP shares the driver's cancellable control-plane timer with SBP-2. It
    // must exist before AV/C discovery constructs per-unit FCP transports.
    kr = DriverWiring::EnsureSbp2Deps(*this, ctx);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "SBP-2 dependency preparation failed");
    }

    if (!ctx.deps.avcDiscovery && ctx.deps.deviceManager && ctx.deps.deviceRegistry) {
        auto& bus = ctx.controller->Bus();
        ctx.deps.avcDiscovery = std::make_shared<ASFW::Protocols::AVC::AVCDiscovery>(
            this, *ctx.deps.deviceRegistry, *ctx.deps.deviceManager, bus, bus, *ctx.deps.sbp2SessionScheduler,
            ctx.audioCoordinator.get());
        ctx.controller->SetAVCDiscovery(ctx.deps.avcDiscovery);
        ASFW_LOG(Controller, "✅ AVCDiscovery initialized");
    }

    if (!ctx.deps.fcpResponseRouter && ctx.deps.avcDiscovery) {
        ctx.deps.fcpResponseRouter =
            std::make_shared<ASFW::Protocols::AVC::FCPResponseRouter>(*ctx.deps.avcDiscovery);
        ctx.controller->SetFCPResponseRouter(ctx.deps.fcpResponseRouter);
        ASFW_LOG(Controller, "✅ FCPResponseRouter initialized");
    }

    // Assemble the single inbound request dispatch (CSR / FCP / DICE / SBP-2)
    // after all control-plane responders have been constructed.
    ASFW::Service::WireLocalRequestDispatch(ctx);
    EnsureRomScanner(ctx);

    kr = ctx.controller->Start(provider);
    if (kr != kIOReturnSuccess) {
        return failStart(kr, "controller start failed");
    }
    ctx.lifecycle->MarkStageComplete(StartStage::kControllerReady);

    if (!ctx.deps.irmClient) {
        ctx.deps.irmClient = std::make_shared<ASFW::IRM::IRMClient>(
            ctx.controller->Bus(),
            MakeLocalIRMAccess(ctx.deps.hardware));
        ctx.controller->SetIRMClient(ctx.deps.irmClient);
        ASFW_LOG(Controller, "✅ IRMClient initialized");
    }

    if (!ctx.deps.cmpClient) {
        if (!ctx.deps.deviceRegistry) {
            return failStart(kIOReturnNotReady, "device registry unavailable for CMP");
        }
        ctx.deps.cmpClient = std::make_shared<ASFW::CMP::CMPClient>(ctx.controller->Bus(),
                                                                      ctx.controller->Bus(),
                                                                      *ctx.deps.deviceRegistry);
        ctx.controller->SetCMPClient(ctx.deps.cmpClient);
        ASFW_LOG(Controller, "✅ CMPClient initialized");
    }

    if (ctx.audioCoordinator) {
        ctx.audioCoordinator->SetCMPClient(ctx.deps.cmpClient.get());
    }

    // Allocate the queryable log ring before configuration so its
    // initialization trace (and everything after) is captured. Appends
    // before this point are silent no-ops by design.
    ASFW::Logging::LogRing::Shared().Initialize();
    ASFW::LogConfig::Shared().Initialize(this);

    ctx.statusPublisher.Publish(ctx.controller.get(), ctx.deps.asyncController.get(),
                                SharedStatusReason::Boot);

    const uint32_t initialMask = IntMaskBits::kMasterIntEnable | kBaseIntMask;
    ctx.deps.hardware->IntMaskSet(initialMask);

    // Register once per service instance: StartRuntime() is re-entered on wake.
    // SBP-2 nubs are published separately and only for discovered SBP-2 units.
    if (!ivars->serviceRegistered) {
        RegisterService();
        ivars->serviceRegistered = true;
    }

    if (!ctx.lifecycle->CompleteStart("runtime start complete", mach_absolute_time())) {
        return failStart(kIOReturnError, "runtime start completion rejected");
    }

    // NOTE: do NOT call ChangePowerState/SetPowerOverride here. The kernel
    // joins a dext into the PM tree only after Start() returns
    // (xnu IOUserServer.cpp serviceStarted -> serviceJoinPMTree), so PM calls
    // made during Start() are dropped: powerOverrideOnPriv returns
    // IOPMNotYetInitialized (surfaced as kIOReturnError) and
    // ChangePowerState_Impl silently discards the same failure. The power
    // desire is pinned in SetPowerState() on the first On callback instead,
    // which the kernel delivers right after the PM join.

    ASFW_LOG(Controller, "ASFWDriver::Start() complete");

    return kIOReturnSuccess;
}

kern_return_t IMPL(ASFWDriver, Stop) {
    // Native Stop and its finalizer are serialized on Default. This receipt
    // also covers a duplicate delivered after the native drain has completed.
    if (ivars && ivars->stopCompleted) return ivars->stopResult;
    if (ivars && !ivars->stopPending) {
        ivars->stopPending = true;
        ivars->stopProvider = provider;
        if (provider) provider->retain();
    }
    // Terminal service Stop can precede the provider notification on Default.
    // Close MMIO before any teardown (including a missing lifecycle queue).
    // This is access revocation, NOT proof of removal or DMA containment:
    // the existing retirement gates must retain an unproved runtime.
    if (ivars && ivars->context && ivars->context->deps.hardware) {
        ivars->context->deps.hardware->LatchProviderRevokedAndDrain();
    }
    RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kProviderRevoked));
    if (ivars && ivars->context &&
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return ivars->context->receiveQuiesceFailure.load(std::memory_order_acquire);
    }
    if (ivars && ivars->context && ivars->context->nativeDrain) return kIOReturnSuccess;
    // A service that never created native sources still has no drain to await.
    return CompleteServiceStop(provider);
}

kern_return_t ASFWDriver::CompleteServiceStop(IOService* provider) {
    if (!ivars) return Stop(provider, SUPERDISPATCH);
    if (ivars->stopCompleted) return ivars->stopResult;
    // Keep both service and the original provider alive through superclass
    // completion. Publish the receipt before calling out, including reentry.
    retain();
    auto* retainedProvider = ivars->stopProvider;
    ivars->stopProvider = nullptr;
    ivars->stopPending = false;
    ivars->stopCompleted = true;
    ivars->stopResult = kIOReturnBusy;
    ivars->powerProvider = nullptr;
    ivars->powerAcknowledgementPending = false;
    ivars->wakeRebuildPending = false;
    const auto result = Stop(retainedProvider ? retainedProvider : provider, SUPERDISPATCH);
    ivars->stopResult = result;
    if (retainedProvider) retainedProvider->release();
    release();
    return result;
}

void ASFWDriver::RequestRuntimeQuiesce(uint32_t rawReason) {
    // LOCALONLY callers include user-client queues. Root resource mutation and
    // every native finalizer run on Default; retain only the service across this
    // hop, rather than borrowing a runtime that a prior request could release.
    IODispatchQueue* rawQueue = nullptr;
    if (CopyDispatchQueue("Default", &rawQueue) != kIOReturnSuccess || !rawQueue) {
        // Without the lifecycle queue, no borrowed graph can safely be
        // inspected or torn down. Only the immutable context address and its
        // atomic containment fields are touched on this caller's queue.
        if (ivars && ivars->context) {
            auto& failedContext = *ivars->context;
            retain();
            if (failedContext.quarantineServiceRetained.exchange(true, std::memory_order_acq_rel))
                release();
            failedContext.receiveQuiesceFailure.store(kIOReturnNotReady, std::memory_order_release);
            failedContext.receiveQuarantined.store(true, std::memory_order_release);
            ASFW_LOG_ERROR(Controller, "[Lifecycle] lifecycle queue unavailable; retaining runtime/service; restart forbidden");
        }
        return;
    }
    auto queue = OSSharedPtr(rawQueue, OSNoRetain);
    if (!queue->OnQueue()) {
        retain();
        queue->DispatchAsync(^{ RequestRuntimeQuiesce(rawReason); release(); });
        return;
    }
    if (!ivars || !ivars->context) {
        return;
    }
    auto& ctx = *ivars->context;
    if (!ctx.lifecycle) {
        return;
    }

    const auto reason = static_cast<QuiesceReason>(rawReason);
    const auto plan = ctx.lifecycle->BeginQuiesce(reason, "runtime quiesce", mach_absolute_time());
    if (!plan.has_value()) {
        return;
    }

    // A revocation request that races an already-running planned teardown must
    // still fence OHCI immediately. The active executor will observe its
    // state as Revoked before publishing its final transition.
    if (plan->revokeImmediately && ctx.deps.hardware) {
        ctx.deps.hardware->LatchProviderRevokedAndDrain();
    }
    if (plan->runTeardown) {
        if (PrepareRuntimeTeardown(*this, ctx, *plan)) {
            ctx.nativeDrainPlan = *plan;
            BeginNativeRuntimeDrain();
        }
    }
}

void ASFWDriver::BeginNativeRuntimeDrain() {
    if (!ivars || !ivars->context) return;
    auto& ctx = *ivars->context;
    if (ctx.nativeDrain || !ctx.nativeDrainPlan) return;

    // One explicit service retain covers all native callbacks and the complete
    // borrowed runtime. On failure it becomes the permanent quarantine retain.
    if (!ctx.nativeDrainServiceRetained) {
        retain();
        ctx.nativeDrainServiceRetained = true;
    }
    ctx.nativeDrainProvider = OSSharedPtr(ivars->powerProvider, OSRetain);
    auto drain = std::make_shared<ASFW::Shared::NativeCallbackDrain>();
    ctx.nativeDrain = drain;

    if (!ctx.nativeDrainQueue) {
        IODispatchQueue* rawQueue = nullptr;
        const auto kr = IODispatchQueue::Create("com.rewinddv.native-retirement",
                                               kIODispatchQueueReentrant, 0, &rawQueue);
        if (kr == kIOReturnSuccess && rawQueue) {
            ctx.nativeDrainQueue = OSSharedPtr(rawQueue, OSNoRetain);
        } else {
            drain->Quarantine();
        }
    }
    if (!ctx.workQueue) {
        IODispatchQueue* rawQueue = nullptr;
        if (CopyDispatchQueue("Default", &rawQueue) == kIOReturnSuccess && rawQueue)
            ctx.workQueue = OSSharedPtr(rawQueue, OSNoRetain);
        else drain->Quarantine();
    }
    if (!ASFW::Timing::initializeHostTimebase()) drain->Quarantine();
    if (drain->Quarantined()) {
        QuarantineRuntime(*this, ctx, kIOReturnNoResources);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] NATIVE_CALLBACK_QUARANTINED supervisor unavailable; retaining runtime/service");
        return;
    }

    const auto supervisor = ctx.nativeDrainQueue;
    const std::weak_ptr<ASFW::Shared::NativeCallbackDrain> weakDrain = drain;
    drain->SetNotifier([supervisor, weakDrain] {
        supervisor->DispatchAsync(^{
            if (const auto state = weakDrain.lock()) (void)supervisor->Wakeup(state.get());
        });
    });

    // Start supervision before invoking the platform primitives, so even a
    // stalled cancellation request cannot extend the ownership deadline. The
    // ledger becomes quarantined off Default and continues owning the graph.
    // DriverKit 27 SleepWithDeadline releases this reentrant supervisor queue;
    // it never blocks Default or the callbacks needed for the native barrier.
    constexpr uint64_t kNativeDrainTimeoutNs = 1'000'000'000ULL;
    const uint64_t deadline = mach_continuous_time() + ASFW::Timing::nanosToHostTicks(kNativeDrainTimeoutNs);
    const auto lifecycleQueue = ctx.workQueue;
    supervisor->DispatchAsync(^{
        while (!drain->AllTerminal() && !drain->Quarantined()) {
            if (mach_continuous_time() >= deadline) { drain->Quarantine(); break; }
            const auto kr = supervisor->SleepWithDeadline(drain.get(),
                kIOTimerClockMachContinuousTime, deadline);
            if (kr != kIOReturnSuccess && !drain->AllTerminal()) {
                drain->Quarantine();
                break;
            }
        }
        lifecycleQueue->DispatchAsync(^{ CompleteNativeRuntimeDrain(); });
    });

    const bool suspend = ctx.nativeDrainPlan->reason == QuiesceReason::kSystemSuspend ||
                         ctx.nativeDrainPlan->reason == QuiesceReason::kWakeRebuild;
    ctx.BeginProviderNativeRetirement(drain);
    ctx.watchdog.BeginNativeRetirement(drain);
    if (ctx.deps.sbp2SessionScheduler) ctx.deps.sbp2SessionScheduler->BeginNativeRetirement(drain);
    if (ctx.deps.interrupts) ctx.deps.interrupts->BeginNativeRetirement(drain, suspend);
    if (ctx.deps.asyncSubsystem) ctx.deps.asyncSubsystem->BeginNativeRetirement(drain);

    // Wake verification belongs to the service but may otherwise act on a new
    // runtime after sleep/rebuild. Drain it on every root transition and create
    // a fresh action if a later wake needs verification.
    OSSharedPtr<IOTimerDispatchSource> wakeTimer(ivars->wakeVerifyTimer, OSNoRetain);
    OSSharedPtr<OSAction> wakeAction(ivars->wakeVerifyAction, OSNoRetain);
    ASFW::Shared::RetireNativeSource(wakeTimer, wakeAction, drain);
    ivars->wakeVerifyTimer = wakeTimer.detach();
    ivars->wakeVerifyAction = wakeAction.detach();
    drain->Seal();
    ASFW_LOG(Controller,
             "[Lifecycle] native drain sealed: sources=%u terminal=%u ledger_owner_refs=%u",
             unsigned(drain->RegisteredSources()), unsigned(drain->TerminalSources()),
             unsigned(drain->RetainedOwnerReferences()));
}

void ASFWDriver::CompleteNativeRuntimeDrain() {
    if (!ivars || !ivars->context) return;
    auto& ctx = *ivars->context;
    const auto drain = ctx.nativeDrain;
    if (!drain || !ctx.nativeDrainPlan) return;
    if (drain->Quarantined() || !drain->AllTerminal()) {
        QuarantineRuntime(*this, ctx, kIOReturnTimeout);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] NATIVE_CALLBACK_QUARANTINED cancel failed/deadline; retaining runtime/service; restart forbidden");
        return;
    }

    auto plan = *ctx.nativeDrainPlan;
    const bool wasSuspend = plan.reason == QuiesceReason::kSystemSuspend ||
                            plan.reason == QuiesceReason::kWakeRebuild;
    const bool revoked = ctx.lifecycle && ctx.lifecycle->CurrentState() == ControllerState::kRevoked;
    if (wasSuspend && (ivars->stopPending || revoked)) {
        // The first wave only disabled IRQ registration. Termination/revocation
        // arriving during that wave requires one additional terminal Cancel,
        // while the same service retain and unchanged runtime remain owned.
        plan.reason = revoked ? QuiesceReason::kProviderRevoked : QuiesceReason::kPlannedStop;
        ctx.nativeDrainPlan = plan;
        ctx.nativeDrain.reset();
        BeginNativeRuntimeDrain();
        return;
    }

    if (!ExecuteRuntimeTeardown(*this, ctx, plan)) {
        QuarantineRuntime(*this, ctx, kIOReturnNotReady);
        return;
    }
    ReleaseQuiescedRuntime(ctx, plan);
    if (ctx.receiveQuarantined.load(std::memory_order_acquire)) {
        QuarantineRuntime(*this, ctx, kIOReturnNotReady);
        return;
    }
    ctx.nativeDrainPlan.reset();
    ctx.nativeDrain.reset();
    ctx.nativeDrainProvider.reset();
    ctx.nativeDrainServiceRetained = false;
    ASFW_LOG(Controller,
             "[Lifecycle] native sources terminal; runtime teardown complete; sources=%u terminal=%u ledger_owner_refs=%u runtime_roots_empty=%u",
             unsigned(drain->RegisteredSources()), unsigned(drain->TerminalSources()),
             unsigned(drain->RetainedOwnerReferences()),
             unsigned(!ctx.controller && !ctx.deps.hardware && !ctx.deps.asyncSubsystem &&
                      !ctx.deps.romScanner && !ctx.deps.avcDiscovery));

    if (ivars->stopPending) {
        (void)CompleteServiceStop(ivars->stopProvider);
        release();
        return;
    }

    const bool powerPending = ivars->powerAcknowledgementPending;
    const uint32_t powerFlags = ivars->pendingPowerFlags;
    ivars->powerAcknowledgementPending = false;
    const bool resume = (powerPending && (powerFlags & kIOServicePowerCapabilityOn)) ||
                        ivars->wakeRebuildPending;
    const uint64_t verifyAttempt = ivars->wakeRebuildPending ? ivars->wakeVerifyAttempt : 1;
    ivars->wakeRebuildPending = false;
    if (resume && ctx.lifecycle && ctx.lifecycle->CurrentState() == ControllerState::kSuspended &&
        ivars->powerProvider) {
        if (StartRuntime(ivars->powerProvider) == kIOReturnSuccess) ScheduleWakeVerify(verifyAttempt);
    }
    if (powerPending) {
        if (ctx.nativeDrain) {
            // A failed resume can open its own failed-start drain. That new
            // continuation owns the PM acknowledgement until it is terminal.
            ivars->powerAcknowledgementPending = true;
            ivars->pendingPowerFlags = powerFlags;
        } else if (!ctx.receiveQuarantined.load(std::memory_order_acquire)) {
            (void)SetPowerState(powerFlags, SUPERDISPATCH);
        }
    }
    release();
}

// Wake verification cadence. 3s puts the first check well past the dark-wake →
// full-wake transition (~2s observed) while staying invisible to the user; 5
// attempts bound the self-heal at ~15s.
static constexpr uint64_t kWakeVerifyDelayNs = 3'000'000'000ull;
static constexpr uint64_t kWakeVerifyMaxAttempts = 5;

kern_return_t IMPL(ASFWDriver, SetPowerState) {
    const bool poweredOn = (powerFlags & kIOServicePowerCapabilityOn) != 0;
    ASFW_LOG(Controller, "SetPowerState: powerFlags=0x%08x (%{public}s)", powerFlags,
             poweredOn ? "on" : "sleep/low");

    if (ivars) {
        if (ivars->context && ivars->context->receiveQuarantined.load(std::memory_order_acquire))
            return kIOReturnNotReady;
        if (ivars->context && ivars->context->nativeDrain) {
            ivars->powerAcknowledgementPending = true;
            ivars->pendingPowerFlags = powerFlags;
            return kIOReturnSuccess;
        }
        if (!poweredOn) {
            // Sleep: quiesce everything and reset the runtime while the
            // controller still answers MMIO. The silicon loses its programmed
            // state in low power (Linux ohci.c pci_suspend does software_reset;
            // Apple gates all hardware access while asleep).
            if (ivars->context && ivars->context->lifecycle &&
                ivars->context->lifecycle->CurrentState() == ControllerState::kRunning) {
                ASFW_LOG(Controller, "SetPowerState: quiescing runtime for sleep");
                ivars->powerAcknowledgementPending = true;
                ivars->pendingPowerFlags = powerFlags;
                RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kSystemSuspend));
                if (ivars->context->receiveQuarantined.load(std::memory_order_acquire))
                    return kIOReturnNotReady;
                if (ivars->context->nativeDrain) return kIOReturnSuccess;
                ivars->powerAcknowledgementPending = false;
            }
        } else {
            // Pin our power desire to full-on. A bus controller must stay
            // powered even with no devices attached (plug detection needs a
            // programmed, interrupting controller). The audio driver matched on
            // our nub is a PM-tree child; when the last nub terminates, the
            // child's demand vanishes and the system sends SetPowerState(0)
            // ~1ms later — which tore down the runtime, leaving the controller
            // dead until the PM domain happened to repower minutes later.
            // SetPowerOverride makes our power state governed solely by our own
            // desire (children ignored), so capability 0 then means real system
            // sleep only. These calls only work once the PM join has happened
            // (after Start() returns) — this callback is the earliest reliable
            // point. Idempotent, so unconditional on every On is fine.
            const kern_return_t pmKr = ChangePowerState(kIOServicePowerCapabilityOn);
            const kern_return_t ovKr = SetPowerOverride(true);
            ASFW_LOG(Controller,
                     "SetPowerState: pin desire On -> 0x%08x, override -> 0x%08x",
                     pmKr, ovKr);
        }
        if (poweredOn && ivars->context && ivars->context->lifecycle &&
            ivars->context->lifecycle->CurrentState() == ControllerState::kSuspended) {
            // Wake: rebuild the runtime from scratch — full OHCI re-init ending
            // in a forced bus reset, after which normal discovery re-publishes
            // devices (Linux pci_resume runs the same ohci_enable as cold probe).
            if (ivars->powerProvider) {
                ASFW_LOG(Controller, "SetPowerState: wake - rebuilding runtime");
                const kern_return_t kr = StartRuntime(ivars->powerProvider);
                if (kr != kIOReturnSuccess) {
                    ASFW_LOG(Controller,
                             "SetPowerState: ❌ wake runtime rebuild failed: 0x%08x", kr);
                } else {
                    // The On callback can arrive during dark wake; verify the
                    // rebuild actually took once the platform has settled.
                    ScheduleWakeVerify(1);
                }
            } else {
                ASFW_LOG(Controller, "SetPowerState: wake with no provider; skipping rebuild");
            }
        }
    }

    if (ivars && ivars->context) {
        if (ivars->context->receiveQuarantined.load(std::memory_order_acquire)) return kIOReturnNotReady;
        if (ivars->context->nativeDrain) {
            ivars->powerAcknowledgementPending = true;
            ivars->pendingPowerFlags = powerFlags;
            return kIOReturnSuccess;
        }
    }
    return SetPowerState(powerFlags, SUPERDISPATCH);
}

void ASFWDriver::VerifyWakeRuntime(uint64_t attempt) {
    if (!ivars || !ivars->context || !ivars->context->lifecycle ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire) ||
        !ivars->context->lifecycle->AdmitsNormalWork()) {
        return; // slept again (or tearing down) before the check fired
    }
    auto& ctx = *ivars->context;
    if (!ctx.deps.hardware || !ctx.deps.busReset) {
        return;
    }

    // The wake rebuild always ends in a forced bus reset, and resetCount only
    // advances via the full interrupt path (IRQ → Self-ID → coordinator). A
    // completed reset therefore proves interrupt delivery end to end.
    const uint32_t resets = ctx.deps.busReset->Metrics().resetCount;
    uint32_t hcControl = 0;
    uint32_t intEvent = 0;
    {
        auto access = ctx.deps.hardware->TryBeginAccess();
        if (!access) {
            return;
        }
        hcControl = access.Read(Register32::kHCControl);
        intEvent = access.Read(Register32::kIntEvent);
    }
    const bool mmioAlive = (hcControl != 0xFFFFFFFFu);
    const bool linkEnabled = mmioAlive && (hcControl & HCControlBits::kLinkEnable);

    if (resets > 0 && linkEnabled) {
        ASFW_LOG(Controller, "Wake verify: ✅ alive (resets=%u HCControl=0x%08x attempt=%llu)",
                 resets, hcControl, attempt);
        return;
    }

    // Distinguish the failure mode for the log: busReset pending in IntEvent
    // with resetCount==0 means the reset happened but the IRQ never arrived
    // (interrupt path dead); linkEnable clear means the controller was reset
    // under us after the rebuild; 0xFFFFFFFF means MMIO itself is gone.
    if (!mmioAlive) {
        intEvent = 0;
    }
    ASFW_LOG(Controller,
             "Wake verify: ❌ dead controller (resets=%u HCControl=0x%08x IntEvent=0x%08x "
             "attempt=%llu/%llu) - rebuilding",
             resets, hcControl, intEvent, attempt, kWakeVerifyMaxAttempts);

    if (attempt >= kWakeVerifyMaxAttempts) {
        ASFW_LOG(Controller, "Wake verify: ❌ giving up after %llu attempts", attempt);
        return;
    }
    if (!ivars->powerProvider) {
        ASFW_LOG(Controller, "Wake verify: no provider; cannot rebuild");
        return;
    }

    ivars->wakeRebuildPending = true;
    ivars->wakeVerifyAttempt = attempt + 1;
    RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kWakeRebuild));
}

void ASFWDriver::ScheduleWakeVerify(uint64_t attempt) {
    if (!ivars || !ivars->context || ivars->context->nativeDrain ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return;
    }
    if (!ivars->wakeVerifyTimer) {
        // ctx.workQueue is the service's default queue (DriverWiring::
        // PrepareQueue), so the timer stays valid across runtime rebuilds and
        // the verify serializes with Start/Stop/SetPowerState.
        auto& queue = ivars->context->workQueue;
        if (!queue) {
            return;
        }
        IOTimerDispatchSource* timer = nullptr;
        kern_return_t kr = IOTimerDispatchSource::Create(queue.get(), &timer);
        if (kr != kIOReturnSuccess || !timer) {
            ASFW_LOG(Controller, "Wake verify: ❌ timer create failed: 0x%08x", kr);
            return;
        }
        OSAction* action = nullptr;
        kr = CreateActionWakeVerifyTimerFired(0, &action);
        if (kr != kIOReturnSuccess || !action) {
            ASFW_LOG(Controller, "Wake verify: ❌ timer action create failed: 0x%08x", kr);
            timer->release();
            return;
        }
        // From the first handler installation attempt onward, preserve both
        // objects for observed native retirement, including setup errors.
        ivars->wakeVerifyTimer = timer;
        ivars->wakeVerifyAction = action;
        kr = timer->SetHandler(action);
        if (kr != kIOReturnSuccess) {
            ASFW_LOG(Controller, "Wake verify: ❌ timer SetHandler failed: 0x%08x", kr);
            RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kPlannedStop));
            return;
        }
        kr = timer->SetEnableWithCompletion(true, nullptr);
        if (kr != kIOReturnSuccess) {
            RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kPlannedStop));
            return;
        }
    }

    ivars->wakeVerifyAttempt = attempt;
    (void)ASFW::Timing::initializeHostTimebase();
    const uint64_t deadline =
        mach_absolute_time() + ASFW::Timing::nanosToHostTicks(kWakeVerifyDelayNs);
    (void)ivars->wakeVerifyTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime, deadline, 0);
}

void ASFWDriver::WakeVerifyTimerFired_Impl(ASFWDriver_WakeVerifyTimerFired_Args) {
    if (!ivars || action != ivars->wakeVerifyAction) {
        return;
    }
    VerifyWakeRuntime(ivars->wakeVerifyAttempt);
}

kern_return_t ASFWDriver::CopyControllerStatus(OSDictionary** status) {
    if (!status)
        return kIOReturnBadArgument;
    *status = nullptr;
    auto dict = OSDictionary::withCapacity(4);
    if (!dict)
        return kIOReturnNoMemory;
    if (ivars && ivars->context && ivars->context->controller) {
        auto& controller = *ivars->context->controller;
        auto stateStr = std::string(ToString(controller.StateMachine().CurrentState()));
        if (auto s = OSSharedPtr<OSString>(OSString::withCString(stateStr.c_str()), OSNoRetain)) {
            dict->setObject("state", s.get());
        }
        auto& m = controller.Metrics().BusReset();
        if (auto n = OSSharedPtr<OSNumber>(OSNumber::withNumber(m.resetCount, 32), OSNoRetain)) {
            dict->setObject("busResetCount", n.get());
        }
        if (auto n =
                OSSharedPtr<OSNumber>(OSNumber::withNumber(m.lastResetStart, 64), OSNoRetain)) {
            dict->setObject("lastResetStart", n.get());
        }
        if (auto n = OSSharedPtr<OSNumber>(OSNumber::withNumber(m.lastResetCompletion, 64),
                                           OSNoRetain)) {
            dict->setObject("lastResetCompletion", n.get());
        }
        if (!m.lastFailureReason.has_value()) {
            dict->removeObject("lastResetFailure");
        } else if (auto s = OSSharedPtr<OSString>(
                       OSString::withCString(m.lastFailureReason->c_str()), OSNoRetain)) {
            dict->setObject("lastResetFailure", s.get());
        }

        if (auto topo = controller.LatestTopology()) {
            if (auto n =
                    OSSharedPtr<OSNumber>(OSNumber::withNumber(topo->generation, 32), OSNoRetain)) {
                dict->setObject("topologyGeneration", n.get());
            }
            if (auto n = OSSharedPtr<OSNumber>(
                    OSNumber::withNumber(static_cast<uint64_t>(topo->physical.nodes.size()), 32),
                    OSNoRetain)) {
                dict->setObject("topologyNodeCount", n.get());
            }
        }
    }
    *status = dict;
    return kIOReturnSuccess;
}

// Positional out-parameters are part of the existing driver/user-client contract.
// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t ASFWDriver::CopyControllerSnapshot(OSDictionary** status, uint64_t* sequence,
                                                 uint64_t* timestamp) {
    if (status) {
        auto kr = CopyControllerStatus(status);
        if (kr != kIOReturnSuccess) {
            return kr;
        }
    }

    if (sequence) {
        *sequence = 0;
    }
    if (timestamp) {
        *timestamp = 0;
    }

    if (!ivars || !ivars->context || !ivars->context->statusPublisher.StatusBlock()) {
        return kIOReturnSuccess;
    }

    const auto& block = *ivars->context->statusPublisher.StatusBlock();
    if (sequence) {
        *sequence = block.sequence;
    }
    if (timestamp) {
        *timestamp = block.updateTimestamp;
    }

    return kIOReturnSuccess;
}

void* ASFWDriver::GetControllerCore() const {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire))
        return nullptr;
    return ivars->context->controller.get();
}

void* ASFWDriver::GetAsyncSubsystem() const {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire))
        return nullptr;
    return ivars->context->deps.asyncController.get();
}

void* ASFWDriver::GetServiceContext() const {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire))
        return nullptr;
    return ivars->context;
}

kern_return_t IMPL(ASFWDriver, NewUserClient) {
    // Quarantine is terminal; a new client cannot reopen normal work.
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return kIOReturnNotReady;
    }
    if (type != 0) {
        return kIOReturnBadArgument;
    }

    if (!userClient) {
        return kIOReturnBadArgument;
    }

    ASFW_LOG(Controller, "NewUserClient request received (type=%u)", type);

    IOService* userClientService = nullptr;
    auto ret = Create(this, "ASFWDriverUserClientProperties", &userClientService);
    if (ret != kIOReturnSuccess || !userClientService) {
        ASFW_LOG(Controller, "NewUserClient Create failed: 0x%08x", ret);
        return ret != kIOReturnSuccess ? ret : kIOReturnNoResources;
    }

    auto client = OSDynamicCast(ASFWDriverUserClient, userClientService);
    if (!client) {
        ASFW_LOG(Controller, "NewUserClient cast failure");
        userClientService->release();
        return kIOReturnNoResources;
    }

    ret = client->Start(this);
    if (ret != kIOReturnSuccess) {
        ASFW_LOG(Controller, "NewUserClient Start failed: 0x%08x", ret);
        client->release();
        return ret;
    }

    *userClient = client;
    ASFW_LOG(Controller, "NewUserClient success (client=%p)", client);
    return kIOReturnSuccess;
}

void ASFWDriver::InterruptOccurred_Impl(ASFWDriver_InterruptOccurred_Args) {
    (void)count;

    // DIAGNOSTIC: Log every interrupt invocation
    ASFW_LOG_V3(Controller, "InterruptOccurred called: time=%llu count=%llu", time, count);

    if (!ivars || !ivars->context) {
        ASFW_LOG(Controller, "InterruptOccurred: no ivars or context");
        return;
    }
    auto& ctx = *ivars->context;
    if (ctx.receiveQuarantined.load(std::memory_order_acquire)) return;
    if (!action || action != ctx.interruptAction.get()) return;
    if (!ctx.lifecycle || !ctx.lifecycle->AdmitsBringupInterrupts()) {
        return;
    }
    if (!ctx.controller || !ctx.deps.hardware) {
        ASFW_LOG(Controller, "InterruptOccurred: no controller or hardware");
        return;
    }
    // DriverKit delivers `time` in mach_absolute_time() ticks, NOT nanoseconds
    // (IOInterruptDispatchSource.iig: kIOInterruptSourceContinuousTime only swaps
    // mach_absolute→mach_continuous, never the unit; our source uses plain index 0).
    // Convert to ns at this single boundary so the value that flows into
    // snapshot.timestamp lands on the same scale as MonotonicNow(). Storing raw
    // ticks made every downstream "now(ns) − timestamp" ≈ uptime, which silently
    // defeated the IEEE 1394-2008 §8.2.1 two-second repeated-reset holdoff and
    // forced the Annex H post-reset timing gates permanently open.
    const uint64_t timestampNs = ASFW::Timing::hostTicksToNanos(time);
    ctx.interruptHandlerActive.store(true, std::memory_order_release);
    auto snap = ctx.deps.hardware->CaptureInterruptSnapshot(timestampNs);
    ASFW_LOG_V2(Controller, "InterruptOccurred: captured snapshot intEvent=0x%08x", snap.intEvent);
    ctx.interruptDispatcher.HandleSnapshot(snap, *ctx.controller, *ctx.deps.hardware,
                                           *ctx.workQueue, ctx.isoch, ctx.statusPublisher,
                                           ctx.deps.asyncController.get());
    ctx.completedInterrupts.fetch_add(1, std::memory_order_release);
    ctx.interruptHandlerActive.store(false, std::memory_order_release);
}

void ASFWDriver::ScheduleAsyncWatchdog(uint64_t delayUsec) {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return;
    }
    auto& ctx = *ivars->context;
    // Gate on the alive states (kStarting/kRunning), NOT AdmitsNormalWork():
    // the initial arm in StartRuntime happens before CompleteStart() flips the
    // state to kRunning, so a kRunning-only gate silently no-ops it and the
    // self-rearming tick chain never starts — no AT transaction timeout can
    // ever fire (0.3.0 regression, 22c82112; observed as an unrecoverable
    // SBP-2 wedge when a target stopped responding). Teardown still kills the
    // chain authoritatively via watchdog.Stop()/Reset() (timer disable), and
    // every return to kRunning re-enters StartRuntime, which re-arms.
    if (!ctx.lifecycle || !ctx.lifecycle->AdmitsBringupInterrupts()) {
        return;
    }
    ctx.watchdog.Schedule(delayUsec);
}

void ASFWDriver::AsyncWatchdogTimerFired_Impl(ASFWDriver_AsyncWatchdogTimerFired_Args) {
    (void)time;

    if (ivars && ivars->context) {
        auto& ctx = *ivars->context;
        if (ctx.receiveQuarantined.load(std::memory_order_acquire)) return;
        if (!ctx.watchdog.OwnsAction(action)) return;
        // Skip only the WORK when normal work is inadmissible — never the
        // reschedule below. An early return here breaks the self-rearming
        // chain permanently on a transient non-running state; the chain's
        // real kill switch is the timer disable in watchdog.Stop()/Reset().
        if (ctx.lifecycle && ctx.lifecycle->AdmitsNormalWork()) {
            // The FW643/M6 stop failure left enabled async events pending while
            // the interrupt thread slept in its kernel wait. Rearm notification
            // once; let the existing IRQ owner drain both AR queues. Do not
            // replay an AV/C command or process DMA from a second owner here.
            const uint64_t nowNs = ASFW::Timing::hostTicksToNanos(mach_absolute_time());
            if (nowNs - ctx.interruptProbeTimeNs >= 50'000'000 && ctx.deps.hardware && ctx.deps.interrupts) {
                ctx.interruptProbeTimeNs = nowNs;
                const auto completed = ctx.completedInterrupts.load(std::memory_order_acquire);
                const bool active = ctx.interruptHandlerActive.load(std::memory_order_acquire);
                if (ctx.interruptRearmAwaitingProgress && completed != ctx.interruptRearmEpoch) {
                    ASFW_LOG(Controller, "[InterruptDelivery] progress resumed after notification rearm epoch=%llu completed=%llu",
                        ctx.interruptRearmEpoch, completed);
                    ctx.interruptRearmAwaitingProgress = false;
                }
                uint32_t raw = 0;
                constexpr uint32_t asyncEvents = ASFW::Driver::IntEventBits::kReqTxComplete |
                    ASFW::Driver::IntEventBits::kRespTxComplete | ASFW::Driver::IntEventBits::kARRQ |
                    ASFW::Driver::IntEventBits::kARRS | ASFW::Driver::IntEventBits::kRQPkt |
                    ASFW::Driver::IntEventBits::kRSPkt;
                const bool pending = !active && ctx.deps.hardware->ReadIntEvent(raw) &&
                    (raw & ctx.deps.interrupts->EnabledMask() & asyncEvents) != 0;
                if (ctx.interruptStall.Observe(nowNs, completed, active, pending)) {
                    uint32_t mask = 0, events = 0;
                    const bool rearmed = ctx.deps.hardware->RearmPendingAsyncInterrupt(mask, events);
                    ASFW_LOG(Controller, "[InterruptDelivery] stalled epoch=%llu mask=0x%08x pending=0x%08x notificationRearmed=%u commandsReplayed=0",
                        completed, mask, events, rearmed ? 1U : 0U);
                    ctx.interruptRearmEpoch = completed;
                    ctx.interruptRearmAwaitingProgress = rearmed;
                }
            }
            const auto receiveOwner = ctx.isoch.CopyReceiveContext();
            ctx.watchdog.HandleTick(ctx.controller.get(), ctx.deps.asyncController.get(),
                                    receiveOwner.get(), ctx.isoch.TransmitContext(),
                                    ctx.statusPublisher);
        }
    }

    ScheduleAsyncWatchdog(kAsyncWatchdogPeriodUsec);
}

void ASFWDriver::SBP2SessionTimerFired_Impl(ASFWDriver_SBP2SessionTimerFired_Args) {
    (void)time;

    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return;
    }
    auto& ctx = *ivars->context;
    if (!ctx.lifecycle || !ctx.lifecycle->AdmitsNormalWork() || !ctx.deps.sbp2SessionScheduler) {
        return;
    }
    if (!ctx.deps.sbp2SessionScheduler->OwnsAction(action)) return;

    ctx.deps.sbp2SessionScheduler->HandleTimerFired();
}

void ASFWDriver::ProviderNotificationReady_Impl(ASFWDriver_ProviderNotificationReady_Args) {

    if (!ivars || !ivars->context) {
        return;
    }
    auto& ctx = *ivars->context;

#ifndef ASFW_HOST_TEST
    if (!ctx.providerNotifications || !action || action != ctx.providerNotificationAction.get()) {
        return;
    }

    __block bool providerTerminated = false;
    (void)ctx.providerNotifications->DeliverNotifications(
        ^(uint64_t type, IOService* service, uint64_t options) {
          (void)service;
          (void)options;
          if (type == kIOServiceNotificationTypeTerminated) {
              providerTerminated = true;
          }
        });

    if (!providerTerminated) {
        return;
    }

    if (ctx.deps.hardware) {
        ctx.deps.hardware->LatchProviderRevokedAndDrain();
    }
    RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kProviderRevoked));
#endif
}

void ASFWDriver::RegisterStatusListener(const OSObject* client) {
    auto* clientObj = OSDynamicCast(ASFWDriverUserClient, const_cast<OSObject*>(client));
    if (!clientObj || !ivars || !ivars->context) {
        return;
    }

    auto& ctx = *ivars->context;
    ctx.statusPublisher.BindListener(clientObj);
    ctx.statusPublisher.Publish(ctx.controller.get(), ctx.deps.asyncController.get(),
                                SharedStatusReason::Manual);
}

void ASFWDriver::UnregisterStatusListener(const OSObject* client) {
    auto* clientObj = OSDynamicCast(ASFWDriverUserClient, const_cast<OSObject*>(client));
    if (!clientObj || !ivars || !ivars->context) {
        return;
    }

    ivars->context->statusPublisher.UnbindListener(clientObj);
}

kern_return_t ASFWDriver::CopySharedStatusMemory(uint64_t* options,
                                                 IOMemoryDescriptor** memory) const {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }

    return ivars->context->statusPublisher.CopySharedMemory(options, memory);
}

// Runtime logging configuration methods
kern_return_t ASFWDriver::SetAsyncVerbosity(uint32_t level) const {
    ASFW_LOG_INFO(Controller, "UserClient: Setting async verbosity to %u", level);
    ASFW::LogConfig::Shared().SetAsyncVerbosity(static_cast<uint8_t>(level));
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::SetIsochVerbosity(uint32_t level) const {
    ASFW_LOG_INFO(Controller, "UserClient: Setting isoch verbosity to %u", level);
    ASFW::LogConfig::Shared().SetIsochVerbosity(static_cast<uint8_t>(level));
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::SetHexDumps(uint32_t enabled) const {
    ASFW_LOG_INFO(Controller, "UserClient: Setting hex dumps to %{public}s",
                  enabled ? "enabled" : "disabled");
    ASFW::LogConfig::Shared().SetHexDumps(enabled != 0);
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::SetAudioAutoStart(uint32_t enabled) const {
    ASFW_LOG_INFO(Controller, "UserClient: Setting audio auto-start to %{public}s",
                  enabled ? "enabled" : "disabled");
    ASFW::LogConfig::Shared().SetAudioAutoStartEnabled(enabled != 0);
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::GetLogConfig(uint32_t* asyncVerbosity, uint32_t* hexDumpsEnabled,
                                       uint32_t* isochVerbosity) const {
    if (!asyncVerbosity || !hexDumpsEnabled || !isochVerbosity) {
        return kIOReturnBadArgument;
    }
    *asyncVerbosity = ASFW::LogConfig::Shared().GetAsyncVerbosity();
    *hexDumpsEnabled = ASFW::LogConfig::Shared().IsHexDumpsEnabled() ? 1 : 0;
    *isochVerbosity = ASFW::LogConfig::Shared().GetIsochVerbosity();
    ASFW_LOG_INFO(Controller,
                  "UserClient: Reading log configuration (Async=%u, Isoch=%u, HexDumps=%d)",
                  *asyncVerbosity, *isochVerbosity, *hexDumpsEnabled);
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::GetAudioAutoStart(uint32_t* enabled) const {
    if (!enabled) {
        return kIOReturnBadArgument;
    }
    *enabled = ASFW::LogConfig::Shared().IsAudioAutoStartEnabled() ? 1u : 0u;
    ASFW_LOG_INFO(Controller, "UserClient: Reading audio auto-start (enabled=%u)", *enabled);
    return kIOReturnSuccess;
}

kern_return_t ASFWDriver::StartAudioStreaming(uint64_t guid) {
    if (!ivars || !ivars->context || !ivars->context->audioCoordinator) {
        ASFW_LOG_ERROR(Audio,
                       "[BeBoB] developer stream start refused stage=%{public}s GUID=0x%016llx",
                       "audio-coordinator", guid);
        return kIOReturnNotReady;
    }
    auto& ctx = *ivars->context;
    // The normal AudioDriverKit path refreshes FCP routing immediately before
    // each AV/C start. MCP must do the same: a GUID survives a bus reset while
    // its node/FCP transport does not. This prevents a developer start from
    // issuing the PHASE 88's unit-plug format command through a stale route.
    if (!ctx.deps.deviceRegistry || !ctx.deps.audioRuntimeRegistry ||
        !ctx.deps.avcDiscovery) {
        ASFW_LOG_ERROR(Audio,
                       "[BeBoB] developer stream start refused stage=%{public}s GUID=0x%016llx",
                       "runtime-dependencies", guid);
        return kIOReturnNotReady;
    }
    const auto record = ctx.deps.deviceRegistry->SnapshotByGuid(guid);
    auto protocol = ctx.deps.audioRuntimeRegistry->FindShared(guid);
    if (!record.has_value() || !protocol) {
        ASFW_LOG_ERROR(Audio,
                       "[BeBoB] developer stream start refused stage=%{public}s GUID=0x%016llx record=%u protocol=%u",
                       "device-config", guid, record.has_value(), protocol != nullptr);
        return kIOReturnNotReady;
    }
    auto* transport = ctx.deps.avcDiscovery->GetFCPTransportForNodeID(record->nodeId);
    if (!ASFW::Audio::HasReadyAVCStartRoute(record->nodeId, transport != nullptr)) {
        ASFW_LOG(Audio,
                 "[BeBoB] developer stream start refused; no live FCP route GUID=0x%016llx node=%u",
                 guid, record->nodeId);
        return kIOReturnNotReady;
    }
    const auto route = ctx.deps.deviceRegistry->CurrentRoute(guid);
    if (!route) {
        return kIOReturnNotReady;
    }
    protocol->UpdateRuntimeContext(*route, transport);
    ASFW_LOG(Audio, "[BeBoB] developer stream start GUID=0x%016llx", guid);
    return ctx.audioCoordinator->StartStreaming(guid);
}

kern_return_t ASFWDriver::StopAudioStreaming(uint64_t guid) {
    if (!ivars || !ivars->context || !ivars->context->audioCoordinator) {
        return kIOReturnNotReady;
    }
    ASFW_LOG(Audio, "[BeBoB] developer stream stop GUID=0x%016llx", guid);
    return ivars->context->audioCoordinator->StopStreaming(guid);
}

kern_return_t ASFWDriver::StartIsochReceive(uint8_t channel, uint32_t wireFormatRaw, uint32_t am824Slots) {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }
    auto& ctx = *ivars->context;
    if (!ctx.deps.asyncSubsystem || !ctx.deps.hardware) {
        ASFW_LOG(Controller, "[Isoch] ❌ StartIsochReceive: Subsystems not ready");
        return kIOReturnNotReady;
    }

    if (!ctx.audioCoordinator) {
        return kIOReturnNotReady;
    }

    if (const auto ir = ctx.isoch.CopyReceiveContext();
        ir && ir->GetState() != ASFW::Isoch::IRPolicy::State::Stopped) {
        ASFW_LOG(Controller, "[Isoch] IR already running; StartIsochReceive is idempotent");
        return kIOReturnSuccess;
    }

    // Audio receive is owned by AudioDuplexCoordinator, which installs its
    // content consumer before arming IR. This legacy driver entry point cannot
    // safely synthesize that owner from a raw wire-format value.
    (void)wireFormatRaw;
    (void)am824Slots;
    ASFW_LOG_ERROR(Controller,
                   "[Isoch] StartIsochReceive is retired; use AudioDuplexCoordinator");
    return kIOReturnUnsupported;
}

kern_return_t ASFWDriver::StopIsochReceive() {
    if (!ivars || !ivars->context || !ivars->context->isoch.ReceiveContext()) {
        return kIOReturnNotReady;
    }
    if (ivars->context->dvCapture.IsActive()) {
        return kIOReturnExclusiveAccess;
    }
    return ivars->context->isoch.StopReceive();
}

void* ASFWDriver::GetIsochReceiveContext() const {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return nullptr;
    }
    return ivars->context->isoch.ReceiveContext();
}

// =============================================================================
// MARK: - DV Capture (no audio nub required)
// =============================================================================

kern_return_t ASFWDriver::StartDVCapture(uint64_t deviceGuid,
                                         uint64_t ownerToken) {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }
    auto& ctx = *ivars->context;
    if (!ctx.deps.hardware) {
        ASFW_LOG(Controller, "[Isoch] ❌ StartDVCapture: hardware not ready");
        return kIOReturnNotReady;
    }
    // dev2 replaced the ServiceContext::stopping flag with the lifecycle
    // coordinator's state machine; only a fully running runtime may start capture.
    if (!ctx.lifecycle || ctx.lifecycle->CurrentState() != ControllerState::kRunning) {
        return kIOReturnOffline;
    }
    if (!ctx.deps.deviceRegistry || !ctx.deps.irmClient ||
        !ctx.deps.cmpClient) {
        return kIOReturnNotReady;
    }
    const auto status = ctx.dvCapture.Start(deviceGuid, ownerToken, ctx.isoch,
                               *ctx.deps.hardware, *ctx.deps.deviceRegistry,
                               *ctx.deps.irmClient, *ctx.deps.cmpClient);
    if (const auto receiveOwner = ctx.isoch.CopyReceiveContext();
        status != kIOReturnSuccess && receiveOwner &&
        receiveOwner->GetState() == ASFW::Isoch::IRPolicy::State::Stopping) {
        RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kPlannedStop));
    }
    return status;
}

kern_return_t ASFWDriver::StopDVCapture(uint64_t ownerToken) {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }
    auto& ctx = *ivars->context;
    const auto status = ctx.dvCapture.Stop(ownerToken, ctx.isoch);
    if (const auto receiveOwner = ctx.isoch.CopyReceiveContext();
        status != kIOReturnSuccess && receiveOwner &&
        receiveOwner->GetState() == ASFW::Isoch::IRPolicy::State::Stopping) {
        RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kPlannedStop));
    }
    return status;
}

kern_return_t ASFWDriver::CopyDVCaptureMemory(
    uint64_t ownerToken,
    uint64_t* options,
    IOMemoryDescriptor** memory) const {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }
    return ivars->context->dvCapture.CopyMemory(ownerToken, options, memory);
}

// =============================================================================
// MARK: - Isochronous Transmit
// =============================================================================

kern_return_t ASFWDriver::StartIsochTransmit(uint8_t channel) {
    if (!ivars || !ivars->context) {
        return kIOReturnNotReady;
    }
    auto& ctx = *ivars->context;
    if (!ctx.deps.asyncSubsystem || !ctx.deps.hardware) {
        ASFW_LOG(Controller, "[Isoch] ❌ StartIsochTransmit: Subsystems not ready");
        return kIOReturnNotReady;
    }

    const uint8_t sid = static_cast<uint8_t>(ctx.deps.hardware->ReadNodeID() & 0x3Fu);

    return ctx.isoch.StartTransmit(channel, *ctx.deps.hardware, sid);
}

kern_return_t ASFWDriver::StopIsochTransmit() {
    if (!ivars || !ivars->context || !ivars->context->isoch.TransmitContext()) {
        return kIOReturnNotReady;
    }
    return ivars->context->isoch.StopTransmit();
}

void* ASFWDriver::GetIsochTransmitContext() const {
    if (!ivars || !ivars->context ||
        ivars->context->receiveQuarantined.load(std::memory_order_acquire)) {
        return nullptr;
    }
    return ivars->context->isoch.TransmitContext();
}
