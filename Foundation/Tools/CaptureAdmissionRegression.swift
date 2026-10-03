// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// OFFLINE ONLY. Production monitor, observer, startIngest and admission guard;
// controlled bridge completions replace IOKit, files and physical commands.
import AppKit
import SwiftUI
import Foundation

@MainActor enum AdmissionFixtureClock {
  static var offset = Duration.zero
  static var now: ContinuousClock.Instant { ContinuousClock.now.advanced(by: offset) }
}

struct LiveReceiveStatus: Sendable {
  var state: UInt32 = 1
  let lastStatus: Int32 = 0
  let packetsSeen: UInt64 = 0, dropped: UInt64 = 0, oversized: UInt64 = 0
}
struct LivePersistenceHealth: Sendable {
  let pendingRecords = 0, durableThrough: UInt64 = 0
  let writerPressure = false
  let diagnosticFailure: String? = nil
}
enum DriverBridgeError: Error { case permanentSessionLockout, commandAlreadyInFlight }
actor Barrier {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}
actor DriverBridge {
  var liveConnection: Bool?
  var commandInFlight = false, inspectionInFlight = false, permanentlyLockedOut = false
  var starts = 0, ends = 0, diagnosticWrites = 0, inspections = 0
  var terminal: UInt32 = 1
  var rejectStart = false, rejectAfterAcquisition = false
  var completedFrames: UInt64 = 42
  var inspectionBarrier: Barrier?
  var failInspection = false
  func configure(command: Bool = false, inspection: Bool = false, receive: Bool = false,
                 reject: Bool = false, acquiredFailure: Bool = false, terminal: UInt32 = 1) {
    commandInFlight = command; inspectionInFlight = inspection
    liveConnection = receive ? true : nil; rejectStart = reject; rejectAfterAcquisition = acquiredFailure; self.terminal = terminal
  }
  func holdInspection(_ barrier: Barrier, fail: Bool = false) {
    inspectionBarrier = barrier; failInspection = fail
  }
  func beginLiveReceive(_ deck: DiscoveredDeck, destinationParent: URL?,
    captureFolderKind: CaptureDirectory.Kind = .manual, expectedRoute: FoundationRoute?,
    existingStopObligation: Bool? = nil) throws -> URL {
    var attempt = ReceiveStartDiagnostic(existingStopObligation: existingStopObligation)
    do {
      // PRODUCTION_ADMISSION_GUARD
      if rejectStart { throw ControlWireError.invalid("Synthetic pre-acquisition failure") }
      starts += 1; liveConnection = true
      if rejectAfterAcquisition {
        attempt.connectionCreated = true; attempt.flightCreationAttempted = true
        attempt.flightCreated = true; attempt.receiveSubmitted = true; attempt.acquiredOwnership = true
        throw ReceiveStartFailure(reason: "Synthetic failure after ownership acquisition", diagnostic: attempt,
          flightURL: URL(fileURLWithPath: "/offline-no-files-created"))
      }
      return URL(fileURLWithPath: "/offline-no-files-created")
    } catch {
      if let acquired = error as? ReceiveStartFailure { throw acquired }
      attempt.blockers = [(liveConnection != nil, "liveConnection"),
        (commandInFlight, "commandInFlight"), (inspectionInFlight, "inspectionInFlight")]
        .compactMap { $0.0 ? $0.1 : nil }
      throw ReceiveStartFailure(reason: "Synthetic admission rejection", diagnostic: attempt, flightURL: nil)
    }
  }
  func readLiveBatch() -> LiveReceiveBatch {
    .init(status: .init(state: terminal), frames: [], drained: true, rejectedPackets: 0,
      assembledFrames: 0, discontinuities: 0, incompleteFrames: 0)
  }
  func endLiveReceive() -> LivePreservedFrame? { ends += 1; liveConnection = nil; return nil }
  func completedReceiveStatistics() -> LiveReceiveBatch? {
    .init(status: .init(state: terminal == 1 ? 2 : terminal), frames: [], drained: true,
      rejectedPackets: 0, assembledFrames: completedFrames, discontinuities: 0, incompleteFrames: 0)
  }
  func recordMonitorDiagnostics(_ message: String) { diagnosticWrites += 1 }
  func receivedMediaFormats() -> ReceiveMediaFormatEvidence { .init() }
  func livePersistenceHealth() -> LivePersistenceHealth { .init() }
  func receiveRequiresLockout() -> Bool { permanentlyLockedOut }
  func inspectDevice(_ deck: DiscoveredDeck, transportOnly: Bool = false,
    expectedRoute: FoundationRoute?, passiveTransport: Bool = false) async throws -> DeviceInspectionReport {
    precondition(!inspectionInFlight && !commandInFlight)
    inspectionInFlight = true; inspections += 1
    defer { inspectionInFlight = false }
    if let inspectionBarrier {
      self.inspectionBarrier = nil
      await inspectionBarrier.wait()
      precondition(!Task.isCancelled, "An admitted query must be joined, not cancelled")
    }
    if failInspection { throw ControlWireError.invalid("Synthetic query failure") }
    return .init(deck: deck, observedAt: Date(), receiptURL: URL(fileURLWithPath: "/offline-query"),
      entries: [], completion: "Synthetic", controlLockedOut: false, route: expectedRoute!,
      validatedTransportState: [12,32,196,96])
  }
}

