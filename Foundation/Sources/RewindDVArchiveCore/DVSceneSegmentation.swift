// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// An offline, reviewed partition of a verified DV master. Marker observations
/// are proposals, not proof of a camera take, a tape boundary or missing content.
public enum DVSceneSegmentation {
  public static let algorithm = "rewindDV-scenes-1"
  public enum Decision: String, Codable, CaseIterable, Sendable { case pending, accepted, rejected }
  public struct Evidence: Codable, Equatable, Sendable {
    public let frame: UInt64
    public let frameSHA256: String
    public let format: String
    public let packs: [DVPackSemanticReport.Pack]
  }
  public struct Boundary: Codable, Equatable, Identifiable, Sendable {
    /// Cut before this zero-based file frame; never before frame zero or after EOF.
    public var id: UInt64 { frame }
    public let frame: UInt64
    public let reasons: [String]
    public let before: Evidence
    public let after: Evidence
    public var decision: Decision
    public var note: String
  }
  public struct Segment: Codable, Equatable, Sendable {
    public let first: UInt64
    public let endExclusive: UInt64
  }
  public struct Plan: Codable, Sendable {
    public let version: String
    public let source: DVReviewedRangeExporter.Snapshot
    public let mapReceiptSHA256: String
    public let framesWithIncompleteOrConflictingEvidence: UInt64
    public var boundaries: [Boundary]
    public var segments: [Segment] {
      let cuts = Set([UInt64(0)] + boundaries.filter { $0.decision == .accepted }.map(\.frame)
        + source.recordingEpochs.map(\.firstFrame) + [source.frameCount]).sorted()
      return zip(cuts, cuts.dropFirst()).map { Segment(first: $0.0, endExclusive: $0.1) }
    }
    public var pendingCount: Int { boundaries.filter { $0.decision == .pending }.count }
  }
  public struct Output: Codable, Sendable {
    public let file: String
    public let first: UInt64
    public let endExclusive: UInt64
    public let bytes: UInt64
    public let sha256: String
    public var sourceByteOffset: UInt64? = nil
    public var sourceByteEndExclusive: UInt64? = nil
    public var epochID: String? = nil
    public var recordingSystem: DVBoundaryEvidence.VideoSystem? = nil
  }
  public struct Receipt: Codable, Sendable {
    public let version: String
    public let state: String
    public let source: DVReviewedRangeExporter.Snapshot
    public let reviewSHA256: String
    public let outputs: [Output]
    public let concatenatedSHA256: String?
    public let policy: String
  }

  // Field identity includes pack scope; AAUX/VAUX and IEC/SMPTE are never conflated.
  struct Observation {
    let evidence: Evidence
    let fields: [String: UInt8]
    let incomplete: Bool
    static func inspect(_ report: DVPackSemanticReport) -> Self {
      let packs = report.packs.filter { ["0x50", "0x51", "0x60", "0x61"].contains($0.typeHex) }
      let wanted: Set<String> = ["REC_S", "REC_E", "SMP", "QU", "CHN", "STYPE", "DISP", "FIELD_SYSTEM"]
      var values: [String: Set<UInt32>] = [:], invalid = Set<String>()
      for pack in packs {
        let scope = String(pack.id.split(separator: ":").first ?? "unknown") + "/" + pack.typeHex
        for field in pack.fields where wanted.contains(field.id) {
          let key = scope + "/" + field.id
          // DISP's exact code is useful even where its semantic mapping is
          // deliberately unqualified. Compare codes, never invent an aspect.
          if field.status == "interpreted" || (field.id == "DISP" && field.status == "uninterpreted") {
            values[key, default: []].insert(field.rawValue)
          }
          else { invalid.insert(key) }
        }
      }
      var known: [String: UInt8] = [:]
      for (key, set) in values where set.count == 1 && !invalid.contains(key) { known[key] = UInt8(exactly: set.first!) }
      let complete = ["0x50", "0x51", "0x60", "0x61"].allSatisfy { type in packs.contains { $0.typeHex == type } }
      let relevant = packs.map { pack in
        DVPackSemanticReport.Pack(id: pack.id, typeHex: pack.typeHex, name: pack.name, rawHex: pack.rawHex,
          sourceByteOffsets: pack.sourceByteOffsets, status: pack.status, fields: pack.fields.filter { wanted.contains($0.id) })
      }
      return Self(evidence: Evidence(frame: report.frameOrdinal, frameSHA256: report.frameSHA256,
        format: report.format, packs: relevant), fields: known,
        incomplete: !complete || !invalid.isEmpty || values.values.contains { $0.count != 1 } || report.format.hasPrefix("Unknown"))
    }
  }

