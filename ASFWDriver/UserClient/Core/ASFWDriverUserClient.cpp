// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
//
//  ASFWDriverUserClient.cpp
//  ASFWDriver
//
//  User client for GUI application communication
//  Refactored into handler-based architecture for maintainability
//

#include "ASFWDriverUserClient.h"
#include "../../Logging/LogConfig.hpp"
#include "../../Logging/Logging.hpp"
#include "../../Shared/DriverVersionInfo.hpp"
#ifdef REWINDDV_FOUNDATION
#include "DriverVersion.hpp"
#else
#include "../../Version/DriverVersion.hpp"
#endif
#include "ASFWDriver.h"
#include "UserClientRuntimeState.hpp"
#include "../../Service/DriverContext.hpp"
#include "../../Protocols/AVC/AVCDiscovery.hpp"
#include <DriverKit/IODispatchQueue.h>
#ifdef REWINDDV_FOUNDATION
#include "../../../Foundation/DriverPolicy/FoundationDriverPolicy.hpp"
#include "../../../Foundation/DriverPolicy/FoundationReceiveWire.hpp"
#endif

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include <memory>
#include <optional>

// Method selectors for ExternalMethod (matching .iig definitions)
enum {
    kMethodGetBusResetCount = 0,
    kMethodGetBusResetHistory = 1,
    kMethodGetControllerStatus = 2,
    kMethodGetMetricsSnapshot = 3,
    kMethodClearHistory = 4,
    kMethodGetSelfIDCapture = 5,
    // 6 (kMethodGetTopologySnapshot) retired: topology now served via the
    // diagnostics ABI (kMethodDiagGetTopology / ASFWDiagTopology).
    kMethodPing = 7,
    kMethodAsyncRead = 8,
    kMethodAsyncWrite = 9,
    kMethodRegisterStatusListener = 10,
    kMethodCopyStatusSnapshot = 11,
    kMethodGetTransactionResult = 12,
    kMethodRegisterTransactionListener = 13,
    kMethodExportConfigROM = 14,
    kMethodTriggerROMRead = 15,
    kMethodGetDiscoveredDevices = 16,
    kMethodAsyncCompareSwap = 17,
    kMethodGetDriverVersion = 18,
    kMethodSetAsyncVerbosity = 19,
    kMethodSetHexDumps = 20,
    kMethodGetLogConfig = 21,
    kMethodGetAVCUnits = 22,
    kMethodGetSubunitCapabilities = 23,
    kMethodGetSubunitDescriptor = 24,
    kMethodReScanAVCUnits = 25,
    kMethodSendRawFCPCommand = 38,
    kMethodGetRawFCPCommandResult = 39,
    kMethodSetIsochVerbosity = 40,
    // 41 retired (was the dev TX-verifier toggle)
    kMethodSetAudioAutoStart = 42,
    kMethodGetAudioAutoStart = 43,
    kMethodAsyncBlockRead = 44,
    kMethodAsyncBlockWrite = 45,
    // SBP2 address space management
    kMethodAllocateAddressRange = 46,
    kMethodDeallocateAddressRange = 47,
    kMethodReadIncomingData = 48,
    kMethodWriteLocalData = 49,
    kMethodCreateSBP2Session = 52,
    kMethodStartSBP2Login = 53,
    kMethodGetSBP2SessionState = 54,
    kMethodSubmitSBP2Inquiry = 55,
    kMethodGetSBP2InquiryResult = 56,
    kMethodSubmitSBP2Command = 57,
    kMethodGetSBP2CommandResult = 58,
    kMethodSubmitSBP2TaskManagement = 59,
    kMethodReleaseSBP2Session = 60,
    kMethodRequestUserBusReset = 61,
    kMethodStartAudioStreaming = 62,
    kMethodStopAudioStreaming = 63,
    kMethodGetFoundationCapabilities = 64,
    kMethodSubmitDeckControl = 65,
    kMethodGetDeckControlResult = 66,
    kMethodGetFoundationRoute = 67,
    kMethodGetInspectorCapabilities = 72,
    kMethodSubmitInspectorProbe = 73,
    kMethodGetInspectorResult = 74,
    kMethodGetTransportCapabilityCatalog = 75,
    kMethodSubmitTransportCapabilityProbe = 76,
    kMethodGetTransportCapabilityResult = 77,
    // TODO(ASFW-IRM): Remove temporary IRM test method after dedicated validation tooling exists.
    kMethodTestIRMAllocation = 26,
    kMethodTestIRMRelease = 27,
    // TODO(ASFW-CMP): Remove temporary CMP test methods after dedicated validation tooling exists.
    kMethodTestCMPConnectOPCR = 28,
    kMethodTestCMPDisconnectOPCR = 29,
    kMethodTestCMPConnectIPCR = 30,
    kMethodTestCMPDisconnectIPCR = 31,

