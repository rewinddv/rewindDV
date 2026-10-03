import Foundation
import Testing
@testable import RewindDVControlCore

private func windRoute(epoch: UInt64 = 3) throws -> FoundationRoute {
  var b = Data()
  func put<T: FixedWidthInteger>(_ value: T) {
    var x = value.littleEndian; withUnsafeBytes(of: &x) { b.append(contentsOf: $0) }
  }
  put(UInt32(1)); put(UInt32(48)); put(UInt64(0xa1b2c3d4e5f60718))
  put(UInt64(1)); put(UInt64(1)); put(epoch); put(UInt32(4)); put(UInt16(1)); put(UInt16(0))
  return try FoundationRoute(data: b)
}

private func observation(_ route: FoundationRoute, bytes: [UInt8]? = [12,32,196,96],
  receipt: URL = URL(fileURLWithPath: "/offline/\(UUID().uuidString)"), locked: Bool = false) -> DeviceInspectionReport {
  .init(deck: .init(guid: route.guid, generation: route.generation, node: route.node,
    state: 1, vendor: "Offline", model: "Fixture"), observedAt: Date(), receiptURL: receipt,
    entries: [], completion: "Offline fixture", controlLockedOut: locked,
    route: route, validatedTransportState: bytes)
}

@Test func windStopRequiresTwoDistinctBoundRepliesAndNeverInfersPosition() throws {
  let route = try windRoute()
  var gate = WindStopEvidenceGate(route: route)
  let first = observation(route)
  #expect(try !gate.observe(first))
  #expect(throws: ControlWireError.self) { try gate.observe(first) }
  #expect(try gate.observe(observation(route)))
  var transition = WindStopEvidenceGate(route: route)
  #expect(try !transition.observe(observation(route, bytes: nil)))
  for bad in [observation(try windRoute(epoch: 4)), observation(route, locked: true)] {
    var rejected = WindStopEvidenceGate(route: route)
    #expect(throws: ControlWireError.self) { try rejected.observe(bad) }
  }
}

@Test func movingAndTransitionResetConsecutiveStopEvidence() throws {
  let route = try windRoute()
  for bytes: [UInt8] in [[11,32,196,96],[12,32,196,101],[12,32,196,117],[12,32,195,117]] {
    var gate = WindStopEvidenceGate(route: route)
    #expect(try !gate.observe(observation(route)))
    #expect(try !gate.observe(observation(route, bytes: bytes)))
    #expect(try !gate.observe(observation(route)))
    #expect(try gate.observe(observation(route)))
  }
}

@Test func coastDownTimecodePermissionDoesNotProveMechanicalStop() throws {
  let route = try windRoute(), transition: [UInt8] = [11,32,196,96]
  var wind = WindStopEvidenceGate(route: route)
  var external = ExternalDeckTransportGate(route: route)
  _ = try external.observe(observation(route, bytes: [12,32,195,117]))
  for _ in 0..<12 {
    let report = observation(route, bytes: transition)
    #expect(DeckTimecodeDisplayState.maySample(transport: report.validatedTransportState,
      receiving: false, stopping: false))
    #expect(try !wind.observe(report))
    #expect(try external.observe(report) == nil)
  }
  #expect(try !wind.observe(observation(route)))
  #expect(try wind.observe(observation(route)))
  #expect(try external.observe(observation(route)) == .stopObserved)
  #expect(try external.observe(observation(route)) == .stopConfirmed)
}

@Test func compactWindReceiptsAcceptIndependentSamplesAndRejectReplay() throws {
  let route = try windRoute(), directory = URL(fileURLWithPath: "/offline/shared-wind-journal")
  var gate = WindStopEvidenceGate(route: route)
  var moving = observation(route, bytes: [12,32,196,117], receipt: directory)
  moving.observationID = UUID()
  #expect(try !gate.observe(moving))
  var firstStop = observation(route, receipt: directory); firstStop.observationID = UUID()
  #expect(try !gate.observe(firstStop))
  #expect(throws: ControlWireError.self) { try gate.observe(firstStop) }
  var secondStop = observation(route, receipt: directory); secondStop.observationID = UUID()
  #expect(try gate.observe(secondStop))
}

