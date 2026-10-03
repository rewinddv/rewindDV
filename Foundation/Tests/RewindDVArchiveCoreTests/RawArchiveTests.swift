import Foundation
import Testing

@testable import RewindDVArchiveCore

private func temporaryArchiveURL(_ label: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "RewindDVFoundation-\(label)-\(UUID().uuidString)", isDirectory: true)
}

private func archiveIdentity(
  maximumExtentBytes: Int = 2_048
) -> ArchiveSessionIdentity {
  ArchiveSessionIdentity(
    sessionID: "test-session",
    createdUTC: "2026-09-12T12:00:00Z",
    softwareVersion: "test",
    admissionLimits: ArchiveAdmissionLimits(
      maximumExtentBytes: maximumExtentBytes,
      maximumOutstandingExtents: 2,
      maximumOutstandingBytes: maximumExtentBytes * 2))
}

private func extent(
  ordinal: UInt64,
  monotonicNanoseconds: UInt64,
  bytes: [UInt8] = [
    0x21, 0x43, 0x00, 0x00, 0x3f, 0x06, 0x80, 0xfa,
    0x00, 0x00, 0x12, 0x34, 0xde, 0xad, 0xbe, 0xef,
  ]
) -> RawTransportExtent {
  RawTransportExtent(
    bytes: Data(bytes),
    observation: RawTransportObservation(
      captureOrdinal: ordinal,
      kind: .ohciIsochronousReceive,
      hostMonotonicNanoseconds: monotonicNanoseconds,
      busGeneration: 7,
      ohciDMASequence: ordinal + 40,
      cycleTimestamp: 0x4321,
      cipDBC: 0xfa,
      cipSYT: 0x1234,
      rawReceiveHeader: Array(bytes.prefix(4)),
      rawCIPHeader: Array(bytes.dropFirst(4).prefix(8)),
      identifiableDVPayloadRange: TransportByteRange(offset: 12, length: 4)))
}

private let validFinalization = ArchiveFinalizationEvidence(
  producerEndedAndQuiesced: true,
  producerEndReason: "operator_stop_then_producer_quiesced",
  lossAccounting: .completeNoHostLossObserved,
  recordedHostLossExtentCount: 0)

@Test func verificationStreamsAcrossJournalChunkBoundaries() throws {
  let url = temporaryArchiveURL("streaming-verification")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  for ordinal in UInt64(0)..<400 {
    try writer.append(extent(ordinal: ordinal, monotonicNanoseconds: ordinal + 1))
  }
  let journalSize =
    try url.appendingPathComponent(RawArchiveWriter.observationsFilename)
    .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  #expect(journalSize > 64 * 1_024)
  try writer.finalize(with: validFinalization)
  let result = try RawArchiveWriter.verify(at: url)
  #expect(result.acknowledgedExtentCount == 400)
  #expect(result.incompleteObservationTailBytes == 0)
  #expect(result.byteIntegrity == .finalizedArchiveVerified)
}

@Test func oversizedJournalAndMetadataFailClosed() throws {
  let url = temporaryArchiveURL("oversized-verification")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))
  let journalURL = url.appendingPathComponent(RawArchiveWriter.observationsFilename)
  let retainedJournal = try Data(contentsOf: journalURL)
  try Data(repeating: 0x61, count: 65 * 1_024).write(to: journalURL)
  #expect(throws: RawArchiveError.self) { try RawArchiveWriter.verify(at: url) }
  try retainedJournal.write(to: journalURL)
  try Data(repeating: 0x61, count: 1_024 * 1_024 + 1)
    .write(to: url.appendingPathComponent(RawArchiveWriter.identityFilename))
  #expect(throws: RawArchiveError.self) { try RawArchiveWriter.verify(at: url) }
}

@Test func declaredHugeLimitsDoNotChooseVerifierAllocationSize() throws {
  let url = temporaryArchiveURL("untrusted-large-limits")
  defer { try? FileManager.default.removeItem(at: url) }
  let identity = ArchiveSessionIdentity(
    sessionID: "large-limit", createdUTC: "test", softwareVersion: "test",
    admissionLimits: ArchiveAdmissionLimits(
      maximumExtentBytes: Int.max / 2,
      maximumOutstandingExtents: 1, maximumOutstandingBytes: Int.max))
  let writer = try RawArchiveWriter(createAt: url, identity: identity)
  let bytes = Data(repeating: 0xab, count: 1_024 * 1_024 + 17)
  try writer.append(
    RawTransportExtent(
      bytes: bytes,
      observation: RawTransportObservation(
        captureOrdinal: 0, kind: .unclassifiedReceive,
        hostMonotonicNanoseconds: 1)))
  try writer.finalize(with: validFinalization)
  let result = try RawArchiveWriter.verify(at: url)
  #expect(result.acknowledgedByteCount == UInt64(bytes.count))
  #expect(result.byteIntegrity == .finalizedArchiveVerified)
}

