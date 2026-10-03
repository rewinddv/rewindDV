import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func reviewFrame(
  marker: UInt8,
  metadataAbsent: Bool = false,
  conflictingVAUX: Bool = false,
  nonzeroSTA: Bool = false
) -> Data {
  var frame = Data()
  for sequence in 0..<10 {
    func append(_ section: Int, _ block: Int) {
      var bytes = Data(repeating: 0xff, count: 80)
      bytes[0] = UInt8(section << 5)
      bytes[1] = UInt8(sequence << 4)
      bytes[2] = UInt8(block)
      if section == 0 {
        bytes[3] = 0
        for index in 4...7 { bytes[index] = 0 }
      } else if section == 1, !metadataAbsent {
        bytes.replaceSubrange(6..<11, with: [0x13, marker, 0, 0, 1])
      } else if section == 2, !metadataAbsent {
        if block == 0 {
          let change = conflictingVAUX && sequence == 1 ? UInt8(0x20) : 0
          bytes.replaceSubrange(3..<8, with: [0x60, 0xff, 0xff, 0x40, 0xff])
          bytes.replaceSubrange(8..<13, with: [0x61, 0x03, 0x81, 0xdc | change, 0xff])
        }
      } else if section == 3, !metadataAbsent {
        bytes.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, 0])
      } else if section == 4 {
        bytes[3] = nonzeroSTA && block == 0 && sequence == 0 ? 0x10 : 0
        bytes[79] = marker
      }
      frame.append(bytes)
    }
    append(0, 0)
    for block in 0..<2 { append(1, block) }
    for block in 0..<3 { append(2, block) }
    for group in 0..<9 {
      append(3, group)
      for block in group * 15..<(group + 1) * 15 { append(4, block) }
    }
  }
  return frame
}

