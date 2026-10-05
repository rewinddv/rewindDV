// OFFLINE ONLY. Links the production monitor/observer/pump to a fake bridge.
// No DriverBridge implementation, IOKit, real route, output capture or tape command.
import AppKit
import Foundation

struct LiveReceiveStatus: Sendable {
  var state: UInt32 = 1
  let lastStatus: Int32 = 0
  let packetsSeen: UInt64 = 0
  let dropped: UInt64 = 0
  let oversized: UInt64 = 0
  // Synthetic terminal receipts have no pending raw records in this fixture.
  let writeSequence: UInt64 = 0, acknowledged: UInt64 = 0
}
struct LivePersistenceHealth: Sendable {
  let pendingRecords = 0
  let durableThrough: UInt64 = 0
  let writerPressure = false
  let diagnosticFailure: String? = nil
}
actor DriverBridge {
  let route: FoundationRoute
  let failStatus: Bool
  let startupDelay: Duration
  let failReceive: Bool
  let terminalState: UInt32?
  let terminalOnlyDuringDrain: Bool
  let finalState: UInt32?
  var began = false, ended = false, physicalStop = false
  var observations = 0, stableStops = 0
  var holdNextStatus = false, statusPending = false
  var statusRelease: CheckedContinuation<Void, Never>?
  var stopSubmissions = 0
  init(route: FoundationRoute, failStatus: Bool, startupDelay: Duration, failReceive: Bool = false,
       terminalState: UInt32? = nil, terminalOnlyDuringDrain: Bool = false, finalState: UInt32? = nil) {
    self.route = route; self.failStatus = failStatus; self.startupDelay = startupDelay; self.failReceive = failReceive
    self.terminalState = terminalState; self.terminalOnlyDuringDrain = terminalOnlyDuringDrain
    self.finalState = finalState
  }
  func beginLiveReceive(_ deck: DiscoveredDeck, destinationParent: URL?,
    captureFolderKind: CaptureDirectory.Kind = .manual, expectedRoute: FoundationRoute?,
    existingStopObligation: Bool? = nil) async throws -> URL {
    precondition(expectedRoute == route)
    try await Task.sleep(for: startupDelay)
    began = true
    return URL(fileURLWithPath: "/offline-not-a-capture")
  }
  func readLiveBatch() throws -> LiveReceiveBatch {
    precondition(began && !ended)
    if failReceive { throw ControlWireError.invalid("synthetic storage persistence failure") }
    return .init(status: LiveReceiveStatus(state: terminalOnlyDuringDrain ? 1 : terminalState ?? 1), frames: [], drained: true,
      rejectedPackets: 0, assembledFrames: 0, discontinuities: 0, incompleteFrames: 0)
  }
  func livePersistenceHealth() -> LivePersistenceHealth { .init() }
  func receivedMediaFormats() -> ReceiveMediaFormatEvidence { .init() }
  func recordMonitorDiagnostics(_ message: String) throws {}
  func inspectDevice(_ deck: DiscoveredDeck, transportOnly: Bool, expectedRoute: FoundationRoute?) async throws -> DeviceInspectionReport {
    precondition(began && !ended && transportOnly && expectedRoute == route)
    if holdNextStatus {
      holdNextStatus = false; statusPending = true
      await withCheckedContinuation { statusRelease = $0 }
      precondition(!Task.isCancelled, "Admitted STATUS was cancelled instead of joined")
      statusPending = false
    }
    observations += 1
    if failStatus { throw ControlWireError.invalid("synthetic unavailable STATUS") }
    let stopped = observations >= 3
    stableStops = stopped ? stableStops + 1 : 0
    return .init(deck: deck, observedAt: Date(), receiptURL: URL(fileURLWithPath: "/offline/\(UUID())"),
      entries: [], completion: "SYNTHETIC", controlLockedOut: false, route: route,
      validatedTransportState: stopped ? [12,32,196,96] : [12,32,195,117])
  }
  func holdStatus() { holdNextStatus = true }
  func releaseStatus() { statusRelease?.resume(); statusRelease = nil }
  func submitSyntheticStop() {
    precondition(!statusPending, "STOP collided with the outstanding PLAY status query")
    stopSubmissions += 1
  }
  func attestPhysicalStop() { physicalStop = true }
  func endLiveReceive() -> LivePreservedFrame? {
    precondition(failReceive || terminalState != nil || stableStops >= 2 || physicalStop, "STOP acceptance or elapsed time must never close receive")
    ended = true
    return nil
  }
  func completedReceiveStatistics() -> LiveReceiveBatch? {
    guard let terminalState else { return nil }
    return .init(status: LiveReceiveStatus(state: finalState ?? terminalState), frames: [], drained: true,
      rejectedPackets: 0, assembledFrames: 42, discontinuities: 0, incompleteFrames: 0)
  }
  func receiveRequiresLockout() -> Bool { failReceive }
}