  /// Adjacent-only comparisons: unavailable metadata breaks format comparison.
  /// A REC_S assertion run yields one proposal, even if a gap interrupts it.
  struct Detector {
    var previous: Observation?
    var startAsserted = Set<String>()
    var boundaries: [Boundary] = []
    var incomplete: UInt64 = 0
    var evidenceBytes = 0
    mutating func consume(_ current: Observation) throws {
      if current.incomplete { incomplete += 1 }
      var reasons: [String] = []
      for key in current.fields.keys.sorted() where key.hasSuffix("/REC_S") {
        if current.fields[key] == 0 {
          if !startAsserted.contains(key), previous != nil { reasons.append("Recording-start assertion: " + key) }
          startAsserted.insert(key)
        } else { startAsserted.remove(key) }
      }
      if let previous {
        // The cut follows an observed REC_E run, retaining every marked frame.
        for key in previous.fields.keys.sorted() where key.hasSuffix("/REC_E") {
          if previous.fields[key] == 0 && current.fields[key] == 1 {
            reasons.append("End of recording-end assertion run: " + key)
          }
        }
        if !previous.evidence.format.hasPrefix("Unknown"), !current.evidence.format.hasPrefix("Unknown"),
          previous.evidence.format != current.evidence.format { reasons.append("DV application-format change") }
        for key in current.fields.keys.sorted() where !key.hasSuffix("/REC_S") && !key.hasSuffix("/REC_E") {
          if let old = previous.fields[key], old != current.fields[key], previous.evidence.format == current.evidence.format {
            reasons.append("Format change: \(key) \(old) → \(current.fields[key]!)")
          }
        }
        if !reasons.isEmpty {
          guard boundaries.count < 100_000 else { throw DVIngestError.invalidEvidence("scene proposal budget exceeded; no truncated plan published") }
          let boundary = Boundary(frame: current.evidence.frame, reasons: reasons, before: previous.evidence,
            after: current.evidence, decision: .pending, note: "")
          evidenceBytes += try DVSceneSegmentation.encode(boundary).count
          guard evidenceBytes <= 50_331_648 else { throw DVIngestError.invalidEvidence("scene evidence exceeds 48 MiB review budget; no incomplete plan published") }
          boundaries.append(boundary)
        }
      }
      previous = current
    }
  }