    // Isoch Stream Control
    kMethodStartIsochReceive = 32,
    kMethodStopIsochReceive = 33,

    // Isoch Metrics
    kMethodGetIsochRxMetrics = 34,
    kMethodResetIsochRxMetrics = 35,

    // Isoch Transmit Control (IT DMA allocation only - no CMP)
    kMethodStartIsochTransmit = 36,
    kMethodStopIsochTransmit = 37,

    // DV capture (raw DIF stream via shared ring, memory type 1)
    kMethodStartDVCapture = 50,
    kMethodStopDVCapture = 51,
};

namespace {

using MethodDispatchResult = std::optional<kern_return_t>;

std::optional<uint32_t> GetFirstScalarInput(const IOUserClientMethodArguments* arguments) {
    if (!arguments || !arguments->scalarInput || arguments->scalarInputCount < 1) {
        return std::nullopt;
    }

    return static_cast<uint32_t>(arguments->scalarInput[0]);
}

MethodDispatchResult DispatchBusResetMethods(ASFW::UserClient::UserClientRuntimeState& runtimeState,
                                             IOUserClientMethodArguments* arguments,
                                             uint64_t selector) {
    switch (selector) {
    case kMethodGetBusResetCount:
        return runtimeState.BusReset().GetBusResetCount(arguments);
    case kMethodGetBusResetHistory:
        return runtimeState.BusReset().GetBusResetHistory(arguments);
    case kMethodClearHistory:
        return runtimeState.BusReset().ClearHistory(arguments);
    case kMethodRequestUserBusReset:
        return runtimeState.BusReset().RequestUserReset(arguments);
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchTopologyMethods(ASFW::UserClient::UserClientRuntimeState& runtimeState,
                                             IOUserClientMethodArguments* arguments,
                                             uint64_t selector) {
    switch (selector) {
    case kMethodGetSelfIDCapture:
        return runtimeState.Topology().GetSelfIDCapture(arguments);
    // kMethodGetTopologySnapshot (6) retired: topology now served via the
    // diagnostics ABI (kMethodDiagGetTopology / ASFWDiagTopology).
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchStatusMethods(ASFW::UserClient::UserClientRuntimeState& runtimeState,
                                           ASFWDriverUserClient& userClient,
                                           IOUserClientMethodArguments* arguments,
                                           uint64_t selector) {
    switch (selector) {
    case kMethodGetControllerStatus:
        return runtimeState.Status().GetControllerStatus(arguments);
    case kMethodGetMetricsSnapshot:
        return runtimeState.Status().GetMetricsSnapshot(arguments);
    case kMethodPing:
        return runtimeState.Status().Ping(arguments);
    case kMethodRegisterStatusListener:
        return runtimeState.Status().RegisterStatusListener(arguments, &userClient);
    case kMethodCopyStatusSnapshot:
        return runtimeState.Status().CopyStatusSnapshot(arguments);
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchTransactionMethods(
    ASFW::UserClient::UserClientRuntimeState& runtimeState, ASFWDriverUserClient& userClient,
    IOUserClientMethodArguments* arguments, uint64_t selector) {
    switch (selector) {
    case kMethodAsyncRead:
        return runtimeState.Transactions().AsyncRead(arguments, &userClient);
    case kMethodAsyncWrite:
        return runtimeState.Transactions().AsyncWrite(arguments, &userClient);
    case kMethodAsyncBlockRead:
        return runtimeState.Transactions().AsyncBlockRead(arguments, &userClient);
    case kMethodAsyncBlockWrite:
        return runtimeState.Transactions().AsyncBlockWrite(arguments, &userClient);
    case kMethodGetTransactionResult:
        return runtimeState.Transactions().GetTransactionResult(arguments);
    case kMethodRegisterTransactionListener:
        return runtimeState.Transactions().RegisterTransactionListener(arguments, &userClient);
    case kMethodAsyncCompareSwap:
        return runtimeState.Transactions().AsyncCompareSwap(arguments, &userClient);
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchConfigRomMethods(
    ASFW::UserClient::UserClientRuntimeState& runtimeState, IOUserClientMethodArguments* arguments,
    uint64_t selector) {
    switch (selector) {
    case kMethodExportConfigROM:
        return runtimeState.ConfigROM().ExportConfigROM(arguments);
    case kMethodTriggerROMRead:
        return runtimeState.ConfigROM().TriggerROMRead(arguments);
    case kMethodGetDiscoveredDevices:
        return runtimeState.DeviceDiscovery().GetDiscoveredDevices(arguments);
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchAVCMethods(ASFWDriver& driver,
                                        IOUserClientMethodArguments* arguments,
                                        uint64_t selector) {
    // Client connections survive suspend/rebuild. Never cache a discovery
    // borrower in the connection: bind each invocation to the current root.
    switch (selector) {
    case kMethodGetAVCUnits:
    case kMethodGetSubunitCapabilities:
    case kMethodGetSubunitDescriptor:
    case kMethodReScanAVCUnits:
    case kMethodSendRawFCPCommand:
    case kMethodGetRawFCPCommandResult:
#ifdef REWINDDV_FOUNDATION
    case kMethodSubmitDeckControl:
    case kMethodGetDeckControlResult:
    case kMethodGetFoundationRoute:
    case kMethodSubmitInspectorProbe:
    case kMethodGetInspectorResult:
    case kMethodSubmitTransportCapabilityProbe:
    case kMethodGetTransportCapabilityResult:
#endif
        break;
    default:
        return std::nullopt;
    }

    IODispatchQueue* rawQueue = nullptr;
    if (driver.CopyDispatchQueue("Default", &rawQueue) != kIOReturnSuccess || !rawQueue)
        return kIOReturnNotReady;
    auto queue = OSSharedPtr(rawQueue, OSNoRetain);
    const auto invoke = [&]() -> kern_return_t {
        auto* context = static_cast<ServiceContext*>(driver.GetServiceContext());
        std::shared_ptr<ASFW::Protocols::AVC::AVCDiscovery> discovery;
        if (context && !context->receiveQuarantined.load(std::memory_order_acquire) &&
            context->lifecycle && context->lifecycle->AdmitsNormalWork())
            discovery = context->deps.avcDiscovery;
        const auto epoch = discovery ? discovery->DeferredWorkEpoch() : nullptr;
        return ASFW::UserClient::WithAVCHandlerForRuntime(discovery, epoch,
            [&](ASFW::UserClient::AVCHandler& handler) -> kern_return_t {
                switch (selector) {
                case kMethodGetAVCUnits:
                    return handler.GetAVCUnits(arguments);
                case kMethodGetSubunitCapabilities:
                    return handler.GetSubunitCapabilities(arguments);
                case kMethodGetSubunitDescriptor:
                    return handler.GetSubunitDescriptor(arguments);
                case kMethodReScanAVCUnits:
                    return handler.ReScanAVCUnits(arguments);
                case kMethodSendRawFCPCommand:
                    return handler.SendRawFCPCommand(arguments);
                case kMethodGetRawFCPCommandResult:
                    return handler.GetRawFCPCommandResult(arguments);
#ifdef REWINDDV_FOUNDATION
                case kMethodSubmitDeckControl:
                    return handler.SubmitDeckControl(arguments);
                case kMethodGetDeckControlResult:
                    return handler.GetDeckControlResult(arguments);
                case kMethodGetFoundationRoute:
                    return handler.GetFoundationRoute(arguments);
                case kMethodSubmitInspectorProbe:
                    return handler.SubmitInspectorProbe(arguments);
                case kMethodGetInspectorResult:
                    return handler.GetInspectorResult(arguments);
                case kMethodSubmitTransportCapabilityProbe:
                    return handler.SubmitTransportCapabilityProbe(arguments);
                case kMethodGetTransportCapabilityResult:
                    return handler.GetTransportCapabilityResult(arguments);
#endif
                default:
                    return kIOReturnUnsupported;
                }
            });
    };
    // No user-client/store lock is held while crossing queues. Keep the entire
    // borrowed-owner use on Default, where root teardown also runs.
    if (queue->OnQueue()) return invoke();
    return queue->RunAction(^{ return invoke(); });
}

#ifdef REWINDDV_FOUNDATION
kern_return_t HandleGetFoundationCapabilities(IOUserClientMethodArguments* arguments) {
    if (!arguments) {
        return kIOReturnBadArgument;
    }

    const auto capabilities = RewindDV::Foundation::DriverPolicy::Capabilities();
    OSData* data = OSData::withBytes(&capabilities, sizeof(capabilities));
    if (!data) {
        return kIOReturnNoMemory;
    }
    arguments->structureOutput = data;
    arguments->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t HandleGetInspectorCapabilities(IOUserClientMethodArguments* arguments) {
    if (!arguments || arguments->scalarInputCount != 0 || arguments->structureInput ||
        arguments->structureInputDescriptor) {
        return kIOReturnBadArgument;
    }
    const auto capabilities = RewindDV::Foundation::DriverPolicy::InspectorCapabilities();
    OSData* data = OSData::withBytes(&capabilities, sizeof(capabilities));
    if (!data) {
        return kIOReturnNoMemory;
    }
    arguments->structureOutput = data;
    arguments->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}

kern_return_t HandleGetTransportCapabilityCatalog(IOUserClientMethodArguments* arguments) {
    if (!arguments || arguments->scalarInputCount != 0 || arguments->structureInput ||
        arguments->structureInputDescriptor) {
        return kIOReturnBadArgument;
    }
    const auto catalog =
        RewindDV::Foundation::DriverPolicy::TransportCapabilityCatalog();
    OSData* data = OSData::withBytes(&catalog, sizeof(catalog));
    if (!data) {
        return kIOReturnNoMemory;
    }
    arguments->structureOutput = data;
    arguments->structureOutputDescriptor = nullptr;
    return kIOReturnSuccess;
}
#endif

kern_return_t HandleGetDriverVersion(IOUserClientMethodArguments* arguments) {
    ASFW_LOG_V3(UserClient, "GetDriverVersion called");
    ASFW_LOG_V3(UserClient, "  structureOutput=%p", arguments->structureOutput);
    ASFW_LOG_V3(UserClient, "  structureOutputDescriptor=%p",
                arguments->structureOutputDescriptor);

    const ASFW::Shared::DriverVersionInfo versionInfo =
        ASFW::Shared::DriverVersionInfo::Create(ASFW::Version::kSemanticVersion,
                                                ASFW::Version::kGitCommitShort,
                                                ASFW::Version::kGitCommitFull,
                                                ASFW::Version::kGitBranch,
                                                ASFW::Version::kBuildTimestamp,
                                                ASFW::Version::kBuildHost,
                                                ASFW::Version::kGitDirty);

    ASFW_LOG_V3(UserClient, "  Creating OSData with %zu bytes", sizeof(versionInfo));

    OSData* data = OSData::withBytes(&versionInfo, sizeof(versionInfo));
    if (!data) {
        ASFW_LOG_V0(UserClient, "  OSData::withBytes failed!");
        return kIOReturnNoMemory;
    }

    arguments->structureOutput = data;
    ASFW_LOG_V3(UserClient, "GetDriverVersion: %{public}s", ASFW::Version::kFullVersionString);
    return kIOReturnSuccess;
}

MethodDispatchResult DispatchDriverScalarSetters(ASFWDriver& driver,
                                                 IOUserClientMethodArguments* arguments,
                                                 uint64_t selector) {
    const auto value = GetFirstScalarInput(arguments);
    switch (selector) {
    case kMethodSetAsyncVerbosity:
        return value ? MethodDispatchResult{driver.SetAsyncVerbosity(*value)}
                     : MethodDispatchResult{kIOReturnBadArgument};
    case kMethodSetIsochVerbosity:
        return value ? MethodDispatchResult{driver.SetIsochVerbosity(*value)}
                     : MethodDispatchResult{kIOReturnBadArgument};
    case kMethodSetHexDumps:
        return value ? MethodDispatchResult{driver.SetHexDumps(*value)}
                     : MethodDispatchResult{kIOReturnBadArgument};
    case kMethodSetAudioAutoStart:
        return value ? MethodDispatchResult{driver.SetAudioAutoStart(*value)}
                     : MethodDispatchResult{kIOReturnBadArgument};
    default:
        return std::nullopt;
    }
}

kern_return_t HandleGetAudioAutoStart(ASFWDriver& driver,
                                      IOUserClientMethodArguments* arguments) {
    if (!arguments->scalarOutput || arguments->scalarOutputCount < 1) {
        return kIOReturnBadArgument;
    }

    uint32_t enabled = 0;
    const kern_return_t kr = driver.GetAudioAutoStart(&enabled);
    if (kr == kIOReturnSuccess) {
        arguments->scalarOutput[0] = enabled;
        arguments->scalarOutputCount = 1;
    }
    return kr;
}

kern_return_t HandleGetLogConfig(ASFWDriver& driver,
                                 IOUserClientMethodArguments* arguments) {
    if (!arguments->scalarOutput || arguments->scalarOutputCount < 2) {
        return kIOReturnBadArgument;
    }

    uint32_t asyncVerbosity = 0;
    uint32_t hexDumpsEnabled = 0;
    uint32_t isochVerbosity = 0;
    const kern_return_t kr =
        driver.GetLogConfig(&asyncVerbosity, &hexDumpsEnabled, &isochVerbosity);
    if (kr != kIOReturnSuccess) {
        return kr;
    }

    arguments->scalarOutput[0] = asyncVerbosity;
    arguments->scalarOutput[1] = hexDumpsEnabled;
    if (arguments->scalarOutputCount >= 4) {
        arguments->scalarOutput[2] = isochVerbosity;
        arguments->scalarOutput[3] = 0;  // reserved (was the removed dev TX-verifier flag)
        arguments->scalarOutputCount = 4;
    } else if (arguments->scalarOutputCount >= 3) {
        arguments->scalarOutput[2] = isochVerbosity;
        arguments->scalarOutputCount = 3;
    } else {
        arguments->scalarOutputCount = 2;
    }

    return kr;
}

MethodDispatchResult DispatchDriverControlMethods(ASFWDriver& driver,
                                                  IOUserClientMethodArguments* arguments,
                                                  uint64_t selector) {
    if (selector == kMethodGetDriverVersion) {
        return HandleGetDriverVersion(arguments);
    }
#ifdef REWINDDV_FOUNDATION
    if (selector == kMethodGetFoundationCapabilities) {
        return HandleGetFoundationCapabilities(arguments);
    }
    if (selector == kMethodGetInspectorCapabilities) {
        return HandleGetInspectorCapabilities(arguments);
    }
    if (selector == kMethodGetTransportCapabilityCatalog) {
        return HandleGetTransportCapabilityCatalog(arguments);
    }
#endif

    if (const auto setterResult =
            DispatchDriverScalarSetters(driver, arguments, selector);
        setterResult.has_value()) {
        return setterResult;
    }

    switch (selector) {
    case kMethodStartAudioStreaming:
    case kMethodStopAudioStreaming: {
        const auto guid = GetFirstScalarInput(arguments);
        if (!guid.has_value() || *guid == 0) {
            return MethodDispatchResult{kIOReturnBadArgument};
        }
        return MethodDispatchResult{selector == kMethodStartAudioStreaming
                                        ? driver.StartAudioStreaming(*guid)
                                        : driver.StopAudioStreaming(*guid)};
    }
    case kMethodGetAudioAutoStart:
        return HandleGetAudioAutoStart(driver, arguments);
    case kMethodGetLogConfig:
        return HandleGetLogConfig(driver, arguments);
    default:
        return std::nullopt;
    }
}

MethodDispatchResult DispatchIsochMethods(ASFW::UserClient::UserClientRuntimeState& runtimeState,
                                          IOUserClientMethodArguments* arguments,
                                          uint64_t selector) {
    switch (selector) {
    case kMethodTestIRMAllocation:
        return runtimeState.Isoch().TestIRMAllocation(arguments);
    case kMethodTestIRMRelease:
        return runtimeState.Isoch().TestIRMRelease(arguments);
    case kMethodTestCMPConnectOPCR:
        return runtimeState.Isoch().TestCMPConnectOPCR(arguments);
    case kMethodTestCMPDisconnectOPCR:
        return runtimeState.Isoch().TestCMPDisconnectOPCR(arguments);
    case kMethodTestCMPConnectIPCR:
        return runtimeState.Isoch().TestCMPConnectIPCR(arguments);
    case kMethodTestCMPDisconnectIPCR:
        return runtimeState.Isoch().TestCMPDisconnectIPCR(arguments);
    case kMethodStartIsochReceive:
        return runtimeState.Isoch().StartIsochReceive(arguments);
    case kMethodStopIsochReceive:
        return runtimeState.Isoch().StopIsochReceive(arguments);
    case kMethodGetIsochRxMetrics:
        return runtimeState.Isoch().GetIsochRxMetrics(arguments);
    case kMethodResetIsochRxMetrics:
        return runtimeState.Isoch().ResetIsochRxMetrics(arguments);
    case kMethodStartIsochTransmit:
        return runtimeState.Isoch().StartIsochTransmit(arguments);
    case kMethodStopIsochTransmit:
        return runtimeState.Isoch().StopIsochTransmit(arguments);
    case kMethodStartDVCapture:
        return runtimeState.Isoch().StartDVCapture(arguments);
    case kMethodStopDVCapture:
        return runtimeState.Isoch().StopDVCapture(arguments);
    default:
        return std::nullopt;
    }
}

constexpr uint64_t kMethodDiagGetBusContract      = 1000;
constexpr uint64_t kMethodDiagGetTopology         = 1001;
constexpr uint64_t kMethodDiagGetRoleCoordinator  = 1002;
constexpr uint64_t kMethodDiagGetOHCI             = 1003;
constexpr uint64_t kMethodDiagGetPHY              = 1004;
constexpr uint64_t kMethodDiagGetCSRContract      = 1005;
constexpr uint64_t kMethodDiagGetAsyncTrace       = 1006;
constexpr uint64_t kMethodDiagGetInboundCSRStats  = 1007;
constexpr uint64_t kMethodDiagClearAsyncTrace     = 1008;
constexpr uint64_t kMethodDiagGetBusManager       = 1009;
constexpr uint64_t kMethodDiagGetPostResetTiming  = 1010;
constexpr uint64_t kMethodDiagGetLogRecords       = 1011;
constexpr uint64_t kMethodDiagGetLogStats         = 1012;
constexpr uint64_t kMethodDiagGetAudioTelemetry   = 1013;
constexpr uint64_t kMethodDiagGetLogCatalog       = 1014;

MethodDispatchResult DispatchDiagnosticsMethods(
    ASFW::UserClient::UserClientRuntimeState& runtimeState,
    IOUserClientMethodArguments* arguments, uint64_t selector) {
    switch (selector) {
    case kMethodDiagGetBusContract:
        return runtimeState.Diagnostics().GetBusContract(arguments);
    case kMethodDiagGetTopology:
        return runtimeState.Diagnostics().GetTopology(arguments);
    case kMethodDiagGetRoleCoordinator:
        return runtimeState.Diagnostics().GetRoleCoordinator(arguments);
    case kMethodDiagGetOHCI:
        return runtimeState.Diagnostics().GetOHCI(arguments);
    case kMethodDiagGetPHY:
        return runtimeState.Diagnostics().GetPHY(arguments);
    case kMethodDiagGetCSRContract:
        return runtimeState.Diagnostics().GetCSRContract(arguments);
    case kMethodDiagGetAsyncTrace:
        return runtimeState.Diagnostics().GetAsyncTrace(arguments);
    case kMethodDiagGetInboundCSRStats:
        return runtimeState.Diagnostics().GetInboundCSRStats(arguments);
    case kMethodDiagClearAsyncTrace:
        return runtimeState.Diagnostics().ClearAsyncTrace(arguments);
    case kMethodDiagGetBusManager:
        return runtimeState.Diagnostics().GetBusManager(arguments);
    case kMethodDiagGetPostResetTiming:
        return runtimeState.Diagnostics().GetPostResetTiming(arguments);
    case kMethodDiagGetLogRecords:
        return runtimeState.Diagnostics().GetLogRecords(arguments);
    case kMethodDiagGetLogStats:
        return runtimeState.Diagnostics().GetLogStats(arguments);
    case kMethodDiagGetAudioTelemetry:
        return runtimeState.Diagnostics().GetAudioTelemetry(arguments);
    case kMethodDiagGetLogCatalog:
        return runtimeState.Diagnostics().GetLogCatalog(arguments);
    default:
        return std::nullopt;
    }
}

} // namespace

bool ASFWDriverUserClient::init() {
    if (!super::init()) {
        return false;
    }

    ivars = IONewZero(ASFWDriverUserClient_IVars, 1);
    if (!ivars) {
        return false;
    }

    ivars->statusRegistered = false;
    ivars->statusAction = nullptr;
    ivars->transactionListenerRegistered = false;
    ivars->transactionAction = nullptr;
    ivars->actionLock = IOLockAlloc();
    if (!ivars->actionLock) {
        IOSafeDeleteNULL(ivars, ASFWDriverUserClient_IVars, 1);
        return false;
    }
    ivars->stopping = false;

    auto runtimeState = std::make_unique<ASFW::UserClient::UserClientRuntimeState>();
    if (!runtimeState || !runtimeState->IsValid()) {
        if (ivars->actionLock) {
            IOLockFree(ivars->actionLock);
            ivars->actionLock = nullptr;
        }
        IOSafeDeleteNULL(ivars, ASFWDriverUserClient_IVars, 1);
        return false;
    }
    ivars->runtimeState = runtimeState.release();

    return true;
}

void ASFWDriverUserClient::free() {
    if (ivars) {
        if (ivars->driver && ivars->statusRegistered) {
            ivars->driver->UnregisterStatusListener(this);
        }
        if (ivars->actionLock) {
            IOLockLock(ivars->actionLock);
            ivars->stopping = true;
            if (ivars->statusAction) {
                ivars->statusAction->release();
                ivars->statusAction = nullptr;
            }
            if (ivars->transactionAction) {
                ivars->transactionAction->release();
                ivars->transactionAction = nullptr;
            }
            IOLockUnlock(ivars->actionLock);
            IOLockFree(ivars->actionLock);
            ivars->actionLock = nullptr;
        }

        if (ivars->runtimeState) {
            auto runtimeState =
                std::unique_ptr<ASFW::UserClient::UserClientRuntimeState>(
                    static_cast<ASFW::UserClient::UserClientRuntimeState*>(ivars->runtimeState));
            runtimeState->ReleaseOwner(this);
            ivars->runtimeState = nullptr;
        }
        IOSafeDeleteNULL(ivars, ASFWDriverUserClient_IVars, 1);
    }
    super::free();
}

kern_return_t IMPL(ASFWDriverUserClient, Start) {
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    // Store typed reference to driver
    ivars->driver = OSDynamicCast(ASFWDriver, provider);
    if (!ivars->driver) {
        return kIOReturnError;
    }

    if (ivars->actionLock) {
        IOLockLock(ivars->actionLock);
        ivars->stopping = false;
        IOLockUnlock(ivars->actionLock);
    }

    ivars->statusRegistered = false;
    if (ivars->statusAction) {
        ivars->statusAction->release();
        ivars->statusAction = nullptr;
    }

    auto* runtimeState = ASFW::UserClient::GetRuntimeState(this);
    if (!runtimeState || !runtimeState->BindDriver(ivars->driver, this)) {
        ASFW_LOG(UserClient, "Start() failed to initialize runtime state");
        return kIOReturnNoMemory;
    }

    ASFW_LOG(UserClient, "Start() completed - runtime state initialized");
    return kIOReturnSuccess;
}

kern_return_t IMPL(ASFWDriverUserClient, Stop) {
    if (ivars && ivars->actionLock) {
        IOLockLock(ivars->actionLock);
        ivars->stopping = true;
        ivars->statusRegistered = false;
        ivars->transactionListenerRegistered = false;
        if (ivars->statusAction) {
            ivars->statusAction->release();
            ivars->statusAction = nullptr;
        }
        if (ivars->transactionAction) {
            ivars->transactionAction->release();
            ivars->transactionAction = nullptr;
        }
        IOLockUnlock(ivars->actionLock);
    }

    if (ivars && ivars->driver) {
        ivars->driver->UnregisterStatusListener(this);
        ivars->driver = nullptr;
    }
    if (auto* runtimeState = ASFW::UserClient::GetRuntimeState(this); runtimeState != nullptr) {
        runtimeState->ReleaseOwner(this);
        runtimeState->ResetHandlers();
    }

    ASFW_LOG(UserClient, "Stop() completed");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t ASFWDriverUserClient::ExternalMethod(uint64_t selector,
                                                   IOUserClientMethodArguments* arguments,
                                                   const IOUserClientMethodDispatch* dispatch,
                                                   OSObject* target, void* reference) {
    (void)dispatch;
    (void)target;
    (void)reference;

    ASFW_LOG_V3(UserClient, "ExternalMethod called: selector=%llu", selector);

    if (!ivars || !ivars->driver) {
        ASFW_LOG(UserClient, "ExternalMethod: Not ready (ivars=%p driver=%p)", ivars,
                 ivars ? ivars->driver : nullptr);
        return kIOReturnNotReady;
    }

#ifdef REWINDDV_FOUNDATION
    const auto disposition =
        RewindDV::Foundation::DriverPolicy::ClassifyExternalMethod(selector);
    if (disposition ==
        RewindDV::Foundation::DriverPolicy::ExternalMethodDisposition::kReject) {
        ASFW_LOG(UserClient,
                 "RewindDV Foundation rejected forbidden external selector=%llu",
                 selector);
        return kIOReturnUnsupported;
    }
#endif

    auto* runtimeState = ASFW::UserClient::GetRuntimeState(this);
    if (runtimeState == nullptr || !runtimeState->HandlersReady()) {
        return kIOReturnNotReady;
    }
#ifdef REWINDDV_FOUNDATION
    if (selector >= RewindDV::Foundation::Receive::kStart &&
        selector <= RewindDV::Foundation::Receive::kAcknowledge) {
        return runtimeState->Isoch().FoundationReceive(arguments, selector);
    }
#endif

    if (auto result = DispatchBusResetMethods(*runtimeState, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchTopologyMethods(*runtimeState, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchStatusMethods(*runtimeState, *this, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchTransactionMethods(*runtimeState, *this, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchConfigRomMethods(*runtimeState, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchAVCMethods(*ivars->driver, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchDriverControlMethods(*ivars->driver, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchIsochMethods(*runtimeState, arguments, selector)) {
        return *result;
    }
    if (auto result = DispatchDiagnosticsMethods(*runtimeState, arguments, selector)) {
        return *result;
    }

    // main's SBP2 address-space management methods (46-49), wired into DICE's
    // dispatch-helper ExternalMethod.
    switch (selector) {
    case kMethodAllocateAddressRange:
        return runtimeState->SBP2().AllocateAddressRange(arguments, this);
    case kMethodDeallocateAddressRange:
        return runtimeState->SBP2().DeallocateAddressRange(arguments, this);
    case kMethodReadIncomingData:
        return runtimeState->SBP2().ReadIncomingData(arguments, this);
    case kMethodWriteLocalData:
        return runtimeState->SBP2().WriteLocalData(arguments, this);
    case kMethodCreateSBP2Session:
        return runtimeState->SBP2().CreateSBP2Session(arguments, this);
    case kMethodStartSBP2Login:
        return runtimeState->SBP2().StartSBP2Login(arguments, this);
    case kMethodGetSBP2SessionState:
        return runtimeState->SBP2().GetSBP2SessionState(arguments, this);
    case kMethodSubmitSBP2Inquiry:
        return runtimeState->SBP2().SubmitSBP2Inquiry(arguments, this);
    case kMethodGetSBP2InquiryResult:
        return runtimeState->SBP2().GetSBP2InquiryResult(arguments, this);
    case kMethodSubmitSBP2Command:
        return runtimeState->SBP2().SubmitSBP2Command(arguments, this);
    case kMethodGetSBP2CommandResult:
        return runtimeState->SBP2().GetSBP2CommandResult(arguments, this);
    case kMethodSubmitSBP2TaskManagement:
        return runtimeState->SBP2().SubmitSBP2TaskManagement(arguments, this);
    case kMethodReleaseSBP2Session:
        return runtimeState->SBP2().ReleaseSBP2Session(arguments, this);
    default:
        break;
    }

    return kIOReturnBadArgument;
}

// LOCALONLY user-client ABI entry point.
// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t ASFWDriverUserClient::AsyncRead(uint16_t destinationID, uint16_t addressHi,
                                              uint32_t addressLo, uint32_t length,
                                              uint16_t* handle) {
    // LOCALONLY method - implementation is in TransactionHandler via ExternalMethod case 8
    // This should never be called directly
    if (handle) {
        *handle = 0;
    }
    return kIOReturnUnsupported;
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t ASFWDriverUserClient::AsyncWrite(uint16_t destinationID, uint16_t addressHi,
                                               uint32_t addressLo, uint32_t length,
                                               const uint8_t* payload, uint16_t* handle) {
    // LOCALONLY method - implementation is in TransactionHandler via ExternalMethod case 9
    // This should never be called directly
    if (handle) {
        *handle = 0;
    }
    return kIOReturnUnsupported;
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t ASFWDriverUserClient::AsyncCompareSwap(uint16_t destinationID, uint16_t addressHi,
                                                     uint32_t addressLo, uint8_t size,
                                                     const uint8_t* compareValue, const uint8_t* newValue, // NOLINT(bugprone-easily-swappable-parameters)
                                                     uint16_t* handle, uint8_t* locked) {
    // LOCALONLY method - implementation is in TransactionHandler via ExternalMethod case 17
    // This should never be called directly
    if (handle) {
        *handle = 0;
    }
    if (locked) {
        *locked = 0;
    }
    return kIOReturnUnsupported;
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
void ASFWDriverUserClient::NotifyStatus(uint64_t sequence, uint32_t reason) {
    if (!ivars || !ivars->actionLock) {
        return;
    }

    OSAction* action = nullptr;
    IOLockLock(ivars->actionLock);
    if (!ivars->stopping && ivars->statusRegistered && ivars->statusAction) {
        action = ivars->statusAction;
        action->retain();
    }
    IOLockUnlock(ivars->actionLock);

    if (!action) {
        return;
    }

    IOUserClientAsyncArgumentsArray data{};
    data[0] = sequence;
    data[1] = reason;
    AsyncCompletion(action, kIOReturnSuccess, data, 2);
    action->release();
}

void ASFWDriverUserClient::NotifyTransactionComplete(uint16_t handle, uint32_t status) {
    if (!ivars || !ivars->actionLock) {
        return;
    }

    ASFW_LOG(UserClient, "NotifyTransactionComplete: handle=0x%04x status=0x%08x", handle, status);

    OSAction* action = nullptr;
    IOLockLock(ivars->actionLock);
    if (!ivars->stopping && ivars->transactionListenerRegistered && ivars->transactionAction) {
        action = ivars->transactionAction;
        action->retain();
    }
    IOLockUnlock(ivars->actionLock);

    if (!action) {
        return;
    }

    IOUserClientAsyncArgumentsArray data{};
    data[0] = handle;
    data[1] = status;
    AsyncCompletion(action, kIOReturnSuccess, data, 2);
    action->release();
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
kern_return_t ASFWDriverUserClient::GetTransactionResult(uint16_t handle, uint32_t* status,
                                                         uint32_t* dataLength, uint8_t* data,
                                                         uint32_t maxDataLength) {
    // LOCALONLY method - implementation is in TransactionHandler via ExternalMethod case 12
    // This should never be called directly
    if (status)
        *status = 0;
    if (dataLength)
        *dataLength = 0;
    return kIOReturnUnsupported;
}

kern_return_t IMPL(ASFWDriverUserClient, CopyClientMemoryForType) {
    if (!memory) {
        return kIOReturnBadArgument;
    }

    if (!ivars || !ivars->driver) {
        return kIOReturnNotReady;
    }

#ifdef REWINDDV_FOUNDATION
    if (!RewindDV::Foundation::DriverPolicy::IsAllowedClientMemoryType(type)) {
        return kIOReturnUnsupported;
    }
#endif

    // Type 0: shared status memory. Type 1: DV capture ring.
    if (type == 0) {
        return ivars->driver->CopySharedStatusMemory(options, memory);
    }
    if (type == 1) {
        auto* runtime = ASFW::UserClient::GetRuntimeState(this);
        if (!runtime || !runtime->ReceiveOwnerToken()) return kIOReturnNotReady;
        const uint64_t ownerToken = runtime->ReceiveOwnerToken();
        return ivars->driver->CopyDVCaptureMemory(
            ownerToken, options, memory);
    }
#ifdef REWINDDV_FOUNDATION
    if (type == RewindDV::Foundation::Receive::kMemoryType) {
        auto* ctx = static_cast<ServiceContext*>(ivars->driver->GetServiceContext());
        auto* runtime = ASFW::UserClient::GetRuntimeState(this);
        if (!ctx || !runtime || !runtime->ReceiveOwnerToken()) return kIOReturnNotReady;
        return ctx->foundationReceive.CopyMemory(
            runtime->ReceiveOwnerToken(), options, memory);
    }
#endif
    return kIOReturnUnsupported;
}

// Note: GetDiscoveredDevices is handled in ExternalMethod (selector 16), no stub needed