@Test func operatorControlledCaptureHasNoFourSecondOrOtherTimerCeiling() throws {
  let url = temporaryArchiveURL("continuous")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())

  #expect(writer.identity.capturePolicy == .operatorControlledContinuous)
  #expect(writer.identity.capturePolicy.automaticStopAfterNanoseconds == nil)
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))
  try writer.append(extent(ordinal: 1, monotonicNanoseconds: 10_000_000_001))
  #expect(writer.status.archive == .incomplete)
  #expect(writer.status.intake == .accepting)

  try writer.finalize(with: validFinalization)
  let verified = try RawArchiveWriter.verify(at: url)
  #expect(writer.status.archive == .finalized)
  #expect(verified.lifecycle == .finalized)
  #expect(verified.byteIntegrity == .finalizedArchiveVerified)
  #expect(verified.acquisitionOutcome == .noHostLossObserved)
  #expect(verified.acknowledgedExtentCount == 2)
}

@Test func duplicateAndOutOfOrderOrdinalsAreRejectedBeforeMutation() throws {
  let url = temporaryArchiveURL("ordering")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))
  let rawURL = url.appendingPathComponent(RawArchiveWriter.transportFilename)
  let before = try Data(contentsOf: rawURL)

  #expect(throws: RawArchiveError.sequenceMismatch(expected: 1, actual: 0)) {
    try writer.append(extent(ordinal: 0, monotonicNanoseconds: 2))
  }
  #expect(throws: RawArchiveError.sequenceMismatch(expected: 1, actual: 2)) {
    try writer.append(extent(ordinal: 2, monotonicNanoseconds: 3))
  }
  #expect(try Data(contentsOf: rawURL) == before)
  try writer.append(extent(ordinal: 1, monotonicNanoseconds: 4))
}

@Test func boundedAdmissionRejectsExplicitlyAtEachCapacityBoundary() {
  let limits = ArchiveAdmissionLimits(
    maximumExtentBytes: 100,
    maximumOutstandingExtents: 2,
    maximumOutstandingBytes: 150)

  #expect(
    ArchiveAdmissionDecision.evaluate(
      extentByteCount: 0, outstandingExtentCount: 0,
      outstandingByteCount: 0, limits: limits) == .rejected(.emptyExtent))
  #expect(
    ArchiveAdmissionDecision.evaluate(
      extentByteCount: 101, outstandingExtentCount: 0,
      outstandingByteCount: 0, limits: limits) == .rejected(.extentTooLarge))
  #expect(
    ArchiveAdmissionDecision.evaluate(
      extentByteCount: 1, outstandingExtentCount: 2,
      outstandingByteCount: 0, limits: limits) == .rejected(.extentCountCapacityExceeded))
  #expect(
    ArchiveAdmissionDecision.evaluate(
      extentByteCount: 51, outstandingExtentCount: 1,
      outstandingByteCount: 100, limits: limits) == .rejected(.byteCapacityExceeded))
  #expect(
    ArchiveAdmissionDecision.evaluate(
      extentByteCount: 50, outstandingExtentCount: 1,
      outstandingByteCount: 100, limits: limits) == .admitted)
}

@Test func destinationIsExclusiveAndExistingEvidenceIsNeverOverwritten() throws {
  let url = temporaryArchiveURL("exclusive")
  defer { try? FileManager.default.removeItem(at: url) }
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  let sentinelURL = url.appendingPathComponent("sentinel")
  try Data("evidence".utf8).write(to: sentinelURL)

  #expect(throws: RawArchiveError.destinationExists(url.path)) {
    _ = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  }
  #expect(try Data(contentsOf: sentinelURL) == Data("evidence".utf8))
}

@Test func writeFailureKeepsFirstErrorAndArchiveFailed() throws {
  let url = temporaryArchiveURL("write-failure")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(
    createAt: url,
    identity: archiveIdentity(),
    faultInjection: RawArchiveFaultInjection(failRawWriteAtOrdinal: 0))

  #expect(throws: RawArchiveError.injectedWriteFailure) {
    try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))
  }
  #expect(writer.status.archive == .failed)
  #expect(writer.status.firstError?.phase == "archive_write")
  writer.recordCleanupFailure(phase: "close_after_failure", message: "secondary")
  #expect(writer.status.firstError?.phase == "archive_write")
  #expect(
    writer.status.cleanupErrors == [
      CaptureFailure(phase: "close_after_failure", message: "secondary")
    ])
}

