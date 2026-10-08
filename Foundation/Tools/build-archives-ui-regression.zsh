#!/bin/zsh
set -euo pipefail
# Native view/model harness. No real bridge, driver, capture or tape access.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing qualification output directory'; exit 2; }
xcrun swiftc -swift-version 6 -parse-as-library -O \
  Foundation/Tools/FrameLoupeRegression.swift \
  Foundation/Tools/MultiPassUIRegression.swift \
  Foundation/App/{RewindDVSection,TapeEvidenceMapView,DVFrameForensicsView,GentleRecoveryView,MultiPassView,LiveDVFrameDecoder,DVMetalFieldProcessor}.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  -o "$1/FrameLoupeRegression"
