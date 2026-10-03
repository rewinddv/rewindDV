// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// This releases a UI motion obligation, never authorizes motion or proves BOT/EOT.
struct WindStopEvidenceGate {
  let route: FoundationRoute
  private var previousReceipt: String?
  private var consecutiveStops = 0

  init(route: FoundationRoute) { self.route = route }

  mutating func observe(_ report: DeviceInspectionReport) throws -> Bool {
    guard !report.controlLockedOut, report.route == route,
      report.receiptIdentity != previousReceipt else {
      throw ControlWireError.invalid("Wind status unavailable, repeated or from a changed route")
    }
    previousReceipt = report.receiptIdentity
    // A freshly journaled transition/INTERIM response has no stable decoded
    // state. It breaks consecutive STOP proof but is not a route failure.
    guard let bytes = report.validatedTransportState else {
      consecutiveStops = 0
      return false
    }
    guard bytes.count == 4, bytes[1] == 0x20,
      [UInt8(0x0c),0x0b].contains(bytes[0]) else {
      throw ControlWireError.invalid("Wind status is malformed")
    }
    // Apple TapeSubunitController.h: kAVCTapeTportModeWind C4 / WindStop 60.
    // M15 observed this exact reply both mid-tape and at operator-reported BOT.
    // Two independently journaled observations are required; no position inference.
    if bytes == [0x0c,0x20,0xc4,0x60] { consecutiveStops += 1 }
    else { consecutiveStops = 0 }
    return consecutiveStops >= 2
  }
}

/// Serialized typed transport observations. Build172 permits this exact STATUS
/// alongside receive. Shutdown joins submitted queries; it never abandons them.
@MainActor final class WindStopObserver {
  private var task: Task<Void, Never>?
  private var delayTask: Task<Void, Error>?
  private var token = UUID()

  func start(route: FoundationRoute, interval: Duration = .seconds(1), sampleImmediately: Bool = false,
    rapidWindingExperiment: Bool = false,
    sample: @escaping @Sendable () async throws -> DeviceInspectionReport,
    update: @escaping @MainActor (DeviceInspectionReport, Bool) async -> Void,
    failed: @escaping @MainActor (String) -> Void) {
    precondition(task == nil, "Previous observation must be joined")
    let run = UUID(); token = run
    task = Task { [weak self] in
      var gate = WindStopEvidenceGate(route: route)
      var burst = WindRefreshBurst(startedAt: DispatchTime.now().uptimeNanoseconds)
      var isFirstSample = true
      while let self, self.token == run {
        // Do not propagate cancellation into a submitted inspector request.
        do {
          let cycleInterval = rapidWindingExperiment
            ? burst.nextInterval(at: DispatchTime.now().uptimeNanoseconds) : interval
          if !sampleImmediately || !isFirstSample {
            let delay = Task { try await Task.sleep(for: cycleInterval) }
            self.delayTask = delay
            try await delay.value
            self.delayTask = nil
            guard self.token == run else { break }
          }
          isFirstSample = false
          let report = try await sample()
          guard self.token == run else { break }
          let stopped = try gate.observe(report)
          await update(report, stopped)
          if stopped { break }
        } catch {
          self.delayTask = nil
          if self.token == run { failed(error.localizedDescription) }
          break
        }
      }
    }
  }

  func stopAndJoin() async {
    let stopToken = UUID(); token = stopToken
    // Interrupt only the idle timer. The transaction task itself is never
    // cancelled: once submitted, its response/ownership fence must complete.
    delayTask?.cancel()
    let pending = task
    await pending?.value
    if token == stopToken { task = nil }
  }
}

/// Exact, route-bound observation of normal forward PLAY. Transitions and
/// stationary STOP are expected while a deck spins up; malformed or stale
/// evidence fails this one observation sequence closed.
struct ForwardPlayEvidenceGate {
  let route: FoundationRoute
  private var previousReceipt: URL?

  init(route: FoundationRoute) { self.route = route }

  mutating func observe(_ report: DeviceInspectionReport) throws -> Bool {
    guard !report.controlLockedOut, report.route == route,
      report.receiptURL != previousReceipt else {
      throw ControlWireError.invalid("PLAY status unavailable, repeated or from a changed route")
    }
    previousReceipt = report.receiptURL
    // Sony decks can report AV/C IN TRANSITION during spin-up. The report and
    // raw bytes remain journaled, but only a later STABLE decode can start time.
    guard let bytes = report.validatedTransportState else { return false }
    guard bytes.count == 4, bytes[1] == 0x20 else {
      throw ControlWireError.invalid("PLAY status is malformed")
    }
    // TA 2004005 response code 0x0b is IN TRANSITION. The M15 preserves the
    // requested normal-forward operands while its mechanism reaches speed.
    // Retain and retry that exact state; it is not yet authority to start time.
    if bytes == [0x0b, 0x20, 0xc3, 0x75] { return false }
    // TA 2004005 table 46: PLAY forward at nominal speed.
    return bytes == [0x0c, 0x20, 0xc3, 0x75]
  }
}

/// Bounded serialized STATUS polling used only to place the elapsed-clock
/// start at device-reported PLAY rather than AV/C command acceptance.
@MainActor final class ForwardPlayObserver {
  private var task: Task<Void, Never>?
  private var delayTask: Task<Void, Error>?
  private var token = UUID()

