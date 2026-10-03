import Foundation
import Testing
@testable import RewindDVArchiveCore

private let proofA = String(repeating: "a", count: 64)
private let proofB = String(repeating: "b", count: 64)
private func cancelledJournal(frames: UInt64 = 6) throws -> (WholeTapeJobJournal, WholeTapeJobEvidence.Capture) {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  let journal = try WholeTapeJobJournal(parentDirectory: parent, routeIdentity: "route/session/1")
  for event: WholeTapeJob.Event in [.preflightPassed, .rewindIntent, .windStopped, .inferredStart, .receiverReady, .playIntent] {
    try journal.record(.init(event: event, evidenceSHA256: proofA, routeIdentity: journal.job.routeIdentity))
  }
  let capture = WholeTapeJobEvidence.Capture(relativeDirectory: "Capture")
  var binding = update(journal); binding.bindCapture = capture; try journal.account(binding)
  if frames > 0 { try journal.record(.init(event: .receivedDV, evidenceSHA256: proofA, routeIdentity: journal.job.routeIdentity, completeFrames: frames)) }
  try journal.record(.init(event: .cancel, evidenceSHA256: proofA, routeIdentity: journal.job.routeIdentity))
  return (journal, capture)
}
private func update(_ journal: WholeTapeJobJournal) -> WholeTapeJobEvidence.Update {
  .init(jobID: journal.job.jobID, routeIdentity: journal.job.routeIdentity)
}
private func verified(_ journal: WholeTapeJobJournal, _ capture: WholeTapeJobEvidence.Capture,
                      frames: UInt64) -> WholeTapeJobEvidence.Update {
  var value = update(journal); value.captureID = capture.id; value.receiveClosed = true
  value.verification = .init(format: .dv, passed: true, reportSHA256: proofA,
    completeDVFrames: frames, needsLossReview: true)
  return value
}
private func stopped(_ journal: WholeTapeJobJournal) -> WholeTapeJobEvidence.Update {
  var value = update(journal); value.stop = .init(.deviceObserved, receipts: [proofA, proofB]); return value
}

