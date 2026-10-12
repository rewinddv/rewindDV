#!/bin/zsh
# Host-only regression runner. No app/driver launch or hardware access.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: verify-upstream-hardening.zsh googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
audit_output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$audit_output"
# Deliberately omit -fno-sanitize-recover here: prove the compiled defaults,
# without inherited environment, actually fail otherwise-recoverable findings.
xcrun clang++ -std=c++23 -g -O0 -fsanitize=address,undefined \
  -DASFW_HOST_TEST -DNDEBUG -I. -Itests/mocks -IASFWDriver/Testing -Idocs -IAppleHeaders \
  tests/support/SanitizerFailureProbe.cpp tests/support/SanitizerDefaults.cpp \
  -o "$audit_output/sanitizer-failure-probe"
for sanitizer in asan ubsan overrelease; do
  if env -u ASAN_OPTIONS -u UBSAN_OPTIONS "$audit_output/sanitizer-failure-probe" "$sanitizer" \
      >"$audit_output/$sanitizer-negative-control.log" 2>&1; then
    print -u2 "ERROR: $sanitizer finding did not fail the negative control"
    exit 1
  fi
  if [[ $sanitizer != ubsan ]]; then
    grep -q 'AddressSanitizer: heap-use-after-free' "$audit_output/$sanitizer-negative-control.log"
  else
    grep -q 'runtime error: signed integer overflow' "$audit_output/$sanitizer-negative-control.log"
  fi
done
print 'ASan and UBSan negative controls failed as required.'
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
run_suite HostOwnershipTests tests/support/HostOwnershipTests.cpp tests/support/PostedWorkEpochTests.cpp
run_suite TopologySpeedTests tests/core/TopologySpeedTests.cpp
run_suite LinkSpeedClampTests tests/async/LinkSpeedClampTests.cpp \
  tests/support/AsyncSubsystemContractStub.cpp tests/support/HardwareInterfaceStub.cpp \
  ASFWDriver/Async/FireWireBusImpl.cpp ASFWDriver/Bus/TopologyManager.cpp \
  ASFWDriver/Bus/SelfIDStreamParser.cpp ASFWDriver/Bus/SelfIDTopologyNormalizer.cpp \
  ASFWDriver/Bus/GenerationTracker.cpp ASFWDriver/Async/Track/LabelAllocator.cpp \
  ASFWDriver/Async/Track/PayloadRegistry.cpp ASFWDriver/Async/Core/Transaction.cpp \
  ASFWDriver/Async/Core/TransactionManager.cpp ASFWDriver/Discovery/SpeedPolicy.cpp
run_suite CompletionRefactorPlanTests tests/async/CompletionRefactorPlanTests.cpp \
  ASFWDriver/Async/Core/Transaction.cpp ASFWDriver/Async/Core/TransactionManager.cpp \
  ASFWDriver/Async/Track/LabelAllocator.cpp ASFWDriver/Shared/Memory/PayloadHandle.cpp
run_suite IRMClientHardeningTests tests/irm/IRMClientHardeningTests.cpp ASFWDriver/Bus/IRM/IRMClient.cpp
run_suite HardwareInterfaceOrderTests tests/core/HardwareInterfaceOrderTests.cpp \
  ASFWDriver/Hardware/HardwareInterface.cpp ASFWDriver/Common/BarrierUtils.cpp
run_suite CyclePolicyTests tests/core/CyclePolicyCoordinatorTests.cpp tests/core/CyclePolicyExecutorTests.cpp \
  ASFWDriver/Bus/BusManager/CyclePolicyCoordinator.cpp
run_suite FCPTransportTests tests/protocols/FCPTransportTests.cpp tests/protocols/FCPHandleLifetimeTests.cpp \
  ASFWDriver/Async/Track/LabelAllocator.cpp \
  ASFWDriver/Protocols/AVC/FCPTransport.cpp ASFWDriver/Discovery/DeviceRegistry.cpp \
  ASFWDriver/Discovery/FWDevice.cpp ASFWDriver/Discovery/FWUnit.cpp
run_suite ResponseSenderHeaderFormatTests tests/async/ResponseSenderHeaderFormatTests.cpp \
  ASFWDriver/Async/Tx/ResponseSender.cpp ASFWDriver/Async/Tx/DescriptorBuilder.cpp \
  ASFWDriver/Shared/Rings/DescriptorRing.cpp ASFWDriver/Shared/Memory/DMAMemoryManager.cpp \
  ASFWDriver/Common/BarrierUtils.cpp tests/support/ResponseSenderProductionDependenciesStub.cpp \
  tests/support/HardwareInterfaceStub.cpp
ruby Foundation/DriverPolicy/Tests/ConfigROMExportSourceTests.rb
ruby Foundation/DriverPolicy/Tests/FoundationAllocationLogSourceTests.rb
print 'Upstream hardening host suites passed (AddressSanitizer + UndefinedBehaviorSanitizer).'
