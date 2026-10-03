// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Persists source-bound, descriptive DV frame evidence without asserting tape
/// identity, source quality, position semantics, repair, deletion or merge.
public enum DVTapeEvidenceMapExporter {
  public static let frameLedgerFileName = "frames.ndjson"
  public static let intentFileName = "map-intent.json"
  public static let completionMarkerName = "map.json"

  public enum ByteIntegrityClassification: String, Codable, Equatable, Sendable {
    case sourceRereadVerified = "source_reread_verified"
    case sourceAndVerificationReportHashBound = "source_and_verification_report_hash_bound"
  }

  public enum AcquisitionReportClassification: String, Codable, Equatable, Sendable {
    case unknownNoVerificationReport = "unknown_no_verification_report"
    case unknownUnacknowledgedOrLegacyReport = "unknown_unacknowledged_or_legacy_verification_report"
    case verificationReportObservesKnownDefects = "verification_report_observes_known_defects"
    case verificationReportObservesNoKnownDefects = "verification_report_observes_no_known_defects"
  }

  public enum IssueCode: String, Codable, CaseIterable, Equatable, Sendable {
    case nonzeroVideoSTA = "nonzero_video_sta_observed"
    case audioRateAbsent = "audio_rate_metadata_absent"
    case audioRateMalformed = "audio_rate_metadata_malformed"
    case audioRateConflicting = "audio_rate_metadata_conflicting"
    case vauxSourceAbsent = "vaux_source_pack_absent"
    case vauxSourceMultiple = "multiple_raw_vaux_source_values"
    case vauxSourceControlAbsent = "vaux_source_control_pack_absent"
    case vauxSourceControlMultiple = "multiple_raw_vaux_source_control_values"
    case titleTimecodeAbsent = "title_timecode_pack_absent"
    case titleTimecodeMultiple = "multiple_raw_title_timecode_values"
    case audioErrorSentinels = "active_audio_error_sentinels"
    case invalidMetadata = "invalid_metadata_values"
    case conflictingMetadata = "conflicting_metadata_values"
    case timecodeTransition = "recorded_timecode_transition"
    case recordedDateTransition = "recorded_date_transition"
    case formatTransition = "recorded_format_transition"
  }

  public struct RawPackValue: Codable, Equatable, Sendable {
    public let rawBytes: [UInt8]
    public let observationSourceByteOffsets: [UInt64]

    private enum CodingKeys: String, CodingKey {
      case rawBytes = "raw_bytes"
      case observationSourceByteOffsets = "observation_source_byte_offsets"
    }
  }

  public struct RawPackSet: Codable, Equatable, Sendable {
    public let packType: UInt8
    public let classification: DVBoundaryEvidence.RawValueSetClassification
    public let uniqueRawValues: [RawPackValue]

    private enum CodingKeys: String, CodingKey {
      case packType = "pack_type"
      case classification
      case uniqueRawValues = "unique_raw_values"
    }
  }
  public struct RawSubcodeEvidence: Codable, Equatable, Sendable {
    public let extentByteCount: Int
    public let extentSourceByteOffsets: [UInt64]
    public let concatenatedExtentSHA256: String
    public let titleTimecodePacks: RawPackSet
    public let positionSemantics: String

    private enum CodingKeys: String, CodingKey {
      case extentByteCount = "extent_byte_count"
      case extentSourceByteOffsets = "extent_source_byte_offsets"
      case concatenatedExtentSHA256 = "concatenated_extent_sha256"
      case titleTimecodePacks = "title_timecode_packs"
      case positionSemantics = "position_semantics"
    }
  }

  public struct FrameIssue: Codable, Equatable, Sendable {
    public let code: IssueCode
    public let observedCount: UInt64
    public let evidenceMeaning: String

    private enum CodingKeys: String, CodingKey {
      case code
      case observedCount = "observed_count"
      case evidenceMeaning = "evidence_meaning"
    }
  }

