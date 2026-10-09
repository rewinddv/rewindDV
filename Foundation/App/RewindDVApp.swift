// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
@preconcurrency import SystemExtensions
import OSLog


enum WorkspacePage: String, CaseIterable, Identifiable {
  case capture = "Workspace"
  case archives = "Analysis & Recovery"
  case inspector = "Device Inspector"
  case diagnostics = "Diagnostics"

  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .capture: "record.circle"
    case .archives: "archivebox"
    case .inspector: "info.circle"
    case .diagnostics: "waveform.path.ecg"
    }
  }
  var accessibilityID: String {
    switch self {
    case .capture: "workspace"
    case .archives: "archives"
    case .inspector: "device-inspector"
    case .diagnostics: "diagnostics"
    }
  }
}

@MainActor
final class RewindDVModel: ObservableObject {
  private static let readinessLog = Logger(subsystem: "net.rewinddigital.RewindDV", category: "DriverReadiness")
  @Published var page: WorkspacePage? = .capture
  @Published var monitorSource: MonitorSource = .deck
  @Published var status = CaptureStatus()
  @Published var driverSnapshot: DriverSnapshot?
  @Published var selectedDeckID: UInt64?
  @Published var isBusy = false
  @Published private(set) var wholeTapeActive = false
  @Published var controlLockedOut = false
  @Published var headline = "rewindDV product preview"
  @Published var detail =
    "Checking driver readiness in the background. Live monitoring and ingest become available after a matching driver and device are found."
  @Published var controlReport: ControlAttemptReport?
  @Published var metadata: DVCaptureMetadataEpochSummary?
  @Published var metadataSource: URL?
  @Published var archiveVerification: RawArchiveVerification?
  @Published var archiveSource: URL?
  @Published var analysisError: String?
  @Published var inspectionReport: DeviceInspectionReport?
  @Published var inspectionError: String?
  @Published var capabilityReport: TransportCapabilityReport?
  @Published var capabilityError: String?
  @Published var refreshFeedback = "Driver readiness has not been checked."
  @Published var refreshFailed = false
  // Diagnostic counters are not workspace state: an unchanged background check
  // must not invalidate the entire SwiftUI graph or pulse transport availability.
  private(set) var lastRefreshDate: Date?
  private(set) var refreshAttempts = 0
  private var refreshInFlight = false
  private(set) var latestDriverSnapshot: DriverSnapshot?
  @Published var handshakeFeedback = "Device information and capabilities will be read automatically."
  private var handshakeGate = DeviceHandshakeGate()

  let bridge = DriverBridge()
  private let windObserver = WindStopObserver()
  private let externalTransportObserver = ExternalDeckTransportObserver()
  private(set) var externalTransportObservationActive = false
  private var passiveObservationFailureRoute: FoundationRoute?
  var passiveTransportObservationAvailable: Bool {
    guard let selectedRoute else { return false }
    return !windObservationActive && passiveObservationFailureRoute != selectedRoute
  }
  @Published private var stoppedWindReceipt: URL?
  @Published var windStatus = ""
  private var windObservationActive = false
  @Published private(set) var deckTimecode = DeckTimecodeDisplayState()
  private var deckTimecodeRoute: FoundationRoute?
  private var deckTimecodeDisabled = false
  private var lastDeckTimecodeAttempt: UInt64 = 0

  func resetDeckTimecode() {
    deckTimecode = DeckTimecodeDisplayState(); deckTimecodeRoute = nil
    deckTimecodeDisabled = false; lastDeckTimecodeAttempt = 0
  }

  /// Runs within the existing serialized observer/job, never a parallel poller.
  /// Optional data is not a precondition for receive, PLAY, STOP or completion.
  func sampleDeckTimecode(deck: DiscoveredDeck, route: FoundationRoute,
    transport: [UInt8]?, receiving: Bool, stopping: Bool, wholeTapeOwner: Bool = false,
    rapidWinding: Bool = false) async {
    guard selectedRoute == route, selectedDeck?.id == deck.id, !controlLockedOut,
      !isBusy, wholeTapeOwner || !wholeTapeActive,
      DeckTimecodeDisplayState.maySample(transport: transport, receiving: receiving, stopping: stopping) else { return }
    if deckTimecodeRoute != route {
      resetDeckTimecode(); deckTimecodeRoute = route
    }
    let now = DispatchTime.now().uptimeNanoseconds
    guard !deckTimecodeDisabled, now >= lastDeckTimecodeAttempt,
      now - lastDeckTimecodeAttempt >= DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(
        transport: transport, rapidWinding: rapidWinding) else { return }
    lastDeckTimecodeAttempt = now
    do {
      let report = try await bridge.inspectDevice(deck, expectedRoute: route,
        passiveTransport: true, timecodeOnly: true, rapidIdleObservation: rapidWinding)
      guard selectedRoute == route, selectedDeck?.id == deck.id else { return }
      if report.controlLockedOut { controlLockedOut = true }
      guard !report.controlLockedOut, report.route == route,
        let response = report.validatedDeckTimecode else {
        deckTimecodeDisabled = true
        deckTimecode.unavailable(report.entries.first?.disposition ?? "No valid deck reply")
        return
      }
      // Use the conservative request-start bound, not publication time: a slow
      // evidence write must not make an old response look freshly sampled.
      deckTimecode.observe(response, at: now)
    } catch {
      guard selectedRoute == route, selectedDeck?.id == deck.id else { return }
      // No optional retries; a new connection permits a new qualification.
      deckTimecodeDisabled = true; deckTimecode.unavailable(error.localizedDescription)
      if case DriverBridgeError.permanentSessionLockout = error { controlLockedOut = true }
    }
  }
  // Receipt churn during winding must not invalidate the entire workspace.
  private(set) var windEvidenceURL: URL?

  var requiresSupervisedStop: Bool {
    controlReport?.requiresSupervisedStop == true && stoppedWindReceipt != controlReport?.receiptURL
  }
  var navigationLocked: Bool { isBusy || wholeTapeActive || controlLockedOut || requiresSupervisedStop }

