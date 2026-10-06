#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 1 ]] || { print -u2 'Usage: run-native-callback-drain-regression.zsh output-directory'; exit 2; }
output=${1:A}
mkdir -p "$output"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx clang++ -std=c++23 -g -fblocks -pthread \
  -DASFW_HOST_TEST -DASFW_NATIVE_RETIREMENT_TEST \
  -Itests/mocks -IASFWDriver/Testing -IAppleHeaders \
  -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
  Foundation/DriverPolicy/Tests/NativeCallbackDrainTests.cpp \
  -o "$output/NativeCallbackDrainTests"
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$output/NativeCallbackDrainTests"
