#!/bin/zsh
# Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
# OFFLINE ONLY. Links production workspace types, never constructs RewindDVApp
# or opens a bridge. Only the test's main entry point runs. Audio is muted.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing task-local output directory'; exit 2; }
output=${1:A}
cp Foundation/App/LiveMonitorModel.swift "$output/OfflineReplayLiveMonitorModel.swift"
cat Foundation/Tools/OfflineWorkspaceReplay.swift.inc >> "$output/OfflineReplayLiveMonitorModel.swift"
app_sources=(Foundation/App/*.swift)
app_sources=(${app_sources:#Foundation/App/LiveMonitorModel.swift})
xcrun clang -mmacosx-version-min=26.0 -c Foundation/App/LiveReceiveAtomics.c -o "$output/atomics.o"
xcrun swiftc -swift-version 6 -parse-as-library -O -whole-module-optimization \
  -target arm64-apple-macos26.0 -D REWINDDV_OFFLINE_REGRESSION \
  -import-objc-header Foundation/App/LiveReceiveAtomics.h \
  Foundation/Tools/LiveWorkspacePerformanceRegression.swift "$output/OfflineReplayLiveMonitorModel.swift" \
  "${app_sources[@]}" Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift "$output/atomics.o" \
  -o "$output/LiveWorkspacePerformanceRegression"
# Run the resulting binary with a saved NTSC .dv and --ui-automation-no-driver.
