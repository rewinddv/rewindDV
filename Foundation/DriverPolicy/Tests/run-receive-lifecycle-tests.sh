#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
receive_test_dir=$(mktemp -d /tmp/rewinddv-receive-lifecycle.XXXXXX)
xcrun --sdk macosx clang++ -std=c++23 -O2 \
  Foundation/DriverPolicy/Tests/DMASafeCopyTests.cpp \
  -o "$receive_test_dir/dma-copy-tests"
"$receive_test_dir/dma-copy-tests"
xcrun --sdk macosx clang++ -std=c++23 -O2 -arch arm64 -S \
  Foundation/DriverPolicy/Tests/DMASafeCopyTests.cpp \
  -o "$receive_test_dir/dma-copy.s"
ruby Foundation/DriverPolicy/Tests/DMASafeCopyCodegenTests.rb "$receive_test_dir/dma-copy.s"
compile_receive_test() {
  receive_source=$1
  receive_output=$2
  shift 2
  xcrun --sdk macosx clang++ -std=c++23 -DASFW_HOST_TEST \
  -I. -IASFWDriver -IASFWDriver/Testing -Itests/mocks -Itests/support \
  -IASFWDriver/Hardware -Idocs -IAppleHeaders \
  -Wno-deprecated-copy -Wno-character-conversion \
  "$receive_source" "$@" \
  ASFWDriver/Isoch/IsochService.cpp \
  ASFWDriver/Isoch/Transmit/IsochTransmitContext.cpp \
  ASFWDriver/Isoch/Transmit/IsochTxDmaRing.cpp \
  ASFWDriver/Isoch/Transmit/IsochTxDescriptorSlab.cpp \
  ASFWDriver/Isoch/Receive/IsochReceiveContext.cpp \
  ASFWDriver/Isoch/Receive/IsochRxDmaRing.cpp \
  ASFWDriver/Isoch/Memory/IsochDMAMemoryManager.cpp \
  ASFWDriver/Shared/Memory/DMAMemoryManager.cpp \
  ASFWDriver/Shared/Rings/DescriptorRing.cpp \
  ASFWDriver/Shared/Rings/BufferRing.cpp \
  ASFWDriver/Common/BarrierUtils.cpp \
  tests/support/HardwareInterfaceStub.cpp tests/support/LoggingStubs.cpp \
  ASFWDriver/Logging/LogRing.cpp \
  -o "$receive_output"
}
compile_receive_test Foundation/DriverPolicy/Tests/IsochReceiveCompletionTests.cpp \
  "$receive_test_dir/receive-completion-tests"
"$receive_test_dir/receive-completion-tests"
compile_receive_test Foundation/DriverPolicy/Tests/FoundationReceiveLifecycleTests.cpp \
  "$receive_test_dir/receive-lifecycle-tests"
"$receive_test_dir/receive-lifecycle-tests"
compile_receive_test Foundation/DriverPolicy/Tests/FoundationRawReceiveTests.cpp \
  "$receive_test_dir/raw-receive-tests" \
  Foundation/DriverPolicy/FoundationReceiveService.cpp \
  ASFWDriver/Protocols/AVC/CMP/CMPClient.cpp \
  ASFWDriver/Bus/IRM/IRMClient.cpp \
  ASFWDriver/Discovery/DeviceRegistry.cpp \
  ASFWDriver/Discovery/FWDevice.cpp ASFWDriver/Discovery/FWUnit.cpp
"$receive_test_dir/raw-receive-tests"
xcrun --sdk macosx clang++ -std=c++23 -DASFW_HOST_TEST \
  -I. -IASFWDriver -IASFWDriver/Testing -IAppleHeaders \
  Foundation/DriverPolicy/Tests/RuntimeEpochTests.cpp \
  -o "$receive_test_dir/runtime-epoch-tests"
"$receive_test_dir/runtime-epoch-tests"
ruby Foundation/DriverPolicy/Tests/FoundationReceiveOuterGateTests.rb
ruby Foundation/DriverPolicy/Tests/FoundationRuntimeBorrowedClientSourceTests.rb
ruby Foundation/DriverPolicy/Tests/WholeTapeCriticalPathSourceTests.rb
echo "Host-only executable retained: $receive_test_dir/receive-lifecycle-tests"
