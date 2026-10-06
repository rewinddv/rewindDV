// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
#include "DriverContext.hpp"

#include "ASFWDriver.h"

#include <PCIDriverKit/IOPCIFamilyDefinitions.h>

#include "../Async/AsyncSubsystem.hpp"
#include "../Async/Interfaces/IFireWireBus.hpp"
#include "../Async/PacketHelpers.hpp"
#include "../Async/ResponseCode.hpp"
#include "../Async/Tx/ResponseSender.hpp"
#include "../Audio/Core/AudioCoordinator.hpp"
#include "../Audio/Core/AudioRuntimeRegistry.hpp"
#include "../Bus/BusManager.hpp"
#include "../Bus/BusResetCoordinator.hpp"
#include "../Bus/SelfIDCapture.hpp"
#include "../Bus/TopologyManager.hpp"
#include "../Bus/CSR/BroadcastChannelCSR.hpp"
#include "../Bus/CSR/TopologyMapService.hpp"
#include "../Bus/BusManager/BusManagerElectionDriver.hpp"
#include "../ConfigROM/ConfigROMBuilder.hpp"
#include "../ConfigROM/ConfigROMStager.hpp"
#include "../ConfigROM/ConfigROMStore.hpp"
#include "../ConfigROM/ROMScanner.hpp"
#include "../Controller/ControllerStateMachine.hpp"
#include "../Diagnostics/MetricsSink.hpp"
#include "../Discovery/DeviceManager.hpp"
#include "../Discovery/DeviceRegistry.hpp"
#include "../Discovery/SpeedPolicy.hpp"
#include "../Hardware/HardwareInterface.hpp"
#include "../Hardware/InterruptManager.hpp"
#include "../Logging/Logging.hpp"
#include "../Protocols/AVC/FCPResponseRouter.hpp"
#include "../Protocols/AVC/AVCDiscovery.hpp"
#include "../Protocols/SBP2/AddressSpaceManager.hpp"
#include "../Protocols/SBP2/Session/DriverKitSessionScheduler.hpp"
#include "../Protocols/SBP2/Session/SessionRegistry.hpp"
#include "../SCSIController/SBP2BridgeHub.hpp"
#include "../SCSIController/SBP2NubPublisher.hpp"
#include "../SCSIController/SBP2TargetBridge.hpp"
#include "../Scheduling/Scheduler.hpp"
#include "../Shared/Completion/NativeSourceRetirement.hpp"

void ServiceContext::DisarmProviderNotifications() {
#ifndef ASFW_HOST_TEST
    if (providerNotifications) {
        if (!providerNotificationDrain || !providerNotificationDrain->AllTerminal() ||
            providerNotificationDrain->Quarantined()) {
            ASFW_LOG_ERROR(Controller, "Provider source reset before native retirement; retaining source/action");
            (void)providerNotifications.detach();
            (void)providerNotificationAction.detach();
            return;
        }
        providerNotifications.reset();
    }
    providerNotificationAction.reset();
    providerNotificationDrain.reset();
#endif
}

void ServiceContext::BeginProviderNativeRetirement(
    const std::shared_ptr<ASFW::Shared::NativeCallbackDrain>& drain) {
#ifndef ASFW_HOST_TEST
    if (!providerNotifications || providerNotificationDrain) return;
    providerNotificationDrain = drain;
    // A pending provider callback must retain access to its notification queue
    // until native Cancel reports it has finished. Releasing these copies is
    // terminal; the delivery aliases above survive until root Reset.
    auto source = providerNotifications;
    auto action = providerNotificationAction;
    ASFW::Shared::RetireNativeSource(source, action, drain);
#else
    (void)drain;
#endif
}

void ServiceContext::Reset(ResetMode mode) {
#ifndef ASFW_HOST_TEST
    if (providerNotifications && (!providerNotificationDrain ||
        !providerNotificationDrain->AllTerminal() || providerNotificationDrain->Quarantined())) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] provider callback retirement unproved; preserving runtime graph");
        return;
    }