@Test @MainActor func rapidWindStopJoinsPendingQueryWithoutStartingAnother() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route, delay: .milliseconds(40))
  let observer = WindStopObserver()
  var updates = 0
  observer.start(route: route, sampleImmediately: true, rapidWindingExperiment: true,
    sample: { try await fixture.sample() }, update: { _, _ in updates += 1 }, failed: { _ in })
  while await fixture.calls == 0 { try await Task.sleep(for: .milliseconds(1)) }
  await observer.stopAndJoin()
  #expect(await fixture.calls == 1)
  #expect(await !fixture.cancelled)
  #expect(updates == 0)
}

private actor WindFixture {
  var calls = 0
  var cancelled = false
  let route: FoundationRoute
  let delay: Duration
  init(route: FoundationRoute, delay: Duration = .zero) { self.route = route; self.delay = delay }
  func sample() async throws -> DeviceInspectionReport {
    calls += 1
    do { try await Task.sleep(for: delay) } catch { cancelled = true; throw error }
    return observation(route)
  }
}

@Test @MainActor func windObserverEndsAfterTwoStopsWithoutSendingControl() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route)
  let observer = WindStopObserver()
  var updates = 0; var stops = 0; var failures = 0
  observer.start(route: route, interval: .milliseconds(1), sample: { try await fixture.sample() },
    update: { _, stopped in updates += 1; if stopped { stops += 1 } }, failed: { _ in failures += 1 })
  for _ in 0..<500 where stops == 0 { try await Task.sleep(for: .milliseconds(2)) }
  await observer.stopAndJoin()
  #expect(updates == 2 && stops == 1 && failures == 0)
  #expect(await fixture.calls == 2)
}

@Test @MainActor func explicitStopJoinsPendingReadAndSuppressesItsUIResult() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route, delay: .milliseconds(40))
  let observer = WindStopObserver()
  var updates = 0; var failures = 0
  observer.start(route: route, interval: .milliseconds(1), sample: { try await fixture.sample() },
    update: { _, _ in updates += 1 }, failed: { _ in failures += 1 })
  while await fixture.calls == 0 { try await Task.sleep(for: .milliseconds(1)) }
  await observer.stopAndJoin()
  #expect(await fixture.calls == 1)
  #expect(await !fixture.cancelled)
  #expect(updates == 0 && failures == 0)
}

@Test @MainActor func failedWindObservationDoesNotRetry() async throws {
  let route = try windRoute()
  let observer = WindStopObserver()
  var failures = 0; var updates = 0
  observer.start(route: route, interval: .milliseconds(1), sample: { throw ControlWireError.invalid("offline failure") },
    update: { _, _ in updates += 1 }, failed: { _ in failures += 1 })
  for _ in 0..<500 where failures == 0 { try await Task.sleep(for: .milliseconds(2)) }
  await observer.stopAndJoin()
  #expect(failures == 1 && updates == 0)
}

@Test @MainActor func explicitStopInterruptsIdleTimerWithoutSubmittingAQuery() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route)
  let observer = WindStopObserver()
  var callbacks = 0
  observer.start(route: route, interval: .seconds(2), sample: { try await fixture.sample() },
    update: { _, _ in callbacks += 1 }, failed: { _ in callbacks += 1 })
  try await Task.sleep(for: .milliseconds(10))
  let start = ContinuousClock.now
  await observer.stopAndJoin()
  #expect(start.duration(to: .now) < .milliseconds(500))
  #expect(await fixture.calls == 0)
  #expect(callbacks == 0)
}

