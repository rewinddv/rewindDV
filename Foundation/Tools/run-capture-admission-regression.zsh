#!/bin/zsh
# Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
set -euo pipefail
# Extract only the real admission guard and main-actor scheduling methods. No
# real DriverBridge, IOKit implementation, app entry point or driver is linked.
[[ $# == 1 && -d "$1" ]] || { print -u2 'Supply an existing output directory'; exit 2; }
python3 - "$1" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
bridge = pathlib.Path('Foundation/App/DriverBridge.swift').read_text()
model = pathlib.Path('Foundation/App/RewindDVApp.swift').read_text()
a = bridge.index('      try Task.checkCancellation()', bridge.index('  func beginLiveReceive'))
b = bridge.index('      finalLiveStatistics = nil', a)
guard = bridge[a:b]
a = model.index('  func pauseExternalTransportObservation()')
b = model.index('\n  var selectedDeck:', a)
methods = model[a:b]
# Test-only suspension after the real join, before production admission.
methods = methods.replace("    await externalTransportObserver.stopAndJoin()",
  "    await externalTransportObserver.stopAndJoin()\n    if let joinBoundary { await joinBoundary.wait() }", 1)
fixture = pathlib.Path('Foundation/Tools/CaptureAdmissionRegression.swift').read_text()
fixture = fixture.replace('      // PRODUCTION_ADMISSION_GUARD', guard)
fixture = fixture.replace('  // PRODUCTION_MODEL_METHODS', methods)
tests = pathlib.Path('Foundation/Tools/CaptureAdmissionCases.swift.inc').read_text()
fixture = fixture.replace('    // COMPILED_CURRENT_TESTS', tests)
workspace = pathlib.Path('Foundation/App/UnifiedMonitorWorkspace.swift').read_text()
fixture += "\n" + workspace[workspace.index('struct CaptureStartAdmissionNotice: View {'):]
fixture += "\n" + pathlib.Path('Foundation/Tools/CaptureAdmissionInteraction.swift.inc').read_text()
(out/'CaptureAdmissionFixture.swift').write_text(fixture)
# A virtual clock advances only while the deterministic join barrier is held.
# It changes no production control flow and avoids a 31-second timing sleep.
monitor = pathlib.Path('Foundation/App/LiveMonitorModel.swift').read_text()
a = monitor.index('  func start(bridge:'); b = monitor.index('  private func verifyHDVFlight', a)
monitor = monitor[:a] + monitor[a:b].replace('ContinuousClock.now', 'AdmissionFixtureClock.now') + monitor[b:]
(out/'AdmissionTestLiveMonitorModel.swift').write_text(monitor)
PY
xcrun swiftc -swift-version 6 -parse-as-library -Onone \
  "$1/CaptureAdmissionFixture.swift" "$1/AdmissionTestLiveMonitorModel.swift" \
  Foundation/App/{DriverReadiness,LiveReceivePump,WindStopObserver,ControlWire,InspectorWire,AVCSpecificationCatalog,LiveDVPreview,LiveAudioMonitor,LiveDVFrameDecoder,DVMetalFieldProcessor}.swift \
  Foundation/Sources/RewindDVMonitorCore/*.swift \
  Foundation/Sources/RewindDVArchiveCore/*.swift \
  -o "$1/CaptureAdmissionRegression"
"$1/CaptureAdmissionRegression"
