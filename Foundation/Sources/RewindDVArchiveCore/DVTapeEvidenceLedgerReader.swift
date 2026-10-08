// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// A descriptor-pinned, bounded-page reader for a completed tape evidence map.
/// Opening performs one streaming verification of the complete ledger. Page
/// reads then recheck file identity and the selected page digest; they do not
/// rescan a potentially large ledger.
public actor DVTapeEvidenceLedgerReader {
  public static let recordsPerPage: UInt64 = 256

  public struct Binding: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let mapReceipt: DVTapeEvidenceMapExporter.Receipt
    public let mapReceiptSHA256: String
    public let mapReceiptByteCount: UInt64
    public let recordsPerPage: UInt64
    public let pageCount: UInt64

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case mapReceipt = "map_receipt"
      case mapReceiptSHA256 = "map_receipt_sha256"
      case mapReceiptByteCount = "map_receipt_byte_count"
      case recordsPerPage = "records_per_page"
      case pageCount = "page_count"
    }
  }

  public struct Page: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let pageNumber: UInt64
    public let firstFrameOrdinal: UInt64
    public let endFrameOrdinalExclusive: UInt64
    public let ledgerByteOffset: UInt64
    public let ledgerByteCount: UInt64
    public let pageSHA256: String
    public let records: [DVTapeEvidenceMapExporter.FrameRecord]

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case pageNumber = "page_number"
      case firstFrameOrdinal = "first_frame_ordinal"
      case endFrameOrdinalExclusive = "end_frame_ordinal_exclusive"
      case ledgerByteOffset = "ledger_byte_offset"
      case ledgerByteCount = "ledger_byte_count"
      case pageSHA256 = "page_sha256"
      case records
    }
  }

  public struct PageSummary: Codable, Equatable, Sendable {
    public let pageNumber: UInt64
    public let firstFrameOrdinal: UInt64
    public let endFrameOrdinalExclusive: UInt64
    public let issueFrameCount: UInt64
    public let totalIssueObservations: UInt64
    public let issueFrameCounts: [DVTapeEvidenceMapExporter.IssueCode: UInt64]
    public let qualityAssessedFrames: UInt64

    private enum CodingKeys: String, CodingKey {
      case pageNumber = "page_number"
      case firstFrameOrdinal = "first_frame_ordinal"
      case endFrameOrdinalExclusive = "end_frame_ordinal_exclusive"
      case issueFrameCount = "issue_frame_count"
      case totalIssueObservations = "total_issue_observations"
      case issueFrameCounts = "issue_frame_counts"
      case qualityAssessedFrames = "quality_assessed_frames"
    }
  }

  public nonisolated let binding: Binding
  /// Sparse display bins derived during the initial verified ledger scan.
  public nonisolated let pageSummaries: [PageSummary]
  public nonisolated let mapDirectory: URL
  private let directoryFD: Int32
  private let directoryStatus: stat
  private let ledgerFD: Int32
  private let ledgerStatus: stat
  private let indexes: [PageIndex]

  public init(mapDirectory: URL) throws {
    let directoryFD = Darwin.open(
      mapDirectory.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else {
      throw DVIngestError.fileOperation("open tape evidence map", errno)
    }
    var keepDirectory = false
    defer { if !keepDirectory { Darwin.close(directoryFD) } }
    var directoryStatus = stat()
    guard fstat(directoryFD, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR else {
      throw DVIngestError.invalidEvidence("tape evidence map is not a regular directory")
    }

    let marker = try Self.readRegularFile(
      directoryFD: directoryFD,
      name: DVTapeEvidenceMapExporter.completionMarkerName,
      maximumByteCount: 67_108_864)
    let receipt: DVTapeEvidenceMapExporter.Receipt
    do { receipt = try JSONDecoder().decode(DVTapeEvidenceMapExporter.Receipt.self, from: marker.data) }
    catch { throw DVIngestError.invalidEvidence("tape evidence completion marker JSON is invalid") }
    try Self.validate(receipt)

    let ledgerFD = openat(
      directoryFD, DVTapeEvidenceMapExporter.frameLedgerFileName,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard ledgerFD >= 0 else {
      throw DVIngestError.fileOperation("open tape evidence frame ledger", errno)
    }
    var keepLedger = false
    defer { if !keepLedger { Darwin.close(ledgerFD) } }
    var ledgerStatus = stat()
    guard fstat(ledgerFD, &ledgerStatus) == 0,
      ledgerStatus.st_mode & S_IFMT == S_IFREG,
      ledgerStatus.st_size >= 0,
      UInt64(ledgerStatus.st_size) == receipt.frameLedgerByteCount else {
      throw DVIngestError.invalidEvidence("tape evidence frame ledger type or size is invalid")
    }

    let indexes = try Self.verifyLedger(
      fd: ledgerFD, expectedByteCount: receipt.frameLedgerByteCount,
      expectedSHA256: receipt.frameLedgerSHA256, receipt: receipt)
    let expectedPages = receipt.frameLedgerRecordCount == 0 ? 0
      : (receipt.frameLedgerRecordCount - 1) / Self.recordsPerPage + 1
    guard UInt64(indexes.count) == expectedPages else {
      throw DVIngestError.invalidEvidence("tape evidence page index count is inconsistent")
    }

    self.binding = Binding(
      schemaVersion: 1, mapReceipt: receipt,
      mapReceiptSHA256: Self.hex(SHA256.hash(data: marker.data)),
      mapReceiptByteCount: UInt64(marker.data.count),
      recordsPerPage: Self.recordsPerPage, pageCount: UInt64(indexes.count))
    self.pageSummaries = indexes.enumerated().map { number, index in
      PageSummary(pageNumber: UInt64(number), firstFrameOrdinal: index.firstOrdinal,
        endFrameOrdinalExclusive: index.endOrdinal,
        issueFrameCount: index.issueFrameCount,
        totalIssueObservations: index.totalIssueObservations,
        issueFrameCounts: index.issueFrameCounts, qualityAssessedFrames: index.qualityAssessedFrames)
    }
    self.mapDirectory = mapDirectory
    self.directoryFD = directoryFD
    self.directoryStatus = directoryStatus
    self.ledgerFD = ledgerFD
    self.ledgerStatus = ledgerStatus
    self.indexes = indexes
    keepDirectory = true
    keepLedger = true
  }

  deinit {
    Darwin.close(ledgerFD)
    Darwin.close(directoryFD)
  }

  public func page(_ pageNumber: UInt64) throws -> Page {
    try Task.checkCancellation()
    guard pageNumber < UInt64(indexes.count), pageNumber <= UInt64(Int.max) else {
      throw DVIngestError.invalidEvidence("tape evidence page number is outside the verified index")
    }
    try requireCurrentEvidence()
    let index = indexes[Int(pageNumber)]
    guard index.byteCount <= UInt64(Int.max) else {
      throw DVIngestError.invalidEvidence("tape evidence page exceeds platform bounds")
    }
    let data = try Self.preadExactly(
      fd: ledgerFD, offset: index.byteOffset, count: Int(index.byteCount))
    guard Self.hex(SHA256.hash(data: data)) == index.sha256 else {
      throw DVIngestError.invalidEvidence("selected tape evidence page hash mismatch")
    }
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true else {
      throw DVIngestError.invalidEvidence("selected tape evidence page lacks its final newline")
    }
    var records: [DVTapeEvidenceMapExporter.FrameRecord] = []
    records.reserveCapacity(Int(index.endOrdinal - index.firstOrdinal))
    for (position, line) in lines.dropLast().enumerated() {
      let record: DVTapeEvidenceMapExporter.FrameRecord
      do { record = try JSONDecoder().decode(DVTapeEvidenceMapExporter.FrameRecord.self, from: Data(line)) }
      catch { throw DVIngestError.invalidEvidence("selected tape evidence page contains invalid JSON") }
      let ordinal = try Self.add(index.firstOrdinal, UInt64(position), "page frame ordinal")
      try Self.validate(record, ordinal: ordinal, receipt: binding.mapReceipt)
      records.append(record)
    }
    guard UInt64(records.count) == index.endOrdinal - index.firstOrdinal else {
      throw DVIngestError.invalidEvidence("selected tape evidence page record count mismatch")
    }
    try requireCurrentEvidence()
    return Page(
      schemaVersion: 1, pageNumber: pageNumber,
      firstFrameOrdinal: index.firstOrdinal,
      endFrameOrdinalExclusive: index.endOrdinal,
      ledgerByteOffset: index.byteOffset, ledgerByteCount: index.byteCount,
      pageSHA256: index.sha256, records: records)
  }

  private struct PageIndex {
    let firstOrdinal: UInt64
    let endOrdinal: UInt64
    let byteOffset: UInt64
    let byteCount: UInt64
    let sha256: String
    let issueFrameCount: UInt64
    let totalIssueObservations: UInt64
    let issueFrameCounts: [DVTapeEvidenceMapExporter.IssueCode: UInt64]
    let qualityAssessedFrames: UInt64
  }

  public func findIssue(after ordinal: UInt64?, forward: Bool,
    code: DVTapeEvidenceMapExporter.IssueCode? = nil) throws -> UInt64? {
    try requireCurrentEvidence()
    let candidates = forward ? Array(indexes.indices) : Array(indexes.indices.reversed())
    for index in candidates {
      try Task.checkCancellation()
      let bin = indexes[index]
      if let ordinal {
        if forward && (ordinal == UInt64.max || bin.endOrdinal <= ordinal + 1) { continue }
        if !forward && bin.firstOrdinal >= ordinal { continue }
      }
      guard code.map({ bin.issueFrameCounts[$0, default: 0] > 0 }) ?? (bin.issueFrameCount > 0) else { continue }
      let records = try page(UInt64(index)).records
      let ordered = forward ? records : Array(records.reversed())
      if let record = ordered.first(where: { record in
        let n = record.boundaryEvidence.frameOrdinal
        return (ordinal.map { forward ? n > $0 : n < $0 } ?? true)
          && record.issues.contains { code == nil || $0.code == code }
      }) { return record.boundaryEvidence.frameOrdinal }
    }
    return nil
  }

  private func requireCurrentEvidence() throws {
    var currentDirectory = stat()
    var pathDirectory = stat()
    var currentLedger = stat()
    var pathLedger = stat()
    guard fstat(directoryFD, &currentDirectory) == 0,
      lstat(mapDirectory.path, &pathDirectory) == 0,
      fstat(ledgerFD, &currentLedger) == 0,
      fstatat(directoryFD, DVTapeEvidenceMapExporter.frameLedgerFileName,
        &pathLedger, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw DVIngestError.fileOperation("reinspect tape evidence map", errno)
    }
    guard Self.sameIdentityAndMetadata(currentDirectory, directoryStatus),
      pathDirectory.st_mode & S_IFMT == S_IFDIR,
      pathDirectory.st_dev == directoryStatus.st_dev,
      pathDirectory.st_ino == directoryStatus.st_ino,
      Self.sameIdentityAndMetadata(currentLedger, ledgerStatus),
      pathLedger.st_mode & S_IFMT == S_IFREG,
      pathLedger.st_dev == ledgerStatus.st_dev,
      pathLedger.st_ino == ledgerStatus.st_ino else {
      throw DVIngestError.invalidEvidence("tape evidence map identity or metadata changed")
    }
    let marker = try Self.readRegularFile(
      directoryFD: directoryFD,
      name: DVTapeEvidenceMapExporter.completionMarkerName,
      maximumByteCount: 67_108_864)
    guard UInt64(marker.data.count) == binding.mapReceiptByteCount,
      Self.hex(SHA256.hash(data: marker.data)) == binding.mapReceiptSHA256 else {
      throw DVIngestError.invalidEvidence("tape evidence completion marker changed")
    }
  }

  private static func verifyLedger(
    fd: Int32,
    expectedByteCount: UInt64,
    expectedSHA256: String,
    receipt: DVTapeEvidenceMapExporter.Receipt
  ) throws -> [PageIndex] {
    guard lseek(fd, 0, SEEK_SET) == 0 else {
      throw DVIngestError.fileOperation("rewind tape evidence ledger", errno)
    }
    var ledgerHash = SHA256()
    var pageHash = SHA256()
    var indexes: [PageIndex] = []
    var ordinal: UInt64 = 0
    var pageStartOrdinal: UInt64 = 0
    var pageStartByte: UInt64 = 0
    var pageBytes: UInt64 = 0
    var pageIssueFrames: UInt64 = 0
    var pageIssueObservations: UInt64 = 0
    var pageCodes: [DVTapeEvidenceMapExporter.IssueCode: UInt64] = [:]
    var qualityFrames: UInt64 = 0
    var previousTimeline: DVFrameTimelineEvidence.Point?
    var totals: [DVTapeEvidenceMapExporter.IssueCode: (frames: UInt64, observations: UInt64)] = [:]
    let totalBytes = try scanLines(fd: fd, maximumLineBytes: 1_048_576) { line, rawLine in
      let record: DVTapeEvidenceMapExporter.FrameRecord
      do { record = try JSONDecoder().decode(DVTapeEvidenceMapExporter.FrameRecord.self, from: line) }
      catch { throw DVIngestError.invalidEvidence("tape evidence ledger contains invalid JSON") }
      try validate(record, ordinal: ordinal, receipt: receipt)
      if let timeline = record.timeline {
        guard timeline.changes == DVFrameTimelineEvidence.changes(from: previousTimeline, to: timeline.point) else {
          throw DVIngestError.invalidEvidence("recorded timeline transitions are inconsistent")
        }
        previousTimeline = timeline.point
      } else { previousTimeline = nil }
      if record.quality != nil { qualityFrames += 1 }
      if !record.issues.isEmpty {
        pageIssueFrames = try add(pageIssueFrames, 1, "tape evidence page issue frame count")
      }
      for issue in record.issues {
        let prior = totals[issue.code] ?? (0, 0)
        totals[issue.code] = (try add(prior.frames, 1, "issue frame total"),
          try add(prior.observations, issue.observedCount, "issue observation total"))
        pageCodes[issue.code, default: 0] += 1
        pageIssueObservations = try add(pageIssueObservations, issue.observedCount,
          "tape evidence page issue observation count")
      }
      ledgerHash.update(data: rawLine)
      pageHash.update(data: rawLine)
      pageBytes = try add(pageBytes, UInt64(rawLine.count), "tape evidence page byte count")
      ordinal = try add(ordinal, 1, "tape evidence record count")
      if ordinal - pageStartOrdinal == recordsPerPage {
        indexes.append(PageIndex(firstOrdinal: pageStartOrdinal, endOrdinal: ordinal,
          byteOffset: pageStartByte, byteCount: pageBytes, sha256: hex(pageHash.finalize()),
          issueFrameCount: pageIssueFrames, totalIssueObservations: pageIssueObservations,
          issueFrameCounts: pageCodes, qualityAssessedFrames: qualityFrames))
        pageStartOrdinal = ordinal
        pageStartByte = try add(pageStartByte, pageBytes, "tape evidence page offset")
        pageBytes = 0
        pageIssueFrames = 0
        pageIssueObservations = 0
        pageCodes = [:]; qualityFrames = 0
        pageHash = SHA256()
      }
    }
    if ordinal > pageStartOrdinal {
      indexes.append(PageIndex(firstOrdinal: pageStartOrdinal, endOrdinal: ordinal,
        byteOffset: pageStartByte, byteCount: pageBytes, sha256: hex(pageHash.finalize()),
        issueFrameCount: pageIssueFrames, totalIssueObservations: pageIssueObservations,
        issueFrameCounts: pageCodes, qualityAssessedFrames: qualityFrames))
    }
    guard totalBytes == expectedByteCount,
      ordinal == receipt.frameLedgerRecordCount,
      ordinal == receipt.sourceSnapshot.frameCount,
      hex(ledgerHash.finalize()) == expectedSHA256 else {
      throw DVIngestError.invalidEvidence("tape evidence ledger hash, size, or record count mismatch")
    }
    guard totals.count == receipt.issueCounts.count, receipt.issueCounts.allSatisfy({ item in
      totals[item.code]?.frames == item.affectedFrameCount && totals[item.code]?.observations == item.totalObservedCount
    }) else { throw DVIngestError.invalidEvidence("tape map summary disagrees with verified frame ledger") }
    return indexes
  }

  private static func validate(_ receipt: DVTapeEvidenceMapExporter.Receipt) throws {
    let snapshot = receipt.sourceSnapshot
    try snapshot.validate()
    guard [1, 2].contains(receipt.schemaVersion), receipt.schemaVersion == snapshot.schemaVersion, receipt.completionState == "complete",
      receipt.frameLedgerFile == DVTapeEvidenceMapExporter.frameLedgerFileName,
      receipt.frameLedgerRecordCount == snapshot.frameCount,
      receipt.coveredFirstFrameOrdinal == 0,
      receipt.coveredEndFrameOrdinalExclusive == snapshot.frameCount,
      receipt.coveredSourceByteOffset == 0,
      receipt.coveredSourceByteEndExclusive == snapshot.verifiedByteCount,
      receipt.uncoveredSourceByteCount == snapshot.sourceByteCount - snapshot.verifiedByteCount,
      isSHA256(snapshot.sourceSHA256), isSHA256(receipt.frameLedgerSHA256),
      (receipt.frameLedgerByteCount > 0 || snapshot.frameCount == 0) else {
      throw DVIngestError.invalidEvidence("tape evidence completion marker fields are invalid")
    }
    let issueCodes = receipt.issueCounts.map(\.code)
    guard Set(issueCodes).count == issueCodes.count else {
      throw DVIngestError.invalidEvidence("tape evidence issue summaries contain duplicates")
    }
  }

  private static func validate(
    _ record: DVTapeEvidenceMapExporter.FrameRecord,
    ordinal: UInt64,
    receipt: DVTapeEvidenceMapExporter.Receipt
  ) throws {
    let boundary = record.boundaryEvidence
    let snapshot = receipt.sourceSnapshot
    let identity = try snapshot.frame(ordinal)
    let offset = identity.byteOffset
    let end = try add(offset, UInt64(identity.byteCount), "tape evidence frame end")
    guard snapshot.schemaVersion == 1 ? record.sourceFrameIdentity == nil : record.sourceFrameIdentity == identity else {
      throw DVIngestError.invalidEvidence("frame-to-epoch binding differs from source snapshot")
    }
    guard record.schemaVersion == 1,
      boundary.schemaVersion == 1,
      boundary.frameOrdinal == ordinal,
      boundary.frameSourceByteOffset == offset,
      boundary.frameByteCount == identity.byteCount,
      boundary.videoSystem == identity.system,
      isSHA256(boundary.frameSHA256), end <= snapshot.sourceByteCount,
      record.metadataExtentCount == (identity.byteCount == 120_000 ? 1_500 : 1_800),
      record.rawSubcode.extentByteCount == 80 else {
      throw DVIngestError.invalidEvidence("tape evidence frame identity, bounds, or schema mismatch")
    }
    if let timeline = record.timeline {
      guard timeline.point.timecodeFrame.map({ (0..<2_592_000).contains($0) }) ?? true,
        timeline.point.formatFingerprint.count <= 256,
        timeline.point.formatFingerprint.allSatisfy({ $0.count <= 256 }),
        timeline.point.timecodeLabel.map({ $0.count == 11 }) ?? true,
        timeline.point.recordedDate.map({ $0.count == 8 }) ?? true,
        Set(timeline.changes).count == timeline.changes.count,
        timeline.changes.allSatisfy({ [.timecodeTransition, .recordedDateTransition, .formatTransition].contains($0) }) else {
        throw DVIngestError.invalidEvidence("invalid recorded timeline evidence")
      }
    }
    if let quality = record.quality {
      let sequences = identity.byteCount / 12_000
      guard quality.version == 1, quality.videoStatusBySequence.count == sequences,
        quality.audioErrorsBySequence.count == sequences,
        quality.videoStatusBySequence.allSatisfy({ (0...135).contains($0) }),
        quality.audioErrorsBySequence.allSatisfy({ (0...432).contains($0) }),
        (0...5184).contains(quality.audioSamplesExamined),
        (0...792).contains(quality.invalidMetadataValues),
        (0...792).contains(quality.conflictingMetadataValues) else {
        throw DVIngestError.invalidEvidence("invalid per-sequence quality evidence")
      }
    }
    let issueCodes = record.issues.map(\.code)
    guard Set(issueCodes).count == issueCodes.count, record.issues.allSatisfy({ $0.observedCount > 0 }) else {
      throw DVIngestError.invalidEvidence("tape evidence frame contains duplicate issue codes")
    }
    try validate(boundary.vauxSource, frameStart: offset, frameEnd: end)
    try validate(boundary.vauxSourceControl, frameStart: offset, frameEnd: end)
    try validate(record.rawSubcode.titleTimecodePacks, frameStart: offset, frameEnd: end)
  }

  private static func validate(
    _ set: DVBoundaryEvidence.PackSet,
    frameStart: UInt64,
    frameEnd: UInt64
  ) throws {
    var offsets = Set<UInt64>()
    for value in set.uniqueRawValues {
      guard value.rawBytes.count == 5 else {
        throw DVIngestError.invalidEvidence("tape evidence raw pack size is invalid")
      }
      for offset in value.observationSourceByteOffsets {
        guard offsets.insert(offset).inserted,
          offset >= frameStart,
          try add(offset, 5, "raw pack end") <= frameEnd else {
          throw DVIngestError.invalidEvidence("tape evidence raw pack offset is duplicate or out of range")
        }
      }
    }
  }

  private static func validate(
    _ set: DVTapeEvidenceMapExporter.RawPackSet,
    frameStart: UInt64,
    frameEnd: UInt64
  ) throws {
    var offsets = Set<UInt64>()
    for value in set.uniqueRawValues {
      guard value.rawBytes.count == 5 else {
        throw DVIngestError.invalidEvidence("tape evidence subcode pack size is invalid")
      }
      for offset in value.observationSourceByteOffsets {
        guard offsets.insert(offset).inserted,
          offset >= frameStart,
          try add(offset, 5, "subcode pack end") <= frameEnd else {
          throw DVIngestError.invalidEvidence("tape evidence subcode offset is duplicate or out of range")
        }
      }
    }
  }

  private static func scanLines(
    fd: Int32,
    maximumLineBytes: Int,
    _ body: (Data, Data) throws -> Void
  ) throws -> UInt64 {
    var line = Data()
    line.reserveCapacity(16_384)
    var total: UInt64 = 0
    while true {
      try Task.checkCancellation()
      var buffer = Data(count: 65_536)
      let amount: Int = try buffer.withUnsafeMutableBytes { bytes in
        let value = Darwin.read(fd, bytes.baseAddress!, bytes.count)
        if value < 0 { throw DVIngestError.fileOperation("read tape evidence ledger", errno) }
        return value
      }
      if amount == 0 { break }
      buffer.removeSubrange(amount..<buffer.count)
      total = try add(total, UInt64(amount), "tape evidence ledger byte count")
      for byte in buffer {
        line.append(byte)
        guard line.count <= maximumLineBytes else {
          throw DVIngestError.invalidEvidence("tape evidence ledger line exceeds bounded size")
        }
        if byte == 10 {
          guard line.count > 1 else {
            throw DVIngestError.invalidEvidence("tape evidence ledger contains an empty record")
          }
          var content = line
          content.removeLast()
          try body(content, line)
          line.removeAll(keepingCapacity: true)
        }
      }
    }
    guard line.isEmpty else {
      throw DVIngestError.invalidEvidence("tape evidence ledger final record is incomplete")
    }
    return total
  }

  private static func preadExactly(fd: Int32, offset: UInt64, count: Int) throws -> Data {
    guard offset <= UInt64(Int64.max) else {
      throw DVIngestError.invalidEvidence("tape evidence page offset exceeds platform bounds")
    }
    var data = Data(count: count)
    var filled = 0
    while filled < count {
      try Task.checkCancellation()
      let amount: Int = try data.withUnsafeMutableBytes { bytes in
        let value = Darwin.pread(fd, bytes.baseAddress!.advanced(by: filled), count - filled,
          off_t(offset) + off_t(filled))
        if value < 0 { throw DVIngestError.fileOperation("read tape evidence page", errno) }
        return value
      }
      guard amount > 0 else {
        throw DVIngestError.invalidEvidence("tape evidence page is truncated")
      }
      filled += amount
    }
    return data
  }

  private static func readRegularFile(
    directoryFD: Int32, name: String, maximumByteCount: UInt64
  ) throws -> (data: Data, status: stat) {
    let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open tape evidence metadata", errno) }
    defer { Darwin.close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0, UInt64(status.st_size) <= maximumByteCount,
      status.st_size <= Int.max else {
      throw DVIngestError.invalidEvidence("tape evidence metadata is not a bounded regular file")
    }
    let data = try preadExactly(fd: fd, offset: 0, count: Int(status.st_size))
    return (data, status)
  }

  private static func sameIdentityAndMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
      && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func multiply(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
