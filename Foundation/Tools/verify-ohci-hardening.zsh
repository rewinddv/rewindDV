#!/bin/zsh
# Host-only selective OHCI regressions. No hardware, installation or app launch.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: verify-ohci-hardening.zsh googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
audit_output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$audit_output"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$audit_output/ModuleCache.noindex"
flags=(-std=c++23 -DASFW_HOST_TEST -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
  -Wno-character-conversion -Wno-deprecated-copy
  -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Core
  -IASFWDriver/Bus -IASFWDriver/Logging -IASFWDriver/Hardware -IASFWDriver/Testing
  -IASFWDriver/Discovery -Idocs -IAppleHeaders
  -I"$gtest/googletest/include" -I"$gtest/googletest"
  -I"$gtest/googlemock/include" -I"$gtest/googlemock")
xcrun clang++ $flags -c "$gtest/googletest/src/gtest-all.cc" -o "$audit_output/gtest.o"
xcrun clang++ $flags -c "$gtest/googletest/src/gtest_main.cc" -o "$audit_output/main.o"
xcrun clang++ $flags -c "$gtest/googlemock/src/gmock-all.cc" -o "$audit_output/gmock.o"
common=(tests/support/SanitizerDefaults.cpp tests/support/LoggingStubs.cpp ASFWDriver/Logging/LogRing.cpp
  "$audit_output/gtest.o" "$audit_output/main.o" "$audit_output/gmock.o")
run_suite() {
  local suite=$1
  shift
  xcrun clang++ $flags "$@" $common -pthread -o "$audit_output/$suite"
  ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$audit_output/$suite" --gtest_brief=1 \
    >"$audit_output/$suite.log" 2>&1 || { tail -80 "$audit_output/$suite.log"; return 1; }
  tail -3 "$audit_output/$suite.log"
}
run_suite ContextControlTests tests/async/ContextControlTests.cpp ASFWDriver/Async/Engine/ContextManager.cpp ASFWDriver/Async/DMAMemoryImpl.cpp \
  tests/support/HardwareInterfaceStub.cpp ASFWDriver/Async/Tx/DescriptorBuilder.cpp \
  ASFWDriver/Shared/Rings/DescriptorRing.cpp ASFWDriver/Shared/Rings/BufferRing.cpp \
  ASFWDriver/Shared/Memory/DMAMemoryManager.cpp ASFWDriver/Common/BarrierUtils.cpp
run_suite ATManagerHotAppendTests tests/async/ATManagerHotAppendTests.cpp \
  tests/support/HardwareInterfaceStub.cpp ASFWDriver/Async/Tx/DescriptorBuilder.cpp \
  ASFWDriver/Shared/Rings/DescriptorRing.cpp ASFWDriver/Shared/Memory/DMAMemoryManager.cpp \
  ASFWDriver/Common/BarrierUtils.cpp
for suite in BufferRingDMATests ARStreamProcessorTests ARStreamFuzzTests; do
  run_suite "$suite" "tests/async/$suite.cpp" ASFWDriver/Shared/Rings/BufferRing.cpp \
    ASFWDriver/Async/Rx/ARPacketParser.cpp ASFWDriver/Common/BarrierUtils.cpp
done
run_suite InterruptEventSequencerTests tests/core/InterruptEventSequencerTests.cpp
run_suite BusResetCoordinatorTests tests/core/BusResetCoordinatorTests.cpp \
  ASFWDriver/Bus/GenerationTracker.cpp ASFWDriver/Async/Track/LabelAllocator.cpp \
  ASFWDriver/Bus/BusResetCoordinator.cpp \
  ASFWDriver/Bus/BusResetCoordinatorFSM.cpp \
  ASFWDriver/Bus/BusResetCoordinatorActions.cpp \
  ASFWDriver/Bus/Timing/PostResetTimingCoordinator.cpp \
  ASFWDriver/Bus/BusResetCoordinatorDiscoveryDelay.cpp \
  ASFWDriver/Bus/BusManager.cpp \
  ASFWDriver/Bus/GapCountOptimizer.cpp \
  ASFWDriver/Bus/SelfIDCapture.cpp \
  ASFWDriver/Bus/TopologyManager.cpp \
  ASFWDriver/Bus/SelfIDStreamParser.cpp \
  ASFWDriver/Bus/SelfIDTopologyNormalizer.cpp \
  ASFWDriver/Bus/CSR/TopologyMapService.cpp \
  ASFWDriver/Bus/CSR/TopologyMapBuilder.cpp \
  ASFWDriver/Common/BarrierUtils.cpp \
  ASFWDriver/Hardware/InterruptManager.cpp \
  tests/support/BusResetCoordinatorDepsStubs.cpp \
  tests/support/HardwareInterfaceStub.cpp