  func acquireWholeTapeOwnership() -> Bool {
    guard !navigationLocked, !refreshInFlight, selectedDeck != nil, selectedRoute != nil else { return false }
    wholeTapeActive = true
    return true
  }
  func releaseWholeTapeOwnership() { wholeTapeActive = false }
  func wholeTapeControlCompleted(_ report: ControlAttemptReport) {
    controlReport = report; stoppedWindReceipt = nil
    if report.disposition == .uncertainLockedOut { controlLockedOut = true }
  }
  func wholeTapeStopObserved() { stoppedWindReceipt = controlReport?.receiptURL }

  func pauseExternalTransportObservation() async {
    await externalTransportObserver.stopAndJoin()
  }

  /// Reserve on the main actor before the first await. All foreground commands,
  /// readiness publication and passive observer restarts already respect isBusy.
  /// Joining lets an admitted STATUS finish; it does not cancel or replay it.
  func startIngest(live: LiveMonitorModel, deck: DiscoveredDeck,
                   route: FoundationRoute, destination: URL) {
    guard monitorSource == .deck, !navigationLocked,
      !live.active, !live.busy, !live.lockedOut,
      selectedDeck?.id == deck.id, selectedRoute == route else { return }
    isBusy = true
    live.start(bridge: bridge, deck: deck, ingestParent: destination,
      expectedRoute: route, existingStopObligation: requiresSupervisedStop,
      beforeAdmission: {
        await self.pauseExternalTransportObservation()
        try Task.checkCancellation()
        guard self.monitorSource == .deck, self.selectedDeck?.id == deck.id,
          self.selectedRoute == route, !self.controlLockedOut,
          !self.requiresSupervisedStop else {
          throw ControlWireError.invalid("Device or capture intent changed while waiting. Choose the destination again to start.")
        }
      }, admissionFinished: { self.isBusy = false }, onReceiving: {
        self.send(.play, onAccepted: {
          live.observeCaptureTransportPlaying(bridge: self.bridge, deck: deck, route: route)
        })
      })
  }

