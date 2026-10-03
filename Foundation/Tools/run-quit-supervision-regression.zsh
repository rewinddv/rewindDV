#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
# Links production app types but never constructs RewindDVApp or calls the bridge.
# The harness alone is @main; synthetic receipts drive only model/delegate state.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing output directory'; exit 2; }
xcrun clang -c Foundation/App/LiveReceiveAtomics.c -o "$1/quit-live-atomics.o"
xcrun swiftc -swift-version 6 -parse-as-library -O -D REWINDDV_OFFLINE_REGRESSION \
  -import-objc-header Foundation/App/LiveReceiveAtomics.h \
  Foundation/Tools/QuitSupervisionRegression.swift Foundation/App/*.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  "$1/quit-live-atomics.o" -o "$1/QuitSupervisionRegression"
"$1/QuitSupervisionRegression" --ui-automation-no-driver