#endif
    if (nativeDrain && (!nativeDrain->AllTerminal() || nativeDrain->Quarantined())) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] native callback retirement unproved; preserving runtime graph");
        return;
    }
    if (deps.asyncSubsystem && !deps.asyncSubsystem->DMAContextsRetired()) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] async DMA retirement unproved; preserving runtime graph");
        return;
    }
    const bool resetWorkQuiesced = !deps.busReset || deps.busReset->RetireDeferredWork();
    const bool controllerWorkQuiesced = !controller || controller->RetireDeferredWork();
    const bool romWorkQuiesced = !deps.romScanner || deps.romScanner->RetireDeferredWork();
    const bool avcWorkQuiesced = !deps.avcDiscovery || deps.avcDiscovery->RetireDeferredWork();
    if (!resetWorkQuiesced || !controllerWorkQuiesced || !romWorkQuiesced || !avcWorkQuiesced) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] deferred controller work remains; preserving runtime graph");
        return;
    }
#ifdef REWINDDV_FOUNDATION
    if (foundationReceive.StopAll() != kIOReturnSuccess) {
        receiveQuarantined.store(true, std::memory_order_release);
        return;
    }
#endif
    if (receiveQuarantined.load(std::memory_order_acquire) ||
        isoch.ReleaseQuiescedReceiveContexts() != kIOReturnSuccess) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller,
                       "[Lifecycle] receive containment unproved; preserving runtime graph");
        return;
    }
    if (deps.avcDiscovery) deps.avcDiscovery->Shutdown();
    if (deps.asyncSubsystem && deps.asyncSubsystem->HasUncertainWire()) {
        receiveQuarantined.store(true, std::memory_order_release);
        ASFW_LOG_ERROR(Controller, "[Lifecycle] remote response retirement unproved; preserving runtime graph");
        return;
    }
    // Runtime stopping is owned by RuntimeLifecycleCoordinator. Reset only
    // releases resources after its quiesce executor has stopped them.
    if (mode == ResetMode::Full && sbp2NubPublisher) {
        sbp2NubPublisher->Shutdown();
        sbp2NubPublisher.reset();
    }
    // Tear down every runtime object that borrows the controller-owned bus while
    // that bus is still alive. The bus lives in ControllerCore::busImpl_; ROMScanner,
    // AVCDiscovery, IRMClient and CMPClient all retain non-owning references to it.
    // None of those objects may survive a suspend/wake or wake-verify rebuild.
    //
    // This is a correctness boundary, not merely destructor hygiene: retaining the
    // CMP client across a controller rebuild leaves busInfo_ pointing at the old
    // FireWireBusImpl. The next receive startup then authenticates a stale vtable
    // pointer before it can submit any I/O.
    //
    // ServiceContext solely owns audioCoordinator, so resetting it here destroys it now.
    // The registry is co-owned by the controller's own deps_ copy, which must be dropped
    // explicitly: ~ControllerCore destroys busImpl_ before deps_, so letting the registry
    // die with the controller would call through a dangling bus.
    audioCoordinator.reset();
    if (controller) {
        controller->ReleaseAudioRuntimeRegistry();
        // ROMScanner borrows the controller-owned IFireWireBus. Drop the
        // controller's shared_ptr while that bus is still alive.
        controller->AttachROMScanner(nullptr);
        // The controller keeps its own shared_ptr copies of these bus borrowers.
        // Clear them explicitly before controller.reset() destroys busImpl_.
        controller->SetFCPResponseRouter(nullptr);
        controller->SetAVCDiscovery(nullptr);
        controller->SetCMPClient(nullptr);
        controller->SetIRMClient(nullptr);
        controller->SetBusManagerElectionDriver(nullptr);
        controller->SetCSRResponder(nullptr);
    }
    deps.audioRuntimeRegistry.reset();
    // Drop the context's remaining scanner reference before destroying the
    // controller. EnsureRomScanner will bind a fresh scanner after rebuild.
    deps.romScanner.reset();
    // Local request handlers and bus-manager election retain raw pointers to
    // the hardware-backed CSR adapters and responder. Retire the complete CSR
    // graph before hardware/topology providers can be destroyed.
    deps.localRequestDispatch.reset();
    if (deps.busManagerElectionDriver) deps.busManagerElectionDriver->Stop();
    deps.busManagerElectionDriver.reset();
    deps.csrResponder.reset();
    deps.csrCycleMasterControl.reset();
    deps.csrRootStatus.reset();
    // The controller also owns a copy; both copies die before hardware below.
    deps.topologyMapService.reset();
    deps.fcpResponseRouter.reset();
    deps.avcDiscovery.reset();
    deps.cmpClient.reset();
    deps.irmClient.reset();
    controller.reset();
    deps.hardware.reset();
    deps.busReset.reset();
    deps.busManager.reset();
    deps.selfId.reset();
    deps.scheduler.reset();
    deps.metrics.reset();
    deps.configRom.reset();
    deps.configRomStager.reset();
    if (mode == ResetMode::Full) {
        deps.interrupts.reset(); // ~InterruptManager cancels the dispatch source
    }
    deps.topology.reset();
    deps.sbp2SessionRegistry.reset();
    deps.sbp2SessionScheduler.reset();
    deps.sbp2AddressSpaceManager.reset();
    deps.asyncController.reset();
    deps.asyncSubsystem.reset(); // Stop and cleanup asyncSubsystem
    if (mode == ResetMode::Full) {
        // A new provider incarnation must rediscover remote hardware. Retaining
        // old FWDevice/FWUnit objects here would let a new SBP-2 nub publisher
        // adopt a stale unit before a fresh ROM scan establishes its route.
        deps.deviceManager.reset();
        deps.deviceRegistry.reset();
    }
    deps.busResetStartedCallback = {};
    deps.cycleInconsistentCallback = {};
    statusPublisher.Reset();
    watchdog.Reset();
    interruptStall = {};
    interruptProbeTimeNs = 0;
    interruptRearmAwaitingProgress = false;
    DisarmProviderNotifications();
    // A disabled interrupt source survives suspend, but the next runtime gets
    // a fresh action identity after the old action's disable barrier completed.
    interruptAction.reset();
    if (mode == ResetMode::Full) {
        workQueue.reset();
        lifecycle.reset();
    }
}

