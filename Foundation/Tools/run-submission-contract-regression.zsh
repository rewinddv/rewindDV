#!/bin/zsh
# Host-only bus admission, ROM, IRM/CMP and register-read regressions.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: run-submission-contract-regression.zsh pinned-googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$output"
flags=(-std=c++23 -DASFW_HOST_TEST -g -fsanitize=address,undefined
  -fno-sanitize-recover=all -fno-omit-frame-pointer -Wno-character-conversion -Wno-deprecated-copy
  -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Hardware
  -IASFWDriver/Testing -Idocs -IAppleHeaders
  -I"$gtest/googletest/include" -I"$gtest/googletest")
xcrun clang++ $flags -c "$gtest/googletest/src/gtest-all.cc" -o "$output/gtest.o"
xcrun clang++ $flags -c "$gtest/googletest/src/gtest_main.cc" -o "$output/main.o"
common=(tests/support/SanitizerDefaults.cpp tests/support/LoggingStubs.cpp ASFWDriver/Logging/LogRing.cpp
  "$output/gtest.o" "$output/main.o")
failed=0
run_suite() {
  local suite=$1
  shift
  xcrun clang++ $flags "$@" $common -pthread -o "$output/$suite"
  ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$output/$suite" \
    >"$output/$suite.log" 2>&1 || failed=1
  cat "$output/$suite.log"
}
run_suite AsyncBusContractTests tests/async/AsyncBusContractTests.cpp tests/discovery/ROMReaderLifetimeTests.cpp \
  tests/support/AsyncSubsystemContractStub.cpp tests/support/HardwareInterfaceStub.cpp \
  ASFWDriver/Async/FireWireBusImpl.cpp ASFWDriver/ConfigROM/Remote/ROMReader.cpp \
  ASFWDriver/Bus/{TopologyManager,SelfIDStreamParser,SelfIDTopologyNormalizer,GenerationTracker}.cpp \
  ASFWDriver/Async/Track/{LabelAllocator,PayloadRegistry}.cpp \
  ASFWDriver/Async/Core/{Transaction,TransactionManager}.cpp ASFWDriver/Discovery/SpeedPolicy.cpp
run_suite ROMScannerLifetimeTests tests/discovery/ROMScannerLifetimeTests.cpp tests/discovery/ROMScannerIRMVerifyTests.cpp \
  ASFWDriver/ConfigROM/Remote/{ROMScanner,ROMReader,ROMScanSession,ROMScanSessionDetails,ROMScanSessionIRM}.cpp \
  ASFWDriver/ConfigROM/Parse/ConfigROMParser.cpp ASFWDriver/Discovery/SpeedPolicy.cpp \
  ASFWDriver/Bus/{TopologyManager,SelfIDStreamParser,SelfIDTopologyNormalizer}.cpp
run_suite IRMClientHardeningTests tests/irm/IRMClientHardeningTests.cpp ASFWDriver/Bus/IRM/IRMClient.cpp
run_suite CMPConnectionTests tests/protocols/CMPConnectionTests.cpp \
  ASFWDriver/Protocols/AVC/CMP/CMPClient.cpp ASFWDriver/Discovery/DeviceRegistry.cpp
run_suite RegisterSubmissionTests tests/devices/RegisterSubmissionTests.cpp \
  ASFWDriver/Audio/Protocols/Oxford/OxfordCsr.cpp \
  ASFWDriver/Audio/Protocols/Oxford/Apogee/{ApogeeTransport,ApogeeVendorCodec}.cpp \
  ASFWDriver/Protocols/AVC/FCPTransport.cpp \
  ASFWDriver/Discovery/{DeviceRegistry,FWDevice,FWUnit}.cpp
run_suite QueuedReadAdmissionTests -DASFW_QUEUE_CONTRACT_TEST tests/async/QueuedReadAdmissionTests.cpp \
  tests/support/AsyncSubsystemContractStub.cpp ASFWDriver/Async/AsyncSubsystemCommandQueue.cpp \
  ASFWDriver/Bus/GenerationTracker.cpp ASFWDriver/Async/Track/{LabelAllocator,PayloadRegistry}.cpp \
  ASFWDriver/Async/Core/{Transaction,TransactionManager}.cpp
run_suite GenerationTrackerTests tests/core/GenerationTrackerTests.cpp \
  ASFWDriver/Bus/GenerationTracker.cpp ASFWDriver/Async/Track/LabelAllocator.cpp
run_suite BusManagerElectionTests tests/core/BusManagerElectionTests.cpp \
  ASFWDriver/Bus/BusManager/{BusManagerElection,BusManagerElectionDriver}.cpp \
  tests/support/BusResetCoordinatorStub.cpp ASFWDriver/Bus/IRM/{LocalIRMResourceController,LocalCSRAccessor}.cpp \
  ASFWDriver/Bus/Timing/PostResetTimingCoordinator.cpp ASFWDriver/Controller/ControllerConfig.cpp \
  ASFWDriver/Scheduling/Scheduler.cpp tests/support/HardwareInterfaceStub.cpp
run_suite GenerationIndexTests tests/discovery/GenerationIndexTests.cpp \
  ASFWDriver/ConfigROM/Store/ConfigROMStore.cpp \
  ASFWDriver/Discovery/{DeviceRegistry,DeviceManager,FWDevice,FWUnit}.cpp
exit "$failed"
