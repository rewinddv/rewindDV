#!/bin/zsh
set -euo pipefail
# Offline only. No GUI or driver service is opened.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing qualification directory'; exit 2; }
xcrun clang -c Foundation/App/LiveReceiveAtomics.c -o "$1/live-atomics.o"
xcrun swiftc -swift-version 6 -parse-as-library -O -D REWINDDV_OFFLINE_REGRESSION \
  -import-objc-header Foundation/App/LiveReceiveAtomics.h \
  Foundation/Tools/LiveReceiveRingRegression.swift Foundation/App/{ControlWire,LiveReceiveRing}.swift \
  "$1/live-atomics.o" -o "$1/LiveReceiveRingRegression"
"$1/LiveReceiveRingRegression"
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Foundation/Tools/LiveReceiveWriterRegression.swift Foundation/App/LiveReceiveFlight.swift \
  Foundation/Sources/RewindDVArchiveCore/CaptureDirectory.swift \
  -o "$1/LiveReceiveWriterRegression"
"$1/LiveReceiveWriterRegression"
