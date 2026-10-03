import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RewindDVArchiveCore

private let mapSourcePackA: [UInt8] = [0x60, 0xff, 0xff, 0x40, 0xff]
private let mapSourcePackB: [UInt8] = [0x60, 0xff, 0xff, 0x00, 0xff]
private let mapControlPackA: [UInt8] = [0x61, 0x03, 0x81, 0xfc, 0xff]
private let mapControlPackB: [UInt8] = [0x61, 0x3f, 0x81, 0xfc, 0xff]

private func tapeMapFrame(
  pal: Bool = false,
  marker: UInt8 = 0,
  audioRateCode: UInt8? = 0,
  includeVAUX: Bool = true,
  conflictingVAUX: Bool = false,
  includeTimecode: Bool = true,
  conflictingTimecode: Bool = false,
  nonzeroSTABlocks: Int = 0
) -> Data {
  let sequences = pal ? 12 : 10
  var frame = Data()
  var videoIndex = 0
  for sequence in 0..<sequences {
    func append(section: Int, block: Int) {
      var bytes = Data(repeating: 0xff, count: 80)
      bytes[0] = UInt8(section << 5)
      bytes[1] = UInt8(sequence << 4)
      bytes[2] = UInt8(block)
      if section == 0 {
        bytes[3] = pal ? 0x80 : 0
        for index in 4...7 { bytes[index] = 0 }
      } else if section == 1, includeTimecode {
        let value: UInt8 = conflictingTimecode && sequence > 0 ? marker &+ 1 : marker
        bytes.replaceSubrange(6..<11, with: [0x13, value, 0, 0, 1])
      } else if section == 2, includeVAUX {
        let useSecond = conflictingVAUX && sequence > 0
        let source = useSecond ? mapSourcePackB : mapSourcePackA
        let control = useSecond ? mapControlPackB : mapControlPackA
        bytes.replaceSubrange(3..<8, with: block == 0 ? source : control)
      } else if section == 3, let audioRateCode {
        bytes.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, audioRateCode << 3])
      } else if section == 4 {
        bytes[3] = videoIndex < nonzeroSTABlocks ? 0x10 : 0
        bytes[79] = marker
        videoIndex += 1
      }
      frame.append(bytes)
    }
    append(section: 0, block: 0)
    for block in 0..<2 { append(section: 1, block: block) }
    for block in 0..<3 { append(section: 2, block: block) }
    for group in 0..<9 {
      append(section: 3, block: group)
      for block in group * 15..<(group + 1) * 15 {
        append(section: 4, block: block)
      }
    }
  }
  return frame
}

