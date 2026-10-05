#!/bin/zsh
# Host-only connected FCP/response ordering regression; no hardware or install.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 1 ]] || { print -u2 'Usage: verify-fcp-response-ordering.zsh output-directory'; exit 2; }
audit_output=${1:A}
mkdir -p "$audit_output"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$audit_output/ModuleCache.noindex"
xcrun --sdk macosx clang++ \
  -std=c++23 \
  -Wall -Wextra -Werror \
  -Wno-unused-parameter -Wno-unused-private-field -Wno-missing-field-initializers \
  -Wno-unused-lambda-capture \
  -DASFW_HOST_TEST \
  -g \
  -fsanitize=address,undefined \
  -fno-sanitize-recover=all \
  -fno-omit-frame-pointer \
  -IASFWDriver/Hardware \
  -I. \
  -IASFWDriver \
  -IASFWDriver/Testing \
  -Itests/mocks \
  -Itests/support \
  -Idocs \
  -IAppleHeaders \
  -Wno-character-conversion \
  -Wno-deprecated-copy \
  Foundation/DriverPolicy/FoundationDriverPolicy.cpp \
  Foundation/DriverPolicy/Tests/FoundationFCPQuadletPipelineTests.cpp \
  ASFWDriver/Async/Rx/ARPacketParser.cpp \
  ASFWDriver/Async/Rx/PacketRouter.cpp \
  ASFWDriver/Async/Rx/LocalRequestDispatch.cpp \
  ASFWDriver/Protocols/AVC/FCPTransport.cpp \
  ASFWDriver/Discovery/DeviceRegistry.cpp \
  ASFWDriver/Discovery/FWDevice.cpp \
  ASFWDriver/Discovery/FWUnit.cpp \
  ASFWDriver/Debug/AsyncTraceCapture.cpp \
  ASFWDriver/Async/Tx/ResponseSender.cpp \
  ASFWDriver/Async/Tx/DescriptorBuilder.cpp \
  ASFWDriver/Shared/Rings/DescriptorRing.cpp \
  ASFWDriver/Shared/Memory/DMAMemoryManager.cpp \
  ASFWDriver/Common/BarrierUtils.cpp \
  tests/support/ResponseSenderProductionDependenciesStub.cpp \
  tests/support/HardwareInterfaceStub.cpp \
  tests/support/LoggingStubs.cpp \
  tests/support/SanitizerDefaults.cpp \
  ASFWDriver/Logging/LogRing.cpp \
  -o "$audit_output/fcp-response-ordering"
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$audit_output/fcp-response-ordering"
print "FCP response submission ordering and failure regressions passed (host only)."