@Test func incompleteArchiveReportsVerifiedAcknowledgedBytesAndOrphanTail() throws {
  let url = temporaryArchiveURL("incomplete")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  let first = extent(ordinal: 0, monotonicNanoseconds: 1)
  try writer.append(first)

  let rawURL = url.appendingPathComponent(RawArchiveWriter.transportFilename)
  let external = try FileHandle(forWritingTo: rawURL)
  try external.seekToEnd()
  try external.write(contentsOf: Data([0xaa, 0xbb, 0xcc]))
  try external.synchronize()
  try external.close()

  let observationsURL = url.appendingPathComponent(
    RawArchiveWriter.observationsFilename)
  let partialJournal = try FileHandle(forWritingTo: observationsURL)
  try partialJournal.seekToEnd()
  let incompleteTail = Data("{\"captureOrdinal\":".utf8)
  try partialJournal.write(contentsOf: incompleteTail)
  try partialJournal.synchronize()
  try partialJournal.close()

  let verified = try RawArchiveWriter.verify(at: url)
  #expect(verified.lifecycle == .incomplete)
  #expect(verified.byteIntegrity == .acknowledgedExtentsVerified)
  #expect(verified.acquisitionOutcome == .unknown)
  #expect(verified.acknowledgedByteCount == UInt64(first.bytes.count))
  #expect(verified.orphanByteCount == 3)
  #expect(verified.incompleteObservationTailBytes == incompleteTail.count)
}

@Test func persistedRereadMismatchPreventsFinalization() throws {
  let url = temporaryArchiveURL("reread-mismatch")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))

  let rawURL = url.appendingPathComponent(RawArchiveWriter.transportFilename)
  let corruptor = try FileHandle(forWritingTo: rawURL)
  try corruptor.seek(toOffset: 0)
  try corruptor.write(contentsOf: Data([0xff]))
  try corruptor.synchronize()
  try corruptor.close()

  do {
    try writer.finalize(with: validFinalization)
    Issue.record("expected persisted reread mismatch")
  } catch let error as RawArchiveError {
    guard case .hashMismatch = error else {
      Issue.record("unexpected error: \(error)")
      return
    }
  }
  #expect(writer.status.archive == .failed)
  #expect(
    !FileManager.default.fileExists(
      atPath:
        url.appendingPathComponent(RawArchiveWriter.manifestFilename).path))
}

@Test func finalizationRequiresProducerQuiescenceAndKnownLossAccounting() throws {
  let url = temporaryArchiveURL("finalization-gates")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))

  #expect(throws: (any Error).self) {
    try writer.finalize(
      with: ArchiveFinalizationEvidence(
        producerEndedAndQuiesced: false,
        producerEndReason: "operator_requested_stop",
        lossAccounting: .completeNoHostLossObserved,
        recordedHostLossExtentCount: 0))
  }
  #expect(throws: (any Error).self) {
    try writer.finalize(
      with: ArchiveFinalizationEvidence(
        producerEndedAndQuiesced: true,
        producerEndReason: "producer_quiesced",
        lossAccounting: .unknown,
        recordedHostLossExtentCount: 0))
  }
  #expect(writer.status.archive == .incomplete)
  try writer.finalize(
    with: ArchiveFinalizationEvidence(
      producerEndedAndQuiesced: true,
      producerEndReason: "producer_quiesced",
      lossAccounting: .completeWithRecordedHostLoss,
      recordedHostLossExtentCount: 3))
  let verified = try RawArchiveWriter.verify(at: url)
  #expect(verified.byteIntegrity == .finalizedArchiveVerified)
  #expect(verified.acquisitionOutcome == .completedWithRecordedHostLoss)
}

@Test func finalizedArchiveFailsClosedAfterTransportTampering() throws {
  let url = temporaryArchiveURL("post-finalize-tamper")
  defer { try? FileManager.default.removeItem(at: url) }
  let writer = try RawArchiveWriter(createAt: url, identity: archiveIdentity())
  try writer.append(extent(ordinal: 0, monotonicNanoseconds: 1))
  try writer.finalize(with: validFinalization)

  let rawURL = url.appendingPathComponent(RawArchiveWriter.transportFilename)
  var bytes = try Data(contentsOf: rawURL)
  bytes[bytes.startIndex] ^= 0xff
  try bytes.write(to: rawURL)

  #expect(throws: (any Error).self) {
    try RawArchiveWriter.verify(at: url)
  }
}