run_suite TrackingRejectionTests tests/async/TrackingRejectionTests.cpp \
  ASFWDriver/Async/Core/Transaction.cpp ASFWDriver/Async/Core/TransactionManager.cpp \
  ASFWDriver/Async/Track/LabelAllocator.cpp ASFWDriver/Async/Track/PayloadRegistry.cpp \
  ASFWDriver/Shared/Memory/PayloadHandle.cpp
run_suite ReceiveStartOrderTests tests/async/ReceiveStartOrderTests.cpp \
  ASFWDriver/Hardware/HardwareInterface.cpp ASFWDriver/Isoch/Receive/IsochReceiveContext.cpp \
  ASFWDriver/Isoch/Receive/IsochRxDmaRing.cpp ASFWDriver/Shared/Rings/DescriptorRing.cpp \
  ASFWDriver/Shared/Rings/BufferRing.cpp ASFWDriver/Common/BarrierUtils.cpp
run_suite HardwareInterfaceOrderTests tests/core/HardwareInterfaceOrderTests.cpp \
  ASFWDriver/Hardware/HardwareInterface.cpp ASFWDriver/Common/BarrierUtils.cpp
run_suite SelfIDCaptureTests tests/core/SelfIDCaptureTests.cpp \
  ASFWDriver/Bus/SelfIDCapture.cpp ASFWDriver/Bus/SelfIDStreamParser.cpp \
  ASFWDriver/Common/BarrierUtils.cpp tests/support/HardwareInterfaceStub.cpp
run_suite ConfigROMStagerTests tests/core/ConfigROMStagerTests.cpp \
  ASFWDriver/ConfigROM/Local/ConfigROMStager.cpp ASFWDriver/ConfigROM/Local/ConfigROMBuilder.cpp \
  ASFWDriver/Common/BarrierUtils.cpp tests/support/HardwareInterfaceStub.cpp
run_suite IsochReceiveOwnershipTests tests/core/IsochReceiveOwnershipTests.cpp \
  ASFWDriver/Isoch/Receive/IsochRxDmaRing.cpp ASFWDriver/Shared/Rings/BufferRing.cpp \
  ASFWDriver/Common/BarrierUtils.cpp
run_suite CyclePolicyTests tests/core/CyclePolicyCoordinatorTests.cpp tests/core/CyclePolicyExecutorTests.cpp \
  ASFWDriver/Bus/BusManager/CyclePolicyCoordinator.cpp
run_suite FWTypesTests tests/core/FWTypesTests.cpp
run_suite BusResetPacketCaptureTests tests/core/BusResetPacketCaptureTests.cpp ASFWDriver/Debug/BusResetPacketCapture.cpp
run_suite CSRContractVerifierTests tests/common/CSRContractVerifierTests.cpp \
  ASFWDriver/Bus/CSR/CSRContractVerifier.cpp ASFWDriver/Bus/CSR/CSRResponder.cpp \
  ASFWDriver/Bus/CSR/TopologyMapService.cpp ASFWDriver/Bus/CSR/TopologyMapBuilder.cpp \
  ASFWDriver/Bus/CSR/SpeedMapService.cpp ASFWDriver/Bus/IRM/LocalCSRAccessor.cpp \
  ASFWDriver/Bus/IRM/LocalIRMResourceController.cpp tests/support/HardwareInterfaceStub.cpp
print "Selective OHCI host suites passed."
