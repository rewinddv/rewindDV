import Foundation
import Testing
@testable import RewindDVArchiveCore

private func jobEntry(_ event: WholeTapeJob.Event, frames: UInt64 = 0, route: String = "full-route-test") -> WholeTapeJob.Entry {
  .init(event: event, evidenceSHA256: String(repeating: "a", count: 64), routeIdentity: route, completeFrames: frames)
}
private func capturingJob() throws -> WholeTapeJob {
  var job = try WholeTapeJob(routeIdentity: "full-route-test")
  for event: WholeTapeJob.Event in [.preflightPassed, .rewindIntent, .windStopped, .operatorConfirmedStart, .receiverReady, .playIntent] {
    try job.record(jobEntry(event))
  }
  try job.record(jobEntry(.receivedDV, frames: 1))
  return job
}

@Test func wholeTapeRequiresBoundariesDrainStopAndVerification() throws {
  var job = try capturingJob()
  try job.record(jobEntry(.signalGap))
  #expect(job.stage == .capturing)
  #expect(throws: (any Error).self) { try job.record(jobEntry(.verificationPassed, frames: 1)) }
  #expect(throws: (any Error).self) { try job.record(jobEntry(.playIntent)) }
  try job.record(jobEntry(.receivedDV, frames: 300))
  try job.record(jobEntry(.transportStopped))
  try job.record(jobEntry(.operatorConfirmedEnd))
  try job.record(jobEntry(.receiveDrained, frames: 302))
  #expect(throws: (any Error).self) { try job.record(jobEntry(.verificationPassed, frames: 300)) }
  try job.record(jobEntry(.verificationPassed, frames: 302))
  #expect(job.stage == .operatorBoundedVerified && !job.manualStopRequired)
  #expect(throws: (any Error).self) { try job.record(jobEntry(.rewindIntent)) }
}

@Test func wholeTapeNeverTreatsStoppedOrWatchdogAsBOTOrEOT() throws {
  var job = try WholeTapeJob(routeIdentity: "full-route-test")
  try job.record(jobEntry(.preflightPassed)); try job.record(jobEntry(.rewindIntent))
  try job.record(jobEntry(.windStopped))
  #expect(job.stage == .awaitingStart)
  #expect(throws: (any Error).self) { try job.record(jobEntry(.receiverReady)) }
  try job.record(jobEntry(.watchdogExpired))
  #expect(job.stage == .interrupted)
  var moving = try capturingJob()
  #expect(throws: (any Error).self) { try moving.record(jobEntry(.receivedDV, frames: 4, route: "stale")) }
  try moving.record(jobEntry(.routeChanged, route: "new"))
  #expect(moving.stage == .interrupted && moving.manualStopRequired)
}

@Test func wholeTapeMissingStopDoesNotFinishAndCancellationNeverReplays() throws {
  var job = try capturingJob()
  try job.record(jobEntry(.operatorConfirmedEnd)); try job.record(jobEntry(.receiveDrained, frames: 1))
  #expect(throws: (any Error).self) { try job.record(jobEntry(.verificationPassed, frames: 1)) }
  try job.record(jobEntry(.cancel))
  #expect(job.manualStopRequired && job.stage == .interrupted)
  #expect(throws: (any Error).self) { try job.record(jobEntry(.playIntent)) }
}

@Test func wholeTapeDurableRecoveryInterruptsInsteadOfReplaying() throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  let journal = try WholeTapeJobJournal(parentDirectory: parent, routeIdentity: "full-route-test")
  try journal.record(jobEntry(.preflightPassed)); try journal.record(jobEntry(.rewindIntent))
  let recovered = try WholeTapeJobJournal.recover(from: journal.directory)
  #expect(recovered.stage == .interrupted && recovered.manualStopRequired)
  #expect(journal.job.stage == .rewinding) // Recovery never rewrites source evidence.
  let checkpoint = journal.directory.appendingPathComponent("00000001.json")
  var tampered = try Data(contentsOf: checkpoint); tampered.append(32)
  try tampered.write(to: checkpoint)
  #expect(throws: (any Error).self) { try WholeTapeJobJournal.recover(from: journal.directory) }
}
