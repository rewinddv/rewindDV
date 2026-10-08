// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Builds UI-ready, source-bound descriptions from a verified tape-map frame.
/// Suggestions are review actions only; they never schedule capture, control a
/// deck, choose replacement bytes, or authorize a merge.
public enum DVTapeDefectInspector {
  public struct Issue: Codable, Equatable, Sendable {
    public let code: DVTapeEvidenceMapExporter.IssueCode
    public let title: String
    public let observedCount: UInt64
    public let knownEvidence: String
    public let unknownLimit: String
    public let reviewSuggestion: String

    private enum CodingKeys: String, CodingKey {
      case code, title
      case observedCount = "observed_count"
      case knownEvidence = "known_evidence"
      case unknownLimit = "unknown_limit"
      case reviewSuggestion = "review_suggestion"
    }
  }

  public struct RawPackProvenance: Codable, Equatable, Sendable {
    public let id: String
    public let typeHex: String
    public let name: String
    public let rawHex: String
    public let sourceByteOffsets: [UInt64]
    public let interpretationStatus: String

    private enum CodingKeys: String, CodingKey {
      case id, name
      case typeHex = "type_hex"
      case rawHex = "raw_hex"
      case sourceByteOffsets = "source_byte_offsets"
      case interpretationStatus = "interpretation_status"
    }
  }

  public struct Model: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let sourceSHA256: String
    public let mapReceiptSHA256: String
    public let frameLedgerSHA256: String
    public let frameOrdinal: UInt64
    public let frameSHA256: String
    public let sourceByteOffset: UInt64
    public let sourceByteEndExclusive: UInt64
    public let issues: [Issue]
    public let rawPackProvenance: [RawPackProvenance]
    public let semanticFormat: String?
    public let semanticFormatEvidence: String?
    public let provenanceScope: String
    public let actionAuthority: String