@Test @MainActor func immediateStopObservationDoesNotWaitBeforeFirstFreshStatus() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route)
  let observer = WindStopObserver()
  var updates = 0
  observer.start(route: route, interval: .seconds(2), sampleImmediately: true,
    sample: { try await fixture.sample() }, update: { _, _ in updates += 1 }, failed: { _ in })
  for _ in 0..<500 where updates == 0 { try await Task.sleep(for: .milliseconds(2)) }
  await observer.stopAndJoin()
  #expect(updates == 1)
  #expect(await fixture.calls == 1)
}

@Test func forwardPlayGateRequiresExactFreshRouteBoundStatus() throws {
  let route = try windRoute()
  var gate = ForwardPlayEvidenceGate(route: route)
  #expect(try !gate.observe(observation(route)))
  #expect(try !gate.observe(observation(route, bytes: nil)))
  #expect(try !gate.observe(observation(route, bytes: [0x0b, 0x20, 0xc3, 0x75])))
  #expect(try gate.observe(observation(route, bytes: [0x0c, 0x20, 0xc3, 0x75])))

  var stale = ForwardPlayEvidenceGate(route: route)
  let report = observation(route, bytes: [0x0c, 0x20, 0xc3, 0x75])
  #expect(try stale.observe(report))
  #expect(throws: ControlWireError.self) { try stale.observe(report) }
  var wrongRoute = ForwardPlayEvidenceGate(route: route)
  #expect(throws: ControlWireError.self) {
    try wrongRoute.observe(observation(try windRoute(epoch: 4),
      bytes: [0x0c, 0x20, 0xc3, 0x75]))
  }
}

private actor ForwardPlayFixture {
  let route: FoundationRoute
  var calls = 0
  init(route: FoundationRoute) { self.route = route }
  func sample() -> DeviceInspectionReport {
    calls += 1
    return observation(route, bytes: calls == 1 ? [0x0c, 0x20, 0xc4, 0x60] : [0x0c, 0x20, 0xc3, 0x75])
  }
}

@Test @MainActor func forwardPlayObserverWaitsThroughSpinUpAndEndsOnReportedPlay() async throws {
  let route = try windRoute()
  let fixture = ForwardPlayFixture(route: route)
  let observer = ForwardPlayObserver()
  var observed = 0; var failures = 0
  observer.start(route: route, interval: .milliseconds(1), timeout: .seconds(1),
    sample: { await fixture.sample() }, observed: { _ in observed += 1 }, failed: { _ in failures += 1 })
  for _ in 0..<500 where observed == 0 && failures == 0 { try await Task.sleep(for: .milliseconds(2)) }
  await observer.stopAndJoin()
  #expect(observed == 1 && failures == 0)
  #expect(await fixture.calls == 2)
}

@Test func externalTransportGateRecognizesPhysicalPlayAndTwoSampleStop() throws {
  let route = try windRoute()
  var gate = ExternalDeckTransportGate(route: route)
  #expect(try gate.observe(observation(route)) == nil) // initial idle is not an event
  #expect(try gate.observe(observation(route, bytes: [0x0b,0x20,0xc3,0x75])) == .playStarting)
  #expect(try gate.observe(observation(route, bytes: [0x0c,0x20,0xc3,0x75])) == .playConfirmed(needsMonitorStart: false))
  #expect(try gate.observe(observation(route, bytes: [0x0c,0x20,0xc3,0x75])) == nil)
  #expect(try gate.observe(observation(route)) == .stopObserved)
  #expect(try gate.observe(observation(route)) == .stopConfirmed)
  #expect(try gate.observe(observation(route)) == nil)
}