namespace ASFW::Driver {

void DriverWiring::EnsureDeps(ASFWDriver* driver, ::ServiceContext& ctx) {
    auto& d = ctx.deps;
    if (!d.hardware) {
        d.hardware = std::make_shared<HardwareInterface>();
    }
    if (!d.busReset) {
        d.busReset = std::make_shared<BusResetCoordinator>();
    }
    if (!d.selfId) {
        d.selfId = std::make_shared<SelfIDCapture>();
    }
    if (!d.scheduler) {
        d.scheduler = std::make_shared<Scheduler>();
    }
    if (!d.metrics) {
        d.metrics = std::make_shared<MetricsSink>();
    }
    if (!d.stateMachine) {
        d.stateMachine = std::make_shared<ControllerStateMachine>();
    }
    if (!ctx.lifecycle) {
        ctx.lifecycle = std::make_unique<RuntimeLifecycleCoordinator>(d.stateMachine);
    }
    if (!d.configRom) {
        d.configRom = std::make_shared<ConfigROMBuilder>();
    }
    if (!d.configRomStager) {
        d.configRomStager = std::make_shared<ConfigROMStager>();
    }
    if (!d.interrupts) {
        d.interrupts = std::make_shared<InterruptManager>();
    }
    if (!d.topology) {
        d.topology = std::make_shared<TopologyManager>();
    }
    if (!d.busManager) {
        d.busManager = std::make_shared<BusManager>();
    }
    if (!d.broadcastChannel) {
        d.broadcastChannel = std::make_shared<ASFW::Bus::BroadcastChannelCSR>();
    }
    if (!d.topologyMapService && d.hardware) {
        d.topologyMapService = std::make_shared<ASFW::Bus::TopologyMapService>(d.hardware.get());
    }

    if (!d.asyncSubsystem) {
        d.asyncSubsystem = std::make_shared<ASFW::Async::AsyncSubsystem>();
    }
    if (!d.asyncController && d.asyncSubsystem) {
        d.asyncController =
            std::static_pointer_cast<ASFW::Async::IAsyncControllerPort>(d.asyncSubsystem);
    }

    if (!d.speedPolicy) {
        d.speedPolicy = std::make_shared<ASFW::Discovery::SpeedPolicy>();
    }
    if (!d.romStore) {
        d.romStore = std::make_shared<ASFW::Discovery::ConfigROMStore>();
    }
    if (!d.deviceRegistry) {
        d.deviceRegistry = std::make_shared<ASFW::Discovery::DeviceRegistry>();
    }
    if (!d.deviceManager) {
        d.deviceManager = std::make_shared<ASFW::Discovery::DeviceManager>();
    }

    // Runtime owner of device-specific IDeviceProtocol instances. Constructed here,
    // before AudioCoordinator and ControllerCore, so both can hold the same instance:
    // the controller triggers creation from its discovery path; the Audio layer reads it.
#ifndef REWINDDV_FOUNDATION
    if (!d.audioRuntimeRegistry) {
        d.audioRuntimeRegistry = std::make_shared<ASFW::Audio::AudioRuntimeRegistry>();
    }

    // Provide genuinely-deferred one-shot timers to protocol control planes.
    // BeBoB uses this for the post-format settle delay instead of IOSleep.
    if (d.audioRuntimeRegistry && d.sbp2SessionScheduler) {
        d.audioRuntimeRegistry->SetTimerScheduler(d.sbp2SessionScheduler.get());
    }

    if (!ctx.audioCoordinator && d.deviceManager && d.deviceRegistry && d.hardware &&
        d.audioRuntimeRegistry) {
        ctx.audioCoordinator = std::make_shared<ASFW::Audio::AudioCoordinator>(
            driver, *d.deviceManager, *d.deviceRegistry, *d.audioRuntimeRegistry, ctx.isoch,
            *d.hardware);
        ASFW_LOG(Controller, "[Controller] ✅ AudioCoordinator initialized");
    }

    if (ctx.audioCoordinator) {
        std::weak_ptr<ASFW::Audio::AudioCoordinator> weakAudio = ctx.audioCoordinator;
        d.cycleInconsistentCallback = [weakAudio] {
            if (auto audio = weakAudio.lock()) {
                audio->HandleCycleInconsistent();
            }
        };
    } else {
        d.cycleInconsistentCallback = {};
    }
#else
    // The initial RewindDV Foundation article is a control-only driver. Do not
    // instantiate automatic audio protocol owners or publication callbacks.
    d.cycleInconsistentCallback = {};
#endif

    d.busResetStartedCallback = [driver, &ctx] {
#ifdef REWINDDV_FOUNDATION
        if (ctx.foundationReceive.StopAll(true) != kIOReturnSuccess) {
            driver->RequestRuntimeQuiesce(
                static_cast<uint32_t>(QuiesceReason::kPlannedStop));
        }
#endif
        if (ctx.dvCapture.HandleBusReset(ctx.isoch) != kIOReturnSuccess) {
            driver->RequestRuntimeQuiesce(
                static_cast<uint32_t>(QuiesceReason::kPlannedStop));
        }
    };

    d.deviceReplacementReady = [&ctx] {
        if (ctx.receiveQuarantined.load(std::memory_order_acquire)) return false;
#ifdef REWINDDV_FOUNDATION
        // The caller admits replacement only after a true reset. This
        // idempotent reset stop invalidates pending receive admission and skips
        // stale PCR/IRM writes, including sessions that have not armed DMA yet.
        if (ctx.foundationReceive.StopAll(true) != kIOReturnSuccess) return false;
#endif
        return !ctx.dvCapture.IsActive() && ctx.isoch.ReceiveContextsQuiesced();
    };
    d.deviceReplacementFailed = [driver] {
        driver->RequestRuntimeQuiesce(static_cast<uint32_t>(QuiesceReason::kPlannedStop));
    };

    // AV/C discovery wiring is done after ControllerCore is created so it can
    // depend only on IFireWireBus ports (ControllerCore::Bus()).
}

kern_return_t DriverWiring::PrepareControlTimer(ASFWDriver& service, ::ServiceContext& ctx) {
    auto& d = ctx.deps;
    // ControllerCore copies Dependencies at construction. Prepare the shared
    // reset/FCP timer before that copy, on both cold start and runtime rebuild.
    if (!d.sbp2SessionScheduler) {
        d.sbp2SessionScheduler =
            std::make_shared<ASFW::Protocols::SBP2::DriverKitSessionScheduler>();
        const auto kr = d.sbp2SessionScheduler->Prepare(service, ctx.workQueue);
        if (kr != kIOReturnSuccess) {
            // Keep partially prepared native objects for failed-start drain.
            return kr;
        }
        ASFW_LOG(Controller, "[Controller] Control timer initialized");
    }
    return kIOReturnSuccess;
}

kern_return_t DriverWiring::EnsureSbp2Deps(ASFWDriver& service, ::ServiceContext& ctx) {
    auto& d = ctx.deps;
    const auto timerStatus = PrepareControlTimer(service, ctx);
    if (timerStatus != kIOReturnSuccess) return timerStatus;

#ifdef REWINDDV_FOUNDATION
    // Only the shared control timer is used by Foundation. Storage address
    // spaces, sessions, login bridges and nub publication remain excluded.
    if (ctx.controller) {
        ctx.controller->SetSbp2AddressSpaceManager(nullptr);
        ctx.controller->SetSbp2SessionRegistry(nullptr);
    }
    return kIOReturnSuccess;
#else

    if (!d.sbp2AddressSpaceManager && d.hardware) {
        d.sbp2AddressSpaceManager =
            std::make_shared<ASFW::Protocols::SBP2::AddressSpaceManager>(d.hardware.get());
        ASFW_LOG(Controller, "[Controller] SBP2 AddressSpaceManager initialized");
    }

    if (d.audioRuntimeRegistry && d.sbp2SessionScheduler) {
        d.audioRuntimeRegistry->SetTimerScheduler(d.sbp2SessionScheduler.get());
    }

    if (!d.sbp2SessionRegistry && ctx.controller && d.sbp2AddressSpaceManager &&
        d.deviceRegistry && d.deviceManager && d.sbp2SessionScheduler) {
        auto& bus = ctx.controller->Bus();
        d.sbp2SessionRegistry = std::make_shared<ASFW::Protocols::SBP2::SessionRegistry>(
            bus, bus, *d.sbp2AddressSpaceManager, *d.deviceRegistry, *d.deviceManager,
            *d.sbp2SessionScheduler,
            ctx.workQueue.get());
        if (d.busReset) {
            // Last-resort recovery for targets whose fetch engine wedges so hard
            // that even the LUN-reset management ORB is never fetched (LS-9000).
            // Long reset: the conservative flavor every device must honor.
            std::weak_ptr<BusResetCoordinator> weakReset = d.busReset;
            d.sbp2SessionRegistry->SetBusResetRequester([weakReset]() {
                if (auto coordinator = weakReset.lock()) {
                    coordinator->RequestUserReset(/*shortReset=*/false,
                                                  "SBP2 LUN-reset escalation");
                }
            });
        }
        ASFW_LOG(Controller, "[Controller] SBP2 SessionRegistry initialized");
    }

    if (ctx.controller) {
        ctx.controller->SetSbp2AddressSpaceManager(d.sbp2AddressSpaceManager);
        ctx.controller->SetSbp2SessionRegistry(d.sbp2SessionRegistry);
    }

    // Phase-1 HBA bridge: watches discovery for an SBP-2 unit, logs in, and
    // executes SCSI tasks handed over by ASFWSCSIController via SBP2BridgeHub.
    if (!ctx.sbp2Bridge && d.sbp2SessionRegistry && d.deviceManager && ctx.workQueue) {
        ctx.sbp2Bridge = std::make_shared<ASFW::Protocols::SBP2::SBP2TargetBridge>(
            d.sbp2SessionRegistry, *d.deviceManager, ctx.workQueue.get(),
            d.sbp2SessionScheduler.get());
        ctx.sbp2Bridge->Start();
        ASFW::Protocols::SBP2::SBP2BridgeHub::Set(ctx.sbp2Bridge);
        ASFW_LOG(Controller, "[Controller] SBP2 target bridge initialized");
    }

    if (!ctx.sbp2NubPublisher && d.deviceManager && ctx.workQueue) {
        ctx.sbp2NubPublisher = std::make_shared<ASFW::Protocols::SBP2::SBP2NubPublisher>(
            &service, *d.deviceManager, ctx.workQueue.get());
        ctx.sbp2NubPublisher->Start();
        ASFW_LOG(Controller, "[Controller] SBP-2 real-unit nub publisher initialized");
    }

    // Inbound local-request routing remains owned centrally by LocalRequestDispatch
    // (see WireLocalRequestDispatch). This helper owns the higher-level SBP-2
    // session dependencies that sit above the address-space manager.
    return kIOReturnSuccess;
#endif
}

kern_return_t DriverWiring::PrepareQueue(ASFWDriver& service, ::ServiceContext& ctx) {
    IODispatchQueue* q = nullptr;
    auto kr = service.CopyDispatchQueue("Default", &q);
    if (kr != kIOReturnSuccess || !q) {
        kr = service.CreateDefaultDispatchQueue(&q);
        if (kr != kIOReturnSuccess || !q)
            return kr != kIOReturnSuccess ? kr : kIOReturnError;
    }
    ctx.workQueue = OSSharedPtr(q, OSNoRetain);
    ctx.deps.scheduler->Bind(ctx.workQueue);
    return kIOReturnSuccess;
}

kern_return_t DriverWiring::PrepareInterrupts(ASFWDriver& service, IOService* provider,
                                              ::ServiceContext& ctx) {
    if (!provider) {
        return kIOReturnBadArgument;
    }

    auto intrMgr = ctx.deps.interrupts;
    if (!intrMgr) {
        return kIOReturnNoResources;
    }

    // MSI configuration happens once per provider lifetime, only before the
    // dispatch source exists. The source survives suspend/rebuild (see
    // ServiceContext::ResetMode): re-running ConfigureInterrupts or creating a
    // second source would re-register the same interrupt vector while the old
    // registration is still live, and the eventual double-unregister panics
    // the kernel on a shared interrupt controller.
    if (!intrMgr->HasSource()) {
        auto pci = OSDynamicCast(IOPCIDevice, provider);
        if (!pci) {
            return kIOReturnBadArgument;
        }

        auto status = pci->ConfigureInterrupts(kIOInterruptTypePCIMessagedX, 1, 1, 0);
        if (status != kIOReturnSuccess) {
            status = pci->ConfigureInterrupts(kIOInterruptTypePCIMessaged, 1, 1, 0);
            if (status != kIOReturnSuccess) {
                return status;
            }
        }
    }

    if (!ctx.interruptAction) {
        OSAction* action = nullptr;
        auto kr = service.CreateActionInterruptOccurred(0, &action);
        if (kr != kIOReturnSuccess || !action)
            return kr != kIOReturnSuccess ? kr : kIOReturnError;
        ctx.interruptAction = OSSharedPtr(action, OSNoRetain);
    }

    auto kr = intrMgr->Initialise(provider, ctx.workQueue, ctx.interruptAction);
    if (kr != kIOReturnSuccess) {
        ctx.interruptAction.reset();
        return kr;
    }
    return kIOReturnSuccess;
}

kern_return_t DriverWiring::PrepareWatchdog(ASFWDriver& service, ::ServiceContext& ctx) {
    return ctx.watchdog.Prepare(service, ctx.workQueue);
}

} // namespace ASFW::Driver