    private enum CodingKeys: String, CodingKey {
      case issues
      case schemaVersion = "schema_version"
      case sourceSHA256 = "source_sha256"
      case mapReceiptSHA256 = "map_receipt_sha256"
      case frameLedgerSHA256 = "frame_ledger_sha256"
      case frameOrdinal = "frame_ordinal"
      case frameSHA256 = "frame_sha256"
      case sourceByteOffset = "source_byte_offset"
      case sourceByteEndExclusive = "source_byte_end_exclusive"
      case rawPackProvenance = "raw_pack_provenance"
      case semanticFormat = "semantic_format"
      case semanticFormatEvidence = "semantic_format_evidence"
      case provenanceScope = "provenance_scope"
      case actionAuthority = "action_authority"
    }
  }

  public static func make(
    binding: DVTapeEvidenceLedgerReader.Binding,
    record: DVTapeEvidenceMapExporter.FrameRecord,
    semanticReport: DVPackSemanticReport? = nil
  ) throws -> Model {
    guard binding.schemaVersion == 1 else {
      throw DVIngestError.invalidEvidence("defect inspector binding schema is unsupported")
    }
    let boundary = record.boundaryEvidence
    let snapshot = binding.mapReceipt.sourceSnapshot
    try snapshot.validate()
    let identity = try snapshot.frame(boundary.frameOrdinal)
    let offset = identity.byteOffset
    let end = try add(offset, UInt64(identity.byteCount), "inspector frame end")
    guard record.schemaVersion == 1, boundary.schemaVersion == 1,
      boundary.frameByteCount == identity.byteCount,
      boundary.frameSourceByteOffset == offset,
      boundary.frameOrdinal < snapshot.frameCount,
      end <= snapshot.sourceByteCount,
      isSHA256(snapshot.sourceSHA256), isSHA256(binding.mapReceiptSHA256),
      isSHA256(binding.mapReceipt.frameLedgerSHA256), isSHA256(boundary.frameSHA256) else {
      throw DVIngestError.invalidEvidence("defect inspector frame is not bound to the map source")
    }
    let codes = record.issues.map(\.code)
    guard Set(codes).count == codes.count else {
      throw DVIngestError.invalidEvidence("defect inspector frame has duplicate issue codes")
    }

    let rawPacks: [RawPackProvenance]
    if let semanticReport {
      guard [1, 2, 3].contains(semanticReport.schemaVersion),
        semanticReport.absoluteOffsetsKnown != false,
        semanticReport.frameOrdinal == boundary.frameOrdinal,
        semanticReport.frameByteOffset == offset,
        semanticReport.frameSHA256 == boundary.frameSHA256 else {
        throw DVIngestError.invalidEvidence("semantic report is not bound to the selected tape-map frame")
      }
      var ids = Set<String>()
      rawPacks = try semanticReport.packs.map { pack in
        guard ids.insert(pack.id).inserted else {
          throw DVIngestError.invalidEvidence("semantic report contains duplicate pack identifiers")
        }
        try validateOffsets(pack.sourceByteOffsets, frameStart: offset, frameEnd: end)
        return RawPackProvenance(
          id: pack.id, typeHex: pack.typeHex, name: pack.name,
          rawHex: pack.rawHex, sourceByteOffsets: pack.sourceByteOffsets,
          interpretationStatus: pack.status)
      }
    } else {
      var values: [RawPackProvenance] = []
      values.append(contentsOf: try provenance(
        boundary.vauxSource, label: "VAUX source", frameStart: offset, frameEnd: end))
      values.append(contentsOf: try provenance(
        boundary.vauxSourceControl, label: "VAUX source control",
        frameStart: offset, frameEnd: end))
      values.append(contentsOf: try provenance(
        record.rawSubcode.titleTimecodePacks, label: "Title timecode",
        frameStart: offset, frameEnd: end))
      rawPacks = values.sorted { $0.id < $1.id }
    }

    return Model(
      schemaVersion: 1,
      sourceSHA256: snapshot.sourceSHA256,
      mapReceiptSHA256: binding.mapReceiptSHA256,
      frameLedgerSHA256: binding.mapReceipt.frameLedgerSHA256,
      frameOrdinal: boundary.frameOrdinal,
      frameSHA256: boundary.frameSHA256,
      sourceByteOffset: offset,
      sourceByteEndExclusive: end,
      issues: record.issues.map(describe).sorted { $0.code.rawValue < $1.code.rawValue },
      rawPackProvenance: rawPacks,
      semanticFormat: semanticReport?.format,
      semanticFormatEvidence: semanticReport?.formatEvidence,
      provenanceScope: semanticReport == nil
        ? "verified_tape_map_frame; raw_VAUX_and_title_timecode_pack_provenance_available; AAUX_requires_a_separately_source_bound_semantic_report"
        : "verified_tape_map_frame_plus_exactly_frame_hash_bound_pack_semantic_report",
      actionAuthority:
        "review_only; no_hardware_command_recapture_replacement_alignment_deletion_or_merge_authority")
  }

  private static func describe(_ issue: DVTapeEvidenceMapExporter.FrameIssue) -> Issue {
    let title: String
    let unknown: String
    let suggestion: String
    switch issue.code {
    case .timecodeTransition, .recordedDateTransition, .formatTransition, .recordingSystemTransition:
      title = issue.code.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
      unknown = "A recorded label change, reset, wrap or missing value is not a transport loss or a proved recording edit. No missing-frame count is inferred."
      suggestion = "Compare this frame with the previous source ordinal and inspect both sets of original packs."
    case .audioErrorSentinels:
      title = "Active audio sample error codes"
      unknown = "An encoded error code does not locate a bus loss or prove the source of the audio defect. Padding is not counted."
      suggestion = "Inspect the exact sample bytes, channel and sample index; compare neighboring frames and retain the original."
    case .invalidMetadata:
      title = "Metadata validation warning"
      unknown = "Invalid or placeholder metadata does not establish missing picture or audio."
      suggestion = "Inspect the format-specific field interpretation and original five-byte pack."
    case .conflictingMetadata:
      title = "Metadata interpretations conflict"
      unknown = "No value wins by majority; differing metadata does not establish a transport defect."
      suggestion = "Compare all repeated pack values, their locations, and adjacent frames."
    case .nonzeroVideoSTA:
      title = "Video block status needs review"
      unknown = "The status bits do not establish tape damage, visible impact, or which replacement would be correct."
      suggestion = "Review the decoded frame and neighboring frames while retaining this original frame unchanged."
    case .audioRateAbsent:
      title = "Audio sample-rate metadata absent"
      unknown = "Missing metadata does not prove missing audio samples or a transport loss."
      suggestion = "Inspect the source audio and adjacent frame metadata; do not default the rate."
    case .audioRateMalformed:
      title = "Audio sample-rate metadata unrecognized"
      unknown = "The unrecognized code does not identify source damage or an intended sample rate."
      suggestion = "Review exact AAUX bytes through a frame-bound semantic report."
    case .audioRateConflicting:
      title = "Audio sample-rate metadata conflicts"
      unknown = "No observed value is automatically authoritative and no majority is selected."
      suggestion = "Compare each exact AAUX observation and neighboring frames."
    case .vauxSourceAbsent:
      title = "VAUX source pack absent"
      unknown = "Pack absence is not proof of lost packets, damaged tape, or missing picture content."
      suggestion = "Review the frame and neighboring raw metadata without synthesizing a value."
    case .vauxSourceMultiple:
      title = "VAUX source pack values differ"
      unknown = "The map does not choose a winning value or infer a correct replacement."
      suggestion = "Inspect every listed raw value and source offset."
    case .vauxSourceControlAbsent:
      title = "VAUX source-control pack absent"
      unknown = "Pack absence does not establish a recording boundary or content defect."
      suggestion = "Review adjacent frames and retain the unknown state."
    case .vauxSourceControlMultiple:
      title = "VAUX source-control values differ"
      unknown = "Flags cannot authorize frame deletion, alignment, or a merge."
      suggestion = "Compare the exact raw values without voting or deduplicating."
    case .titleTimecodeAbsent:
      title = "Title-timecode pack absent"
      unknown = "Missing timecode is not evidence of missing frames or packet loss."
      suggestion = "Use source ordinals and byte offsets for navigation; retain position as unknown."
    case .titleTimecodeMultiple:
      title = "Title-timecode values differ"
      unknown = "Conflicting or wrapping timecode is not exact alignment authority."
      suggestion = "Review each raw pack and neighboring ordinals without selecting a value automatically."
    }
    return Issue(
      code: issue.code, title: title, observedCount: issue.observedCount,
      knownEvidence: issue.evidenceMeaning, unknownLimit: unknown,
      reviewSuggestion: suggestion)
  }

  private static func provenance(
    _ set: DVBoundaryEvidence.PackSet,
    label: String,
    frameStart: UInt64,
    frameEnd: UInt64
  ) throws -> [RawPackProvenance] {
    try set.uniqueRawValues.map { value in
      try validateOffsets(value.observationSourceByteOffsets,
        frameStart: frameStart, frameEnd: frameEnd)
      let rawHex = value.rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
      return RawPackProvenance(
        id: "map:\(String(format: "0x%02X", set.packType)):\(rawHex.replacingOccurrences(of: " ", with: "").lowercased())",
        typeHex: String(format: "0x%02X", set.packType), name: label,
        rawHex: rawHex, sourceByteOffsets: value.observationSourceByteOffsets,
        interpretationStatus: "raw tape-map observation; not semantically selected")
    }
  }

  private static func provenance(
    _ set: DVTapeEvidenceMapExporter.RawPackSet,
    label: String,
    frameStart: UInt64,
    frameEnd: UInt64
  ) throws -> [RawPackProvenance] {
    try set.uniqueRawValues.map { value in
      try validateOffsets(value.observationSourceByteOffsets,
        frameStart: frameStart, frameEnd: frameEnd)
      let rawHex = value.rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
      return RawPackProvenance(
        id: "map:\(String(format: "0x%02X", set.packType)):\(rawHex.replacingOccurrences(of: " ", with: "").lowercased())",
        typeHex: String(format: "0x%02X", set.packType), name: label,
        rawHex: rawHex, sourceByteOffsets: value.observationSourceByteOffsets,
        interpretationStatus: "raw tape-map observation; not semantically selected")
    }
  }

  private static func validateOffsets(
    _ offsets: [UInt64], frameStart: UInt64, frameEnd: UInt64
  ) throws {
    var unique = Set<UInt64>()
    for offset in offsets {
      guard unique.insert(offset).inserted, offset >= frameStart,
        try add(offset, 5, "inspector raw pack end") <= frameEnd else {
        throw DVIngestError.invalidEvidence("inspector raw pack offset is duplicate or out of frame")
      }
    }
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
}
