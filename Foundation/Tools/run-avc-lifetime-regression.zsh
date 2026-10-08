#!/bin/zsh
# Host-only AV/C lifecycle regressions against production implementations.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: run-avc-lifetime-regression.zsh pinned-googletest-checkout output-directory'; exit 2; }
gtest=${1:A}
output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$output"
flags=(-fblocks -fno-access-control -ffunction-sections -fdata-sections -DREWINDDV_FOUNDATION -IFoundation/Config -std=c++23 -DASFW_HOST_TEST -g -fsanitize=address,undefined
  -fno-sanitize-recover=all -fno-omit-frame-pointer -Wno-character-conversion -Wno-deprecated-copy
  -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Hardware
  -IASFWDriver/Testing -Idocs -IAppleHeaders
  -I"$gtest/googletest/include" -I"$gtest/googletest")
xcrun clang++ $flags -c "$gtest/googletest/src/gtest-all.cc" -o "$output/gtest.o"
xcrun clang++ $flags -c "$gtest/googletest/src/gtest_main.cc" -o "$output/main.o"
common=(tests/support/SanitizerDefaults.cpp tests/support/LoggingStubs.cpp ASFWDriver/Logging/LogRing.cpp
  "$output/gtest.o" "$output/main.o")
xcrun clang++ $flags tests/protocols/AVCLifetimeRegressionTests.cpp \
  ASFWDriver/Protocols/AVC/{AVCDiscovery,AVCUnit,FCPTransport,AudioFunctionBlockCommand}.cpp \
  ASFWDriver/Protocols/AVC/Music/MusicSubunit.cpp \
  ASFWDriver/Protocols/AVC/Descriptors/{DescriptorAccessor,AVCInfoBlock}.cpp \
  ASFWDriver/Protocols/AVC/StreamFormats/StreamFormatParser.cpp \
  ASFWDriver/Protocols/AVC/Audio/AudioSubunit.cpp ASFWDriver/Protocols/AVC/Camera/CameraSubunit.cpp \
  ASFWDriver/Discovery/{DeviceRegistry,DeviceManager,FWDevice,FWUnit}.cpp \
  ASFWDriver/Audio/Protocols/DeviceStreamModeQuirks.cpp \
  ASFWDriver/Audio/Protocols/BeBoB/BeBoBPlug0StreamDiscovery.cpp \
  ASFWDriver/Audio/DriverKit/Config/{AudioProfileRegistry,AVC/BeBoBProfile}.cpp \
  ASFWDriver/Audio/Protocols/Oxford/{OxfordCsr,OxfwStreamFormats}.cpp \
  ASFWDriver/Audio/Protocols/Oxford/Apogee/{ApogeeDuetProtocol,ApogeeDuetDuplex,ApogeeParamsSerdes,ApogeeVendorCodec,ApogeeTransport}.cpp \
  ASFWDriver/Protocols/AVC/CMP/CMPClient.cpp ASFWDriver/Bus/IRM/IRMClient.cpp \
  $common -pthread -Wl,-dead_strip -o "$output/AVCLifetimeRegressionTests"
python3 - "$output" <<'RUN'
import sys,subprocess,pathlib,os
out=pathlib.Path(sys.argv[1]); failed=False
filters=['*DescriptorFallbackLifetimeTests*/*0','*DescriptorFallbackLifetimeTests*/*1',
         '*FormatContinuationLifetimeTests*','AVCLifetimeRegressionTests.*']
for i,filt in enumerate(filters):
    with (out/(str(i)+'.log')).open('w') as log:
        try:
            r=subprocess.run([str(out/'AVCLifetimeRegressionTests'),'--gtest_filter='+filt],stdout=log,stderr=subprocess.STDOUT,timeout=15)
            failed |= r.returncode != 0
        except subprocess.TimeoutExpired:
            log.write('\nTIMEOUT: test process terminated after 15 seconds\n');failed=True
    print((out/(str(i)+'.log')).read_text())
sys.exit(1 if failed else 0)
RUN