  func observeExternalTransport(live: LiveMonitorModel, deck: DiscoveredDeck,
                                route: FoundationRoute) async {
    guard !externalTransportObservationActive, !isBusy, !wholeTapeActive, !windObservationActive,
      passiveObservationFailureRoute != route, selectedDeck?.id == deck.id,
      selectedRoute == route else { return }
    externalTransportObservationActive = true
    defer { externalTransportObservationActive = false }
    externalTransportObserver.start(route: route, sample: { [bridge] in
      try await bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route, passiveTransport: true)
    }, update: { [weak self, weak live] report, event in
      guard let self, let live, self.monitorSource == .deck,
        self.selectedDeck?.id == deck.id, self.selectedRoute == route else { return }
      switch event {
      case .playStarting:
        guard !live.active, !live.busy, !live.lockedOut else { return }
        live.start(bridge: self.bridge, deck: deck, expectedRoute: route)
        // start() initializes the session clock. Arm the interval only after
        // that reset so physical PLAY cannot have its pending clock erased.
        live.prepareCaptureTransportPlay()
      case .playConfirmed(let needsMonitorStart):
        if needsMonitorStart, !live.active, !live.busy, !live.lockedOut {
          live.start(bridge: self.bridge, deck: deck, expectedRoute: route)
          live.prepareCaptureTransportPlay()
        }
        // Clock authority is the completed PLAY observation, not receive
        // startup. Never hold the STATUS owner while receive is preparing:
        // an operator STOP must be able to join it immediately.
        if live.active || live.busy, live.captureElapsedAwaitingPlay {
          live.markCaptureTransportPlaying()
          self.headline = "Physical PLAY detected"
          self.detail = "Live picture, audio, meters and source timecode started from fresh route-bound transport evidence. No PLAY command was sent."
        }
      case .stopObserved:
        live.markCaptureTransportStopped()
      case .stopConfirmed:
        live.confirmReceiverTapeStopped(on: route)
        live.markCaptureTransportStopped()
        self.wholeTapeStopObserved()
        self.headline = "Physical STOP detected"
        self.detail = "The deck reported stopped twice. Final received bytes are being drained; no STOP command was sent."
        if live.active || live.busy { await live.stopAndWait() }
      }
      _ = report // receipt remains preserved by the inspector flight
    }, idle: { [weak self, weak live] report in
      guard let self, let live else { return }
      await self.sampleDeckTimecode(deck: deck, route: route,
        transport: report.validatedTransportState, receiving: live.active || live.busy,
        stopping: self.isBusy || live.awaitingTapeStop)
    }, failed: { [weak self] reason in
      guard let self else { return }
      self.passiveObservationFailureRoute = route
      self.handshakeFeedback = "Passive transport observation paused: \(reason). No retry on this route. Raw reception, if active, continues; use explicit GUI STOP or physical STOP and Finish receiving. Resolve the evidence/route problem before reconnecting or reopening."
    })
    await externalTransportObserver.waitUntilEnded()
    await externalTransportObserver.stopAndJoin()
  }

  var selectedDeck: DiscoveredDeck? {
    guard let selectedDeckID else { return nil }
    return driverSnapshot?.decks.first { $0.guid == selectedDeckID && $0.isOperational }
  }

  var selectedRoute: FoundationRoute? {
    driverSnapshot?.routes.first { $0.guid == selectedDeckID }
  }
  var fastForwardAvailable: Bool {
    capabilityReport?.permitsFastForward(on: selectedRoute) == true
  }
  func probeCapabilities() {
    guard !navigationLocked, let deck = selectedDeck else { return }
    isBusy = true
    capabilityReport = nil
    capabilityError = nil
    Task {
      defer { isBusy = false }
      do {
        await pauseExternalTransportObservation()
        let report = try await bridge.probeTransportCapabilities(deck)
        capabilityReport = report
        if report.lockedOut { controlLockedOut = true }
      } catch { capabilityError = error.localizedDescription }
    }
  }

  func inspectDevice(tapeStateOnly: Bool = false) {
    guard !navigationLocked, let deck = selectedDeck else { return }
    isBusy = true
    inspectionError = nil
    Task {
      defer { isBusy = false }
      do {
        await pauseExternalTransportObservation()
        let report = try await bridge.inspectDevice(deck, tapeStateOnly: tapeStateOnly)
        inspectionReport = report
        if report.controlLockedOut { controlLockedOut = true }
      } catch { inspectionError = error.localizedDescription }
    }
  }

  func refreshDriver() {
    guard Bundle.main.object(forInfoDictionaryKey: "RewindDVOfflineOnly") as? Bool != true else {
      detail = "Offline-only distribution: driver discovery and hardware acquisition are unavailable."
      return
    }
    guard !refreshInFlight, !isBusy, !wholeTapeActive, !externalTransportObservationActive,
      !controlLockedOut, !requiresSupervisedStop else { return }
    refreshAttempts += 1
    refreshInFlight = true
    Self.readinessLog.debug("refresh_started attempt=\(self.refreshAttempts)")
    Task {
      defer { refreshInFlight = false; lastRefreshDate = Date() }
      do {
        let previousRoute = selectedRoute
        let snapshot = try await bridge.refresh()
        // A foreground operation may have started while this actor hop was
        // outstanding. Never publish its preceding snapshot over that operation.
        guard !isBusy, !controlLockedOut, !requiresSupervisedStop else { return }
        latestDriverSnapshot = snapshot
        let nextDeckID = snapshot.decks.contains(where: { $0.guid == selectedDeckID })
          ? selectedDeckID : (snapshot.decks.count == 1 ? snapshot.decks[0].guid : nil)
        let nextRoute = snapshot.routes.first { $0.guid == nextDeckID }
        guard driverSnapshot?.presentation != snapshot.presentation || refreshFailed
          || selectedDeckID != nextDeckID || handshakeGate.needsAttempt(nextRoute) else { return }
        driverSnapshot = snapshot
        refreshFailed = false
        status.driver = .connected
        status.deck = .unknown
        status.intake = .disabled
        if selectedDeckID != nextDeckID { selectedDeckID = nextDeckID }
        if previousRoute != selectedRoute {
          inspectionReport = nil; capabilityReport = nil
          inspectionError = nil; capabilityError = nil
        }
        handshakeGate.observe(selectedRoute)
        headline = "Exact \(DriverBuildRequirement.display) matched"
        detail = snapshot.discoveryNote
        refreshFeedback = "\(DriverBuildRequirement.display) is attached and responding. \(snapshot.discoveryNote)"
        Self.readinessLog.notice("refresh_finished exact_driver=true discovered_decks=\(snapshot.decks.count)")
        // Only an actual route transition can enter the bounded handshake.
        // Normal idle checks never disable controls or repeat device inquiries.
        isBusy = true
        defer { isBusy = false }
        await automaticDeviceHandshake()
      } catch {
        guard !isBusy, !controlLockedOut, !requiresSupervisedStop else { return }
        latestDriverSnapshot = nil
        guard driverSnapshot != nil || !refreshFailed || refreshFeedback != error.localizedDescription else { return }
        driverSnapshot = nil
        selectedDeckID = nil
        handshakeGate.observe(nil)
        inspectionReport = nil; capabilityReport = nil
        status.driver = .unavailable
        status.deck = .unknown
        status.intake = .disabled
        headline = "Driver unavailable"
        detail = error.localizedDescription
        refreshFailed = true
        refreshFeedback = error.localizedDescription
        Self.readinessLog.error("refresh_failed reason=\(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Runs only inside an idle readiness transaction. The bridge separately
  /// excludes live receive/control and revalidates identity before every query.
  /// No transport CONTROL is submitted by connection/discovery.
  private func automaticDeviceHandshake() async {
    guard let deck = selectedDeck, let route = selectedRoute,
      handshakeGate.beginIfNeeded(route, eligible: !controlLockedOut && !requiresSupervisedStop)
    else { return }
    handshakeFeedback = "Reading device information…"
    Self.readinessLog.notice("handshake_started guid=\(deck.guidText, privacy: .public) generation=\(route.generation)")
    do {
      let inventory = try await bridge.inspectDevice(deck)
      if inventory.controlLockedOut {
        controlLockedOut = true
        inspectionReport = inventory
        handshakeFeedback = "Device inspection stopped; see Diagnostics before continuing."
        return
      }
      guard try await handshakeRouteStillCurrent(route) else { return }
      inspectionReport = inventory
      handshakeFeedback = "Checking transport capabilities…"
      let capabilities = try await bridge.probeTransportCapabilities(deck)
      if capabilities.lockedOut {
        controlLockedOut = true
        capabilityReport = capabilities
        handshakeFeedback = "Capability inspection stopped; see Diagnostics before continuing."
        return
      }
      guard try await handshakeRouteStillCurrent(route), capabilities.route == route else { return }
      capabilityReport = capabilities
      handshakeFeedback = "Device handshake complete. \(capabilities.completion)"
      Self.readinessLog.notice("handshake_finished guid=\(deck.guidText, privacy: .public)")
    } catch {
      // One attempt per route; an unsupported or failed optional inquiry must
      // never cause automatic tape commands, repeated polling or a fabricated capability.
      handshakeFeedback = "Device handshake incomplete: \(error.localizedDescription). See Device Inspector."
      Self.readinessLog.error("handshake_failed reason=\(error.localizedDescription, privacy: .public)")
      if case DriverBridgeError.permanentSessionLockout = error { controlLockedOut = true }
    }
  }

  private func handshakeRouteStillCurrent(_ route: FoundationRoute) async throws -> Bool {
    let fresh = try await bridge.refresh()
    latestDriverSnapshot = fresh
    if driverSnapshot?.presentation != fresh.presentation { driverSnapshot = fresh }
    let current = fresh.routes.first { $0.guid == selectedDeckID }
    handshakeGate.observe(current)
    guard handshakeGate.accepts(route, selected: current) else {
      inspectionReport = nil; capabilityReport = nil
      handshakeFeedback = "Connection changed during discovery; stale results were discarded."
      return false
    }
    return true
  }

  func send(_ command: DeckCommand, duringLiveMonitoring: Bool = false,
    beforeSubmission: (@MainActor () async -> Void)? = nil,
    onAccepted: (@MainActor () -> Void)? = nil) {
    // An accepted PLAY creates a continuing STOP obligation, not an uncertain
    // transaction. Explicit picture search may change that motion; uncertainty
    // remains a lockout and never gains authority through the preview's state.
    let deliberateMonitorCommand = duringLiveMonitoring &&
      controlReport?.disposition == .protocolAcceptedMotionUnverified &&
      (command == .play || command == .shuttleForward || command == .shuttleReverse)
    guard monitorSource == .deck, !isBusy, !wholeTapeActive, !controlLockedOut, let deck = selectedDeck,
      !requiresSupervisedStop || command == .stop || deliberateMonitorCommand
    else { return }
    if command == .fastForward || command == .shuttleForward || command == .shuttleReverse {
      guard capabilityReport?.permits(command, on: selectedRoute) == true else { return }
    }
    isBusy = true
    // Keep an accepted motion command's STOP obligation through a failed follow-up.
    // Only a new receipt can replace the prior receipt; beginning a request cannot.
    let commandRoute = selectedRoute
    Task {
      defer { isBusy = false }
      do {
        await pauseExternalTransportObservation()
        await windObserver.stopAndJoin()
        windObservationActive = false
        await beforeSubmission?()
        let report = try await bridge.perform(
          // This call exists only on a direct Deck transport-button action.
          // The click supplies one-command intent, not a persistent permission.
          command, selectedDeck: deck, explicitlyArmed: true, expectedRoute: commandRoute)
        controlReport = report
        stoppedWindReceipt = nil
        windStatus = ""
        windEvidenceURL = nil
        status.deck = .unknown
        headline =
          report.disposition == .protocolAcceptedMotionUnverified
          ? "Protocol response recorded"
          : "Control locked out"
        detail = report.message
        if report.disposition == .protocolAcceptedMotionUnverified {
          onAccepted?()
          if !duringLiveMonitoring, command == .rewind || command == .fastForward,
            let route = commandRoute, let result = report.result,
            result.guid == route.guid, result.driverInstanceID == route.driverInstanceID,
            result.deviceIncarnation == route.deviceIncarnation, result.routeEpoch == route.routeEpoch,
            result.generation == route.generation, result.nodeID == route.nodeID {
            observeWindStop(deck: deck, route: route, controlReceipt: report.receiptURL)
          }
        }
        if report.disposition == .uncertainLockedOut {
          controlLockedOut = true
          status.firstError = CaptureFailure(
            phase: "deck_control", message: report.firstError ?? report.message)
          status.cleanupErrors = report.cleanupErrors.map {
            CaptureFailure(phase: "control_receipt_cleanup", message: $0)
          }
        }
      } catch {
        headline = "Control request failed"
        detail = error.localizedDescription
        if case DriverBridgeError.permanentSessionLockout = error {
          controlLockedOut = true
        }
      }
    }
  }

  private func observeWindStop(deck: DiscoveredDeck, route: FoundationRoute, controlReceipt: URL) {
    windObservationActive = true
    windStatus = "Observing transport state; STOP remains available. BOT/EOT is not inferred."
    let bridge = bridge
    windObserver.start(route: route, interval: .milliseconds(100), sampleImmediately: true,
      rapidWindingExperiment: true, sample: {
      try await bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route,
        passiveTransport: true, rapidIdleObservation: true)
    }, update: { [weak self] report, stopped in
      guard let self, self.controlReport?.receiptURL == controlReceipt else { return }
      self.windEvidenceURL = report.receiptURL
      await self.sampleDeckTimecode(deck: deck, route: route,
        transport: report.validatedTransportState, receiving: false, stopping: self.isBusy,
        rapidWinding: true)
      if stopped {
        self.windObservationActive = false
        self.stoppedWindReceipt = controlReceipt
        self.windStatus = "Deck reports stopped in two consecutive observations. Controls released; BOT/EOT remains unverified."
        self.headline = "Deck reports stopped"
        self.detail = "No extra STOP was sent. The original wind command and subsequent status evidence remain separate."
      }
    }, failed: { [weak self] reason in
      guard let self, self.controlReport?.receiptURL == controlReceipt else { return }
      self.windStatus = "Transport observation ended: \(reason). Stop remains unverified; use STOP, or physical STOP if needed."
      self.windObservationActive = false
    })
  }

  func chooseArchive() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose a rewindDV archive folder"
    panel.prompt = "Verify Archive"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    verifyArchive(url)
  }

  func analyzeNativeDV(_ url: URL) {
    isBusy = true
    analysisError = nil
    metadata = nil
    metadataSource = url
    Task {
      defer { isBusy = false }
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          return try DVCaptureMetadataEpochAnalyzer.analyzeSummary(url: url)
        }.value
        metadata = result
      } catch {
        analysisError = error.localizedDescription
      }
    }
  }

  func verifyArchive(_ url: URL) {
    isBusy = true
    analysisError = nil
    archiveVerification = nil
    archiveSource = url
    Task {
      defer { isBusy = false }
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          return try RawArchiveWriter.verify(at: url)
        }.value
        archiveVerification = result
        status.archive = result.lifecycle == .finalized ? .finalized : .incomplete
      } catch {
        status.archive = .failed
        analysisError = error.localizedDescription
      }
    }
  }
}