private func withReviewRoot(_ body: (URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("RewindDVRecoveryReviewTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}

private func reviewSHA(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test func tapeEvidenceReaderBuildsVerifiedSparsePagesAndInspectorModels() async throws {
  try await withReviewRoot { root in
    var sourceData = Data()
    sourceData.reserveCapacity(257 * 120_000)
    let absent = reviewFrame(marker: 1, metadataAbsent: true, nonzeroSTA: true)
    let conflicting = reviewFrame(marker: 2, conflictingVAUX: true)
    sourceData.append(absent)
    sourceData.append(conflicting)
    for ordinal in 2..<257 { sourceData.append(reviewFrame(marker: UInt8(ordinal & 0xff))) }
    let source = root.appendingPathComponent("source.dv")
    try sourceData.write(to: source)
    let map = root.appendingPathComponent("map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)

    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    #expect(reader.binding.pageCount == 2)
    #expect(reader.pageSummaries.count == 2)
    #expect(reader.pageSummaries[0].firstFrameOrdinal == 0)
    #expect(reader.pageSummaries[0].endFrameOrdinalExclusive == 256)
    #expect(reader.pageSummaries[0].issueFrameCount >= 2)
    #expect(reader.pageSummaries[1].firstFrameOrdinal == 256)
    let firstPage = try await reader.page(0)
    let finalPage = try await reader.page(1)
    #expect(firstPage.records.count == 256)
    #expect(finalPage.records.count == 1)
    #expect(firstPage.records[0].boundaryEvidence.frameSHA256 == reviewSHA(absent))

    let absentModel = try DVTapeDefectInspector.make(
      binding: reader.binding, record: firstPage.records[0])
    #expect(absentModel.sourceByteOffset == 0)
    #expect(absentModel.sourceByteEndExclusive == 120_000)
    #expect(absentModel.issues.contains { $0.code == .vauxSourceAbsent
      && $0.unknownLimit.contains("not proof") })
    #expect(absentModel.actionAuthority.contains("no_hardware"))

    let inventory = try DVMetadataInventory.inspect(
      frame: conflicting, ordinal: 1, byteOffset: 120_000)
    let semantic = DVPackSemanticReport.inspect(inventory)
    let conflictModel = try DVTapeDefectInspector.make(
      binding: reader.binding, record: firstPage.records[1], semanticReport: semantic)
    #expect(conflictModel.issues.contains { $0.code == .vauxSourceControlMultiple })
    #expect(conflictModel.rawPackProvenance.contains { $0.typeHex == "0x61"
      && !$0.sourceByteOffsets.isEmpty })
    #expect(conflictModel.actionAuthority.contains("no_hardware"))
    #expect(conflictModel.actionAuthority.contains("merge"))

    let sidecar = root.appendingPathComponent("paged-review", isDirectory: true)
    let journal = try DVRecoveryReviewJournal.create(
      at: sidecar, evidenceMapDirectory: map, binding: reader.binding)
    for ordinal in UInt64(0)..<257 {
      let item = try DVRecoveryReviewJournal.makeRangeItem(
        binding: reader.binding, firstFrameOrdinal: ordinal,
        endFrameOrdinalExclusive: ordinal + 1,
        issueCodes: [.nonzeroVideoSTA], summary: "Operator-selected review")
      _ = try await journal.append(
        item: item, state: .unreviewed, expectedRevision: ordinal)
    }
    #expect(try await journal.currentItemCount() == 257)
    #expect(try await journal.currentItemsPage(0).latestEvents.count == 256)
    #expect(try await journal.currentItemsPage(1).latestEvents.count == 1)
  }
}

@Test func tapeEvidenceReaderRejectsChangedOrDuplicateLedgerEvidence() async throws {
  try await withReviewRoot { root in
    let sourceData = reviewFrame(marker: 1) + reviewFrame(marker: 2)
    let source = root.appendingPathComponent("source.dv")
    try sourceData.write(to: source)
    let map = root.appendingPathComponent("map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    let ledger = map.appendingPathComponent(DVTapeEvidenceMapExporter.frameLedgerFileName)
    let handle = try FileHandle(forWritingTo: ledger)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    await #expect(throws: (any Error).self) { try await reader.page(0) }

    let secondMap = root.appendingPathComponent("duplicate-map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(
      source: source, destination: secondMap)
    let secondLedger = secondMap.appendingPathComponent(
      DVTapeEvidenceMapExporter.frameLedgerFileName)
    let lines = try Data(contentsOf: secondLedger).split(separator: 10)
    let duplicate = Data(lines[0]) + Data([10]) + Data(lines[0]) + Data([10])
    try duplicate.write(to: secondLedger)
    let marker = secondMap.appendingPathComponent(DVTapeEvidenceMapExporter.completionMarkerName)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
    json["frame_ledger_sha256"] = reviewSHA(duplicate)
    json["frame_ledger_byte_count"] = duplicate.count
    try JSONSerialization.data(withJSONObject: json).write(to: marker)
    #expect(throws: (any Error).self) {
      _ = try DVTapeEvidenceLedgerReader(mapDirectory: secondMap)
    }
  }
}

@Test func recoveryReviewJournalPersistsLatestQueueStateWithoutChangingEvidence() async throws {
  try await withReviewRoot { root in
    let sourceData = reviewFrame(marker: 8, metadataAbsent: true)
      + reviewFrame(marker: 9, conflictingVAUX: true)
    let source = root.appendingPathComponent("source.dv")
    try sourceData.write(to: source)
    let map = root.appendingPathComponent("map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let sourceBefore = reviewSHA(try Data(contentsOf: source))
    let ledgerURL = map.appendingPathComponent(DVTapeEvidenceMapExporter.frameLedgerFileName)
    let ledgerBefore = reviewSHA(try Data(contentsOf: ledgerURL))
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    let page = try await reader.page(0)
    let model = try DVTapeDefectInspector.make(
      binding: reader.binding, record: page.records[0])
    let item = try DVRecoveryReviewJournal.makeItem(
      from: model, issueCodes: [.vauxSourceAbsent], summary: "Review missing VAUX metadata")
    let sidecar = root.appendingPathComponent("review", isDirectory: true)
    let journal = try DVRecoveryReviewJournal.create(
      at: sidecar, evidenceMapDirectory: map, binding: reader.binding)

    let first = try await journal.append(
      item: item, state: .unreviewed, expectedRevision: 0)
    #expect(first.revision == 1)
    let revisedItem = try DVRecoveryReviewJournal.makeItem(
      from: model, issueCodes: [.vauxSourceAbsent], summary: "Reviewed missing VAUX metadata")
    #expect(revisedItem.id == item.id)
    let second = try await journal.append(
      item: revisedItem, state: .reviewed,
      operatorNote: "Visual review only; no replacement selected.", expectedRevision: 1)
    #expect(second.revision == 2)
    #expect(try await journal.currentItemCount() == 1)
    let current = try await journal.currentItemsPage(0)
    #expect(current.totalCurrentItemCount == 1)
    #expect(current.latestEvents.first?.revision == 2)
    #expect(current.latestEvents.first?.state == .reviewed)
    let history = try await journal.eventsPage(0)
    #expect(history.events.map(\.revision) == [1, 2])
    let journalURL = sidecar.appendingPathComponent(
      DVRecoveryReviewJournal.eventLedgerFileName)
    let beforeDuplicate = try Data(contentsOf: journalURL)
    await #expect(throws: (any Error).self) {
      try await journal.append(item: revisedItem, state: .reviewed,
        operatorNote: "Visual review only; no replacement selected.", expectedRevision: 2)
    }
    #expect(try Data(contentsOf: journalURL) == beforeDuplicate)
    #expect(try await journal.status().latestRevision == 2)

    let range = try DVRecoveryReviewJournal.makeRangeItem(
      binding: reader.binding, firstFrameOrdinal: 0, endFrameOrdinalExclusive: 2,
      issueCodes: [.vauxSourceAbsent, .vauxSourceControlMultiple],
      summary: "Grouped operator review range")
    _ = try await journal.append(
      item: range, state: .flaggedForOperatorDecision, expectedRevision: 2)
    #expect(try await journal.currentItemCount() == 2)
    #expect(reviewSHA(try Data(contentsOf: source)) == sourceBefore)
    #expect(reviewSHA(try Data(contentsOf: ledgerURL)) == ledgerBefore)
    #expect(!FileManager.default.fileExists(atPath:
      map.appendingPathComponent(DVRecoveryReviewJournal.manifestFileName).path))

    let manifestURL = sidecar.appendingPathComponent(DVRecoveryReviewJournal.manifestFileName)
    var manifestBytes = try Data(contentsOf: manifestURL)
    manifestBytes.append(32)
    try manifestBytes.write(to: manifestURL)
    await #expect(throws: (any Error).self) {
      try await journal.currentItemsPage(0)
    }

    #expect(throws: (any Error).self) {
      _ = try DVRecoveryReviewJournal.create(
        at: map.appendingPathComponent("forbidden-review"),
        evidenceMapDirectory: map, binding: reader.binding)
    }
  }
}