  public static func analyze(map: DVTapeEvidenceLedgerReader, source: DVVerifiedFrameSource,
    progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> Plan {
    let snapshot = map.binding.mapReceipt.sourceSnapshot
    try await source.requireSnapshot(snapshot)
    var detector = Detector(), count: UInt64 = 0
    for number in 0..<map.binding.pageCount {
      for record in try await map.page(number).records {
        try Task.checkCancellation()
        let original = try await source.frame(record)
        try detector.consume(.inspect(original.evidence.semantics)); count += 1
        if count % 128 == 0 || count == snapshot.frameCount { progress(count, snapshot.frameCount) }
      }
    }
    guard count == snapshot.frameCount else { throw DVIngestError.invalidEvidence("scene scan coverage mismatch") }
    try await source.verifyUnchanged()
    if map.binding.pageCount > 0 { _ = try await map.page(map.binding.pageCount - 1) }
    return Plan(version: algorithm, source: snapshot, mapReceiptSHA256: map.binding.mapReceiptSHA256,
      framesWithIncompleteOrConflictingEvidence: detector.incomplete, boundaries: detector.boundaries)
  }

  static func validate(_ plan: Plan) throws {
    try plan.source.validate()
    guard plan.version == algorithm, plan.source.frameCount > 0, plan.boundaries.count <= 100_000 else {
      throw DVIngestError.invalidEvidence("unsupported scene plan")
    }
    var previous: UInt64 = 0
    for boundary in plan.boundaries {
      guard boundary.frame > previous, boundary.frame < plan.source.frameCount,
        boundary.before.frame == boundary.frame - 1, boundary.after.frame == boundary.frame,
        !boundary.reasons.isEmpty, boundary.note.utf8.count <= 4096 else {
        throw DVIngestError.invalidEvidence("invalid scene boundary or review note")
      }
      previous = boundary.frame
    }
  }

  /// Review reload only against a fresh analysis. Claims from a JSON file never
  /// create new evidence or silently bind to a similarly named DV file.
  public static func restore(_ url: URL, against fresh: Plan) throws -> Plan {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open scene review", errno) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= 67_108_864 else {
      throw DVIngestError.invalidEvidence("scene review is not a bounded regular JSON file")
    }
    guard let bytes = try file.read(upToCount: Int(st.st_size) + 1), bytes.count == Int(st.st_size) else {
      throw DVIngestError.invalidEvidence("scene review changed while reading")
    }
    let saved = try JSONDecoder().decode(Plan.self, from: bytes)
    try validate(saved); try validate(fresh)
    var neutral = saved, baseline = fresh
    for index in neutral.boundaries.indices { neutral.boundaries[index].decision = .pending; neutral.boundaries[index].note = "" }
    for index in baseline.boundaries.indices { baseline.boundaries[index].decision = .pending; baseline.boundaries[index].note = "" }
    guard try encode(neutral) == encode(baseline) else { throw DVIngestError.invalidEvidence("scene review does not match current original-byte analysis") }
    return saved
  }

