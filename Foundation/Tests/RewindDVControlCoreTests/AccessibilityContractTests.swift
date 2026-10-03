import Foundation
import Testing

private var foundationRoot: URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
}

@Test func scrollableAppViewsUseStableSemanticSectionsInsteadOfNativeGroupBox() throws {
  let app = foundationRoot.appendingPathComponent("App")
  let files = [
    "AcknowledgmentsView.swift", "DVPackMetadataView.swift", "DeviceInspectorView.swift",
    "ReviewedRangeView.swift", "RewindDVApp.swift", "TapeEvidenceMapView.swift",
    "RewindDVSection.swift", "DVFrameForensicsView.swift",
    "UnifiedMonitorWorkspace.swift",
  ]
  for file in files {
    let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
    #expect(!source.contains("GroupBox("), "\(file) reintroduced the macOS 26 accessibility crash trigger")
  }
  let root = try String(
    contentsOf: app.appendingPathComponent("RewindDVSection.swift"), encoding: .utf8)
  #expect(root.contains("struct RewindDVSection"))
  #expect(root.contains(".accessibilityElement(children: .contain)"))
}

@Test func workspaceExposesStableAutomationIdentifiersAndHidesDecorativeRenderers() throws {
  let app = foundationRoot.appendingPathComponent("App")
  let root = try String(contentsOf: app.appendingPathComponent("RewindDVApp.swift"), encoding: .utf8)
  let workspace = try String(
    contentsOf: app.appendingPathComponent("UnifiedMonitorWorkspace.swift"), encoding: .utf8)
  let video = try String(
    contentsOf: app.appendingPathComponent("MonitorVideoSurface.swift"), encoding: .utf8)
  let meters = try String(contentsOf: app.appendingPathComponent("MeterBank.swift"), encoding: .utf8)
  for identifier in [
    "primary-sidebar", "sidebar-", "page-", "workspace-page", "monitor-source",
    "monitor-time-display", "capture-elapsed-time", "transport-", "deck-selector", "capture-whole-tape",
    "start-ingest", "ingest-verification-progress", "open-verified-capture",
  ] {
    #expect(root.contains(identifier) || workspace.contains(identifier), "missing \(identifier)")
  }
  #expect(video.contains("setAccessibilityElement(false)"))
  #expect(meters.contains(".accessibilityHidden(true)"))
}

@Test func developmentStatusChannelIsObservationOnlyAndExplicitlyEnabled() throws {
  let source = try String(
    contentsOf: foundationRoot.appendingPathComponent("App/AutomationStatusSnapshot.swift"),
    encoding: .utf8)
  #expect(source.contains("--automation-status"))
  #expect(source.contains("REWINDDV_AUTOMATION_STATUS"))
  #expect(source.contains("current-status.json"))
  #expect(source.contains("--ui-automation-no-driver"))
  #expect(source.contains(".posixPermissions: 0o600"))
  #expect(!source.contains("DriverBridge"))
  #expect(!source.contains("submitActivation"))
  #expect(!source.contains("DeckCommand"))
}

@Test func accessibilityIsolationHarnessStaysDriverFreeAndCoversFailureSurfaces() throws {
  let source = try String(
    contentsOf: foundationRoot.appendingPathComponent(
      "Tools/AccessibilityIsolationHarness/AccessibilityIsolationHarness.swift"),
    encoding: .utf8)
  for mode in ["static", "navigation", "canvas", "timeline", "video", "combined"] {
    #expect(source.contains("\"\(mode)\""), "missing isolation mode \(mode)")
  }
  #expect(!source.contains("DriverBridge"))
  #expect(!source.contains("IOKit"))
  #expect(!source.contains("SystemExtensions"))
}

@Test func appOnlyAccessibilityPackagerPreservesQualifiedDriverBytes() throws {
  let source = try String(
    contentsOf: foundationRoot.appendingPathComponent("Tools/package-b172-app-only.zsh"),
    encoding: .utf8)
  #expect(source.contains("source_dext_hash="))
  #expect(source.contains("== \"$source_dext_hash\""))
  #expect(source.contains("cp \"$built_app/Contents/MacOS/RewindDV\""))
  #expect(!source.contains("codesign --force --sign \"$signing_identity\" \\\n+  --entitlements Foundation/Config/Driver.entitlements"))
  #expect(!source.contains("systemextensionsctl"))
  #expect(!source.contains("open \"$candidate_app\""))
}
