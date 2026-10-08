#!/bin/zsh
# Actual controller construction, Stop, root-cycle closure and scheduler. Hardware
# accesses use the host stub; the unused reset policy entry aborts if reached.
# Private access is enabled only for this fixture; no production method is replaced.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: run-controller-lifetime-regression.zsh pinned-googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$output"
flags=(-std=c++23 -DASFW_HOST_TEST -DREWINDDV_FOUNDATION -IFoundation/Config -g -fno-access-control -fblocks -ffunction-sections -fdata-sections -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -Wno-character-conversion -Wno-deprecated-copy -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Hardware -IASFWDriver/Testing -Idocs -IAppleHeaders -I"$gtest/googletest/include" -I"$gtest/googletest")
xcrun clang++ $flags tests/core/ControllerDeferredLifetimeTests.cpp \
 ASFWDriver/Controller/{ControllerCoreLifecycle,ControllerCoreDiscovery,ControllerCoreFacades,ControllerConfig}.cpp \
 ASFWDriver/Scheduling/Scheduler.cpp ASFWDriver/Hardware/InterruptManager.cpp \
 ASFWDriver/Bus/Role/{RoleCoordinator,RolePolicy,CycleObserver}.cpp \
 ASFWDriver/Bus/BusManager/{CyclePolicyCoordinator,RootSelectionCoordinator,GapPolicyCoordinator,PowerLinkPolicyCoordinator,BusManagerPolicyCoordinator}.cpp \
 ASFWDriver/Bus/CSR/{SpeedMapService,TopologyMapService,TopologyMapBuilder}.cpp \
 ASFWDriver/Bus/IRM/{IRMFallbackCoordinator,LocalIRMResourceController,LocalCSRAccessor}.cpp \
 ASFWDriver/Bus/BusManager/{BusManagerElectionDriver,BusManagerElection}.cpp \
 ASFWDriver/Bus/Timing/PostResetTimingCoordinator.cpp \
 ASFWDriver/Bus/{TopologyManager,SelfIDStreamParser,SelfIDTopologyNormalizer}.cpp \
 ASFWDriver/Controller/ControllerStateMachine.cpp ASFWDriver/Async/FireWireBusImpl.cpp \
 ASFWDriver/Common/BarrierUtils.cpp tests/support/ControllerLifetimeOffPathStub.cpp \
 tests/support/{HardwareInterfaceStub,LoggingStubs,SanitizerDefaults}.cpp ASFWDriver/Logging/LogRing.cpp \
 "$gtest/googletest/src/gtest-all.cc" "$gtest/googletest/src/gtest_main.cc" -pthread -Wl,-dead_strip -o "$output/ControllerDeferredLifetimeTests"
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$output/ControllerDeferredLifetimeTests"