@MainActor
final class SystemExtensionInstaller: NSObject, ObservableObject,
  OSSystemExtensionRequestDelegate
{
  enum State: Equatable, Sendable {
    case idle
    case submitting
    case pendingApproval
    case restartRequired
    case completedAwaitingReadiness
    case failed(String)

    var title: String {
      switch self {
      case .idle: "Not requested"
      case .submitting: "Submitting request"
      case .pendingApproval: "Pending approval"
      case .restartRequired: "Restart required"
      case .completedAwaitingReadiness: "Completed — awaiting readiness"
      case .failed: "Request failed"
      }
    }
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var settingsOpenFailed = false
  nonisolated private static let identifier = "net.rewinddigital.RewindDV.Driver"
  var isInFlight: Bool { state == .submitting || state == .pendingApproval }

  func submitActivation() {
    guard Bundle.main.object(forInfoDictionaryKey: "RewindDVOfflineOnly") as? Bool != true else {
      state = .failed("This offline-only distribution includes no DriverKit extension or activation capability.")
      return
    }
    guard !isInFlight else { return }
    guard Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "190",
      DriverBuildRequirement.bundled != nil
    else {
      state = .failed("The host app build or required-driver identity is not valid for this candidate.")
      return
    }
    state = .submitting
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: Self.identifier, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.state = .pendingApproval
      self.openDriverSettings()
    }
  }

  func openDriverSettings() {
    // This pane advertises the x-apple.systempreferences scheme on macOS 27.
    // Keep manual navigation visible if a later OS stops accepting the link.
    let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    settingsOpenFailed = !NSWorkspace.shared.open(url)
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    guard existing.bundleIdentifier == Self.identifier,
      ext.bundleIdentifier == Self.identifier,
      DriverBuildRequirement.bundled?.permitsReplacement(bundleVersion: ext.bundleVersion) == true
    else { return .cancel }
    return .replace
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    let nextState: State
    switch result {
    case .completed:
      nextState = .completedAwaitingReadiness
    case .willCompleteAfterReboot:
      nextState = .restartRequired
    @unknown default:
      nextState = .failed("The operating system returned an unknown activation result.")
    }
    Task { @MainActor [weak self] in self?.state = nextState }
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest, didFailWithError error: Error
  ) {
    let message = error.localizedDescription
    Task { @MainActor [weak self] in self?.state = .failed(message) }
  }
}

