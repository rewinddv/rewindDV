#!/bin/zsh
set -euo pipefail
# Offline controller: this list deliberately excludes the real bridge/receiver.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing qualification output directory'; exit 2; }
output=$1
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Foundation/Tools/WholeTapeOrchestrationRegression.swift \
  Foundation/App/{WholeTapeCaptureModel,ControlWire,InspectorWire,AVCSpecificationCatalog}.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$output/WholeTapeOrchestrationRegression"
"$output/WholeTapeOrchestrationRegression"
