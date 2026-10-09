import Foundation
import Testing
@testable import RewindDVControlCore

@Test func transportDiagnosticsSampleDifferentDeckSequencesWithoutInterpretingThem() {
  let play: [UInt8] = [0x0c, 0x20, 0xc3, 0x75]
  let transition: [UInt8] = [0x0b, 0x20, 0xc3, 0x75]
  let stop: [UInt8] = [0x0c, 0x20, 0xc4, 0x60]
  let unsupported: [UInt8] = [0x08, 0x20, 0xc3, 0xff]
  // Immediate PLAY, delayed PLAY, a transient stable reply, unsupported and
  // absent evidence are all recorded as observations, without timing assumptions.
  let traces: [[([UInt8]?, Bool)]] = [
    [(play,true), (play,true), (play,false), (stop,true), (stop,true), (stop,false)],
    [(transition,true), (transition,true), (transition,false), (play,true)],
    [(play,true), (transition,true), (play,true), (play,true), (play,false)],
    [(unsupported,true), (unsupported,true), (unsupported,false), (nil,true), (nil,true), (nil,false), (play,true)]
  ]
  for trace in traces {
    var sampler = ReceiveTransportDiagnosticSampler()
    for (response, expected) in trace {
      let recorded = sampler.shouldRecord(response)
      #expect(recorded == expected)
    }
  }
  var sampler = ReceiveTransportDiagnosticSampler()
  var recorded = 0
  for _ in 0..<10_000 { if sampler.shouldRecord(play) { recorded += 1 } }
  #expect(recorded == 2)
  sampler = ReceiveTransportDiagnosticSampler() // a new receive flight
  let first = sampler.shouldRecord(play)
  #expect(first)
}

@Test func cleanupFailurePreservesOnlyObservedDMAStopEvidence() {
  let pending = ReceiveCleanupEvidence.failureMessage(lastObservedState: 6, cause: "status read unavailable")
  #expect(pending.contains("Local receive DMA stopped"))
  #expect(pending.contains("cleanup could not be confirmed"))
  #expect(pending.contains("status read unavailable"))
  for state: UInt32? in [nil, 0, 1, 2, 3, 4, 5] {
    let message = ReceiveCleanupEvidence.failureMessage(lastObservedState: state, cause: "original error")
    #expect(!message.contains("Local receive DMA stopped"))
    #expect(message.contains("original error"))
  }
}

@Test func idleConnectionChecksAreFastWithoutWorkspacePollingFeedback() throws {
  #expect(DriverRefreshPolicy.intervalMilliseconds(hasAttachedDriver: false) == 250)
  #expect(DriverRefreshPolicy.intervalMilliseconds(hasAttachedDriver: true) == 1_000)
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let model = try String(contentsOf: root.appendingPathComponent("App/RewindDVApp.swift"), encoding: .utf8)
  let start = try #require(model.range(of: "  func refreshDriver()"))
  let end = try #require(model.range(of: "  private func automaticDeviceHandshake()"))
  let body = String(model[start.lowerBound..<end.lowerBound])
  let changed = try #require(body.range(of: "guard driverSnapshot?.presentation != snapshot.presentation"))
  let busy = try #require(body.range(of: "isBusy = true"))
  #expect(changed.lowerBound < busy.lowerBound)
  #expect(body.contains("!refreshInFlight"))
  #expect(!body.contains("Checking attached driver…"))
  #expect(!model.contains("@Published var refreshAttempts"))
  #expect(!model.contains("@Published var lastRefreshDate"))
  #expect(model.contains("hasAttachedDriver: model.latestDriverSnapshot != nil"))
  let diagnostics = try #require(model.range(of: "private struct DiagnosticsPage: View"))
  let diagnosticsBody = String(model[diagnostics.lowerBound...])
  #expect(diagnosticsBody.contains("TimelineView(.periodic(from: .now, by: 1))"))
  let view = try String(contentsOf: root.appendingPathComponent("App/UnifiedMonitorWorkspace.swift"), encoding: .utf8)
  // The viewport must own sizing; measuring content into State creates a
  // growing minimum-width feedback loop after fullscreen/resizing.
  #expect(view.contains("GeometryReader { viewport in"))
  #expect(view.contains("let workspaceWidth = viewport.size.width"))
  #expect(!view.contains("@State private var workspaceWidth"))
  #expect(!view.contains("model.refreshAttempts"))
  #expect(!view.contains("model.lastRefreshDate"))
}