#if !REWINDDV_OFFLINE_REGRESSION
@main
#endif
struct RewindDVApp: App {
  private var alphaVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "RewindDVAlphaVersion") as? String ?? "development"
  }
  private var productTitle: String { "rewindDV LAB (Alpha \(alphaVersion))" }
  @NSApplicationDelegateAdaptor(WholeTapeAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = RewindDVModel()
  // AppKit's sidebar can write selection while SwiftUI is reconciling rows.
  // Keep that write in view state; publish navigation to the shared model from
  // onChange, not from List's binding setter during a view update.
  @State private var sidebarSelection: WorkspacePage? = .capture
  @StateObject private var installer = SystemExtensionInstaller()
  @StateObject private var playback = OfflineDVPlaybackModel()
  @StateObject private var surgery = SurgeryModel()
  @State private var commandBridge = RewindDVCommandBridge()
  @StateObject private var live = LiveMonitorModel()
  @StateObject private var wholeTape = WholeTapeCaptureModel()
  @StateObject private var tapeMap = TapeEvidenceMapModel()
  @StateObject private var recoveryPlanner = GentleRecoveryModel()
  @StateObject private var multiPass = MultiPassModel()
  @StateObject private var forensicPrefix = ForensicPrefixModel()
  @State private var mappedCapture: URL?
  @State private var showActivationConfirmation = false
  private static let consentDomain = "net.rewinddigital.RewindDV"
  @State private var disclaimerAccepted = AlphaDisclaimer.isAccepted(domain: consentDomain)
  @State private var disclaimerSaveError: String?

  var body: some Scene {
    Window(productTitle, id: "monitor-workspace") {
      if disclaimerAccepted {
      NavigationSplitView {
        List(WorkspacePage.allCases, selection: $sidebarSelection) { page in
          Label {
            Text(page.rawValue).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: page.symbol)
          }.tag(page)
            .accessibilityIdentifier("sidebar-\(page.accessibilityID)")
        }
        .accessibilityIdentifier("primary-sidebar")
        .onChange(of: sidebarSelection) { _, page in
          if model.page != page { model.page = page }
        }
        .onChange(of: model.page) { _, page in
          if sidebarSelection != page { sidebarSelection = page }
        }
        .disabled(model.navigationLocked || installer.isInFlight || live.active || live.busy)
        .navigationTitle(productTitle)
      } detail: {
        Group {
          switch model.page ?? .capture {
          case .capture:
            UnifiedMonitorWorkspace(
              model: model,
              installer: installer,
              playback: playback, live: live, wholeTape: wholeTape, surgery: surgery)
          case .archives:
            ArchivesPage(model: model, tapeMap: tapeMap, recovery: recoveryPlanner, multiPass: multiPass,
              forensicPrefix: forensicPrefix, live: live, wholeTape: wholeTape, interactionLocked: interactionLocked)
          case .inspector:
            DeviceInspectorView(model: model, live: live, activationInFlight: installer.isInFlight)
          case .diagnostics:
            DiagnosticsPage(model: model, installer: installer,
              showActivationConfirmation: $showActivationConfirmation,
              activationLocked: live.active || live.busy || model.navigationLocked)
          }
        }
        .accessibilityIdentifier("page-\((model.page ?? .capture).accessibilityID)")
        .frame(minWidth: 760, minHeight: 560)
      }
      .onAppear {
        appDelegate.bind(model: model, live: live)
        commandBridge.start(model: model, playback: playback, surgery: surgery,
                            live: live, wholeTape: wholeTape, installer: installer,
                            tapeMap: tapeMap, recovery: recoveryPlanner, multiPass: multiPass,
                            forensicPrefix: forensicPrefix,
                            requestActivation: { showActivationConfirmation = true })
      }
      .confirmationDialog(
        "Request \(DriverBuildRequirement.display) activation?",
        isPresented: $showActivationConfirmation,
        titleVisibility: .visible
      ) {
        Button("Request activation") { installer.submitActivation() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "macOS may require approval or a restart. rewindDV checks the attached driver automatically; approval alone does not prove readiness."
        )
      }
      .onDisappear {
        commandBridge.stop()
        playback.close()
      }
      .task(id: scenePhase) {
        // A task retains the environment from its creation. Recreate it when
        // activation changes so a cold-launch inactive phase cannot persist.
        // Idle discovery never submits tape commands or replaces a receive owner.
        while !Task.isCancelled {
          if !RewindDVRuntimeOptions.hardwareDisabled,
            DriverRefreshPolicy.mayCheck(sceneActive: scenePhase == .active,
            modelBusy: model.isBusy || model.wholeTapeActive || playback.canPause || playback.isLoading, activationInFlight: installer.isInFlight,
            receiveActive: live.active || live.busy, lockedOut: model.controlLockedOut || live.lockedOut,
            stopOutstanding: model.requiresSupervisedStop) {
            model.refreshDriver()
          }
          do {
            try await Task.sleep(for: .milliseconds(
              DriverRefreshPolicy.intervalMilliseconds(hasAttachedDriver: model.latestDriverSnapshot != nil)))
          } catch { break }
        }
      }
      .task(id: scenePhase) {
        // One passive, route-bound STATUS owner recognizes physical PLAY/STOP.
        // It is explicitly joined before every foreground FCP operation.
        while !Task.isCancelled {
          if !RewindDVRuntimeOptions.hardwareDisabled, scenePhase == .active,
            model.monitorSource == .deck, !model.isBusy, !model.wholeTapeActive,
            model.passiveTransportObservationAvailable,
            !model.controlLockedOut, !live.lockedOut, !live.busy,
            !live.awaitingTapeStop, !live.captureElapsedAwaitingPlay,
            let deck = model.selectedDeck, let route = model.selectedRoute {
            await model.observeExternalTransport(live: live, deck: deck, route: route)
          } else {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
          }
        }
        await model.pauseExternalTransportObservation()
      }
      .onChange(of: installer.state) { _, state in
        if !RewindDVRuntimeOptions.hardwareDisabled,
          state == .completedAwaitingReadiness, !live.active, !live.busy { model.refreshDriver() }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active {
          Task { await model.pauseExternalTransportObservation() }
        }
      }
      .onChange(of: model.monitorSource) { _, _ in
        Task { await model.pauseExternalTransportObservation() }
      }
      .onChange(of: model.selectedDeckID) { _, _ in
        model.resetDeckTimecode()
        Task { await model.pauseExternalTransportObservation() }
      }
      .onChange(of: model.selectedRoute) { _, _ in
        model.resetDeckTimecode()
        Task { await model.pauseExternalTransportObservation() }
      }
      .onChange(of: live.active || live.busy, initial: true) { _, receiving in
        if receiving { multiPass.cancel(); forensicPrefix.cancel() }
        WholeTapeAppDelegate.receiveActive = receiving
        if receiving { tapeMap.cancel() }
        if !receiving, let verified = live.verification, verified.integritySHA256Verified,
          verified.nativeDVRereadVerified, let name = verified.captureFile, let flight = live.flightURL {
          let source = flight.appendingPathComponent(name)
          if mappedCapture != source, !tapeMap.busy {
            mappedCapture = source
            tapeMap.create(source: source, parent: flight,
              archiveVerification: flight.appendingPathComponent(verified.verificationFile), accessRoot: live.ingestDestinationURL)
          }
        }
      }
      .task {
        await RewindDVAutomationStatus.recordWhileVisible {
          if let job = wholeTape.evidenceURL, live.flightURL == nil || live.flightURL!.path.hasPrefix(job.path + "/") {
            AlphaDiagnosticsModel.shared.latestCaptureFolder = job
          } else { AlphaDiagnosticsModel.shared.latestCaptureFolder = live.flightURL }
          AlphaDiagnosticsModel.shared.latestAccessRoot = live.ingestDestinationURL
          var snapshot = RewindDVAutomationSnapshot(
            schemaVersion: 1, generatedAt: Date(), build: "190",
            page: (model.page ?? .capture).accessibilityID,
            monitorSource: model.monitorSource.rawValue,
            driverState: model.status.driver.rawValue,
            driverReady: model.latestDriverSnapshot != nil && !model.refreshFailed,
            selectedDeckName: model.selectedDeck?.name,
            selectedDeckGUID: model.selectedDeck?.guidText,
            handshake: model.handshakeFeedback,
            modelBusy: model.isBusy,
            controlLockedOut: model.controlLockedOut || live.lockedOut,
            stopNeedsSupervision: model.requiresSupervisedStop || live.awaitingTapeStop,
            liveActive: live.active,
            liveBusy: live.busy,
            ingestRequested: live.ingestRequested,
            liveStatus: live.detail,
            packetsSeen: live.packetsSeen,
            completeFrames: live.completeFrames,
            captureElapsed: live.captureElapsed.display(
              atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds),
            captureElapsedRunning: live.captureElapsedRunning,
            captureElapsedSystem: live.captureElapsedSystemDescription,
            playbackState: playback.state.title,
            playbackSourceName: playback.sourceURL?.lastPathComponent,
            wholeTapeActive: wholeTape.active,
            wholeTapeStatus: wholeTape.status)
          snapshot.alphaDiagnostics = [
            "activation": String(describing: installer.state), "readiness": model.refreshFeedback,
            "readinessChecks": String(model.refreshAttempts), "ingest": live.ingestDetail,
            "captureFlight": live.flightURL?.path ?? "none", "wholeTapeFlight": wholeTape.evidenceURL?.path ?? "none",
            "droppedPackets": String(live.knownDroppedPackets), "oversizedPackets": String(live.oversizedPackets),
            "incompleteFrames": String(live.incompleteFrames), "continuityBreaks": String(live.continuityBreaks),
            "rejectedPackets": String(live.rejectedPackets), "previewDeliverySkips": String(live.deliverySkips),
            "durableRecords": String(live.durableRecords), "pendingDurabilityRecords": String(live.pendingDurabilityRecords),
            "writerUnderPressure": String(live.writerUnderPressure), "diagnosticWarning": live.diagnosticWarning ?? "none",
            "timecode": live.sourceTimecode ?? "unknown", "stopFeedback": live.tapeStopFeedback,
            "previewQueueSkips": String(live.preview.queueSkippedFrames),
            "previewRendererSkips": String(live.preview.rendererSkippedFrames),
            "previewFailedFrames": String(live.preview.failedVideoFrames),
            "previewError": live.preview.error ?? "none",
            "audioSkips": String(live.preview.audio.skippedAudioFrames),
            "audioResyncs": String(live.preview.audio.resynchronizations),
            "receiveStartRejection": live.startRejection?.json ?? "none",
            "receiveSessionAcquired": String(live.hasReceiveSession),
            "waitingForAdmission": String(live.waitingForAdmission),
            "audioInputInterruptions": String(live.preview.audio.inputInterruptions),
            "audioRendererFailures": String(live.preview.audio.rendererFailureFrames),
          ]
          if !live.hasCurrentPreview {
            for key in ["previewQueueSkips", "previewRendererSkips", "previewFailedFrames",
              "audioSkips", "audioResyncs", "audioInputInterruptions", "audioRendererFailures"] {
              snapshot.alphaDiagnostics[key] = "not_applicable_preview_not_started"
            }
            snapshot.alphaDiagnostics["previewError"] = "none_for_this_attempt"
            snapshot.alphaDiagnostics["timecode"] = "unknown"
          }
          return snapshot
        }
      }
      } else {
        alphaAcknowledgement
      }
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 1_440, height: 810)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About rewindDV") {
          let info = Bundle.main.infoDictionary ?? [:]
          let build = info["CFBundleVersion"] as? String ?? "Unknown"
          let revision = info["RewindDVCandidateRevision"] as? String ?? "Unpackaged development build"
          NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "rewindDV LAB",
            .applicationVersion: "Alpha \(alphaVersion) · Build \(build) · \(revision)",
            .version: build
          ])
        }
      }
      CommandGroup(after: .appInfo) {
        AcknowledgmentsCommand()
      }
      CommandMenu("Alpha testing") {
        Button("Export support ZIP…") { AlphaDiagnosticsModel.shared.export() }
          .disabled(!disclaimerAccepted || live.active || live.busy || wholeTape.active || AlphaDiagnosticsModel.shared.exporting)
        Button("Include capture folder…") { AlphaDiagnosticsModel.shared.chooseCaptureFolder() }
          .disabled(!disclaimerAccepted || live.active || live.busy || wholeTape.active)
      }
    }
    Window("Acknowledgments", id: "acknowledgments") { AcknowledgmentsView() }
  }

  // Render the notice in the locked window itself. Synchronous AppKit modal
  // presentation from a SwiftUI task can be suppressed during a UI transaction;
  // that must never be mistaken for the user choosing Cancel.
  private var alphaAcknowledgement: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(AlphaDisclaimer.title, systemImage: "exclamationmark.triangle")
        .font(.title2.bold())
      Text(productTitle).font(.headline)
      ScrollView {
        Text(AlphaDisclaimer.message)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      if let disclaimerSaveError {
        Text(disclaimerSaveError)
          .foregroundStyle(.red)
          .accessibilityIdentifier("alpha-disclaimer-save-error")
      }
      Text("Driver discovery and tape controls have not started.")
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("alpha-disclaimer-cancel")
        Button("Accept") { acceptAlphaDisclaimer() }
          .accessibilityIdentifier("alpha-disclaimer-accept")
      }
    }
    .padding(32)
    .frame(maxWidth: 760)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("alpha-disclaimer-gate")
  }

  @MainActor private func acceptAlphaDisclaimer() {
    guard !disclaimerAccepted else { return }
    guard AlphaDisclaimer.accept(domain: Self.consentDomain, alphaVersion: alphaVersion) else {
      disclaimerSaveError = "Could not save your acknowledgement. The app remains locked. Check that your user preferences are writable, then try Accept again or Cancel to quit."
      return
    }
    disclaimerSaveError = nil
    disclaimerAccepted = true
  }

  private var interactionLocked: Bool {
    model.isBusy || installer.isInFlight
  }
}

