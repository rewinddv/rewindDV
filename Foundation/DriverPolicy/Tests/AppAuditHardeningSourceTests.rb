#!/usr/bin/env ruby
# Wiring checks supplement executable fake-bridge and filesystem regressions.
# No app launch, driver connection, hardware, or source mutations.
app = File.read('Foundation/App/RewindDVApp.swift')
workspace = File.read('Foundation/App/UnifiedMonitorWorkspace.swift')
bridge = File.read('Foundation/App/DriverBridge.swift')
whole = File.read('Foundation/App/WholeTapeCaptureModel.swift')
live = File.read('Foundation/App/LiveMonitorModel.swift')
observers = File.read('Foundation/App/WindStopObserver.swift')
send_start = app.index('func send(') or abort 'missing command entrypoint'
send_finish = app.index('private func observeWindStop', send_start) || app.length
send_body = app[send_start...send_finish]
join = send_body.index('await beforeSubmission?()') or abort 'missing pre-submit owner handoff'
submit = send_body.index('try await bridge.perform(') or abort 'missing typed command submission'
abort 'handoff occurs after command submission' unless join < submit
abort 'manual STOP is not wired to the PLAY observer handoff' unless workspace.include?(
  'model.send(.stop, beforeSubmission: { await live.prepareForOperatorStop() }, onAccepted:')
abort 'compact evidence should have only one opt-in caller' unless app.scan('passiveTransport: true').length == 1
abort 'failed passive observation would spin/retry on the same route' unless app.include?('self.passiveObservationFailureRoute = route') &&
  app.include?('model.passiveTransportObservationAvailable,')
abort 'whole-tape receipts must remain immutable per-flight' if whole.include?('passiveTransport: true')
abort 'whole-tape alerts bypass unified loss review' unless whole.include?('let defects = result.needsLossReview')
abort 'bridge compact mode must require a route-bound transport-only query' unless bridge.include?(
  '!passiveTransport || (transportOnly && !tapeStateOnly && expectedRoute != nil)')
abort 'specification search failures are hidden' unless workspace.include?(
  'technicalSpecificationsStatus.localizedCaseInsensitiveContains("unavailable")')
abort 'capture headline bypasses loss review' unless workspace.include?('Label(result.completionHeadline,') &&
  workspace.include?('result.needsLossReview ? "exclamationmark.triangle.fill"')
%w[model.monitorSource model.selectedDeckID model.selectedRoute].each do |key|
  block = app[/\.onChange\(of: #{Regexp.escape(key)}\).*?\n      \}/m]
  abort "passive observer not joined on #{key}" unless block&.include?('await model.pauseExternalTransportObservation()')
end
abort 'passive callback waits indefinitely for receive startup' if app.include?('while live.busy, !live.active')
abort 'passive callback not source/route fenced' unless app.include?('self.monitorSource == .deck') && app.include?('self.selectedRoute == route')
abort 'replacement PLAY setup does not join previous setup' unless live.include?('await previousSetup?.value')
abort 'receive cleanup skips deferred setup owner' unless live.include?('await prepareForOperatorStop()\n      await tapeStopObserver.stopAndJoin()'.gsub('\\n', "\n"))
abort 'observer joins can clear a replacement task' unless observers.scan('if token == stopToken { task = nil }').length == 3
puts 'APP_AUDIT_HARDENING_SOURCE_PASS: STOP ordering, compact-evidence scope, visible search failures, honest completion'
