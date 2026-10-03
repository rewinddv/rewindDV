import Testing
@testable import RewindDVArchiveCore

private let stopped: [UInt8] = [0x0c, 0x20, 0xc4, 0x60]
private let playing: [UInt8] = [0x0c, 0x20, 0xc3, 0x75]
private func observation(_ gate: inout TapeMotionEvidence, _ response: [UInt8]?, _ n: UInt64,
                         route: String = "route") -> TapeMotionEvidence.Decision {
  gate.observe(response: response, route: route, receipt: "receipt-\(n)", uptimeNanoseconds: n)
}

@Test func tapeCaptureHasNoContentOrDurationStopCondition() throws {
  var gate = TapeMotionEvidence(routeIdentity: "route", direction: .forwardPlayback)
  #expect(observation(&gate, playing, 1) == .keepReceiving)
  // Hours of missing timecode, ATN, frames and even complete DV signal silence
  // do not create a completion signal. STATUS can also be temporarily absent.
  for n in UInt64(2)...10_000 {
    #expect(gate.signalGap() == .keepReceiving)
    #expect(observation(&gate, n.isMultiple(of: 2) ? nil : playing, n) == .keepReceiving)
  }
  #expect(observation(&gate, stopped, 10_001) == .keepReceiving)
  #expect(observation(&gate, stopped, 10_002) == .naturalStop)
}

@Test func tapeStopEvidenceCannotUseCachedTransitioningOrWrongRouteReports() {
  var gate = TapeMotionEvidence(routeIdentity: "route", direction: .forwardPlayback)
  _ = observation(&gate, playing, 1)
  #expect(observation(&gate, stopped, 2) == .keepReceiving)
  #expect(observation(&gate, stopped, 2) == .keepReceiving)
  #expect(observation(&gate, stopped, 3, route: "other") == .keepReceiving)
  #expect(observation(&gate, stopped, 4) == .keepReceiving)
  #expect(observation(&gate, [0x0b, 0x20, 0xc4, 0x60], 5) == .keepReceiving)
  #expect(observation(&gate, stopped, 6) == .keepReceiving)
  #expect(observation(&gate, nil, 7) == .keepReceiving)
  #expect(observation(&gate, stopped, 8) == .keepReceiving)
  #expect(observation(&gate, stopped, 9) == .naturalStop)
}

@Test func tapeFaultOrStationaryStartIsNotNaturalBoundaryProof() {
  var gate = TapeMotionEvidence(routeIdentity: "route", direction: .rewind)
  _ = observation(&gate, playing, 1) // Wrong direction cannot establish rewind.
  _ = observation(&gate, stopped, 2)
  #expect(observation(&gate, stopped, 3) == .stoppedWithoutObservedMotion)
  #expect(observation(&gate, [0x0c, 0x20, 0xc4, 0x31], 4) == .transportFault)
  _ = observation(&gate, [0x0c, 0x20, 0xc4, 0x65], 5)
  _ = observation(&gate, stopped, 6)
  #expect(observation(&gate, stopped, 7) == .naturalStop)
}

@Test func automatedBlankTapeStaysArmedUntilMechanismStops() throws {
  var job = try WholeTapeJob(routeIdentity: "route")
  func entry(_ event: WholeTapeJob.Event) -> WholeTapeJob.Entry {
    .init(event: event, evidenceSHA256: String(repeating: "a", count: 64), routeIdentity: "route")
  }
  for event: WholeTapeJob.Event in [.preflightPassed, .rewindIntent, .windStopped, .inferredStart,
                                   .receiverReady, .playIntent] { try job.record(entry(event)) }
  for _ in 0..<100 { try job.record(entry(.signalGap)) }
  #expect(job.stage == .awaitingDV && job.manualStopRequired)
  #expect(throws: (any Error).self) { try job.record(entry(.inferredEnd)) }
  for event: WholeTapeJob.Event in [.transportStopped, .inferredEnd, .receiveDrained, .verificationPassed] {
    try job.record(entry(event))
  }
  #expect(job.stage == .transportBoundedVerified && job.receivedFrames == 0)
  #expect(throws: (any Error).self) { try job.record(entry(.playIntent)) }
}