private struct AcknowledgmentsCommand: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button("Acknowledgments…") { openWindow(id: "acknowledgments") }
  }
}

private struct ArchivesPage: View {
  @ObservedObject var model: RewindDVModel
  @ObservedObject var tapeMap: TapeEvidenceMapModel
  @ObservedObject var recovery: GentleRecoveryModel
  @ObservedObject var multiPass: MultiPassModel
  @ObservedObject var forensicPrefix: ForensicPrefixModel
  @ObservedObject var live: LiveMonitorModel
  @ObservedObject var wholeTape: WholeTapeCaptureModel
  let interactionLocked: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("ANALYSIS & RECOVERY").font(.largeTitle.bold()).foregroundStyle(.white)
        Text("Read-only inspection and explicitly supervised recovery. Source evidence is never overwritten.")
          .foregroundStyle(.secondary)

        if model.isBusy || tapeMap.busy || multiPass.busy || recovery.busy || forensicPrefix.busy {
          Text("Processing continues even when sections are collapsed. Expand the active section for progress and available Cancel controls. Keep source and destination drives connected.")
            .foregroundStyle(.orange).accessibilityIdentifier("archives-processing-notice")
        }

        ForensicPrefixView(model: forensicPrefix,
          available: !interactionLocked && !multiPass.busy && !tapeMap.busy && !live.active && !live.busy)