  /// Save review only, or export a complete, ordered partition as raw DV copies.
  /// The partition concatenates exactly to the master. Pending reviews block DV
  /// export, but may be saved and resumed. No transcoding or audio resampling.
  public static func publish(plan: Plan, map: DVTapeEvidenceLedgerReader, source: DVVerifiedFrameSource,
    destination: URL, exportDV: Bool,
    progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> Receipt {
    try validate(plan)
    guard !exportDV || plan.source.isComplete else {
      throw DVIngestError.invalidEvidence("complete scene partition cannot exclude unknown source bytes; use an explicitly reviewed verified frame range")
    }
    guard plan.mapReceiptSHA256 == map.binding.mapReceiptSHA256,
      plan.source == map.binding.mapReceipt.sourceSnapshot,
      !exportDV || plan.pendingCount == 0 else { throw DVIngestError.invalidEvidence("review every proposed cut before exporting scenes") }
    try await source.requireSnapshot(plan.source)
    guard !DVGentleRecovery.isWithin(destination, directory: map.mapDirectory) else {
      throw DVIngestError.invalidEvidence("scene output must be outside the source evidence map")
    }
    // Re-derive proposals before trusting even a caller-constructed plan.
    let fresh = try await analyze(map: map, source: source, progress: progress)
    var expected = fresh
    guard expected.boundaries.count == plan.boundaries.count else { throw DVIngestError.invalidEvidence("scene proposals changed") }
    for i in expected.boundaries.indices { expected.boundaries[i].decision = plan.boundaries[i].decision; expected.boundaries[i].note = plan.boundaries[i].note }
    guard try encode(expected) == encode(plan) else { throw DVIngestError.invalidEvidence("scene plan evidence differs from original bytes") }
    let directory = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { directory.close() }
    try directory.writeExclusive(named: "intent.json", data: try encode(["state": "incomplete_until_scenes_json"]), synchronize: true)
    let review = try encode(plan)
    guard review.count <= 67_108_864 else { throw DVIngestError.invalidEvidence("review exceeds portable reload budget") }
    let reviewSHA = hex(SHA256.hash(data: review))
    try directory.writeExclusive(named: "review.json.partial", data: review, synchronize: true)
    var outputs: [Output] = [], combined = SHA256(), count: UInt64 = 0
    if exportDV {
      let segments = plan.segments
      var segmentIndex = 0, handle: FileHandle?, hash = SHA256(), bytes: UInt64 = 0
      defer { try? handle?.close() }
      for page in 0..<map.binding.pageCount {
        for record in try await map.page(page).records {
          try Task.checkCancellation()
          let frame = try await source.frame(record), segment = segments[segmentIndex]
          let name = String(format: "scene-%06d.dv", segmentIndex + 1)
          if handle == nil { handle = try directory.makeExclusiveWriter(named: name + ".partial") }
          try handle!.write(contentsOf: frame.bytes)
          hash.update(data: frame.bytes); combined.update(data: frame.bytes); bytes += UInt64(frame.bytes.count); count += 1
          if count == segment.endExclusive {
            try handle!.synchronize(); try handle!.close(); handle = nil
            let digest = hex(hash.finalize()), reread = try directory.hashRegularFile(named: name + ".partial")
            guard reread.bytes == bytes, reread.sha256 == digest else { throw DVIngestError.invalidEvidence("scene reread mismatch") }
            outputs.append(Output(file: name, first: segment.first, endExclusive: segment.endExclusive, bytes: bytes, sha256: digest,
              sourceByteOffset: try plan.source.byteOffset(atBoundary: segment.first),
              sourceByteEndExclusive: try plan.source.byteOffset(atBoundary: segment.endExclusive),
              epochID: try plan.source.frame(segment.first).epochID,
              recordingSystem: try plan.source.frame(segment.first).system))
            hash = SHA256(); bytes = 0; segmentIndex += 1
          }
          if count % 128 == 0 || count == plan.source.frameCount { progress(count, plan.source.frameCount) }
        }
      }
      guard count == plan.source.frameCount, segmentIndex == segments.count,
        hex(combined.finalize()) == plan.source.sourceSHA256 else { throw DVIngestError.invalidEvidence("scene partition differs from master") }
    }
    let receipt = Receipt(version: algorithm, state: exportDV ? "complete_verified_partition" : "review_saved_no_media_exported",
      source: plan.source, reviewSHA256: reviewSHA, outputs: outputs,
      concatenatedSHA256: exportDV ? plan.source.sourceSHA256 : nil,
      policy: "Every master frame retained exactly once in source order when exporting. No re-encode, audio resample, timecode rewrite, master modification or hardware command. Marker cuts are reviewed interpretations, not proven camera takes. Recording-system boundaries split output independently of reviewed scene cuts; concatenating files in manifest order reconstructs the original raw sequence.")
    for output in outputs {
      try Task.checkCancellation()
      try directory.promoteExclusive(from: output.file + ".partial", to: output.file, expectedBytes: output.bytes, expectedSHA256: output.sha256)
    }
    try directory.promoteExclusive(from: "review.json.partial", to: "review.json", expectedBytes: UInt64(review.count), expectedSHA256: reviewSHA)
    let receiptBytes = try encode(receipt)
    try directory.writeExclusive(named: "scenes.json.partial", data: receiptBytes, synchronize: true)
    try await source.verifyUnchanged()
    if map.binding.pageCount > 0 { _ = try await map.page(map.binding.pageCount - 1) }
    try Task.checkCancellation(); try directory.synchronize()
    try directory.promoteExclusive(from: "scenes.json.partial", to: "scenes.json", expectedBytes: UInt64(receiptBytes.count), expectedSHA256: hex(SHA256.hash(data: receiptBytes)))
    do { try directory.synchronize() }
    catch { directory.withdrawCompletionMarkerBestEffort(from: "scenes.json", to: "scenes.json.partial"); throw error }
    return receipt
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  static func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 { data.map { String(format: "%02x", $0) }.joined() }
}
