// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

/// Offline, streaming derivatives. Completion is published only after all files
/// are flushed and reread. Neither report import nor export has transport authority.
public enum DVAnalysisReportExporter {
  public static let parserVersion = "rewindDV-analysis-1"
  public static let xmlNamespace = "https://mediaarea.net/dvrescue"
  public static let upstreamRevision = "5cead7a5dae4ec7ffdf24115c8e3bc6d9c05c033"
  public struct Artifact: Codable, Equatable, Sendable {
    public let name: String
    public let bytes: UInt64
    public let sha256: String
  }
  public struct Receipt: Codable, Sendable {
    public let schemaVersion: Int
    public let completion: String
    public let parser: String
    public let source: DVReviewedRangeExporter.Snapshot
    public let map: DVTapeEvidenceLedgerReader.Binding
    public let artifacts: [Artifact]
    public let frameCount: UInt64
    public let cueCount: UInt64
    public let timestampBasis: String
    public let xmlProfile: String
    public let limitations: [String]
  }
  public struct Frame: Codable, Sendable {
    public let sourceSHA256: String
    public let presentationNumerator: UInt64
    public let presentationDenominator: UInt64
    public let mapRecord: DVTapeEvidenceMapExporter.FrameRecord
    public let currentQuality: DVFrameForensics.Summary
    public let videoStatusBlocks: [DVFrameForensics.Block]
    public let audioErrorSamples: [DVFrameForensics.AudioError]
  }