        TapeEvidenceMapView(map: tapeMap).disabled(interactionLocked || multiPass.busy || forensicPrefix.busy)

        MultiPassView(model: multiPass, map: tapeMap).disabled(interactionLocked || tapeMap.busy || forensicPrefix.busy || live.active || live.busy)

        GentleRecoveryView(recovery: recovery, map: tapeMap,
          executionAvailable: !interactionLocked && !multiPass.busy && tapeMap.canExportReports && !live.lockedOut && model.selectedRoute != nil,
          start: startRecovery)
          .disabled(interactionLocked || multiPass.busy || forensicPrefix.busy)
          .onAppear { recovery.refresh() }

        DVPackMetadataView(archiveModel: model, interactionLocked: interactionLocked)

        ArchiveSection("Raw archive verifier") {
          VStack(alignment: .leading, spacing: 12) {
            Button("Choose Archive Folder…", systemImage: "checkmark.shield") {
              model.chooseArchive()
            }
            .disabled(interactionLocked)
            if let source = model.archiveSource {
              Text(source.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let report = model.archiveVerification {
              LabeledContent("Lifecycle", value: report.lifecycle.rawValue)
              LabeledContent("Byte integrity", value: report.byteIntegrity.rawValue)
              LabeledContent("Acquisition outcome", value: report.acquisitionOutcome.rawValue)
              LabeledContent(
                "Acknowledged extents", value: report.acknowledgedExtentCount.formatted())
              LabeledContent("Orphan bytes", value: report.orphanByteCount.formatted())
              if report.lifecycle == .incomplete {
                Text("Verified stored bytes do not make an incomplete acquisition complete.")
                  .font(.caption).foregroundStyle(.orange)
              }
            }
          }
          .padding(.vertical, 6)
        }

        if let error = model.analysisError {
          HonestNotice(
            title: "Inspection failed closed", message: error, symbol: "xmark.octagon", tint: .red)
        }
      }
      .padding(28)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("archives-page")
  }
  private func startRecovery(_ journal: DVGentleRecoveryJournal, target: String, positioningSeconds: Int) {
    guard !interactionLocked, !tapeMap.busy, !live.lockedOut,
      let deck = model.selectedDeck, let route = model.selectedRoute,
      journal.plan.source == tapeMap.receipt?.sourceSnapshot,
      journal.plan.mapSHA256 == tapeMap.reader?.binding.mapReceiptSHA256 else { return }
    let alert = NSAlert()
    alert.messageText = "Approve one supervised recovery pass"
    alert.informativeText = "Tape: \(journal.plan.tapeLabel)\nTarget: \(target) (file-frame reference only)\n\(journal.plan.budget.passSeconds)s forward PLAY, then one STOP request. \(journal.plan.budget.stopAllowanceSeconds)s stopping allowance.\n\nStay at the deck with physical STOP available. There is no automatic rewind, seek or retry. Missing DV/timecode never disarms receive. New footage is saved separately."
    alert.addButton(withTitle: "Approve one pass"); alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    panel.message = "Choose a destination for this separate recovery capture. Keep the tape, Mac and destination connected."
    guard panel.runModal() == .OK, let destination = panel.url,
      model.selectedDeck?.id == deck.id, model.selectedRoute == route,
      !interactionLocked, !live.lockedOut else { return }
    if DVGentleRecovery.isWithin(destination, directory: journal.directory) ||
      tapeMap.directory.map({ DVGentleRecovery.isWithin(destination, directory: $0) }) == true {
      let warning = NSAlert(); warning.messageText = "Choose a separate capture destination"
      warning.informativeText = "Recovery media must be stored outside the immutable tape map and recovery plan folders. No attempt or tape command was issued."
      warning.runModal(); return
    }
    guard let region = journal.plan.targets.first(where: { $0.id == target }) else { return }
    Task {
      do {
        try await tapeMap.validateRecoveryTarget(region, plan: journal.plan)
        guard model.selectedDeck?.id == deck.id, model.selectedRoute == route,
          !interactionLocked, !live.lockedOut else { return }
        model.monitorSource = .deck; model.page = .capture
        wholeTape.start(model: model, live: live, destination: destination,
          recovery: .init(journal: journal, target: target, positioningSeconds: positioningSeconds, confirmedTapeAndPosition: true))
      } catch {
        let warning = NSAlert(); warning.messageText = "Recovery not started"
        warning.informativeText = error.localizedDescription + " No tape command was issued."
        warning.runModal()
      }
    }
  }
}

