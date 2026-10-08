#!/bin/zsh
# Production command admission on host memory only; no hardware or driver launch.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: run-command-payload-regression.zsh pinned-googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$output"
xcrun clang++ -std=c++23 -DASFW_HOST_TEST -g -fsanitize=address,undefined \
  -fno-sanitize-recover=all -fno-omit-frame-pointer -Wno-character-conversion -Wno-deprecated-copy \
  -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Hardware \
  -IASFWDriver/Testing -Idocs -IAppleHeaders -I"$gtest/googletest/include" -I"$gtest/googletest" \
  tests/async/CommandPayloadAdmissionTests.cpp tests/support/SanitizerDefaults.cpp tests/support/LoggingStubs.cpp \
  ASFWDriver/Logging/LogRing.cpp ASFWDriver/Common/BarrierUtils.cpp \
  ASFWDriver/Bus/GenerationTracker.cpp \
  ASFWDriver/Async/AsyncSubsystem.cpp ASFWDriver/Async/Commands/{ReadCommand,WriteCommand,LockCommand,PhyCommand}.cpp \
  ASFWDriver/Async/Tx/{PayloadContext,PacketBuilder,DescriptorBuilder}.cpp \
  ASFWDriver/Shared/Memory/{DMAMemoryManager,PayloadHandle}.cpp ASFWDriver/Shared/Rings/DescriptorRing.cpp \
  ASFWDriver/Async/Track/{LabelAllocator,PayloadRegistry}.cpp \
  ASFWDriver/Async/Core/{Transaction,TransactionManager}.cpp \
  "$gtest/googletest/src/gtest-all.cc" "$gtest/googletest/src/gtest_main.cc" \
  -pthread -o "$output/CommandPayloadAdmissionTests"
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$output/CommandPayloadAdmissionTests"