private func withTapeMapTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("RewindDVTapeMapTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

@Test(arguments: [Int.min, -1, 0, 1, 119_999, Int.max])
func tapeMapRejectsInvalidImportedFrameSize(_ frameByteCount: Int) throws {
  try withTapeMapTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try tapeMapFrame().write(to: source)
    let map = root.appendingPathComponent("map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let marker = map.appendingPathComponent(DVTapeEvidenceMapExporter.completionMarkerName)
    var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
    var snapshot = try #require(receipt["source_snapshot"] as? [String: Any])
    snapshot["frame_byte_count"] = frameByteCount
    receipt["source_snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: receipt).write(to: marker)

    #expect(throws: DVIngestError.self) {
      try DVTapeEvidenceLedgerReader(mapDirectory: map)
    }
    #expect(try Data(contentsOf: source) == tapeMapFrame())
  }
}

private func withAsyncTapeMapTemporaryDirectory(
  _ body: (URL) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("RewindDVTapeMapTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}

private func tapeMapSHA(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func tapeMapLedgerRecords(_ url: URL) throws -> [DVTapeEvidenceMapExporter.FrameRecord] {
  let data = try Data(contentsOf: url)
  return try data.split(separator: 10).map {
    try JSONDecoder().decode(DVTapeEvidenceMapExporter.FrameRecord.self, from: Data($0))
  }
}

private func tapeMapVerification(
  source: Data,
  frameCount: UInt64,
  knownDrops: UInt64 = 0,
  oversized: UInt64 = 0,
  cip: UInt64 = 0,
  rawGaps: UInt64 = 0,
  rejected: UInt64 = 0,
  incomplete: UInt64 = 0,
  finalAcknowledgement: Bool = true,
  legacy: Bool = false,
  captureFile: String? = "capture.dv"
) -> DVIngestVerification {
  DVIngestVerification(
    schemaVersion: 1,
    completeDVFrames: frameCount,
    dvBytes: UInt64(source.count),
    rawRecordCount: 11,
    rawRecordBytes: 22,
    rawRecordSHA256: String(repeating: "a", count: 64),
    nativeDVSHA256: tapeMapSHA(source),
    journalSHA256: String(repeating: "b", count: 64),
    frameManifestSHA256: String(repeating: "c", count: 64),
    frameManifestBytes: 33,
    hostRingDrops: knownDrops - oversized,
    oversizedPackets: oversized,
    knownDroppedPackets: knownDrops,
    CIPDiscontinuities: cip,
    rejectedPackets: rejected,
    incompleteFrames: incomplete,
    finalAcknowledgementConfirmed: finalAcknowledgement,
    legacyStoppedSnapshotUsed: legacy,
    rawTransportGapEvents: rawGaps,
    integritySHA256Verified: true,
    nativeDVRereadVerified: true,
    hardwareContinuity: "unknown",
    exactLostFrameCount: nil,
    sourceMediaDamage: "unknown",
    captureFile: captureFile,
    frameManifestFile: "frames.ndjson",
    verificationFile: "verification.json",
    finalStatusWireBase64: Data(repeating: 0, count: 128).base64EncodedString())
}

@Test func tapeMapPersistsExactCoverageAndBoundedFrameObservations() throws {
  try withTapeMapTemporaryDirectory { root in
    let first = tapeMapFrame(marker: 7)
    let second = tapeMapFrame(
      marker: 8, audioRateCode: nil, includeVAUX: false,
      includeTimecode: false, nonzeroSTABlocks: 2)
    var sourceBytes = Data()
    sourceBytes.append(first)
    sourceBytes.append(second)
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let destination = root.appendingPathComponent("map", isDirectory: true)

    let receipt = try DVTapeEvidenceMapExporter.create(
      source: source, destination: destination)
    #expect(receipt.sourceSnapshot.sourceSHA256 == tapeMapSHA(sourceBytes))
    #expect(receipt.sourceSnapshot.frameCount == 2)
    #expect(receipt.coveredFirstFrameOrdinal == 0)
    #expect(receipt.coveredEndFrameOrdinalExclusive == 2)
    #expect(receipt.coveredSourceByteOffset == 0)
    #expect(receipt.coveredSourceByteEndExclusive == UInt64(sourceBytes.count))
    #expect(receipt.uncoveredSourceByteCount == 0)
    #expect(receipt.frameLedgerRecordCount == 2)
    #expect(receipt.byteIntegrity == .sourceRereadVerified)
    #expect(receipt.acquisitionReport == .unknownNoVerificationReport)
    #expect(receipt.archiveReportProvenance == nil)
    #expect(receipt.sourceQuality.contains("unknown"))
    #expect(receipt.positionAuthority.contains("ATN_ETN_not_decoded"))
    #expect(receipt.continuityAuthority.contains("never_imply_lost_packets"))
    #expect(receipt.repairAuthority.hasPrefix("none"))

    let ledgerURL = destination.appendingPathComponent(
      DVTapeEvidenceMapExporter.frameLedgerFileName)
    let ledgerData = try Data(contentsOf: ledgerURL)
    #expect(receipt.frameLedgerSHA256 == tapeMapSHA(ledgerData))
    #expect(receipt.frameLedgerByteCount == UInt64(ledgerData.count))
    let records = try tapeMapLedgerRecords(ledgerURL)
    #expect(records.count == 2)
    #expect(records[0].boundaryEvidence.frameOrdinal == 0)
    #expect(records[0].boundaryEvidence.frameSHA256 == tapeMapSHA(first))
    #expect(records[0].rawSubcode.extentSourceByteOffsets.count == 20)
    #expect(records[0].rawSubcode.titleTimecodePacks.classification
      == .singleUniqueRawValueObserved)
    #expect(records[0].rawSubcode.titleTimecodePacks.uniqueRawValues.first?.rawBytes
      == [0x13, 7, 0, 0, 1])
    #expect(records[1].boundaryEvidence.frameSourceByteOffset == 120_000)
    #expect(records[1].issues.contains {
      $0.code == .nonzeroVideoSTA && $0.observedCount == 2
    })
    #expect(records[1].issues.contains { $0.code == .audioRateAbsent })
    #expect(records[1].issues.contains { $0.code == .vauxSourceAbsent })
    #expect(records[1].issues.contains { $0.code == .titleTimecodeAbsent })
    let counts = Dictionary(uniqueKeysWithValues: receipt.issueCounts.map {
      ($0.code, ($0.affectedFrameCount, $0.totalObservedCount))
    })
    #expect(counts[.nonzeroVideoSTA]?.0 == 1)
    #expect(counts[.nonzeroVideoSTA]?.1 == 2)
    #expect(counts[.audioRateAbsent]?.0 == 1)

    let markerData = try Data(contentsOf:
      destination.appendingPathComponent(DVTapeEvidenceMapExporter.completionMarkerName))
    #expect(markerData.last == 10)
    #expect(try JSONDecoder().decode(
      DVTapeEvidenceMapExporter.Receipt.self, from: Data(markerData.dropLast())) == receipt)
    #expect(!FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(
        DVTapeEvidenceMapExporter.frameLedgerFileName + ".partial").path))
  }
}