@Test(arguments: [UInt64(1899), 17, 0]) func cancelledAccountingPreservesHistoryAndFinalCounts(_ frames: UInt64) throws {
  let (journal, capture) = try cancelledJournal(frames: frames == 0 ? 0 : 6)
  let snapshots = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
  let originals = try snapshots.map { ($0, try Data(contentsOf: $0)) }
  try journal.account(stopped(journal)); try journal.account(verified(journal, capture, frames: frames))
  let recovered = try WholeTapeJobJournal.recover(from: journal.directory)
  #expect(recovered.stage == .interrupted && recovered.manualStopRequired)
  #expect(recovered.receivedFrames == (frames == 0 ? 0 : 6))
  #expect(recovered.entries.last?.event == .cancel)
  #expect(recovered.currentSummary.evidence?.verification?.completeDVFrames == frames)
  #expect(recovered.currentSummary.evidence?.stopped == true)
  #expect(recovered.currentSummary.text.contains("warnings retained"))
  for (url, bytes) in originals { #expect(try Data(contentsOf: url) == bytes) }
  #expect(throws: (any Error).self) { try journal.record(.init(event: .playIntent, evidenceSHA256: proofA, routeIdentity: journal.job.routeIdentity)) }
  if frames == 0 { #expect(recovered.currentSummary.text.contains("does not establish a blank tape")) }
}

@Test func stopAcceptanceCannotResolveMotionEvenAfterSavedVerification() throws {
  let (journal, capture) = try cancelledJournal()
  var accepted = update(journal); accepted.stop = .init(.accepted, receipts: [proofA])
  try journal.account(accepted); try journal.account(verified(journal, capture, frames: 1899))
  #expect(journal.job.currentSummary.evidence?.stopped == false)
  #expect(journal.job.currentSummary.text.contains("stopped transport remains unconfirmed"))
  var insufficient = stopped(journal); insufficient.stop = .init(.deviceObserved, receipts: [proofA, proofA])
  #expect(throws: (any Error).self) { try journal.account(insufficient) }
}

@Test func physicalStopAndDeviceStopRetainDistinctProvenance() throws {
  let (journal, _) = try cancelledJournal()
  var physical = update(journal); physical.stop = .init(.operatorConfirmed, receipts: [proofA])
  try journal.account(physical)
  #expect(journal.job.currentSummary.text.contains("confirmed by operator"))
  #expect(!journal.job.currentSummary.text.contains("two device observations"))
  try journal.account(stopped(journal))
  #expect(journal.job.accounting?.stops.map(\.kind) == [.deviceObserved, .operatorConfirmed])
}

@Test func delayedOrFailedVerificationDoesNotInventCountsOrRegressSuccess() throws {
  let (journal, capture) = try cancelledJournal()
  try journal.account(stopped(journal))
  #expect(journal.job.currentSummary.evidence?.verification == nil)
  var failed = update(journal); failed.captureID = capture.id
  failed.verification = .init(format: .dv, passed: false, reportSHA256: proofB, needsLossReview: true)
  try journal.account(failed)
  #expect(journal.job.currentSummary.text.contains("final count unknown"))
  try journal.account(verified(journal, capture, frames: 77)); try journal.account(failed)
  #expect(journal.job.accounting?.verification?.completeDVFrames == 77)
  #expect(throws: (any Error).self) { try journal.account(verified(journal, capture, frames: 6)) }
}

@Test func duplicateAndReorderedAccountingAreBoundedAndReplayable() throws {
  let (journal, capture) = try cancelledJournal()
  let final = verified(journal, capture, frames: 1899), stop = stopped(journal)
  try journal.account(final); try journal.account(stop)
  let files = try FileManager.default.contentsOfDirectory(atPath: journal.directory.path)
  for _ in 0..<10 {
    try journal.account(stop); try journal.account(final)
    #expect(try WholeTapeJobJournal.recover(from: journal.directory) == journal.job)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: journal.directory.path) == files)
  #expect(journal.job.accounting?.stopped == true && journal.job.accounting?.verification?.completeDVFrames == 1899)
}

@Test func wrongJobRouteCaptureAndReplacementCannotReconcile() throws {
  let (journal, capture) = try cancelledJournal()
  var wrongJob = WholeTapeJobEvidence.Update(jobID: UUID(), routeIdentity: journal.job.routeIdentity)
  wrongJob.stop = stopped(journal).stop
  #expect(throws: (any Error).self) { try journal.account(wrongJob) }
  let wrongRoute = WholeTapeJobEvidence.Update(jobID: journal.job.jobID, routeIdentity: "replacement")
  #expect(throws: (any Error).self) { try journal.account(wrongRoute) }
  var wrongCapture = verified(journal, capture, frames: 1899); wrongCapture.captureID = UUID()
  #expect(throws: (any Error).self) { try journal.account(wrongCapture) }
  var replacement = update(journal); replacement.bindCapture = .init(relativeDirectory: "Capture")
  #expect(throws: (any Error).self) { try journal.account(replacement) }
  #expect(journal.job.accounting?.verification == nil)
}

@Test func preCaptureAndLegacyCancellationRemainExplicitlyIncomplete() throws {
  var legacy = try WholeTapeJob(routeIdentity: "route")
  try legacy.record(.init(event: .cancel, evidenceSHA256: proofA, routeIdentity: "route"))
  let decoded = try JSONDecoder().decode(WholeTapeJob.self, from: JSONEncoder().encode(legacy))
  #expect(decoded.currentSummary.evidence == nil)
  #expect(decoded.currentSummary.text.contains("verification not recorded"))
  var unbound = WholeTapeJobEvidence.Update(jobID: legacy.jobID, routeIdentity: "route")
  unbound.captureID = UUID(); unbound.receiveClosed = true
  #expect(throws: (any Error).self) { try legacy.account(unbound) }
}

@Test func failedAccountingWritePreservesPriorDurableStateAndPoisonsWriter() throws {
  let (journal, capture) = try cancelledJournal()
  let prior = journal.job
  let count = try FileManager.default.contentsOfDirectory(atPath: journal.directory.path).count
  let blocker = journal.directory.appendingPathComponent(String(format: "%08d.json", count))
  try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { try journal.account(verified(journal, capture, frames: 1899)) }
  #expect(journal.job == prior)
  try FileManager.default.removeItem(at: blocker) // Remove only the fixture's failed-create obstacle.
  #expect(try WholeTapeJobJournal.recover(from: journal.directory) == prior)
  #expect(throws: (any Error).self) { try journal.account(verified(journal, capture, frames: 1899)) }
  try Data("{partial".utf8).write(to: blocker)
  #expect(throws: (any Error).self) { try WholeTapeJobJournal.recover(from: journal.directory) }
  let incomplete = try WholeTapeJobJournal.readSummary(from: journal.directory)
  #expect(incomplete.journalWarning != nil && incomplete.evidence?.verification == nil)
  #expect(try Data(contentsOf: blocker) == Data("{partial".utf8))
  try Data("null".utf8).write(to: blocker)
  #expect(throws: (any Error).self) { try WholeTapeJobJournal.readSummary(from: journal.directory) }
}

@Test func hdvAccountingNeverClaimsDVFramesAndClosureIsIndependent() throws {
  let (journal, capture) = try cancelledJournal(frames: 0)
  var hdv = update(journal); hdv.captureID = capture.id
  hdv.verification = .init(format: .hdv, passed: true, reportSHA256: proofA,
    transportPackets: 100, transportBytes: 18800, needsLossReview: false)
  try journal.account(hdv)
  #expect(journal.job.currentSummary.evidence?.verification?.completeDVFrames == nil)
  #expect(journal.job.currentSummary.text.contains("100 HDV transport packets"))
  #expect(journal.job.accounting?.receiveClosed == false && journal.job.accounting?.stopped == false)
}
