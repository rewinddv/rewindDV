#!/bin/zsh
set -euo pipefail
# Offline native preview harness, deliberately excludes DriverBridge/IOKit clients.
output=$1
harness=$2
case "$harness" in
  LiveAudioStarvationRegression|LivePreviewStartupRegression|LivePreviewRecoveryRegression|LivePreviewControlsRegression|LivePreviewBurstRegression) ;;
  *) exit 2 ;;
esac
preview_sources=(Foundation/App/{LiveAudioMonitor,LiveDVPreview,LiveDVFrameDecoder,DVMetalFieldProcessor}.swift)
if [[ "$harness" == LivePreviewControlsRegression ]]; then
  preview_sources+=(Foundation/App/OfflineDVPlayback.swift Foundation/App/LiveReceiveFlight.swift)
fi
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Foundation/Tools/$harness.swift \
  "${preview_sources[@]}" \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$output/$harness"
