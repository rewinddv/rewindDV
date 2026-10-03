import Foundation
import Testing
@testable import RewindDVArchiveCore

private let recoveryMapHash = String(repeating: "b", count: 64)
private let recoverySource = DVReviewedRangeExporter.Snapshot(schemaVersion: 1,
  sourceSHA256: String(repeating: "a", count: 64), frameCount: 1000,
  frameByteCount: 120000, sourceByteCount: 120000000, videoSystem: .ntsc525_60)
private let recoveryTarget = DVGentleRecovery.Target(first: 0, endExclusive: 10, reason: "Original-byte defect")
private func recoveryPlan(_ budget: DVGentleRecovery.Budget = .init()) throws -> DVGentleRecovery.Plan {
  try .init(source: recoverySource, mapSHA256: recoveryMapHash, tapeLabel: "TEST TAPE", budget: budget, targets: [recoveryTarget])
}
private func recoveryFolder(_ body: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory.appendingPathComponent("plan"))
}
private func makeRecovery(_ directory: URL, _ budget: DVGentleRecovery.Budget = .init()) throws -> DVGentleRecoveryJournal {
  try .init(directory: directory, creating: recoveryPlan(budget), expectedSource: recoverySource, expectedMapSHA256: recoveryMapHash)
}
private func reserveRecovery(_ journal: DVGentleRecoveryJournal, now: Date = Date(), positioning: Int = 0) async throws -> DVGentleRecovery.Attempt {
  try await journal.reserve(target: recoveryTarget.id, route: "full-route-generation-1", positioningSeconds: positioning, confirmedTapeAndPosition: true, now: now)
}
private func finishRecovery(_ journal: DVGentleRecoveryJournal, _ id: UUID, seconds: Int = 2, now: Date = Date()) async throws {
  try await journal.finish(id, result: .init(outcome: "test_no_repair_claim", observedSeconds: seconds, note: "Synthetic"), physicalStopConfirmed: true, now: now)
}

@Test func containmentResolvesExistingAncestorsBeforeAppendingNewOutputPaths() throws {
  // Exercise the /private/tmp spelling returned by directory pickers, including
  // a child that does not exist yet. Foundation may canonicalize only the parent.
  let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("rewindDV-containment-\(UUID())", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let map = root.appendingPathComponent("map", isDirectory: true)
  try FileManager.default.createDirectory(at: map, withIntermediateDirectories: false)
  let alias = root.appendingPathComponent("alias", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: map)
  for parent in [map, alias, map.resolvingSymlinksInPath()] {
    #expect(DVGentleRecovery.isWithin(parent, directory: map))
    #expect(DVGentleRecovery.isWithin(parent.appendingPathComponent("new/nested"), directory: map))
  }
  #expect(!DVGentleRecovery.isWithin(root.appendingPathComponent("map-sibling/new"), directory: map))
  #expect(!DVGentleRecovery.isWithin(root, directory: map))
  #expect(DVGentleRecovery.isWithin(map, directory: URL(fileURLWithPath: "/")))
}

@Test func recoveryInvalidBudgetsAndOverlappingTargetsFailClosed() throws {
  for budget in [DVGentleRecovery.Budget(maximumAttempts: 0), .init(attemptsPerTarget: 4),
                 .init(passSeconds: 301), .init(stopAllowanceSeconds: 0), .init(totalReservedSeconds: 1), .init(cooldownSeconds: 0)] {
    #expect(throws: Error.self) { try recoveryPlan(budget) }
  }
  #expect(throws: Error.self) {
    try DVGentleRecovery.Plan(source: recoverySource, mapSHA256: recoveryMapHash, tapeLabel: "", budget: .init(), targets: [recoveryTarget])
  }
  #expect(throws: Error.self) {
    try DVGentleRecovery.Plan(source: recoverySource, mapSHA256: recoveryMapHash, tapeLabel: "T", budget: .init(),
      targets: [recoveryTarget, .init(first: 5, endExclusive: 20, reason: "overlap")])
  }
}