  public static func export(map: DVTapeEvidenceLedgerReader, source: DVVerifiedFrameSource,
    destination: URL, progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> Receipt {
    try Task.checkCancellation()
    let binding = map.binding, snapshot = binding.mapReceipt.sourceSnapshot
    try await source.requireSnapshot(snapshot)
    guard !DVGentleRecovery.isWithin(destination, directory: map.mapDirectory) else {
      throw DVIngestError.invalidEvidence("report output must be outside the source evidence map")
    }
    let directory = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { directory.close() }
    let intent = try encode(["state": "incomplete_until_report_json", "sourceSHA256": snapshot.sourceSHA256,
      "parser": parserVersion])
    try directory.writeExclusive(named: "report-intent.json", data: intent, synchronize: true)
    try directory.synchronize()
    let names = ["analysis.json", "frames.csv", "review.vtt", "dvrescue.xml"]
    var writers: [FileHandle] = []
    defer { for writer in writers { try? writer.close() } }
    for name in names { writers.append(try directory.makeExclusiveWriter(named: name + ".partial")) }
    var writtenHashes = Array(repeating: SHA256(), count: names.count)
    var writtenBytes = Array(repeating: UInt64(0), count: names.count)
    func putData(_ index: Int, _ data: Data) throws {
      try writers[index].write(contentsOf: data)
      writtenHashes[index].update(data: data); writtenBytes[index] += UInt64(data.count)
    }
    func put(_ index: Int, _ text: String) throws { try putData(index, Data(text.utf8)) }
    try put(0, "{\"schemaVersion\":1,\"parser\":\"\(parserVersion)\",\"source\":")
    try putData(0, encode(snapshot))
    try put(0, ",\"mapReceiptSHA256\":\"\(binding.mapReceiptSHA256)\",\"frames\":[\n")
    let headings = ["source_sha256", "frame_ordinal", "source_byte_offset", "frame_bytes", "frame_sha256",
      "presentation_numerator", "presentation_denominator", "source_timecode", "recorded_date_YY_MM_DD",
      "video_sta_blocks", "active_audio_error_samples", "active_audio_samples_examined", "audio_coverage",
      "invalid_metadata_values", "conflicting_metadata_values", "map_issue_codes"]
    try put(1, csvRow(headings))
    try put(2, "WEBVTT\n\nNOTE Source SHA-256: \(snapshot.sourceSHA256)\nParser: \(parserVersion)\nFile presentation time, not tape timecode. Cues are review observations, not proof of damage.\n\n")
    try put(3, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<dvrescue xmlns=\"\(xmlNamespace)\" version=\"1.2.1\">\n<creator><program>rewindDV</program><version>\(parserVersion)</version></creator>\n<media ref=\"urn:sha256:\(snapshot.sourceSHA256)\" format=\"DV\" size=\"\(snapshot.sourceByteCount)\">\n")
    try put(3, "<!-- Partial compatibility report. Exact audio sample findings and coverage limits are in analysis.json and report.json. Missing XML attributes do not mean zero defects. -->\n")
    var count: UInt64 = 0, cues: UInt64 = 0
    for pageNumber in 0..<binding.pageCount {
      let page = try await map.page(pageNumber)
      for record in page.records {
        try Task.checkCancellation()
        guard record.quality != nil, let timeline = record.timeline else {
          throw DVIngestError.invalidEvidence("portable reports require a detailed map from Alpha 0.0.41 or later; create a separate new map")
        }
        let original = try await source.frame(record)
        let evidence = original.evidence, b = record.boundaryEvidence
        // A self-consistent edited ledger must not invent/suppress report counts.
        var expectedIssues = Dictionary(uniqueKeysWithValues:
          DVTapeEvidenceMapExporter.frameIssues(boundary: b, titleTimecode: record.rawSubcode.titleTimecodePacks)
            .map { ($0.code, $0.observedCount) })
        for code in timeline.changes { expectedIssues[code] = 1 }
        for (code, value) in [(DVTapeEvidenceMapExporter.IssueCode.audioErrorSentinels, evidence.audioErrors.count),
          (.invalidMetadata, evidence.summary.invalidMetadataValues), (.conflictingMetadata, evidence.summary.conflictingMetadataValues)] where value > 0 {
          expectedIssues[code] = UInt64(value)
        }
        guard Dictionary(uniqueKeysWithValues: record.issues.map { ($0.code, $0.observedCount) }) == expectedIssues else {
          throw DVIngestError.invalidEvidence("map issue counts disagree with original-frame analysis")
        }
        let ticks = try numerator(b.frameOrdinal, pal: snapshot.frameByteCount == 144_000)
        let denominator: UInt64 = snapshot.frameByteCount == 144_000 ? 25 : 30_000
        let video = evidence.blocks.filter { ($0.videoSTA ?? 0) != 0 }
        let item = Frame(sourceSHA256: snapshot.sourceSHA256,
          presentationNumerator: ticks, presentationDenominator: denominator,
          mapRecord: record, currentQuality: evidence.summary,
          videoStatusBlocks: video, audioErrorSamples: evidence.audioErrors)
        if count > 0 { try put(0, ",\n") }
        try putData(0, encode(item))
        let q = evidence.summary
        try put(1, csvRow([snapshot.sourceSHA256, String(b.frameOrdinal), String(b.frameSourceByteOffset),
          String(b.frameByteCount), b.frameSHA256, String(ticks), String(denominator),
          record.timeline?.point.timecodeLabel ?? "", record.timeline?.point.recordedDate ?? "",
          String(video.count), String(evidence.audioErrors.count), String(q.audioSamplesExamined), q.audioCoverage,
          String(q.invalidMetadataValues), String(q.conflictingMetadataValues), record.issues.map { $0.code.rawValue }.joined(separator: ";")]))
        if !record.issues.isEmpty {
          let start = try timestamp(frame: b.frameOrdinal, pal: b.frameByteCount == 144_000, precision: 3)
          let end = try timestamp(frame: b.frameOrdinal + 1, pal: b.frameByteCount == 144_000, precision: 3)
          try put(2, "frame-\(b.frameOrdinal)\n\(start) --> \(end)\nFrame \(b.frameOrdinal); original bytes \(b.frameSourceByteOffset)..&lt;\(b.frameSourceByteOffset + UInt64(b.frameByteCount))\n\(record.issues.map { $0.code.rawValue }.joined(separator: ", "))\nFrame SHA-256: \(b.frameSHA256)\n\n")
          cues += 1
        }
        try put(3, try xmlFrame(record, evidence: evidence))
        count += 1
        if count % 128 == 0 || count == snapshot.frameCount { progress(count, snapshot.frameCount) }
      }
    }
    guard count == snapshot.frameCount else { throw DVIngestError.invalidEvidence("report frame count mismatch") }
    try put(0, "\n]}\n"); try put(3, "</media>\n</dvrescue>\n")
    try await source.verifyUnchanged()
    // Recheck map identity after the last frame and before publication.
    if binding.pageCount > 0 { _ = try await map.page(binding.pageCount - 1) }
    var artifacts: [Artifact] = []
    for (index, name) in names.enumerated() {
      try writers[index].synchronize(); try writers[index].close()
      let verified = try directory.hashRegularFile(named: name + ".partial")
      guard verified.bytes == writtenBytes[index], verified.sha256 == hex(writtenHashes[index].finalize()) else {
        throw DVIngestError.invalidEvidence("report reread differs from bytes written")
      }
      artifacts.append(Artifact(name: name, bytes: verified.bytes, sha256: verified.sha256))
    }
    let receipt = Receipt(schemaVersion: 1, completion: "complete", parser: parserVersion,
      source: snapshot, map: binding, artifacts: artifacts, frameCount: count, cueCount: cues,
      timestampBasis: "zero-based file frame ordinal; exact rational 1001/30000 NTSC or 1/25 PAL; text timestamps rounded to nearest millisecond (VTT) or microsecond (XML); never recorded timecode",
      xmlProfile: "DVRescue XSD 1.2.1 subset; pinned upstream \(upstreamRevision); truthful rewindDV creator",
      limitations: [
        "No report establishes pristine content, exact missing-frame count, tape identity or recovery/merge authority.",
        "Acquisition totals remain in map.mapReceipt.archiveReportProvenance; never redistributed onto file frames.",
        "XML includes file ordinals, offsets, presentation times, source timecode when available, dimensions, rate, qualified chroma, caption-pack presence and per-sequence/per-frame STA counts.",
        "XML omits aud: DVRescue counts audio blocks, not our active error samples. Exact sample codes/offsets/masks remain in analysis.json.",
        "XML omits recorded date/time, ATN, recording flags, audio rate/channels and discontinuity flags rather than guessing or conflating semantics. Native map metadata remains in JSON.",
        "Some DVRescue utilities require creator/program=dvrescue and reject honest third-party reports. XSD compatibility is not compatibility with every utility.",
        "CSV blanks mean unavailable. Spreadsheet-leading formula characters are escaped with an apostrophe; JSON preserves exact values.",
        "VTT cues cover warning frames, not all frames; temporal labels reset independently of file presentation time."
      ])
    let bytes = try encode(receipt) + Data([10])
    try directory.writeExclusive(named: "report.json.partial", data: bytes, synchronize: true)
    for artifact in artifacts {
      try Task.checkCancellation(); try directory.requireCurrentDestinationPath()
      try directory.promoteExclusive(from: artifact.name + ".partial", to: artifact.name,
        expectedBytes: artifact.bytes, expectedSHA256: artifact.sha256)
    }
    try directory.synchronize(); try await source.verifyUnchanged()
    try Task.checkCancellation(); try directory.requireCurrentDestinationPath()
    try directory.promoteExclusive(from: "report.json.partial", to: "report.json",
      expectedBytes: UInt64(bytes.count), expectedSHA256: hex(SHA256.hash(data: bytes)))
    do { try directory.synchronize() }
    catch { directory.withdrawCompletionMarkerBestEffort(from: "report.json", to: "report.json.partial"); throw error }
    return receipt
  }

  static func xmlFrame(_ record: DVTapeEvidenceMapExporter.FrameRecord, evidence: DVFrameForensics) throws -> String {
    let b = record.boundaryEvidence, pal = b.frameByteCount == 144_000
    let start = try timestamp(frame: b.frameOrdinal, pal: pal, precision: 6)
    let end = try timestamp(frame: b.frameOrdinal + 1, pal: pal, precision: 6)
    var text = "<frames count=\"1\" pts=\"\(start)\" end_pts=\"\(end)\" size=\"720x\(pal ? 576 : 480)\" video_rate=\"\(pal ? "25" : "30000/1001")\""
    if let layout = evidence.videoLayout { text += " chroma_subsampling=\"\(layout == .pal420 ? "4:2:0" : "4:1:1")\"" }
    text += " captions=\"\(evidence.semantics.packs.contains { $0.typeHex == "0x65" && $0.id.hasPrefix("vaux") } ? "y" : "n")\">\n"
    text += "<frame n=\"\(b.frameOrdinal)\" pos=\"\(b.frameSourceByteOffset)\" pts=\"\(start)\""
    if let tc = record.timeline?.point.timecodeLabel { text += " tc=\"\(xmlEscape(tc))\"" }
    text += ">\n"
    let flags = evidence.blocks.filter { ($0.videoSTA ?? 0) != 0 }
    for sequence in 0..<(pal ? 12 : 10) {
      let group = flags.filter { $0.sequence == sequence }
      if group.isEmpty { continue }
      text += "<dseq n=\"\(sequence)\">"
      for type in Set(group.compactMap(\.videoSTA)).sorted() {
        text += "<sta t=\"\(type)\" n=\"\(group.filter { $0.videoSTA == type }.count)\"/>"
      }
      text += "</dseq>\n"
    }
    for type in Set(flags.compactMap(\.videoSTA)).sorted() {
      let matching = flags.filter { $0.videoSTA == type }
      text += "<sta t=\"\(type)\" n=\"\(matching.count)\" n_even=\"\(matching.filter { $0.sequence % 2 == 0 }.count)\"/>\n"
    }
    return text + "</frame>\n</frames>\n"
  }
  static func numerator(_ frame: UInt64, pal: Bool) throws -> UInt64 {
    let (value, overflow) = frame.multipliedReportingOverflow(by: pal ? 1 : 1001)
    guard !overflow else { throw DVIngestError.invalidEvidence("report timestamp overflow") }; return value
  }
  static func timestamp(frame: UInt64, pal: Bool, precision: Int) throws -> String {
    guard precision == 3 || precision == 6 else { throw DVIngestError.invalidEvidence("timestamp precision") }
    let ticks = try numerator(frame, pal: pal), denominator: UInt64 = pal ? 25 : 30_000
    let scale: UInt64 = precision == 3 ? 1000 : 1_000_000
    let seconds = ticks / denominator, fraction = ((ticks % denominator) * scale + denominator / 2) / denominator
    let whole = seconds + fraction / scale, remainder = fraction % scale
    return String(format: "%02llu:%02llu:%02llu.%0*llu", whole / 3600, whole / 60 % 60, whole % 60, precision, remainder)
  }
  static func csvRow(_ fields: [String]) -> String {
    fields.map { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
      return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }.joined(separator: ",") + "\r\n"
  }
  static func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