@Test func readinessPresentationIgnoresDiagnosticClocksButDetectsDeviceChanges() {
  let deck = DiscoveredDeck(guid: 1, generation: 3, node: 1, state: 1, vendor: "Sony", model: "M25")
  let a = DriverReadinessPresentation(capabilityFlags: 0x3ff, decks: [deck], routes: [], discoveryNote: "ready")
  #expect(a == DriverReadinessPresentation(capabilityFlags: 0x3ff, decks: [deck], routes: [], discoveryNote: "ready"))
  #expect(a != DriverReadinessPresentation(capabilityFlags: 0x3ff, decks: [], routes: [], discoveryNote: "ready"))
  let newGeneration = DiscoveredDeck(guid: 1, generation: 4, node: 1, state: 1, vendor: "Sony", model: "M25")
  #expect(a != DriverReadinessPresentation(capabilityFlags: 0x3ff, decks: [newGeneration], routes: [], discoveryNote: "ready"))
}

@Test func physicalPlayArmsElapsedOnlyAfterLiveSessionInitialization() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let source = try String(contentsOf: root.appendingPathComponent("App/RewindDVApp.swift"), encoding: .utf8)
  let observer = try #require(source.range(of: "  func observeExternalTransport("))
  let selected = try #require(source.range(of: "  var selectedDeck:", range: observer.upperBound..<source.endIndex))
  let body = String(source[observer.lowerBound..<selected.lowerBound])
  let start = try #require(body.range(of: "live.start(bridge:"))
  let arm = try #require(body.range(of: "live.prepareCaptureTransportPlay()", range: start.upperBound..<body.endIndex))
  #expect(start.lowerBound < arm.lowerBound)
  // A qualified PLAY report starts the clock even while receive is preparing.
  // Never block the STATUS owner waiting for receiver startup: STOP joins it.
  #expect(body.contains("if live.active || live.busy, live.captureElapsedAwaitingPlay"))
  #expect(!body.contains("while live.busy"))
  #expect(body.contains("case .playConfirmed(let needsMonitorStart):"))
  #expect(body.contains("self.monitorSource == .deck"))
  #expect(body.contains("self.selectedDeck?.id == deck.id, self.selectedRoute == route"))
  #expect(body.contains("live.markCaptureTransportPlaying()"))
}

private func handshakeRoute(_ changedOffset: Int? = nil) throws -> FoundationRoute {
  var data = Data(count: 48)
  func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
  }
  put(UInt32(1), at: 0); put(UInt32(48), at: 4)
  for offset in [8,16,24,32] { put(UInt64(1), at: offset) }
  put(UInt32(9), at: 40); put(UInt16(1), at: 44)
  if let changedOffset { data[changedOffset] &+= 1 }
  return try FoundationRoute(data: data)
}

@Test func automaticHandshakeIsOncePerFullRouteNotEveryRefresh() throws {
  var gate = DeviceHandshakeGate()
  let route = try handshakeRoute()
  var began = gate.beginIfNeeded(nil, eligible: true); #expect(!began)
  began = gate.beginIfNeeded(route, eligible: false); #expect(!began)
  began = gate.beginIfNeeded(route, eligible: true); #expect(began)
  for _ in 0..<20 { began = gate.beginIfNeeded(route, eligible: true); #expect(!began) }
  #expect(gate.accepts(route, selected: route))
  #expect(!gate.accepts(route, selected: nil))
  gate.observe(nil)
  #expect(!gate.accepts(route, selected: route))
  began = gate.beginIfNeeded(route, eligible: true); #expect(began)
}

@Test func unchangedPresentationStillHandshakesANewRouteObservedDuringPriorHandshake() throws {
  var gate = DeviceHandshakeGate()
  let original = try handshakeRoute()
  let changed = try handshakeRoute(40)
  #expect(!gate.needsAttempt(nil))
  #expect(gate.needsAttempt(original))
  let beganOriginal = gate.beginIfNeeded(original, eligible: true)
  #expect(beganOriginal)
  #expect(!gate.needsAttempt(original))
  gate.observe(changed)
  #expect(gate.needsAttempt(changed))
  let beganChanged = gate.beginIfNeeded(changed, eligible: true)
  #expect(beganChanged)
  #expect(!gate.needsAttempt(changed))
  #expect(!gate.accepts(original, selected: changed))
}

@Test func handshakeRejectsStaleResultsAcrossEveryRouteComponent() throws {
  let original = try handshakeRoute()
  for offset in [8,16,24,32,40,44] {
    var gate = DeviceHandshakeGate()
    var began = gate.beginIfNeeded(original, eligible: true); #expect(began)
    let changed = try handshakeRoute(offset)
    gate.observe(changed)
    #expect(!gate.accepts(original, selected: changed))
    began = gate.beginIfNeeded(changed, eligible: true); #expect(began)
    #expect(gate.accepts(changed, selected: changed))
  }
}

@Test func automaticHandshakeUsesInventoryThenCapabilitiesAndRechecksRoute() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let source = try String(contentsOf: root.appendingPathComponent("App/RewindDVApp.swift"), encoding: .utf8)
  let start = try #require(source.range(of: "private func automaticDeviceHandshake()"))
  let end = try #require(source.range(of: "  func send("))
  let body = String(source[start.lowerBound..<end.lowerBound])
  #expect(body.contains("bridge.inspectDevice(deck)"))
  #expect(body.contains("bridge.probeTransportCapabilities(deck)"))
  #expect(body.components(separatedBy: "handshakeRouteStillCurrent(route)").count == 3)
  #expect(!body.contains("bridge.perform("))
  #expect(body.contains("bridge.refresh()"))
}