@MainActor final class RewindDVModel {
  let bridge = DriverBridge()
  let externalTransportObserver = ExternalDeckTransportObserver()
  var selectedDeck: DiscoveredDeck?, selectedRoute: FoundationRoute?
  var isBusy = false, wholeTapeActive = false, controlLockedOut = false
  var requiresSupervisedStop = false, externalTransportObservationActive = false
  var windObservationActive = false
  var passiveObservationFailureRoute: FoundationRoute?
  var monitorSource = MonitorSource.deck
  var headline = "", detail = "", handshakeFeedback = ""
  var plays = 0
  var joinBoundary: Barrier?
  var navigationLocked: Bool { isBusy || wholeTapeActive || controlLockedOut || requiresSupervisedStop }
  func send(_ command: DeckCommand, onAccepted: (@MainActor () -> Void)? = nil) {
    precondition(!isBusy, "Reservation must release before the initial PLAY")
    plays += 1 // No hardware or callback observer needed for this fixture.
  }
  func wholeTapeStopObserved() {}
  func sampleDeckTimecode(deck: DiscoveredDeck, route: FoundationRoute, transport: [UInt8]?,
                         receiving: Bool, stopping: Bool) async {}
  // PRODUCTION_MODEL_METHODS
}

@main struct CaptureAdmissionRegression {
  @MainActor static func until(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()) {
      precondition(ContinuousClock.now < deadline, "Deterministic barrier did not settle")
      await Task.yield()
    }
  }
  @MainActor static func runInteraction(deck: DiscoveredDeck, route: FoundationRoute) {
    let fixture = AdmissionInteractionFixture(deck: deck, route: route)
    withExtendedLifetime(fixture) { NSApp.run() }
  }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var bytes = Data()
    func put<T: FixedWidthInteger>(_ value: T) {
      var x = value.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
    }
    put(UInt32(1)); put(UInt32(48)); for _ in 0..<4 { put(UInt64(1)) }
    put(UInt32(1)); put(UInt16(1)); put(UInt16(0))
    let route = try FoundationRoute(data: bytes)
    let deck = DiscoveredDeck(guid: 1, generation: 1, node: 1, state: 1, vendor: "Synthetic", model: "Offline")
    let destination = URL(fileURLWithPath: "/offline-no-files-created")
    if CommandLine.arguments.contains("--interactive") {
      runInteraction(deck: deck, route: route)
      return
    }
    // Red/green case also compiles against the original LiveMonitorModel.
    for conflict in 0..<4 {
      let bridge = DriverBridge(), live = LiveMonitorModel(muteAudio: true)
      await bridge.configure(command: conflict == 0, inspection: conflict == 1,
        receive: conflict == 2, reject: conflict == 3)
      live.start(bridge: bridge, deck: deck, ingestParent: destination, expectedRoute: route)
      await until { !live.busy && !live.active }
      let ends = await bridge.ends, starts = await bridge.starts, writes = await bridge.diagnosticWrites
      precondition(ends == 0 && starts == 0 && writes == 0,
        "Rejected start touched receive cleanup, opened receive, or wrote another owner's diagnostics")
      precondition(live.flightURL == nil && live.completeFrames == 0 && live.packetsSeen == 0)
      precondition(live.ingestDetail.contains("Capture did not start") && !live.ingestDetail.contains("retained"))
      precondition(!live.receiverFailedWithoutTapeStopProof && !live.tapeStopNeedsAttention)
    }
    print("PASS: four pre-acquisition failures leave owners, counters and STOP state untouched")
    if CommandLine.arguments.contains("--reporting-only") { return }
    // COMPILED_CURRENT_TESTS
  }
}