@main struct ManualStopTailRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let scenarios = CommandLine.arguments.contains("--terminal-only") ? 9..<15 : 0..<15
    for scenario in scenarios {
      var bytes = Data()
      func put<T: FixedWidthInteger>(_ value: T) {
        var x = value.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
      }
      put(UInt32(1)); put(UInt32(48))
      for _ in 0..<4 { put(UInt64(1)) }
      put(UInt32(1)); put(UInt16(1)); put(UInt16(0))
      let route = try FoundationRoute(data: bytes)
      let deck = DiscoveredDeck(guid: 1, generation: 1, node: 1, state: 1, vendor: "Synthetic", model: "No hardware")
      let bridge = DriverBridge(route: route, failStatus: scenario == 2,
        startupDelay: [3, 5, 6].contains(scenario) ? .seconds(2) : .milliseconds(300), failReceive: scenario == 8,
        terminalState: scenario >= 9 ? (scenario.isMultiple(of: 2) ? 4 : 3) : nil,
        terminalOnlyDuringDrain: (11...12).contains(scenario), finalState: scenario >= 13 ? 2 : nil)
      let live = LiveMonitorModel(muteAudio: true)
      var playCallbacks = 0, confirmedStops = 0
      live.start(bridge: bridge, deck: deck, expectedRoute: route, onReceiving: { playCallbacks += 1 })
      if scenario >= 9 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        if (11...12).contains(scenario) {
          while !live.receiverReady {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
          }
          await live.stopAndWait()
        }
        while live.active || live.busy {
          precondition(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(10))
        }
        try FileHandle.standardError.write(contentsOf: Data(
          "Terminal scenario \(scenario): lockedOut=\(live.lockedOut), stopWarning=\(live.receiverFailedWithoutTapeStopProof), needsAttention=\(live.tapeStopNeedsAttention), frames=\(live.completeFrames)\n".utf8))
        precondition(!live.lockedOut, "A terminal failure does not invent a bridge lockout")
        precondition(live.receiverFailedWithoutTapeStopProof && live.tapeStopNeedsAttention,
          "Bus-reset/failed receive status must retain the physical STOP warning even when cleanup succeeds")
        precondition(live.tapeStopFeedback.contains("MANUAL STOP REQUIRED"))
        precondition(live.completeFrames == 42, "Failure reporting must retain final drain accounting")
        let submissions = await bridge.stopSubmissions
        precondition(submissions == 0, "Receive failure must not guess a route or submit a tape command")
        print("TERMINAL_RECEIVE_FAILURE_PASS scenario=\(scenario)")
        continue
      }
      if scenario == 8 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while live.active || live.busy {
          precondition(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(10))
        }
        precondition(live.lockedOut && live.receiverFailedWithoutTapeStopProof && live.tapeStopNeedsAttention)
        precondition(live.tapeStopFeedback.contains("MANUAL STOP REQUIRED"))
        let submissions = await bridge.stopSubmissions
        precondition(submissions == 0, "A persistence fault must not replay or guess a route for STOP")
        print("RECEIVE_FAULT_PHYSICAL_STOP_WARNING_NO_REPLAY_PASS")
        continue
      }
      if scenario == 1 {
        while !live.active { try await Task.sleep(for: .milliseconds(10)) }
      }
      if scenario == 6 {
        live.observeCaptureTransportPlaying(bridge: bridge, deck: deck, route: route)
        await bridge.attestPhysicalStop()
        await live.stopAndWait()
        try await Task.sleep(for: .milliseconds(100))
        let count = await bridge.observations
        precondition(count == 0, "Receive cleanup allowed a deferred STATUS to start")
        precondition(!live.active && !live.busy)
        print("MANUAL_STOP_TAIL_PASS scenario=6 deferred observer revoked by receive cleanup")
        continue
      }
      if scenario == 4 || scenario == 7 {
        while !live.active { try await Task.sleep(for: .milliseconds(10)) }
        await bridge.holdStatus()
        live.observeCaptureTransportPlaying(bridge: bridge, deck: deck, route: route)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await bridge.statusPending) {
          precondition(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(10))
        }
        if scenario == 7 {
          live.observeCaptureTransportPlaying(bridge: bridge, deck: deck, route: route)
          await Task.yield()
          live.observeCaptureTransportPlaying(bridge: bridge, deck: deck, route: route)
          await Task.yield()
        }
        let handoff = Task { await live.prepareForOperatorStop(); await bridge.submitSyntheticStop() }
        try await Task.sleep(for: .milliseconds(50))
        let submissions = await bridge.stopSubmissions
        precondition(submissions == 0, "STOP must wait for the admitted STATUS")
        await bridge.releaseStatus()
        await handoff.value
      }
      if scenario == 5 {
        live.observeCaptureTransportPlaying(bridge: bridge, deck: deck, route: route)
        await live.prepareForOperatorStop()
        await bridge.submitSyntheticStop()
        let count = await bridge.observations
        precondition(count == 0, "Deferred PLAY observer survived STOP intent")
      }
      live.cancelPendingIngestPlay()
      live.stopAfterTapeResponse(bridge: bridge, deck: deck, route: route) { confirmedStops += 1 }
      precondition(live.awaitingTapeStop)
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      let began = ContinuousClock.now
      while live.active || live.busy {
        precondition(ContinuousClock.now < deadline, "STOP tail lifecycle hung")
        if scenario == 3, ContinuousClock.now - began > .milliseconds(1100) {
          await bridge.attestPhysicalStop()
          await live.finishAfterPhysicalStop()
        }
        if live.tapeStopNeedsAttention {
          let ended = await bridge.ended
          precondition(scenario == 2 && live.active && !ended)
          await bridge.attestPhysicalStop()
          await live.finishAfterPhysicalStop()
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      let ended = await bridge.ended
      let beganReceive = await bridge.began
      // Scenario 3 explicitly stops before the synthetic begin acquires anything.
      // Rejection/cancellation must not invoke cleanup for an unowned session.
      precondition(ended == beganReceive)
      if scenario == 3 {
        precondition(!beganReceive && !live.awaitingTapeStop && !live.tapeStopNeedsAttention)
      } else { precondition(ended) }
      precondition(confirmedStops == (scenario == 2 || scenario == 3 ? 0 : 1))
      if scenario >= 4 {
        let count = await bridge.stopSubmissions
        precondition(count == 1, "One operator intent must submit exactly one STOP")
      }
      if scenario == 3 {
        let count = await bridge.observations
        precondition(count == 0, "Join submitted a new STATUS after physical stop attestation")
      }
      if scenario != 1 && scenario != 4 && scenario != 7 { precondition(playCallbacks == 0, "STOP failed to revoke pending startup PLAY") }
      print("MANUAL_STOP_TAIL_PASS scenario=\(scenario) startup_or_active_owner_joined; no fixed acceptance tail")
    }
  }
}