  public struct FrameRecord: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let boundaryEvidence: DVBoundaryEvidence
    public let metadataExtentCount: Int
    public let rawSubcode: RawSubcodeEvidence
    public let issues: [FrameIssue]
    public let repairAuthority: String
    /// Optional addition: old immutable maps remain readable, but unassessed.
    public var quality: DVFrameForensics.Summary? = nil
    public var timeline: DVFrameTimelineEvidence? = nil

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case boundaryEvidence = "boundary_evidence"
      case metadataExtentCount = "metadata_extent_count"
      case rawSubcode = "raw_subcode"
      case issues
      case repairAuthority = "repair_authority"
      case quality
      case timeline
    }
  }

  public struct IssueCount: Codable, Equatable, Sendable {
    public let code: IssueCode
    public let affectedFrameCount: UInt64
    public let totalObservedCount: UInt64

    private enum CodingKeys: String, CodingKey {
      case code
      case affectedFrameCount = "affected_frame_count"
      case totalObservedCount = "total_observed_count"
    }
  }

  /// Exact provenance copied from a hash-bound `verification.json`. The map
  /// does not independently reread the raw record file or journal.
  public struct ArchiveReportProvenance: Codable, Equatable, Sendable {
    public let verificationFileSHA256: String
    public let verificationFileByteCount: UInt64
    public let rawRecordSHA256: String
    public let rawRecordCount: UInt64
    public let rawRecordBytes: UInt64
    public let journalSHA256: String
    public let frameManifestSHA256: String
    public let frameManifestBytes: UInt64
    public let hostRingDrops: UInt64
    public let oversizedPackets: UInt64
    public let knownDroppedPackets: UInt64
    public let CIPDiscontinuities: UInt64
    public let rawTransportGapEvents: UInt64
    public let rejectedPackets: UInt64
    public let incompleteFrames: UInt64
    public let finalAcknowledgementConfirmed: Bool
    public let legacyStoppedSnapshotUsed: Bool
    public let evidenceScope: String

    private enum CodingKeys: String, CodingKey {
      case verificationFileSHA256 = "verification_file_sha256"
      case verificationFileByteCount = "verification_file_byte_count"
      case rawRecordSHA256 = "raw_record_sha256"
      case rawRecordCount = "raw_record_count"
      case rawRecordBytes = "raw_record_bytes"
      case journalSHA256 = "journal_sha256"
      case frameManifestSHA256 = "frame_manifest_sha256"
      case frameManifestBytes = "frame_manifest_bytes"
      case hostRingDrops = "host_ring_drops"
      case oversizedPackets = "oversized_packets"
      case knownDroppedPackets = "known_dropped_packets"
      case CIPDiscontinuities = "cip_discontinuities"
      case rawTransportGapEvents = "raw_transport_gap_events"
      case rejectedPackets = "rejected_packets"
      case incompleteFrames = "incomplete_frames"
      case finalAcknowledgementConfirmed = "final_acknowledgement_confirmed"
      case legacyStoppedSnapshotUsed = "legacy_stopped_snapshot_used"
      case evidenceScope = "evidence_scope"
    }
  }

  public struct Receipt: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let completionState: String
    public let sourceSnapshot: DVReviewedRangeExporter.Snapshot
    public let coveredFirstFrameOrdinal: UInt64
    public let coveredEndFrameOrdinalExclusive: UInt64
    public let coveredSourceByteOffset: UInt64
    public let coveredSourceByteEndExclusive: UInt64
    public let uncoveredSourceByteCount: UInt64
    public let frameLedgerFile: String
    public let frameLedgerSHA256: String
    public let frameLedgerByteCount: UInt64
    public let frameLedgerRecordCount: UInt64
    public let issueCounts: [IssueCount]
    public let byteIntegrity: ByteIntegrityClassification
    public let acquisitionReport: AcquisitionReportClassification
    public let archiveReportProvenance: ArchiveReportProvenance?
    public let tapeIdentity: String
    public let sourceQuality: String
    public let positionAuthority: String
    public let continuityAuthority: String
    public let repairAuthority: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case completionState = "completion_state"
      case sourceSnapshot = "source_snapshot"
      case coveredFirstFrameOrdinal = "covered_first_frame_ordinal"
      case coveredEndFrameOrdinalExclusive = "covered_end_frame_ordinal_exclusive"
      case coveredSourceByteOffset = "covered_source_byte_offset"
      case coveredSourceByteEndExclusive = "covered_source_byte_end_exclusive"
      case uncoveredSourceByteCount = "uncovered_source_byte_count"
      case frameLedgerFile = "frame_ledger_file"
      case frameLedgerSHA256 = "frame_ledger_sha256"
      case frameLedgerByteCount = "frame_ledger_byte_count"
      case frameLedgerRecordCount = "frame_ledger_record_count"
      case issueCounts = "issue_counts"
      case byteIntegrity = "byte_integrity"
      case acquisitionReport = "acquisition_report"
      case archiveReportProvenance = "archive_report_provenance"
      case tapeIdentity = "tape_identity"
      case sourceQuality = "source_quality"
      case positionAuthority = "position_authority"
      case continuityAuthority = "continuity_authority"
      case repairAuthority = "repair_authority"
    }
  }

  /// Creates an immutable evidence directory. `archiveVerification` is optional
  /// and must name a bounded regular JSON file whose current schema, native-DV
  /// hash and sizes bind it to `source`. Its raw counters remain report facts.
  public static func create(
    source: URL,
    archiveVerification: URL? = nil,
    destination: URL
  ) throws -> Receipt {
    try createImplementation(
      source: source, archiveVerification: archiveVerification,
      destination: destination, beforeCommit: {})
  }

  /// Deterministic filesystem-race seam. Production callers use `create`.
  static func createForTesting(
    source: URL,
    archiveVerification: URL? = nil,
    destination: URL,
    beforeCommit: () throws -> Void
  ) throws -> Receipt {
    try createImplementation(
      source: source, archiveVerification: archiveVerification,
      destination: destination, beforeCommit: beforeCommit)
  }

  private static func createImplementation(
    source: URL,
    archiveVerification: URL?,
    destination: URL,
    beforeCommit: () throws -> Void
  ) throws -> Receipt {
    try Task.checkCancellation()
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    let report = try archiveVerification.map { try readVerification($0, snapshot: snapshot) }

    let sourceReader = try RegularInput(source, maximumByteCount: nil)
    defer { sourceReader.close() }
    guard sourceReader.byteCount == snapshot.sourceByteCount else {
      throw DVIngestError.invalidEvidence("tape map source size changed after inspection")
    }
    let directory = try EvidenceDirectory.create(destination)
    defer { directory.close() }
    let intent = Intent(
      schemaVersion: 1,
      state: "incomplete_until_map_json_is_published",
      sourceSnapshot: snapshot,
      archiveVerificationSHA256: report?.provenance.verificationFileSHA256,
      frameLedgerFile: frameLedgerFileName,
      completionMarker: completionMarkerName)
    try directory.writeExclusive(
      named: intentFileName, data: try encode(intent) + Data([10]), synchronize: true)
    try directory.synchronize()

    let ledgerPartial = frameLedgerFileName + ".partial"
    let ledger = try directory.makeExclusiveWriter(named: ledgerPartial)
    var ledgerClosed = false
    defer { if !ledgerClosed { try? ledger.close() } }
    var sourceHash = SHA256()
    var ledgerHash = SHA256()
    var ledgerBytes: UInt64 = 0
    var issueSummary: [IssueCode: (frames: UInt64, observations: UInt64)] = [:]

    var previousTimeline: DVFrameTimelineEvidence.Point?
    for ordinal in 0..<snapshot.frameCount {
      try Task.checkCancellation()
      let frame = try sourceReader.readExactly(snapshot.frameByteCount)
      sourceHash.update(data: frame)
      let byteOffset = try multiply(ordinal, UInt64(snapshot.frameByteCount), "tape map frame offset")
      let inventory = try DVMetadataInventory.inspect(
        frame: frame, ordinal: ordinal, byteOffset: byteOffset)
      let boundary = try DVBoundaryEvidence.inspect(
        frame: frame, ordinal: ordinal, sourceByteOffset: byteOffset)
      let subcode = rawSubcodeEvidence(inventory)
      let forensics = DVFrameForensics.inspectValidated(frame: frame, inventory: inventory)
      let quality = forensics.summary
      let point = DVFrameTimelineEvidence.inspect(inventory, report: forensics.semantics)
      let changes = DVFrameTimelineEvidence.changes(from: previousTimeline, to: point)
      let timeline = DVFrameTimelineEvidence(point: point, changes: changes)
      previousTimeline = point
      var issues = frameIssues(boundary: boundary, titleTimecode: subcode.titleTimecodePacks)
      for code in changes {
        issues.append(FrameIssue(code: code, observedCount: 1,
          evidenceMeaning: "Recorded label or format transition between adjacent source ordinals, including becoming known/unknown; not a missing-frame count or transport defect"))
      }
      let extra: [(IssueCode, Int, String)] = [
        (.audioErrorSentinels, quality.audioErrorsBySequence.reduce(0, +), "Error sentinel in a declared active IEC audio sample; not a raw packet-loss count"),
        (.invalidMetadata, quality.invalidMetadataValues, "Raw metadata values rejected by format-specific validation; not proof of lost content"),
        (.conflictingMetadata, quality.conflictingMetadataValues, "Conflicting metadata values retained without majority selection")]
      for (code, count, meaning) in extra where count > 0 {
        issues.append(FrameIssue(code: code, observedCount: UInt64(count), evidenceMeaning: meaning))
      }
      for issue in issues {
        let existing = issueSummary[issue.code] ?? (0, 0)
        issueSummary[issue.code] = (
          try add(existing.frames, 1, "issue frame count"),
          try add(existing.observations, issue.observedCount, "issue observation count"))
      }
      let record = FrameRecord(
        schemaVersion: 1,
        boundaryEvidence: boundary,
        metadataExtentCount: inventory.extents.count,
        rawSubcode: subcode,
        issues: issues,
        repairAuthority:
          "descriptive_observation_only; no_delete_repair_alignment_or_merge_authority", quality: quality, timeline: timeline)
      let line = try encode(record) + Data([10])
      try ledger.write(contentsOf: line)
      ledgerHash.update(data: line)
      ledgerBytes = try add(ledgerBytes, UInt64(line.count), "frame ledger byte count")
    }
    guard try sourceReader.isAtEOF() else {
      throw DVIngestError.invalidEvidence("tape map source grew during scan")
    }
    let observedSourceSHA = hex(sourceHash.finalize())
    try sourceReader.requireStableAndCurrentPath(source)
    guard observedSourceSHA == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("tape map source changed after inspection")
    }
    try ledger.synchronize()
    try ledger.close()
    ledgerClosed = true

    try sourceReader.rewind()
    let sourceReread = try sourceReader.hashToEOF()
    try sourceReader.requireStableAndCurrentPath(source)
    guard sourceReread.bytes == snapshot.sourceByteCount,
      sourceReread.sha256 == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("tape map source reread mismatch")
    }
    let ledgerSHA = hex(ledgerHash.finalize())
    let ledgerReread = try directory.hashRegularFile(named: ledgerPartial)
    try sourceReader.requireStableAndCurrentPath(source)
    guard ledgerReread.bytes == ledgerBytes, ledgerReread.sha256 == ledgerSHA else {
      throw DVIngestError.invalidEvidence("tape map frame ledger reread mismatch")
    }

    let issueCounts = issueSummary.keys.sorted { $0.rawValue < $1.rawValue }.map { code in
      let count = issueSummary[code]!
      return IssueCount(
        code: code, affectedFrameCount: count.frames,
        totalObservedCount: count.observations)
    }
    let acquisition: AcquisitionReportClassification
    if let verification = report?.verification {
      if hasReportedAcquisitionDefects(verification) {
        acquisition = .verificationReportObservesKnownDefects
      } else if !verification.finalAcknowledgementConfirmed
        || verification.legacyStoppedSnapshotUsed {
        acquisition = .unknownUnacknowledgedOrLegacyReport
      } else {
        acquisition = .verificationReportObservesNoKnownDefects
      }
    } else {
      acquisition = .unknownNoVerificationReport
    }
    let receipt = Receipt(
      schemaVersion: 1,
      completionState: "complete",
      sourceSnapshot: snapshot,
      coveredFirstFrameOrdinal: 0,
      coveredEndFrameOrdinalExclusive: snapshot.frameCount,
      coveredSourceByteOffset: 0,
      coveredSourceByteEndExclusive: snapshot.sourceByteCount,
      uncoveredSourceByteCount: 0,
      frameLedgerFile: frameLedgerFileName,
      frameLedgerSHA256: ledgerSHA,
      frameLedgerByteCount: ledgerBytes,
      frameLedgerRecordCount: snapshot.frameCount,
      issueCounts: issueCounts,
      byteIntegrity: report == nil
        ? .sourceRereadVerified : .sourceAndVerificationReportHashBound,
      acquisitionReport: acquisition,
      archiveReportProvenance: report?.provenance,
      tapeIdentity: "unknown_not_established_by_dv_bytes_or_verification_report",
      sourceQuality:
        "unknown; complete DIF structure, zero STA, or zero reported capture defects does not prove pristine tape content",
      positionAuthority:
        "raw_subcode_and_title_timecode_observations_only; ATN_ETN_not_decoded; missing_conflicting_wrap_or_reset_values_never_align_or_seek",
      continuityAuthority:
        "ATN_ETN_or_timecode_gaps_never_imply_lost_packets; optional acquisition counters are verification_report_observations_only",
      repairAuthority:
        "none; map does not authorize deletion, replacement, automatic recapture, alignment or merge")

    try beforeCommit()
    try Task.checkCancellation()
    try directory.requireCurrentDestinationPath()
    let markerPartial = completionMarkerName + ".partial"
    let markerBytes = try encode(receipt) + Data([10])
    let markerSHA = hex(SHA256.hash(data: markerBytes))
    try directory.writeExclusive(named: markerPartial, data: markerBytes, synchronize: true)
    try directory.promoteExclusive(from: ledgerPartial, to: frameLedgerFileName,
      expectedBytes: ledgerBytes, expectedSHA256: ledgerSHA)
    try directory.synchronize()
    try directory.requireCurrentDestinationPath()
    try directory.promoteExclusive(from: markerPartial, to: completionMarkerName,
      expectedBytes: UInt64(markerBytes.count), expectedSHA256: markerSHA)
    do {
      try directory.synchronize()
    } catch {
      directory.withdrawCompletionMarkerBestEffort(
        from: completionMarkerName, to: markerPartial)
      throw error
    }
    return receipt
  }

  private struct Intent: Codable {
    let schemaVersion: UInt16
    let state: String
    let sourceSnapshot: DVReviewedRangeExporter.Snapshot
    let archiveVerificationSHA256: String?
    let frameLedgerFile: String
    let completionMarker: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case state
      case sourceSnapshot = "source_snapshot"
      case archiveVerificationSHA256 = "archive_verification_sha256"
      case frameLedgerFile = "frame_ledger_file"
      case completionMarker = "completion_marker"
    }
  }

  private struct BoundVerification {
    let verification: DVIngestVerification
    let provenance: ArchiveReportProvenance
  }

  private static func readVerification(
    _ url: URL,
    snapshot: DVReviewedRangeExporter.Snapshot
  ) throws -> BoundVerification {
    let input = try RegularInput(url, maximumByteCount: 1_048_576)
    defer { input.close() }
    let data = try input.readExactly(Int(input.byteCount))
    guard try input.isAtEOF() else {
      throw DVIngestError.invalidEvidence("archive verification grew during read")
    }
    try input.requireStableAndCurrentPath(url)
    let verificationSHA = hex(SHA256.hash(data: data))
    let value: DVIngestVerification
    do {
      value = try JSONDecoder().decode(DVIngestVerification.self, from: data)
    } catch {
      throw DVIngestError.invalidEvidence("archive verification JSON or schema fields are invalid")
    }
    let finalStatus = Data(base64Encoded: value.finalStatusWireBase64)
    guard value.schemaVersion == 1,
      value.captureFile == "capture.dv",
      value.frameManifestFile == "frames.ndjson",
      value.verificationFile == "verification.json",
      value.nativeDVSHA256 == snapshot.sourceSHA256,
      value.completeDVFrames == snapshot.frameCount,
      value.dvBytes == snapshot.sourceByteCount,
      value.integritySHA256Verified,
      value.nativeDVRereadVerified,
      value.rawRecordCount > 0,
      value.rawRecordBytes > 0,
      value.frameManifestBytes > 0,
      isSHA256(value.rawRecordSHA256),
      isSHA256(value.journalSHA256),
      isSHA256(value.frameManifestSHA256),
      finalStatus?.count == 128,
      value.knownDroppedPackets >= value.oversizedPackets,
      value.hostRingDrops == value.knownDroppedPackets - value.oversizedPackets else {
      throw DVIngestError.invalidEvidence(
        "archive verification is not strictly bound to this native DV source")
    }
    let provenance = ArchiveReportProvenance(
      verificationFileSHA256: verificationSHA,
      verificationFileByteCount: input.byteCount,
      rawRecordSHA256: value.rawRecordSHA256,
      rawRecordCount: value.rawRecordCount,
      rawRecordBytes: value.rawRecordBytes,
      journalSHA256: value.journalSHA256,
      frameManifestSHA256: value.frameManifestSHA256,
      frameManifestBytes: value.frameManifestBytes,
      hostRingDrops: value.hostRingDrops,
      oversizedPackets: value.oversizedPackets,
      knownDroppedPackets: value.knownDroppedPackets,
      CIPDiscontinuities: value.CIPDiscontinuities,
      rawTransportGapEvents: value.rawTransportGapEvents,
      rejectedPackets: value.rejectedPackets,
      incompleteFrames: value.incompleteFrames,
      finalAcknowledgementConfirmed: value.finalAcknowledgementConfirmed,
      legacyStoppedSnapshotUsed: value.legacyStoppedSnapshotUsed,
      evidenceScope:
        "hash_bound_verification_report_observation; raw_records_journal_and_manifest_not_independently_reread_by_tape_map")
    return BoundVerification(verification: value, provenance: provenance)
  }

  private static func hasReportedAcquisitionDefects(_ value: DVIngestVerification) -> Bool {
    value.knownDroppedPackets != 0
      || value.CIPDiscontinuities != 0
      || value.rawTransportGapEvents != 0
      || value.rejectedPackets != 0
      || value.incompleteFrames != 0
  }

  static func rawSubcodeEvidence(_ inventory: DVMetadataInventory) -> RawSubcodeEvidence {
    let subcode = inventory.extents.filter { $0.section == 1 }
    var digest = SHA256()
    var titleValues: [[UInt8]: [UInt64]] = [:]
    for extent in subcode {
      digest.update(data: extent.bytes)
      for slot in stride(from: 6, through: 46, by: 8) {
        let raw = Array(extent.bytes[slot..<(slot + 5)])
        if raw[0] == 0x13 {
          titleValues[raw, default: []].append(extent.sourceByteOffset + UInt64(slot))
        }
      }
    }
    return RawSubcodeEvidence(
      extentByteCount: 80,
      extentSourceByteOffsets: subcode.map(\.sourceByteOffset),
      concatenatedExtentSHA256: hex(digest.finalize()),
      titleTimecodePacks: rawPackSet(type: 0x13, values: titleValues),
      positionSemantics:
        "raw_subcode_coverage_only; ATN_ETN_fragments_uninterpreted_and_not_alignment_authority")
  }

  private static func rawPackSet(
    type: UInt8,
    values: [[UInt8]: [UInt64]]
  ) -> RawPackSet {
    let unique = values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { raw in
      RawPackValue(
        rawBytes: raw,
        observationSourceByteOffsets: values[raw]!.sorted())
    }
    let classification: DVBoundaryEvidence.RawValueSetClassification
    switch unique.count {
    case 0: classification = .notObserved
    case 1: classification = .singleUniqueRawValueObserved
    default: classification = .multipleUniqueRawValuesObserved
    }
    return RawPackSet(packType: type, classification: classification, uniqueRawValues: unique)
  }

  static func frameIssues(
    boundary: DVBoundaryEvidence,
    titleTimecode: RawPackSet
  ) -> [FrameIssue] {
    var issues: [FrameIssue] = []
    func append(_ code: IssueCode, _ count: UInt64, _ meaning: String) {
      issues.append(FrameIssue(code: code, observedCount: count, evidenceMeaning: meaning))
    }
    if boundary.nonzeroVideoSTABlockCount > 0 {
      append(
        .nonzeroVideoSTA, UInt64(boundary.nonzeroVideoSTABlockCount),
        "source-encoded nonzero STA observations; source damage and decoded impact remain unproven")
    }
    switch boundary.audioSampleRate {
    case .absent:
      append(.audioRateAbsent, 1, "no valid AAUX source-rate observation in this frame")
    case .malformed:
      append(.audioRateMalformed, 1, "AAUX source-rate bits were not a recognized rate")
    case .conflicting:
      append(.audioRateConflicting, 1, "multiple recognized AAUX source rates were observed")
    case .known32000Hz, .known44100Hz, .known48000Hz: break
    }
    appendPackIssues(
      boundary.vauxSource.classification,
      absent: .vauxSourceAbsent, multiple: .vauxSourceMultiple,
      uniqueCount: boundary.vauxSource.uniqueRawValues.count, into: &issues)
    appendPackIssues(
      boundary.vauxSourceControl.classification,
      absent: .vauxSourceControlAbsent, multiple: .vauxSourceControlMultiple,
      uniqueCount: boundary.vauxSourceControl.uniqueRawValues.count, into: &issues)
    appendPackIssues(
      titleTimecode.classification,
      absent: .titleTimecodeAbsent, multiple: .titleTimecodeMultiple,
      uniqueCount: titleTimecode.uniqueRawValues.count, into: &issues)
    return issues.sorted { $0.code.rawValue < $1.code.rawValue }
  }

  private static func appendPackIssues(
    _ classification: DVBoundaryEvidence.RawValueSetClassification,
    absent: IssueCode,
    multiple: IssueCode,
    uniqueCount: Int,
    into issues: inout [FrameIssue]
  ) {
    switch classification {
    case .notObserved:
      issues.append(FrameIssue(
        code: absent, observedCount: 1,
        evidenceMeaning: "pack not observed; absence is not proof of content loss or tape damage"))
    case .multipleUniqueRawValuesObserved:
      issues.append(FrameIssue(
        code: multiple, observedCount: UInt64(uniqueCount),
        evidenceMeaning: "multiple exact raw values observed; no value is selected as authoritative"))
    case .singleUniqueRawValueObserved: break
    }
  }

  private final class RegularInput {
    let fd: Int32
    let initialStatus: stat
    let byteCount: UInt64
    private var closed = false

    init(_ url: URL, maximumByteCount: UInt64?) throws {
      fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw DVIngestError.fileOperation("open tape map input", errno) }
      var status = stat()
      guard fstat(fd, &status) == 0 else {
        let code = errno
        Darwin.close(fd)
        throw DVIngestError.fileOperation("inspect tape map input", code)
      }
      guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
        Darwin.close(fd)
        throw DVIngestError.invalidEvidence("tape map input is not a regular file")
      }
      let size = UInt64(status.st_size)
      guard maximumByteCount.map({ size <= $0 }) ?? true else {
        Darwin.close(fd)
        throw DVIngestError.invalidEvidence("tape map metadata input exceeds bounded size")
      }
      initialStatus = status
      byteCount = size
    }

    func close() {
      if !closed { Darwin.close(fd); closed = true }
    }

    func readExactly(_ count: Int) throws -> Data {
      guard count >= 0 else { throw DVIngestError.invalidEvidence("negative tape map read refused") }
      var result = Data(count: count)
      var filled = 0
      while filled < count {
        try Task.checkCancellation()
        let amount: Int = try result.withUnsafeMutableBytes { bytes in
          let value = Darwin.read(fd, bytes.baseAddress!.advanced(by: filled), count - filled)
          if value < 0 { throw DVIngestError.fileOperation("read tape map input", errno) }
          return value
        }
        guard amount > 0 else { throw DVIngestError.invalidEvidence("tape map input is truncated") }
        filled += amount
      }
      return result
    }

    func isAtEOF() throws -> Bool {
      var byte: UInt8 = 0
      let amount = Darwin.read(fd, &byte, 1)
      guard amount >= 0 else { throw DVIngestError.fileOperation("check tape map input end", errno) }
      return amount == 0
    }

    func rewind() throws {
      guard lseek(fd, 0, SEEK_SET) == 0 else {
        throw DVIngestError.fileOperation("rewind tape map input", errno)
      }
    }

    func hashToEOF() throws -> (bytes: UInt64, sha256: String) {
      var hash = SHA256()
      var count: UInt64 = 0
      while true {
        try Task.checkCancellation()
        var buffer = Data(count: 1_048_576)
        let amount: Int = try buffer.withUnsafeMutableBytes { bytes in
          let value = Darwin.read(fd, bytes.baseAddress!, bytes.count)
          if value < 0 { throw DVIngestError.fileOperation("reread tape map input", errno) }
          return value
        }
        if amount == 0 { break }
        buffer.removeSubrange(amount..<buffer.count)
        hash.update(data: buffer)
        count = try add(count, UInt64(amount), "tape map input byte count")
      }
      return (count, hex(hash.finalize()))
    }

    func requireStableAndCurrentPath(_ url: URL) throws {
      var current = stat()
      var path = stat()
      guard fstat(fd, &current) == 0, lstat(url.path, &path) == 0 else {
        throw DVIngestError.fileOperation("reinspect tape map input", errno)
      }
      guard current.st_mode & S_IFMT == S_IFREG,
        path.st_mode & S_IFMT == S_IFREG,
        current.st_dev == initialStatus.st_dev,
        current.st_ino == initialStatus.st_ino,
        current.st_size == initialStatus.st_size,
        current.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
        current.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec,
        current.st_ctimespec.tv_sec == initialStatus.st_ctimespec.tv_sec,
        current.st_ctimespec.tv_nsec == initialStatus.st_ctimespec.tv_nsec,
        path.st_dev == initialStatus.st_dev,
        path.st_ino == initialStatus.st_ino else {
        throw DVIngestError.invalidEvidence("tape map input identity or metadata changed")
      }
    }
  }

  // Shared only by offline evidence exporters; preserves exclusive publication.
  final class EvidenceDirectory {
    let fd: Int32
    let parentFD: Int32
    let parentURL: URL
    let name: String
    let initialParentStatus: stat
    let initialDirectoryStatus: stat
    private var closed = false

    static func create(_ url: URL) throws -> EvidenceDirectory {
      let name = url.lastPathComponent
      guard !name.isEmpty, name != ".", name != ".." else {
        throw DVIngestError.invalidEvidence("tape map destination name is invalid")
      }
      let parent = Darwin.open(
        url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else {
        throw DVIngestError.fileOperation("open tape map destination parent", errno)
      }
      guard mkdirat(parent, name, 0o700) == 0 else {
        let code = errno
        Darwin.close(parent)
        if code == EEXIST { throw DVIngestError.destinationExists(url.path) }
        throw DVIngestError.fileOperation("create tape map destination", code)
      }
      let child = openat(
        parent, name, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else {
        let code = errno
        Darwin.close(parent)
        throw DVIngestError.fileOperation("open tape map destination", code)
      }
      var childStatus = stat()
      var pathStatus = stat()
      guard fstat(child, &childStatus) == 0,
        fstatat(parent, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
        let code = errno
        Darwin.close(child)
        Darwin.close(parent)
        throw DVIngestError.fileOperation("bind tape map destination", code)
      }
      guard childStatus.st_mode & S_IFMT == S_IFDIR,
        pathStatus.st_mode & S_IFMT == S_IFDIR,
        childStatus.st_dev == pathStatus.st_dev,
        childStatus.st_ino == pathStatus.st_ino else {
        Darwin.close(child)
        Darwin.close(parent)
        throw DVIngestError.invalidEvidence("tape map destination identity mismatch")
      }
      guard fsync(parent) == 0 else {
        let code = errno
        Darwin.close(child)
        Darwin.close(parent)
        throw DVIngestError.fileOperation("synchronize tape map destination parent", code)
      }
      var parentStatus = stat()
      guard fstat(parent, &parentStatus) == 0 else {
        let code = errno
        Darwin.close(child)
        Darwin.close(parent)
        throw DVIngestError.fileOperation("bind tape map destination parent", code)
      }
      return EvidenceDirectory(
        fd: child,
        parentFD: parent,
        parentURL: url.deletingLastPathComponent(),
        name: name,
        initialParentStatus: parentStatus,
        initialDirectoryStatus: childStatus)
    }

    init(
      fd: Int32,
      parentFD: Int32,
      parentURL: URL,
      name: String,
      initialParentStatus: stat,
      initialDirectoryStatus: stat
    ) {
      self.fd = fd
      self.parentFD = parentFD
      self.parentURL = parentURL
      self.name = name
      self.initialParentStatus = initialParentStatus
      self.initialDirectoryStatus = initialDirectoryStatus
    }

    func close() {
      if !closed {
        Darwin.close(fd)
        Darwin.close(parentFD)
        closed = true
      }
    }

    func makeExclusiveWriter(named name: String) throws -> FileHandle {
      let child = openat(
        fd, name, O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard child >= 0 else {
        throw DVIngestError.fileOperation("create exclusive tape map file", errno)
      }
      return FileHandle(fileDescriptor: child, closeOnDealloc: true)
    }

    func writeExclusive(named name: String, data: Data, synchronize: Bool) throws {
      let writer = try makeExclusiveWriter(named: name)
      defer { try? writer.close() }
      try writer.write(contentsOf: data)
      if synchronize { try writer.synchronize() }
      try writer.close()
    }

    func hashRegularFile(named name: String) throws -> (bytes: UInt64, sha256: String) {
      let child = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else { throw DVIngestError.fileOperation("open tape map reread", errno) }
      defer { Darwin.close(child) }
      var initial = stat()
      guard fstat(child, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
        throw DVIngestError.invalidEvidence("tape map output is not a regular file")
      }
      var digest = SHA256()
      var bytes: UInt64 = 0
      while true {
        try Task.checkCancellation()
        var buffer = Data(count: 1_048_576)
        let amount: Int = try buffer.withUnsafeMutableBytes { region in
          let value = Darwin.read(child, region.baseAddress!, region.count)
          if value < 0 { throw DVIngestError.fileOperation("reread tape map output", errno) }
          return value
        }
        if amount == 0 { break }
        buffer.removeSubrange(amount..<buffer.count)
        digest.update(data: buffer)
        bytes = try add(bytes, UInt64(amount), "tape map output byte count")
      }
      var final = stat()
      var path = stat()
      guard fstat(child, &final) == 0,
        fstatat(fd, name, &path, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw DVIngestError.fileOperation("reinspect tape map output", errno)
      }
      guard initial.st_size >= 0,
        UInt64(initial.st_size) == bytes,
        final.st_dev == initial.st_dev,
        final.st_ino == initial.st_ino,
        final.st_size == initial.st_size,
        final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
        final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
        final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
        final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
        path.st_mode & S_IFMT == S_IFREG,
        path.st_dev == initial.st_dev,
        path.st_ino == initial.st_ino else {
        throw DVIngestError.invalidEvidence("tape map output identity or size changed")
      }
      return (bytes, hex(digest.finalize()))
    }

    func promoteExclusive(
      from: String, to: String, expectedBytes: UInt64, expectedSHA256: String
    ) throws {
      try DVPortablePublication.promoteExclusive(
        directoryFD: fd, from: from, to: to,
        expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
    }

    func synchronize() throws {
      guard fsync(fd) == 0 else {
        throw DVIngestError.fileOperation("synchronize tape map directory", errno)
      }
    }

    func requireCurrentDestinationPath() throws {
      var heldParent = stat()
      var pathParent = stat()
      var heldDirectory = stat()
      var pathDirectory = stat()
      guard fstat(parentFD, &heldParent) == 0,
        lstat(parentURL.path, &pathParent) == 0,
        fstat(fd, &heldDirectory) == 0,
        fstatat(parentFD, name, &pathDirectory, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw DVIngestError.fileOperation("rebind tape map destination path", errno)
      }
      guard heldParent.st_mode & S_IFMT == S_IFDIR,
        pathParent.st_mode & S_IFMT == S_IFDIR,
        heldDirectory.st_mode & S_IFMT == S_IFDIR,
        pathDirectory.st_mode & S_IFMT == S_IFDIR,
        heldParent.st_dev == initialParentStatus.st_dev,
        heldParent.st_ino == initialParentStatus.st_ino,
        pathParent.st_dev == initialParentStatus.st_dev,
        pathParent.st_ino == initialParentStatus.st_ino,
        heldDirectory.st_dev == initialDirectoryStatus.st_dev,
        heldDirectory.st_ino == initialDirectoryStatus.st_ino,
        pathDirectory.st_dev == initialDirectoryStatus.st_dev,
        pathDirectory.st_ino == initialDirectoryStatus.st_ino else {
        throw DVIngestError.invalidEvidence(
          "tape map destination pathname no longer identifies the admitted directory")
      }
    }

    func withdrawCompletionMarkerBestEffort(from: String, to: String) {
      DVPortablePublication.withdrawCompletionMarkerBestEffort(
        directoryFD: fd, from: from, to: to)
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func multiply(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}
