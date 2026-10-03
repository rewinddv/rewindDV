import Testing
@testable import RewindDVControlCore

@Test func tapeStatusIDsSurviveRepeatedClockTicksAndAppRestart() throws {
  var first = InspectorAttemptSequence()
  #expect(try first.next(uptimeNanoseconds: 100) == 100)
  #expect(try first.next(uptimeNanoseconds: 100) == 101)
  #expect(try first.next(uptimeNanoseconds: 99) == 102)
  var restarted = InspectorAttemptSequence()
  #expect(try restarted.next(uptimeNanoseconds: 200) > first.last)
  for now in UInt64(201)...20_000 { #expect(try restarted.next(uptimeNanoseconds: now) == now) }
  #expect(try restarted.next(uptimeNanoseconds: .max) == .max)
  #expect(throws: (any Error).self) { try restarted.next(uptimeNanoseconds: .max) }
}
