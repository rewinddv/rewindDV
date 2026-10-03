import Foundation
import Testing
@testable import RewindDVControlCore

@Test func deckTimecodeIsExactStatusNotSearch() throws {
  #expect(InspectorQuery.tapeTimecode.kind == 7)
  #expect(InspectorQuery.tapeTimecode.frame == [1,0x20,0x51,0x71,255,255,255,255])
  #expect(InspectorQuery.tapeTimecode.isTapeState)
  let valid: [UInt8] = [12,0x20,0x51,0x71,0x29,0x59,0x59,0x23]
  #expect(AVCTapeStatusDecoder.timecode(valid)?.text == "23:59:59:29")
  var noFrames = valid; noFrames[4] = 0x7f
  #expect(AVCTapeStatusDecoder.timecode(noFrames)?.text == "23:59:59:--")
  for index in 0..<8 {
    var bad = valid; bad[index] = 0xff
    #expect(AVCTapeStatusDecoder.timecode(bad) == nil)
  }
  for prefix: UInt8 in [0,1,8,9,10,11,13,15] {
    var bad = valid; bad[0] = prefix
    #expect(AVCTapeStatusDecoder.timecode(bad) == nil)
  }
  for (offset, value): (Int, UInt8) in [(4,0x30),(4,0x1a),(5,0x60),(6,0x60),(7,0x24)] {
    var bad = valid; bad[offset] = value
    #expect(AVCTapeStatusDecoder.timecode(bad) == nil)
  }
  #expect(AVCTapeStatusDecoder.timecode(Array(valid.dropLast())) == nil)
  #expect(AVCTapeStatusDecoder.timecode(valid + [0]) == nil)
  #expect(try InspectorInterpretation.decode(valid, query: .tapeTimecode).facts[0].value == "23:59:59:29")
  var rejected = valid; rejected[0] = 0x0a
  #expect(try InspectorInterpretation.decode(rejected, query: .tapeTimecode).facts.isEmpty)
  var unsupported = valid; unsupported[0] = 0x08
  #expect(try InspectorInterpretation.decode(unsupported, query: .tapeTimecode).disposition == "Not implemented")
}

@Test func deckTimecodePreservesHistoricalValueButLabelsItStale() {
  var state = DeckTimecodeDisplayState()
  #expect(state.text == nil)
  #expect(state.label(at: 100).hasPrefix("Unavailable"))
  state.observe([12,32,0x51,0x71,0x12,0x34,0x05,0x01], at: 100)
  #expect(state.text == "01:05:34:12")
  #expect(state.label(at: 100) == "Deck-reported · sampled")
  #expect(state.label(at: 2_000_000_101).hasPrefix("Stale"))
  #expect(state.label(at: 99).hasPrefix("Stale"))
  state.unavailable("Not implemented")
  #expect(state.text == "01:05:34:12")
  #expect(state.label(at: 101) == "Stale: Not implemented")
  state.observe([255], at: 102)
  #expect(state.text == "01:05:34:12")
  #expect(state.label(at: 102).hasPrefix("Stale"))
  state = DeckTimecodeDisplayState() // connection identity invalidation
  #expect(state.text == nil)
}

@Test func optionalTimecodeNeverAdmittedDuringReceiveStopOrUnprovedMotion() {
  for operand: UInt8 in [0x60,0x45,0x65,0x75] {
    let reply: [UInt8] = [12,32,0xc4,operand]
    #expect(DeckTimecodeDisplayState.maySample(transport: reply, receiving: false, stopping: false))
    #expect(!DeckTimecodeDisplayState.maySample(transport: reply, receiving: true, stopping: false))
    #expect(!DeckTimecodeDisplayState.maySample(transport: reply, receiving: false, stopping: true))
  }
  for reply: [UInt8]? in [nil, [], [11,32,0xc4,0x75], [12,32,0xc3,0x75], [12,32,0xc4,0x30]] {
    #expect(!DeckTimecodeDisplayState.maySample(transport: reply, receiving: false, stopping: false))
  }
}

