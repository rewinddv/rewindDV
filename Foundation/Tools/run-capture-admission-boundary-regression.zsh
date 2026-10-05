#!/bin/zsh
# Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing output directory'; exit 2; }
python3 - "$1" <<'PY'
import pathlib, sys
bridge = pathlib.Path('Foundation/App/DriverBridge.swift').read_text()
a = bridge.index('  func beginLiveReceive('); b = bridge.index('\n  func readLiveBatch()', a)
fixture = pathlib.Path('Foundation/Tools/CaptureAdmissionBoundaryRegression.swift').read_text()
c = bridge.index('  func rediscoverAfterBusReset('); d = bridge.index('\n  func perform(', c)
pathlib.Path(sys.argv[1], 'AdmissionBoundaryFixture.swift').write_text(fixture.replace('  // PRODUCTION_BEGIN_RECEIVE', bridge[a:b]).replace('  // PRODUCTION_REDISCOVERY', bridge[c:d]))
PY
xcrun swiftc -swift-version 6 -parse-as-library -Onone \
  "$1/AdmissionBoundaryFixture.swift" Foundation/App/{DriverReadiness,ControlWire}.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$1/AdmissionBoundaryRegression"
"$1/AdmissionBoundaryRegression"
