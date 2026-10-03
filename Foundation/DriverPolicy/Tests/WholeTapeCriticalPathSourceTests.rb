#!/usr/bin/env ruby
# Notification authorization is optional presentation work. It must never be
# awaited on the whole-tape transport/receive critical path.

source = File.read('Foundation/App/WholeTapeCaptureModel.swift')
abort 'whole-tape notification preparation must not be awaited' if
  source.include?('await prepareNotification()')

task = source.index('Task { [weak self] in await self?.prepareNotification() }')
preflight = source.index('let preflight = try await model.bridge.inspectDevice')
abort 'nonblocking notification preparation is missing' unless task
abort 'whole-tape preflight is missing' unless preflight
abort 'notification preparation must be launched before preflight without blocking it' unless task < preflight
abort 'notification test seam is missing' unless
  source.include?('notificationPreparationOverride: (@MainActor @Sendable () async -> Void)?')
abort 'notification delivery test seam is missing' unless
  source.include?('notificationDeliveryOverride: (@MainActor @Sendable (String, String) async -> Void)?')

puts 'Whole-tape critical-path source gate passed: notification preparation cannot delay transport or receive'

workspace = File.read('Foundation/App/UnifiedMonitorWorkspace.swift')
abort 'main STOP must route through the active job, not ordinary busy-gated transport' unless
  workspace.match?(/if wholeTape.active \{\s*\/\/ The job owns FCP.*?Button \{ wholeTape.requestStop\(\) \}.*?accessibilityIdentifier\("transport-stop"\).*?disabled\(!wholeTape.canRequestStop\)/m)
transport = workspace.split('private var transport: some View {', 2).last.split('private func transportButton', 2).first
abort 'active job status and physical STOP confirmation must stay outside collapsed sections' unless
  transport.include?('whole-tape-active-status') && transport.include?('WholeTapePhysicalStopConfirmation(wholeTape: wholeTape)')
puts 'Whole-tape STOP UI source gate passed: visible job-owned cancellation and physical confirmation'