@Test func recoveryReservationDurableBeforeSingleRouteBoundPlay() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    await #expect(throws: Error.self) {
      try await journal.reserve(target: recoveryTarget.id, route: "R", positioningSeconds: 0, confirmedTapeAndPosition: false)
    }
    let attempt = try await reserveRecovery(journal, positioning: 15)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0000.json").path))
    #expect(try await journal.snapshot().chargedSeconds == 45)
    await #expect(throws: Error.self) { try await reserveRecovery(journal) }
    await #expect(throws: Error.self) { try await journal.recordPlayIntent(attempt.id, route: "stale-route") }
    try await journal.recordPlayIntent(attempt.id, route: attempt.route)
    await #expect(throws: Error.self) { try await journal.recordPlayIntent(attempt.id, route: attempt.route) }
    await #expect(throws: Error.self) {
      try await journal.finish(attempt.id, result: .init(outcome: "x", observedSeconds: 1, note: ""), physicalStopConfirmed: false)
    }
    try await finishRecovery(journal, attempt.id)
    #expect(try await journal.snapshot().chargedSeconds == 45, "No refund after early stop")
    await #expect(throws: Error.self) { try await finishRecovery(journal, attempt.id) }
  }
}

@Test func recoveryExclusiveWriterAndSourceBinding() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    #expect(throws: Error.self) { try DVGentleRecoveryJournal(directory: folder, expectedSource: recoverySource, expectedMapSHA256: recoveryMapHash) }
    #expect(try await journal.snapshot().attempts.isEmpty)
    let wrong = folder.deletingLastPathComponent().appendingPathComponent("wrong")
    #expect(throws: Error.self) {
      try DVGentleRecoveryJournal(directory: wrong, creating: recoveryPlan(), expectedSource: recoverySource, expectedMapSHA256: String(repeating: "c", count: 64))
    }
    #expect(!FileManager.default.fileExists(atPath: wrong.path))
  }
}

@Test func recoveryReopenCannotReplayOrFinishInterruptedIntent() async throws {
  try await recoveryFolder { folder in
    func prepare() async throws -> UUID {
      let journal = try makeRecovery(folder)
      let attempt = try await reserveRecovery(journal)
      try await journal.recordPlayIntent(attempt.id, route: attempt.route)
      return attempt.id
    }
    let id = try await prepare()
    let restored = try DVGentleRecoveryJournal(directory: folder, expectedSource: recoverySource, expectedMapSHA256: recoveryMapHash)
    #expect(try await restored.snapshot().chargedSeconds == 30)
    await #expect(throws: Error.self) { try await restored.recordPlayIntent(id, route: "full-route-generation-1") }
    await #expect(throws: Error.self) { try await finishRecovery(restored, id) }
    await #expect(throws: Error.self) { try await restored.reconcileInterrupted(operatorConfirmedStopped: false, note: "") }
    try await restored.reconcileInterrupted(operatorConfirmedStopped: true, note: "Physically stopped")
    #expect(try await restored.snapshot().attempts.last?.phase == .reconciledInterrupted)
    await #expect(throws: Error.self) { try await reserveRecovery(restored, now: Date().addingTimeInterval(10000)) }
  }
}

@Test func recoveryCooldownClockRollbackAndPerTargetBudget() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder, .init(maximumAttempts: 3, attemptsPerTarget: 2, cooldownSeconds: 10))
    let time = Date()
    let one = try await reserveRecovery(journal, now: time)
    try await finishRecovery(journal, one.id, now: time.addingTimeInterval(1))
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: time.addingTimeInterval(-10)) }
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: time.addingTimeInterval(5)) }
    let two = try await reserveRecovery(journal, now: time.addingTimeInterval(11))
    try await finishRecovery(journal, two.id, now: time.addingTimeInterval(12))
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: time.addingTimeInterval(100)) }
    #expect(try await journal.snapshot().chargedSeconds == 60)
  }
}

@Test func recoveryTotalSecondsAndPositioningAreCharged() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder, .init(totalReservedSeconds: 60))
    let now = Date()
    let one = try await reserveRecovery(journal, now: now, positioning: 1)
    try await finishRecovery(journal, one.id, now: now.addingTimeInterval(1))
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: now.addingTimeInterval(100)) }
    #expect(try await journal.snapshot().chargedSeconds == 31)
  }
}