private struct DiagnosticsPage: View {
  @ObservedObject var model: RewindDVModel
  @ObservedObject var installer: SystemExtensionInstaller
  @Binding var showActivationConfirmation: Bool
  let activationLocked: Bool

  var body: some View {
    // Only the visible diagnostics page redraws for diagnostic clocks/bytes.
    // This neither issues driver queries nor invalidates the capture workspace.
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      diagnosticsContent
    }
  }

  private var diagnosticsContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("DIAGNOSTICS").font(.largeTitle.bold()).foregroundStyle(.white)
        HStack {
          Button("Activate Driver…") { showActivationConfirmation = true }
            .disabled(activationLocked || installer.isInFlight)
            .accessibilityIdentifier("activate-driver")
          Button("Open Driver Settings…") { installer.openDriverSettings() }
            .disabled(activationLocked)
            .accessibilityIdentifier("open-driver-settings")
        }
        if installer.state == .pendingApproval || installer.settingsOpenFailed {
          Text("In System Settings, open General → Login Items & Extensions → rewindDV. Enable the driver extension and complete the macOS approval prompt.")
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        ArchiveSection("Driver readiness") {
          Label(model.refreshFailed ? "Driver not ready" : "Driver readiness",
            systemImage: model.refreshFailed ? "exclamationmark.triangle" : "info.circle")
            .foregroundStyle(model.refreshFailed ? Color.orange : Color.secondary)
          Text(model.refreshFeedback).textSelection(.enabled)
          Text(model.handshakeFeedback).font(.callout).foregroundStyle(.secondary)
          Text("Activation: \(installer.state.title). Activation approval does not prove that the new driver is attached.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("driver-readiness")
        AlphaDiagnosticsView(captureBusy: activationLocked || installer.isInFlight)
        ArchiveSection("Candidate identity") {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Driver class", value: "ASFWDriver")
            LabeledContent("Bundle / server", value: "net.rewinddigital.RewindDV.Driver")
            LabeledContent("Required driver", value: DriverBuildRequirement.display)
            LabeledContent("PCI provider", value: "11c1:5901")
            LabeledContent("Activation", value: installer.state.title)
          }
          .padding(.vertical, 6)
        }
        ArchiveSection("Automatic connection") {
          VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Checks attempted", value: model.refreshAttempts.formatted())
            Text(model.refreshFeedback).textSelection(.enabled)
            if let checked = model.lastRefreshDate {
              LabeledContent("Last check", value: checked.formatted(date: .omitted, time: .standard))
            }
          }
          .padding(.vertical, 6)
        }
        if let snapshot = model.latestDriverSnapshot {
          ArchiveSection("Last driver readiness check") {
            VStack(alignment: .leading, spacing: 8) {
              LabeledContent(
                "Capability flags", value: String(format: "0x%03X", snapshot.capabilities.flags))
              LabeledContent("Discovered decks", value: snapshot.decks.count.formatted())
              switch snapshot.health {
              case .unverified(let bytes, let note):
                LabeledContent("Raw status bytes", value: bytes.formatted())
                Text(note).font(.caption).foregroundStyle(.secondary)
              }
              if !snapshot.rawStatus.isEmpty {
                Text(snapshot.rawStatus.prefix(96).map { String(format: "%02x", $0) }.joined())
                  .font(.caption2.monospaced())
                  .textSelection(.enabled)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 6)
          }
        } else {
          Text("Automatic discovery is waiting for an idle, active workspace.")
            .foregroundStyle(.secondary)
        }
      }
      .padding(28)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("diagnostics-page")
  }
}

private struct StateTile: View {
  let title: String
  let value: String
  let symbol: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(value.replacingOccurrences(of: "_", with: " ").capitalized)
        .font(.title3.weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct HonestNotice: View {
  let title: String
  let message: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol).font(.title2).foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(message).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.22)))
  }
}