@Test func managedCleanupMustFinishBeforeTerminalFlightAndOwnerClose() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let source = try String(contentsOf: root.appendingPathComponent("App/DriverBridge.swift"), encoding: .utf8)
  let start = try #require(source.range(of: "func endLiveReceive() async throws"))
  let end = try #require(source.range(of: "  func receiveRequiresLockout()"))
  let body = String(source[start.lowerBound..<end.lowerBound])
  let pending = try #require(body.range(of: "while status.state == 6"))
  let terminal = try #require(body.range(of: "receive_final_status"))
  #expect(pending.lowerBound < terminal.lowerBound)
  #expect(body.contains("cleanupDeadline"))
  #expect(body.contains("(2...4).contains(status.state)"))
  #expect(body.components(separatedBy: "liveScalarCall(69").count == 2)
}

@Test func installedNewDriverDoesNotMakeAttachedOldDriverReady() {
  // Reproduces the real 2026-09-13 upgrade: sysext161 enabled; IORegistry160.
  #expect(DriverBuildAssessment.assess([160], required: 161) == .differentBuilds([160]))
  #expect(DriverBuildAssessment.assess([161], required: 161) == .exact)
  #expect(DriverBuildAssessment.assess([], required: 161) == .absent)
  #expect(DriverBuildAssessment.assess([nil], required: 161) == .differentBuilds([nil]))
  #expect(DriverBuildAssessment.assess([161,161], required: 161) == .ambiguous(2))
  #expect(DriverBuildAssessment.assess([160,161], required: 161) == .exact)
}

@Test func driverMismatchMessageNamesObservedAndRequiredVersionsWithoutInventingReadiness() {
  let message = DriverBuildAssessment.mismatchMessage([160], required: 161)
  #expect(message.contains("Build160 is still attached"))
  #expect(message.contains("requires Build161"))
  #expect(message.contains("does not activate"))
  #expect(message.contains("may require a restart"))
  #expect(!message.contains("Restart required")) // mismatch alone does not prove it.
  #expect(DriverBuildAssessment.mismatchMessage([nil], required: 161).contains("unidentified build"))
}