@Test func recoveryAttemptCapAndOverrunHold() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder, .init(maximumAttempts: 1, attemptsPerTarget: 1))
    let one = try await reserveRecovery(journal)
    try await finishRecovery(journal, one.id)
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: Date().addingTimeInterval(1000)) }
  }
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    let one = try await reserveRecovery(journal, positioning: 5)
    try await finishRecovery(journal, one.id, seconds: 45)
    #expect(try await journal.snapshot().hasOverrun)
    #expect(try await journal.snapshot().chargedSeconds == 50)
    await #expect(throws: Error.self) { try await reserveRecovery(journal, now: Date().addingTimeInterval(1000)) }
  }
}

@Test func recoveryUnknownOrInvalidCompletionCannotUndercharge() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    let one = try await reserveRecovery(journal)
    for seconds in [nil, -1, Int.max] as [Int?] {
      await #expect(throws: Error.self) {
        try await journal.finish(one.id, result: .init(outcome: "invalid", observedSeconds: seconds, note: ""), physicalStopConfirmed: true)
      }
    }
    #expect(try await journal.snapshot().unresolved?.id == one.id)
  }
}

@Test func recoveryMutatedCheckpointPreventsMotion() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    let one = try await reserveRecovery(journal)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("0000.json"))
    await #expect(throws: Error.self) { try await journal.recordPlayIntent(one.id, route: one.route) }
  }
}

@Test func recoveryMissingAndUnexpectedCheckpointFailClosed() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    let one = try await reserveRecovery(journal)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("0000.json"))
    await #expect(throws: Error.self) { try await journal.recordPlayIntent(one.id, route: one.route) }
  }
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    try Data("unexpected".utf8).write(to: folder.appendingPathComponent("extra"))
    await #expect(throws: Error.self) { try await reserveRecovery(journal) }
  }
}

@Test func recoverySymlinkAndRenamedDirectoryAreRejected() async throws {
  try await recoveryFolder { folder in
    let journal = try makeRecovery(folder)
    let moved = folder.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: folder, to: moved)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
    await #expect(throws: Error.self) { try await reserveRecovery(journal) }
    #expect(throws: Error.self) { try DVGentleRecoveryJournal(directory: folder, expectedSource: recoverySource, expectedMapSHA256: recoveryMapHash) }
  }
}

@Test func recoveryCompletedHistorySurvivesReopen() async throws {
  try await recoveryFolder { folder in
    func prepare() async throws {
      let journal = try makeRecovery(folder)
      let one = try await reserveRecovery(journal, positioning: 25)
      try await finishRecovery(journal, one.id)
    }
    try await prepare()
    let journal = try DVGentleRecoveryJournal(directory: folder, expectedSource: recoverySource, expectedMapSHA256: recoveryMapHash)
    let restored = try await journal.snapshot()
    #expect(restored.chargedSeconds == 55 && restored.attempts.count == 1)
    #expect(restored.attempts[0].phase == .completed)
  }
}

@Test func recoveryPathContainmentUsesComponentBoundaries() {
  let root = URL(fileURLWithPath: "/tmp/recovery-test")
  #expect(DVGentleRecovery.isWithin(root, directory: root))
  #expect(DVGentleRecovery.isWithin(root.appendingPathComponent("nested"), directory: root))
  #expect(!DVGentleRecovery.isWithin(URL(fileURLWithPath: "/tmp/recovery-test-other"), directory: root))
}

@Test func recoveryStageNeverInfersTapeBoundaries() throws {
  var job = try WholeTapeJob(routeIdentity: "R")
  func entry(_ event: WholeTapeJob.Event) -> WholeTapeJob.Entry { .init(event: event, evidenceSHA256: recoveryMapHash, routeIdentity: "R") }
  for event: WholeTapeJob.Event in [.preflightPassed, .operatorPositionedRecoveryStart, .receiverReady, .playIntent] { try job.record(entry(event)) }
  #expect(throws: Error.self) { try job.record(entry(.supervisedRecoveryEnd)) }
  for event: WholeTapeJob.Event in [.transportStopped, .supervisedRecoveryEnd, .receiveDrained, .verificationPassed] { try job.record(entry(event)) }
  #expect(job.stage == .recoveryBoundedVerified && job.isTerminal && !job.manualStopRequired)
  #expect(!job.entries.contains { [.rewindIntent, .inferredStart, .inferredEnd].contains($0.event) })
  #expect(throws: Error.self) { try job.record(entry(.playIntent)) }
}