@Test func compactPassiveReceiptsRemainIndependentAndReplayIsRejected() throws {
  let route = try windRoute(), directory = URL(fileURLWithPath: "/offline/shared-journal")
  var gate = ExternalDeckTransportGate(route: route)
  var play = observation(route, bytes: [12,32,195,117], receipt: directory)
  play.observationID = UUID()
  #expect(try gate.observe(play) == .playConfirmed(needsMonitorStart: true))
  #expect(throws: ControlWireError.self) { try gate.observe(play) }
  var firstStop = observation(route, receipt: directory); firstStop.observationID = UUID()
  #expect(try gate.observe(firstStop) == .stopObserved)
  var secondStop = observation(route, receipt: directory); secondStop.observationID = UUID()
  #expect(try gate.observe(secondStop) == .stopConfirmed)
  var stale = observation(try windRoute(epoch: 99), receipt: directory); stale.observationID = UUID()
  #expect(throws: ControlWireError.self) { try gate.observe(stale) }
}

@Test func externalTransportGateCanAttachWhileAlreadyPlayingAndIgnoresSearch() throws {
  let route = try windRoute()
  var gate = ExternalDeckTransportGate(route: route)
  #expect(try gate.observe(observation(route, bytes: [0x0c,0x20,0xc3,0x75])) == .playConfirmed(needsMonitorStart: true))
  #expect(try gate.observe(observation(route, bytes: [0x0c,0x20,0xc3,0x65])) == nil)
  #expect(try gate.observe(observation(route)) == .stopObserved)
  #expect(try gate.observe(observation(route)) == .stopConfirmed)
}

private actor ExternalTransportFixture {
  let route: FoundationRoute
  var calls = 0
  init(route: FoundationRoute) { self.route = route }
  func sample() -> DeviceInspectionReport {
    calls += 1
    let sequence: [[UInt8]] = [
      [0x0c,0x20,0xc4,0x60], [0x0b,0x20,0xc3,0x75],
      [0x0c,0x20,0xc3,0x75], [0x0c,0x20,0xc4,0x60], [0x0c,0x20,0xc4,0x60]
    ]
    return observation(route, bytes: sequence[min(calls - 1, sequence.count - 1)])
  }
}

@Test @MainActor func externalObserverEmitsOnlyChangedPhysicalTransportEvents() async throws {
  let route = try windRoute()
  let fixture = ExternalTransportFixture(route: route)
  let observer = ExternalDeckTransportObserver()
  var events: [ExternalDeckTransportEvent] = []
  observer.start(route: route, interval: .milliseconds(1), sample: { await fixture.sample() },
    update: { _, event in events.append(event) }, failed: { _ in })
  for _ in 0..<500 where events.count < 4 { try await Task.sleep(for: .milliseconds(2)) }
  await observer.stopAndJoin()
  #expect(events == [.playStarting, .playConfirmed(needsMonitorStart: false), .stopObserved, .stopConfirmed])
  #expect(await fixture.calls >= 5)
}

@Test @MainActor func foregroundStopSuppressesOptionalReadAfterPendingTransportCompletes() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route, delay: .milliseconds(40))
  let observer = ExternalDeckTransportObserver()
  var optionalReads = 0
  observer.start(route: route, interval: .milliseconds(1), sample: { try await fixture.sample() },
    update: { _, _ in }, idle: { _ in optionalReads += 1 }, failed: { _ in })
  while await fixture.calls == 0 { try await Task.sleep(for: .milliseconds(1)) }
  await observer.stopAndJoin()
  #expect(optionalReads == 0)
  #expect(await fixture.calls == 1)
  #expect(await !fixture.cancelled)
}

@Test @MainActor func foregroundStopJoinsAlreadyDispatchedOptionalReadWithoutReplay() async throws {
  let route = try windRoute()
  let fixture = WindFixture(route: route)
  let observer = ExternalDeckTransportObserver()
  var optionalReads = 0
  var completed = false
  observer.start(route: route, interval: .milliseconds(1), sample: { try await fixture.sample() },
    update: { _, _ in }, idle: { _ in
      optionalReads += 1
      try? await Task.sleep(for: .milliseconds(40))
      completed = true
    }, failed: { _ in })
  while optionalReads == 0 { try await Task.sleep(for: .milliseconds(1)) }
  await observer.stopAndJoin()
  #expect(completed && optionalReads == 1)
  #expect(await fixture.calls == 1)
}