@Test func tapeMapRetainsConflictingRawValuesWithoutSelectingAuthority() throws {
  try withTapeMapTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try tapeMapFrame(
      marker: 11, conflictingVAUX: true, conflictingTimecode: true).write(to: source)
    let destination = root.appendingPathComponent("map", isDirectory: true)
    let receipt = try DVTapeEvidenceMapExporter.create(
      source: source, destination: destination)
    let record = try #require(tapeMapLedgerRecords(
      destination.appendingPathComponent(DVTapeEvidenceMapExporter.frameLedgerFileName)).first)

    #expect(record.boundaryEvidence.vauxSource.classification
      == .multipleUniqueRawValuesObserved)
    #expect(record.boundaryEvidence.vauxSource.uniqueRawValues.count == 2)
    #expect(record.rawSubcode.titleTimecodePacks.classification
      == .multipleUniqueRawValuesObserved)
    #expect(record.rawSubcode.titleTimecodePacks.uniqueRawValues.count == 2)
    #expect(record.issues.contains { $0.code == .vauxSourceMultiple })
    #expect(record.issues.contains { $0.code == .titleTimecodeMultiple })
    #expect(receipt.positionAuthority.contains("never_align_or_seek"))
  }
}

@Test func tapeMapBindsOptionalArchiveReportWithoutUpgradingRawEvidence() throws {
  try withTapeMapTemporaryDirectory { root in
    let sourceBytes = tapeMapFrame(marker: 3)
    let source = root.appendingPathComponent("capture-copy.dv")
    try sourceBytes.write(to: source)
    let verification = tapeMapVerification(
      source: sourceBytes, frameCount: 1, knownDrops: 3,
      oversized: 1, cip: 2, rawGaps: 1, rejected: 4, incomplete: 5)
    let verificationData = try JSONEncoder().encode(verification)
    let verificationURL = root.appendingPathComponent("verification.json")
    try verificationData.write(to: verificationURL)
    let destination = root.appendingPathComponent("map", isDirectory: true)

    let receipt = try DVTapeEvidenceMapExporter.create(
      source: source, archiveVerification: verificationURL,
      destination: destination)
    #expect(receipt.byteIntegrity == .sourceAndVerificationReportHashBound)
    #expect(receipt.acquisitionReport == .verificationReportObservesKnownDefects)
    let provenance = try #require(receipt.archiveReportProvenance)
    #expect(provenance.verificationFileSHA256 == tapeMapSHA(verificationData))
    #expect(provenance.verificationFileByteCount == UInt64(verificationData.count))
    #expect(provenance.rawRecordSHA256 == String(repeating: "a", count: 64))
    #expect(provenance.knownDroppedPackets == 3)
    #expect(provenance.hostRingDrops == 2)
    #expect(provenance.oversizedPackets == 1)
    #expect(provenance.CIPDiscontinuities == 2)
    #expect(provenance.rawTransportGapEvents == 1)
    #expect(provenance.rejectedPackets == 4)
    #expect(provenance.incompleteFrames == 5)
    #expect(provenance.evidenceScope.contains("not_independently_reread"))
  }
}

@Test func tapeMapReportsNoKnownArchiveDefectsWithoutClaimingContinuityOrQuality() throws {
  try withTapeMapTemporaryDirectory { root in
    let sourceBytes = tapeMapFrame(marker: 4)
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let verificationURL = root.appendingPathComponent("verification.json")
    try JSONEncoder().encode(tapeMapVerification(
      source: sourceBytes, frameCount: 1)).write(to: verificationURL)
    let receipt = try DVTapeEvidenceMapExporter.create(
      source: source, archiveVerification: verificationURL,
      destination: root.appendingPathComponent("map", isDirectory: true))

    #expect(receipt.acquisitionReport == .verificationReportObservesNoKnownDefects)
    #expect(receipt.sourceQuality.contains("does not prove pristine"))
    #expect(receipt.continuityAuthority.contains("report_observations_only"))
    #expect(receipt.tapeIdentity.contains("unknown"))
  }
}

