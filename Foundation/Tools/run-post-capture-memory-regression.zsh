#!/bin/zsh
set -euo pipefail
# Build only; invoking the executable requires explicit new fixture/log paths.
# No production DriverBridge or driver client is linked.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing output directory'; exit 2; }
xcrun swiftc -swift-version 6 -parse-as-library -O -D MEMORY_APP_HARNESS \
  -module-cache-path "$1/module-cache" \
  Foundation/Tools/PostCaptureMemoryRegression.swift \
  Foundation/App/{DriverReadiness,LiveMonitorModel,LiveReceivePump,WindStopObserver,ControlWire,InspectorWire,AVCSpecificationCatalog,LiveDVPreview,LiveAudioMonitor,LiveDVFrameDecoder,DVMetalFieldProcessor}.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$1/PostCaptureMemoryRegression"
