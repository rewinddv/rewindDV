#!/bin/zsh
set -euo pipefail
# Offline production monitor/observers/pump with a fake bridge and muted audio.
# The real DriverBridge, app entry point and driver client are never linked.
[[ ( $# == 1 || ( $# == 2 && "$2" == --terminal-only ) ) && -d "$1" ]] || { print -u2 'Supply an existing regression output directory [--terminal-only]'; exit 2; }
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Foundation/Tools/ManualStopTailRegression.swift \
  Foundation/App/{DriverReadiness,LiveMonitorModel,LiveReceivePump,WindStopObserver,ControlWire,InspectorWire,AVCSpecificationCatalog,LiveDVPreview,LiveAudioMonitor,LiveDVFrameDecoder,DVMetalFieldProcessor}.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$1/ManualStopTailRegression"
"$1/ManualStopTailRegression" "${@:2}"