  func start(route: FoundationRoute, interval: Duration = .milliseconds(100),
    timeout: Duration = .seconds(15),
    sample: @escaping @Sendable () async throws -> DeviceInspectionReport,
    observed: @escaping @MainActor (DeviceInspectionReport) -> Void,
    failed: @escaping @MainActor (String) -> Void) {
    precondition(task == nil, "Previous PLAY observation must be joined")
    let run = UUID(); token = run
    task = Task { [weak self] in
      var gate = ForwardPlayEvidenceGate(route: route)
      let deadline = ContinuousClock.now.advanced(by: timeout)
      while let self, self.token == run {
        do {
          let report = try await sample()
          guard self.token == run else { break }
          if try gate.observe(report) {
            observed(report)
            break
          }
          guard ContinuousClock.now < deadline else {
            failed("The deck did not report normal forward PLAY before the observation deadline")
            break
          }
          let delay = Task { try await Task.sleep(for: interval) }
          self.delayTask = delay
          try await delay.value
          self.delayTask = nil
        } catch {
          self.delayTask = nil
          if self.token == run { failed(error.localizedDescription) }
          break
        }
      }
    }
  }

  func stopAndJoin() async {
    let stopToken = UUID(); token = stopToken
    delayTask?.cancel()
    let pending = task
    await pending?.value
    if token == stopToken { task = nil }
  }
}

/// Changed-state events from passive, route-bound transport STATUS. These are
/// observations only: they never authorize or replay a tape command.
enum ExternalDeckTransportEvent: Equatable {
  case playStarting
  case playConfirmed(needsMonitorStart: Bool)
  case stopObserved
  case stopConfirmed
}

/// Recognizes only the exact normal-forward PLAY and stationary STOP states
/// used by the qualified transport path. Other motion remains observable raw
/// evidence but cannot start or stop the monitor.
struct ExternalDeckTransportGate {
  let route: FoundationRoute
  private var previousReceipt: String?
  private var playSequenceSeen = false
  private var playConfirmedSeen = false
  private var stableStopCount = 0

  init(route: FoundationRoute) { self.route = route }

  mutating func observe(_ report: DeviceInspectionReport) throws -> ExternalDeckTransportEvent? {
    guard !report.controlLockedOut, report.route == route,
      report.receiptIdentity != previousReceipt else {
      throw ControlWireError.invalid("Transport status unavailable, repeated or from a changed route")
    }
    previousReceipt = report.receiptIdentity
    guard let bytes = report.validatedTransportState else {
      stableStopCount = 0
      return nil
    }
    guard bytes.count == 4, bytes[1] == 0x20,
      [UInt8(0x0c), 0x0b].contains(bytes[0]) else {
      throw ControlWireError.invalid("Transport status is malformed")
    }
    switch bytes {
    case [0x0b, 0x20, 0xc3, 0x75]:
      stableStopCount = 0
      guard !playSequenceSeen else { return nil }
      playSequenceSeen = true
      playConfirmedSeen = false
      return .playStarting
    case [0x0c, 0x20, 0xc3, 0x75]:
      stableStopCount = 0
      guard !playConfirmedSeen else { return nil }
      let needsStart = !playSequenceSeen
      playSequenceSeen = true
      playConfirmedSeen = true
      return .playConfirmed(needsMonitorStart: needsStart)
    case [0x0c, 0x20, 0xc4, 0x60]:
      guard playSequenceSeen else { return nil }
      stableStopCount += 1
      if stableStopCount == 1 { return .stopObserved }
      if stableStopCount == 2 {
        playSequenceSeen = false
        playConfirmedSeen = false
        stableStopCount = 0
        return .stopConfirmed
      }
      return nil
    default:
      // Search, wind and other device states neither fabricate PLAY nor end a
      // running monitor. A later exact STOP still requires two fresh samples.
      stableStopCount = 0
      return nil
    }
  }
}

/// One serialized passive observer shared by physical and GUI transport use.
/// `stopAndJoin` interrupts only its delay and joins any submitted STATUS before
/// a GUI command, receive startup, inspection or whole-tape job can proceed.
@MainActor final class ExternalDeckTransportObserver {
  private var task: Task<Void, Never>?
  private var delayTask: Task<Void, Error>?
  private var token = UUID()

  func start(route: FoundationRoute, interval: Duration = .milliseconds(200),
    sample: @escaping @Sendable () async throws -> DeviceInspectionReport,
    update: @escaping @MainActor (DeviceInspectionReport, ExternalDeckTransportEvent) async -> Void,
    idle: @escaping @MainActor (DeviceInspectionReport) async -> Void = { _ in },
    failed: @escaping @MainActor (String) -> Void) {
    precondition(task == nil, "Previous external transport observation must be joined")
    let run = UUID(); token = run
    task = Task { [weak self] in
      var gate = ExternalDeckTransportGate(route: route)
      while let self, self.token == run {
        do {
          let report = try await sample()
          guard self.token == run else { break }
          if let event = try gate.observe(report) { await update(report, event) }
          guard self.token == run else { break }
          await idle(report)
          guard self.token == run else { break }
          let delay = Task { try await Task.sleep(for: interval) }
          self.delayTask = delay
          try await delay.value
          self.delayTask = nil
        } catch {
          self.delayTask = nil
          if self.token == run { failed(error.localizedDescription) }
          break
        }
      }
    }
  }

  func waitUntilEnded() async { await task?.value }

  func stopAndJoin() async {
    let stopToken = UUID(); token = stopToken
    delayTask?.cancel()
    let pending = task
    await pending?.value
    if token == stopToken { task = nil }
  }
}