@Test func readinessIntegrationKeepsIdentityGateAndVisibleRefreshFeedback() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let bridge = try String(contentsOf: root.appendingPathComponent("App/DriverBridge.swift"), encoding: .utf8)
  let open = try #require(bridge.range(of: "let openStatus = IOServiceOpen"))
  let exact = try #require(bridge.range(of: "guard assessment == .exact else"))
  #expect(exact.lowerBound < open.lowerBound)
  #expect(bridge.contains("identityMatches && build == requiredBuildNumber"))
  #expect(bridge.contains("registryString(service, key: \"CFBundleIdentifier\") == Self.driverIdentifier"))
  #expect(bridge.contains("registryString(service, key: \"IOUserServerName\") == Self.driverIdentifier"))
  #expect(bridge.contains("IOObjectConformsTo(provider, \"IOPCIDevice\")"))
  #expect(bridge.contains("registryUInt32(provider, key: \"vendor-id\") == Self.controllerVendor"))
  #expect(bridge.contains("registryUInt32(provider, key: \"device-id\") == Self.controllerDevice"))
  let view = try String(contentsOf: root.appendingPathComponent("App/UnifiedMonitorWorkspace.swift"), encoding: .utf8)
  #expect(!view.contains("Text(model.refreshFeedback)"))
  let model = try String(contentsOf: root.appendingPathComponent("App/RewindDVApp.swift"), encoding: .utf8)
  let diagnosticsStart = try #require(model.range(of: "private struct DiagnosticsPage"))
  let diagnostics = model[diagnosticsStart.lowerBound...]
  let activation = try #require(diagnostics.range(of: "Button(\"Activate Driver…\")"))
  let feedback = try #require(diagnostics.range(of: "Text(model.refreshFeedback)"))
  let identity = try #require(diagnostics.range(of: "ArchiveSection(\"Candidate identity\")"))
  #expect(activation.lowerBound < feedback.lowerBound && feedback.lowerBound < identity.lowerBound)
  #expect(!diagnostics.contains("Health remains UNVERIFIED"))
  #expect(diagnostics.contains("Text(model.handshakeFeedback)"))
  #expect(diagnostics.contains(".accessibilityIdentifier(\"driver-readiness\")"))
  let refreshStart = try #require(model.range(of: "  func refreshDriver()"))
  let refreshEnd = try #require(model.range(of: "  func send("))
  let refresh = model[refreshStart.lowerBound..<refreshEnd.lowerBound]
  #expect(refresh.contains("refresh_started") && refresh.contains("refresh_finished") && refresh.contains("refresh_failed"))
  #expect(!refresh.contains("submitActivation") && !refresh.contains("perform("))
  #expect(model.contains("LabeledContent(\"Required driver\", value: DriverBuildRequirement.display)"))
  #expect(bridge.contains("private static let requiredBuildNumber = DriverBuildRequirement.bundled?.build"))
  #expect(bridge.contains("mismatchMessage(builds, required: DriverBuildRequirement.bundled?.build ?? 0)"))
  let project = try String(contentsOf: root.appendingPathComponent("RewindDV.xcodeproj/project.pbxproj"), encoding: .utf8)
  // Xcode 27 must not silently drop the existing macOS 26 runtime floor.
  #expect(project.components(separatedBy: "\"MACOSX_DEPLOYMENT_TARGET\" = \"26.0\"").count == 3)
  #expect(project.components(separatedBy: "\"DRIVERKIT_DEPLOYMENT_TARGET\" = \"25.0\"").count == 3)
  #expect(project.components(separatedBy: "\"ARCHS\" = \"arm64e\"").count == 3)
  #expect(!project.contains("\"CURRENT_PROJECT_VERSION\" ="))
  #expect(!project.contains("\"MARKETING_VERSION\" ="))
  #expect(model.contains("ProductIdentity.matchesHost(Bundle.main.infoDictionary ?? [:])"))
  #expect(model.contains("generatedAt: Date(), build: ProductIdentity.appBuild"))
  // Both configurations sanitize compile-time file macros, not just debug symbols.
  #expect(project.components(separatedBy: "-ffile-prefix-map=$(SRCROOT:dir)=/rewindDV/").count == 3)
  #expect(project.components(separatedBy: "\"-file-prefix-map\", \"$(SRCROOT:dir)=/rewindDV/\"").count == 3)
  // The shipped Release executable must not retain N_OSO object-file paths.
  #expect(project.contains("\"DEPLOYMENT_POSTPROCESSING\" = \"YES\""))
  #expect(project.contains("\"STRIP_INSTALLED_PRODUCT\" = \"YES\""))
  #expect(project.contains("\"STRIP_STYLE\" = \"debugging\""))

  #expect(model.contains("DriverRefreshPolicy.mayCheck"))
  #expect(!view.contains("Button(\"Refresh Driver\""))
}