@Test func recoveryReviewJournalExcludesSecondWriterAndReleasesOwnership() async throws {
  try await withReviewRoot { root in
    let source = root.appendingPathComponent("source.dv")
    let original = reviewFrame(marker: 3)
    try original.write(to: source)
    let map = root.appendingPathComponent("map", isDirectory: true)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    let sidecar = root.appendingPathComponent("review", isDirectory: true)
    var journal: DVRecoveryReviewJournal? = try .create(
      at: sidecar, evidenceMapDirectory: map, binding: reader.binding)
    let item = try DVRecoveryReviewJournal.makeRangeItem(
      binding: reader.binding, firstFrameOrdinal: 0, endFrameOrdinalExclusive: 1,
      issueCodes: [.nonzeroVideoSTA], summary: "Operator-selected review")
    #expect(throws: DVIngestError.self) {
      _ = try DVRecoveryReviewJournal.open(
        at: sidecar, evidenceMapDirectory: map, expectedBinding: reader.binding)
    }
    // A rejected opener must not modify the first owner's files or lock.
    #expect(try await journal!.append(item: item, state: .unreviewed, expectedRevision: 0).revision == 1)
    weak let released = journal
    journal = nil
    #expect(released == nil)
    let reopened = try DVRecoveryReviewJournal.open(
      at: sidecar, evidenceMapDirectory: map, expectedBinding: reader.binding)
    #expect(try await reopened.status().latestRevision == 1)
    #expect(try await reopened.append(item: item, state: .reviewed, expectedRevision: 1).revision == 2)
    #expect(try await reopened.eventsPage(0).events.map(\.revision) == [1, 2])
    #expect(try Data(contentsOf: source) == original)
    #expect(try await reader.page(0).records.count == 1)
  }
}