@Test func coastDownTimecodeRequiresExactTransitionAndIdleControlOwner() throws {
  let transition: [UInt8] = [11,32,196,96]
  #expect(try InspectorInterpretation.decode(transition, query: .tapeTransportState)
    .disposition == "In transition — not stable state proof")
  #expect(DeckTimecodeDisplayState.maySample(transport: transition, receiving: false, stopping: false))
  for (receiving, stopping) in [(true, false), (false, true), (true, true)] {
    #expect(!DeckTimecodeDisplayState.maySample(transport: transition, receiving: receiving, stopping: stopping))
  }
  // Every byte must match; broad acceptance of IN TRANSITION is not intended.
  for index in transition.indices {
    var other = transition; other[index] ^= 1
    #expect(!DeckTimecodeDisplayState.maySample(transport: other, receiving: false, stopping: false))
  }
  for other in [Array(transition.dropLast()), transition + [0]] {
    #expect(!DeckTimecodeDisplayState.maySample(transport: other, receiving: false, stopping: false))
  }
  #expect(DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(transport: transition) == 150_000_000)
}

@Test func windingTimecodeCadenceIsFasterThanIdleAndNeverInterpolated() {
  #expect(DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(transport: [12,32,0xc4,0x60]) == 500_000_000)
  for mode: UInt8 in [0x45,0x65,0x75] {
    #expect(DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(transport: [12,32,0xc4,mode]) == 150_000_000)
  }
  var value = DeckTimecodeDisplayState()
  value.observe([12,32,0x51,0x71,0x12,0x34,0x05,0x01], at: 100)
  _ = value.label(at: 1_000_000_100)
  #expect(value.text == "01:05:34:12")
}

@Test func stopConfirmationBurstIsFasterButBounded() {
  for count in 1..<20 { #expect(TapeStopPollingPolicy.interval(afterObservation: count) == .milliseconds(250)) }
  for count in [20,21,100,Int.max] { #expect(TapeStopPollingPolicy.interval(afterObservation: count) == .seconds(1)) }
}

@Test func rapidWindingBurstIsBoundedByCountAndElapsedTime() {
  var countBounded = WindRefreshBurst(startedAt: 100)
  for _ in 0..<64 { #expect(countBounded.nextInterval(at: 100) == .milliseconds(1)) }
  for _ in 0..<100 { #expect(countBounded.nextInterval(at: 100) == .milliseconds(50)) }
  #expect(countBounded.cycles == 64)
  var timeBounded = WindRefreshBurst(startedAt: 100)
  #expect(timeBounded.nextInterval(at: 5_000_000_099) == .milliseconds(1))
  #expect(timeBounded.nextInterval(at: 5_000_000_100) == .milliseconds(50))
  #expect(timeBounded.nextInterval(at: UInt64.max) == .milliseconds(50))
  var reversedClock = WindRefreshBurst(startedAt: 100)
  #expect(reversedClock.nextInterval(at: 99) == .milliseconds(50))
}

@Test func rapidCompletionPollingBacksOffWithoutAffectingDefault() {
  for count in 0..<100 {
    #expect(InspectorCompletionPolling.interval(rapidIdle: false, notReadyCount: count) == .milliseconds(50))
    let expected: Duration = count < 10 ? .milliseconds(1) : count < 50 ? .milliseconds(5) : .milliseconds(50)
    #expect(InspectorCompletionPolling.interval(rapidIdle: true, notReadyCount: count) == expected)
  }
  #expect(DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(transport: [12,32,196,96], rapidWinding: true) == 500_000_000)
  for mode: UInt8 in [0x45,0x65,0x75] {
    #expect(DeckTimecodeDisplayState.minimumSampleIntervalNanoseconds(transport: [12,32,196,mode], rapidWinding: true) == 1_000_000)
  }
}