// Native startup ordering is outside SwiftPM's executable scope. This source
// integration gate catches the Build187 cold-start dependency-copy regression;
// it does not substitute for an actual DriverKit attachment check.
@Test func controlTimerIsPreparedBeforeControllerCopiesDependencies() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let driver = try String(contentsOf: root.appendingPathComponent("ASFWDriver/ASFWDriver.cpp"), encoding: .utf8)
  let prepare = try #require(driver.range(of: "kr = DriverWiring::PrepareControlTimer(*this, ctx);"))
  let construct = try #require(driver.range(of: "ctx.controller = std::make_shared<ControllerCore>"))
  #expect(prepare.lowerBound < construct.lowerBound)
  #expect(driver[prepare.upperBound..<construct.lowerBound].contains("return failStart(kr, \"control timer preparation failed\")"))
  let wiring = try String(contentsOf: root.appendingPathComponent("ASFWDriver/Service/DriverContext.cpp"), encoding: .utf8)
  let method = try #require(wiring.range(of: "kern_return_t DriverWiring::PrepareControlTimer"))
  let protocolMethod = try #require(wiring.range(of: "kern_return_t DriverWiring::EnsureSbp2Deps"))
  let timer = wiring[method.lowerBound..<protocolMethod.lowerBound]
  #expect(timer.contains("d.sbp2SessionScheduler->Prepare(service, ctx.workQueue)"))
  // Failed native initialization may already have installed a callback. The
  // scheduler must survive until the failed-start aggregate observes Cancel.
  #expect(!timer.contains("d.sbp2SessionScheduler.reset();"))
  #expect(driver.contains("ctx.deps.sbp2SessionScheduler->BeginNativeRetirement(drain)"))
  #expect(driver.contains("ctx.nativeDrainPlan = *plan;"))
  #expect(driver.contains("!ctx.nativeDrain->AllTerminal()"))
  #expect(!timer.contains("#ifdef REWINDDV_FOUNDATION"))
  #expect(wiring.components(separatedBy: "std::make_shared<ASFW::Protocols::SBP2::DriverKitSessionScheduler>()").count == 2)
  #expect(wiring[protocolMethod.lowerBound...].contains("const auto timerStatus = PrepareControlTimer(service, ctx);"))
}


@Test func requiredDriverBuildIsIndependentAndFailsClosed() throws {
  let required = try #require(DriverBuildRequirement(metadata: "189"))
  #expect(required.build == 189)
  #expect(DriverBuildAssessment.assess([189], required: required.build) == .exact)
  #expect(DriverBuildAssessment.assess([188], required: required.build) != .exact)
  #expect(DriverBuildAssessment.assess([190], required: required.build) != .exact)
  #expect(required.permitsReplacement(bundleVersion: "189"))
  #expect(!required.permitsReplacement(bundleVersion: "188"))
  #expect(!required.permitsReplacement(bundleVersion: "190"))
  for value: String? in [nil, "", "0", "0189", "189.0", " 189", "189 ", "+189", "-1", "4294967296", "９"] {
    #expect(DriverBuildRequirement(metadata: value) == nil)
    if let value { #expect(!required.permitsReplacement(bundleVersion: value)) }
  }
  #expect(DriverBuildRequirement(metadata: "4294967295")?.build == UInt64(UInt32.max))
}

@Test func activationAndDiscoveryUseSignedRequiredDriverMetadata() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let model = try String(contentsOf: root.appendingPathComponent("App/RewindDVApp.swift"), encoding: .utf8)
  let bridge = try String(contentsOf: root.appendingPathComponent("App/DriverBridge.swift"), encoding: .utf8)
  #expect(model.contains("existingBuild: existing.bundleVersion, existingVersion: existing.bundleShortVersion"))
  #expect(model.contains("incomingBuild: ext.bundleVersion, incomingVersion: ext.bundleShortVersion"))
  #expect(model.contains("productVersion: ProductIdentity.version) == true"))
  #expect(model.contains("DriverBuildRequirement.bundled != nil"))
  #expect(!model.contains("ext.bundleVersion == \"188\""))
  #expect(bridge.contains("guard let requiredBuildNumber = Self.requiredBuildNumber else"))
  #expect(bridge.contains("identityMatches && build == requiredBuildNumber"))
}

@Test func replacementRequiresExactIncomingAndForwardExistingIdentity() {
  let requirement = DriverBuildRequirement(metadata: "194")!
  func permits(_ oldBuild: String, _ oldVersion: String, _ newBuild: String = "194", _ newVersion: String = "0.1.1") -> Bool {
    requirement.permitsReplacement(existingBuild: oldBuild, existingVersion: oldVersion,
      incomingBuild: newBuild, incomingVersion: newVersion, productVersion: "0.1.1")
  }
  #expect(permits("193", "0.1.0"))
  #expect(permits("193", "0.0.96"))
  #expect(permits("193", "0.0.100"))
  #expect(permits("193", "0.1.1"))
  #expect(!permits("193", "0.2.0"))
  #expect(!permits("195", "0.1.0"))
  #expect(!permits("194", "0.1.1")) // same identity cannot authenticate bytes
  #expect(!permits("0193", "0.1.0"))
  #expect(!permits("193", "0.01.0"))
  #expect(!permits("193", "garbage"))
  #expect(!permits("193", "0.1.0", "193"))
  #expect(!permits("193", "0.1.0", "194", "0.1.0"))
}
