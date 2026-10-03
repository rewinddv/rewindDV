#!/usr/bin/env ruby
# Presentation contract only: do not open a driver or a DV file.
workspace = File.read('Foundation/App/UnifiedMonitorWorkspace.swift')
abort 'Inspector must not be collapsible in either module' if
  workspace.include?('CollapsibleWorkspaceSection(title: "Inspector"')
abort 'static Inspector must remain beside and top-aligned with Audio levels' unless
  workspace.match?(/HStack\(alignment: \.top, spacing: 18\) \{\s*meters\.frame\(width: 214\).*?inspector\.frame\(width: 240\)/m)
abort 'static Inspector needs a stable accessibility identifier' unless
  workspace.include?('.accessibilityIdentifier("workspace-inspector")')
abort 'Inspector must have exactly one info-circle heading' unless
  workspace.scan('Label("Inspector", systemImage: "info.circle")').length == 1
abort 'live status and playback source specifications must both remain available' unless
  workspace.include?('LiveTechnicalSpecificationsPanel(live: live, metadata: live.preview.metadata)') &&
  workspace.include?('playback.technicalSpecifications')
puts 'Static Inspector source contract passed: both modules, one heading, meter alignment and accessibility'