@Test func tapeMapDoesNotTreatUnacknowledgedReportAsClosedContinuity() throws {
  try withTapeMapTemporaryDirectory { root in
    let sourceBytes = tapeMapFrame(marker: 9)
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let verificationURL = root.appendingPathComponent("verification.json")
    try JSONEncoder().encode(tapeMapVerification(
      source: sourceBytes, frameCount: 1,
      finalAcknowledgement: false, legacy: true)).write(to: verificationURL)
    let receipt = try DVTapeEvidenceMapExporter.create(
      source: source, archiveVerification: verificationURL,
      destination: root.appendingPathComponent("map", isDirectory: true))

    #expect(receipt.acquisitionReport == .unknownUnacknowledgedOrLegacyReport)
    #expect(receipt.archiveReportProvenance?.legacyStoppedSnapshotUsed == true)
    #expect(receipt.archiveReportProvenance?.finalAcknowledgementConfirmed == false)
  }
}

@Test func tapeMapRejectsUnboundOrPathBearingArchiveReportsBeforeDestination() throws {
  try withTapeMapTemporaryDirectory { root in
    let sourceBytes = tapeMapFrame(marker: 5)
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let invalid = [
      tapeMapVerification(source: tapeMapFrame(marker: 6), frameCount: 1),
      tapeMapVerification(source: sourceBytes, frameCount: 1, captureFile: "../capture.dv"),
    ]
    for (index, verification) in invalid.enumerated() {
      let verificationURL = root.appendingPathComponent("verification-\(index).json")
      try JSONEncoder().encode(verification).write(to: verificationURL)
      let destination = root.appendingPathComponent("invalid-\(index)", isDirectory: true)
      #expect(throws: (any Error).self) {
        try DVTapeEvidenceMapExporter.create(
          source: source, archiveVerification: verificationURL,
          destination: destination)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }
}

@Test func tapeMapRefusesExistingDestinationAndSymlinkOrFIFOInputs() throws {
  try withTapeMapTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try tapeMapFrame().write(to: source)
    let sourceLink = root.appendingPathComponent("source-link.dv")
    try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
    #expect(throws: (any Error).self) {
      try DVTapeEvidenceMapExporter.create(
        source: sourceLink,
        destination: root.appendingPathComponent("link-map", isDirectory: true))
    }

    let fifo = root.appendingPathComponent("verification.fifo")
    #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) {
      try DVTapeEvidenceMapExporter.create(
        source: source, archiveVerification: fifo,
        destination: root.appendingPathComponent("fifo-map", isDirectory: true))
    }

    let destination = root.appendingPathComponent("existing", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)
    #expect(throws: DVIngestError.self) {
      try DVTapeEvidenceMapExporter.create(source: source, destination: destination)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["sentinel"])
  }
}

@Test func tapeMapRefusesDestinationRenameAndReplacementBeforeCommit() throws {
  try withTapeMapTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try tapeMapFrame(marker: 12).write(to: source)
    let destination = root.appendingPathComponent("map", isDirectory: true)
    let moved = root.appendingPathComponent("moved-map", isDirectory: true)

    #expect(throws: (any Error).self) {
      try DVTapeEvidenceMapExporter.createForTesting(
        source: source,
        destination: destination,
        beforeCommit: {
          try FileManager.default.moveItem(at: destination, to: moved)
          try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false)
        })
    }
    #expect(!FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(
        DVTapeEvidenceMapExporter.completionMarkerName).path))
    #expect(!FileManager.default.fileExists(atPath:
      moved.appendingPathComponent(DVTapeEvidenceMapExporter.completionMarkerName).path))
    #expect(FileManager.default.fileExists(atPath:
      moved.appendingPathComponent(DVTapeEvidenceMapExporter.intentFileName).path))
    #expect(FileManager.default.fileExists(atPath:
      moved.appendingPathComponent(
        DVTapeEvidenceMapExporter.frameLedgerFileName + ".partial").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }
}

private actor TapeMapGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    if let continuation {
      continuation.resume()
      self.continuation = nil
    } else {
      isOpen = true
    }
  }
}

@Test func tapeMapHonorsCancellationBeforeCreatingEvidence() async throws {
  try await withAsyncTapeMapTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try tapeMapFrame().write(to: source)
    let destination = root.appendingPathComponent("cancelled", isDirectory: true)
    let gate = TapeMapGate()
    let task = Task {
      await gate.wait()
      return try DVTapeEvidenceMapExporter.create(
        source: source, destination: destination)
    }
    task.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
