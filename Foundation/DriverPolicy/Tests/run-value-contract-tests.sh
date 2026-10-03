#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
value_test_dir=$(mktemp -d /tmp/rewinddv-value-tests.XXXXXX)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
compile() {
  xcrun --sdk macosx clang++ -std=c++23 -DASFW_HOST_TEST -g \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -Wno-character-conversion -Wno-deprecated-copy -I. -Itests/mocks -IASFWDriver \
    "$@" tests/support/SanitizerDefaults.cpp
}
compile Foundation/DriverPolicy/Tests/ClockConversionTests.cpp -o "$value_test_dir/clocks"
"$value_test_dir/clocks"
compile Foundation/DriverPolicy/Tests/AddressValueTests.cpp \
  ASFWDriver/Async/Tx/PacketBuilder.cpp tests/support/LoggingStubs.cpp \
  ASFWDriver/Logging/LogRing.cpp -o "$value_test_dir/addresses"
"$value_test_dir/addresses"
printf 'Host contract executables retained: %s\n' "$value_test_dir"
