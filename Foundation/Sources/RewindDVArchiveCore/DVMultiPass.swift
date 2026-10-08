// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Offline comparison and reviewed whole-frame donor selection. No synthesized
/// blocks/samples, timecode-only alignment, master overwrite or hardware access.
public enum DVMultiPass {
  public static let algorithm = "rewindDV-multipass-1"
  public static let maximumInputs = 8
  public static let maximumTotalFrames: UInt64 = 1_000_000
  public static let maximumCandidates = 50_000
  public static let anchorDistance = 30
  public struct Input: Sendable {
    public let map: DVTapeEvidenceLedgerReader
    public let source: DVVerifiedFrameSource
    public init(map: DVTapeEvidenceLedgerReader, source: DVVerifiedFrameSource) { self.map = map; self.source = source }
    public var binding: Binding { .init(source: map.binding.mapReceipt.sourceSnapshot, mapSHA256: map.binding.mapReceiptSHA256) }
  }
  public struct Binding: Codable, Equatable, Sendable {
    public let source: DVReviewedRangeExporter.Snapshot
    public let mapSHA256: String
  }
  public struct Range: Codable, Equatable, Sendable { public let first: UInt64; public var endExclusive: UInt64 }
  public struct Anchor: Codable, Equatable, Sendable {
    public let base: UInt64; public let donor: UInt64; public let sha256: String
  }
  public struct Quality: Codable, Equatable, Sendable {
    public let videoSTA: Int; public let audioErrors: Int; public let assessed: Bool
  }
  public struct Candidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(baseFrame):\(donorPass):\(donorFrame)" }
    public let baseFrame: UInt64
    public let donorPass: Int
    public let donorFrame: UInt64
    public let baseSHA256: String
    public let donorSHA256: String
    public let metadataSHA256: String
    public let anchors: [Anchor]
    public let before: Quality
    public let after: Quality
    public var eligible: Bool
    public var reason: String
  }
  public struct Comparison: Codable, Equatable, Sendable {
    public let donorPass: Int
    public let uniqueExactFrames: UInt64
    public let monotonicAnchors: Bool
    public var unresolvedBaseRanges: [Range]
    public let unmatchedDonorFrames: UInt64
    public let policy: String
  }
  public struct Review: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64 { baseFrame }
    public let baseFrame: UInt64
    /// nil=pending, "original"=retain base; otherwise an eligible candidate id.
    public var choice: String?
    public var note: String
  }
  public struct Plan: Codable, Equatable, Sendable {
    public let version: String
    public let inputs: [Binding]
    public let comparisons: [Comparison]
    public let candidates: [Candidate]
    public var reviews: [Review]
    public var pending: Int { reviews.filter { $0.choice == nil }.count }
    public var replacements: Int { reviews.filter { $0.choice != nil && $0.choice != "original" }.count }
  }
  public struct Provenance: Codable, Equatable, Sendable {
    public let outputFrame: UInt64
    public let outputByteOffset: UInt64
    public let byteCount: Int
    public let sourcePass: Int
    public let sourceSHA256: String
    public let sourceFrame: UInt64
    public let sourceByteOffset: UInt64
    public let frameSHA256: String
    public let choice: String
  }
  public struct Receipt: Codable, Sendable {
    public let version: String
    public let state: String
    public let inputs: [Binding]
    public let frames: UInt64
    public let replacements: Int
    public let reviewSHA256: String
    public let mediaSHA256: String?
    public let provenanceSHA256: String?
    public let policy: String
  }
  struct FrameIndex: Sendable {
    let hash: String; let metadata: String; let quality: Quality
  }
  struct Index: Sendable {
    let frames: [FrameIndex]
    let hashes: [String: Int]
    let metadata: [String: Int]
  }
  /// Operation-local, single-page cursor: no shared cache or retained DV
  /// payload. Each source frame is still freshly read and hash/identity checked;
  /// all input maps are rechecked before comparison/export completion.
  struct FrameCursor: Sendable {
    var page: DVTapeEvidenceLedgerReader.Page?
    mutating func read(_ input: Input, ordinal: UInt64) async throws -> DVVerifiedFrameSource.Frame {
      guard ordinal < input.binding.source.frameCount else { throw error("frame outside source") }
      let number = ordinal / DVTapeEvidenceLedgerReader.recordsPerPage
      if page?.pageNumber != number { page = try await input.map.page(number) }
      guard let record = page?.records.first(where: { $0.boundaryEvidence.frameOrdinal == ordinal }) else { throw error("map frame missing") }
      return try await input.source.frame(record)
    }
  }
  static func error(_ text: String) -> DVIngestError { .invalidEvidence("multi-pass: " + text) }
  static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
  static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  static func unique(_ values: [String]) -> [String: Int] {
    var result: [String: Int] = [:]
    for (i, key) in values.enumerated() { result[key] = result[key] == nil ? i : -1 }
    return result
  }
  static func quality(_ frame: DVVerifiedFrameSource.Frame) -> Quality {
    let e = frame.evidence, s = e.summary
    return .init(videoSTA: s.videoStatusBySequence.reduce(0,+), audioErrors: e.audioErrors.count,
      assessed: e.semantics.format == "IEC 61834 consumer DV" && e.videoLayout != nil &&
        s.audioCoverage == "Both IEC audio halves examined; active sample positions only" &&
        s.invalidMetadataValues == 0 && s.conflictingMetadataValues == 0)
  }
  /// Exact non-media bytes, including all metadata, AAUX sample counts and DIF
  /// identities. Never strip or repair invalid timecode to manufacture a match.
  static func metadata(_ frame: DVVerifiedFrameSource.Frame) -> String {
    var bytes = Data()
    for (i, block) in frame.evidence.blocks.enumerated() {
      let start = i * 80, count = block.section == 4 ? 3 : block.section == 3 ? 8 : 80
      bytes.append(frame.bytes[start..<(start + count)])
    }
    return hash(bytes)
  }
  static func scan(_ input: Input, progress: @Sendable (UInt64) -> Void) async throws -> Index {
    try await input.source.requireSnapshot(input.binding.source)
    var frames: [FrameIndex] = []
    for page in 0..<input.map.binding.pageCount {
      for record in try await input.map.page(page).records {
        try Task.checkCancellation()
        let frame = try await input.source.frame(record)
        frames.append(.init(hash: record.boundaryEvidence.frameSHA256, metadata: metadata(frame), quality: quality(frame)))
        if frames.count % 128 == 0 { progress(UInt64(frames.count)) }
      }
    }
    guard frames.count == input.binding.source.frameCount else { throw error("incomplete comparison scan") }
    try await input.source.verifyUnchanged(); progress(UInt64(frames.count))
    return Index(frames: frames, hashes: unique(frames.map(\.hash)), metadata: unique(frames.map(\.metadata)))
  }
  public static func frame(_ input: Input, ordinal: UInt64) async throws -> DVVerifiedFrameSource.Frame {
    guard ordinal < input.binding.source.frameCount else { throw error("frame outside source") }
    let page = try await input.map.page(ordinal / DVTapeEvidenceLedgerReader.recordsPerPage)
    guard let record = page.records.first(where: { $0.boundaryEvidence.frameOrdinal == ordinal }) else { throw error("map frame missing") }
    return try await input.source.frame(record)
  }
  /// Conservative no-regression oracle. Entire donor frame is copied, but
  /// differences outside flagged video five-DIF segments and exact flagged
  /// audio sample bits are rejected. Healthy and unknown bytes stay identical.
  static func replacementReason(base: DVVerifiedFrameSource.Frame, donor: DVVerifiedFrameSource.Frame) -> String? {
    let b = quality(base), d = quality(donor)
    guard b.assessed && d.assessed else { return "Unassessed/unsupported metadata, video or audio layout" }
    guard d.videoSTA == 0 && d.audioErrors == 0 else { return "Donor retains measured video/audio errors" }
    guard b.videoSTA > 0 || b.audioErrors > 0 else { return "No measured base error to justify replacement" }
    guard base.bytes.count == donor.bytes.count, metadata(base) == metadata(donor) else { return "Non-media bytes or audio sample counts differ" }
    let groups = Set(base.evidence.blocks.filter { ($0.videoSTA ?? 0) != 0 }.map { $0.sequence * 27 + $0.number / 5 })
    var audioMasks: [Int: UInt8] = [:]
    guard let baseOffset = base.evidence.semantics.frameByteOffset else { return "Source coordinates unavailable" }
    for sample in base.evidence.audioErrors {
      for (offset, mask) in zip(sample.byteOffsets, sample.bitMasks) { audioMasks[Int(offset - baseOffset), default: 0] |= mask }
    }
    for (index, block) in base.evidence.blocks.enumerated() {
      let start = index * 80
      if block.section == 4 && groups.contains(block.sequence * 27 + block.number / 5) { continue }
      for at in start..<(start + 80) {
        let allowed = block.section == 3 && at >= start + 8 ? audioMasks[at, default: 0] : 0
        if (base.bytes[at] ^ donor.bytes[at]) & ~allowed != 0 { return "Donor changes already-good or unassessed bytes outside flagged dependency units" }
      }
    }
    return nil
  }
  static func anchors(base: Int, donor: Int, exact: [Int: Int], hashes: [FrameIndex]) -> [Anchor] {
    guard base >= 2 else { return [] }
    var left: Int?, right: Int?
    for at in stride(from: base - 2, through: max(0, base - anchorDistance), by: -1) {
      if let one = exact[at], exact[at + 1] == one + 1, one - at == donor - base { left = at; break }
    }
    if base + 2 < hashes.count {
      for at in (base + 1)...min(hashes.count - 2, base + anchorDistance) {
        if let one = exact[at], exact[at + 1] == one + 1, one - at == donor - base { right = at; break }
      }
    }
    guard let left, let right else { return [] }
    for at in left...(right + 1) {
      if let match = exact[at], match - at != donor - base { return [] }
    }
    return [left, left + 1, right, right + 1].map { .init(base: UInt64($0), donor: UInt64(exact[$0]!), sha256: hashes[$0].hash) }
  }
  static func appendRange(_ frame: Int, to ranges: inout [Range]) {
    if let last = ranges.last, last.endExclusive == UInt64(frame) { ranges[ranges.count - 1].endExclusive += 1 }
    else { ranges.append(.init(first: UInt64(frame), endExclusive: UInt64(frame + 1))) }
  }
  public static func compare(_ inputs: [Input], progress: @Sendable (String, UInt64, UInt64) -> Void = { _,_,_ in }) async throws -> Plan {
    guard (2...maximumInputs).contains(inputs.count), let first = inputs.first else { throw error("select a base and one to seven donor passes") }
    let bindings = inputs.map(\.binding)
    var total: UInt64 = 0
    for binding in bindings {
      try binding.source.validate()
      guard binding.source.isComplete, binding.source.frameCount <= maximumTotalFrames - total,
        Set(binding.source.recordingEpochs.map(\.system)) == Set(first.binding.source.recordingEpochs.map(\.system)) else {
        throw error("unknown source intervals or aggregate frame budget exceeded")
      }
      total += binding.source.frameCount
    }
    var indexes: [Index] = []
    for (number, input) in inputs.enumerated() {
      indexes.append(try await scan(input) { progress("Verify pass \(number + 1)", $0, input.binding.source.frameCount) })
    }
    let base = indexes[0]
    var candidates: [Candidate] = [], comparisons: [Comparison] = []
    for pass in 1..<inputs.count {
      let donor = indexes[pass]
      var baseCursor = FrameCursor(), donorCursor = FrameCursor()
      var exact: [Int: Int] = [:], mapped = Set<Int>()
      for (i, frame) in base.frames.enumerated() {
        if base.hashes[frame.hash] == i, let match = donor.hashes[frame.hash], match >= 0 { exact[i] = match }
      }
      let ordered = exact.keys.sorted().map { exact[$0]! }
      let monotonic = zip(ordered, ordered.dropFirst()).allSatisfy { $0 < $1 }
      var unresolved: [Range] = []
      for (i, b) in base.frames.enumerated() {
        try Task.checkCancellation()
        if let match = exact[i], monotonic { mapped.insert(match); continue }
        guard monotonic, base.metadata[b.metadata] == i,
          let j = donor.metadata[b.metadata], j >= 0 else { appendRange(i, to: &unresolved); continue }
        mapped.insert(j)
        let d = donor.frames[j]
        if b.hash == d.hash { appendRange(i, to: &unresolved); continue } // nonunique exact identity is not an anchor
        let proof = anchors(base: i, donor: j, exact: exact, hashes: base.frames)
        var reason = proof.count == 4 ? nil : "No two unique exact consecutive anchors on each side at one consistent offset"
        if reason == nil {
          let original = try await baseCursor.read(inputs[0], ordinal: UInt64(i))
          let alternate = try await donorCursor.read(inputs[pass], ordinal: UInt64(j))
          reason = replacementReason(base: original, donor: alternate)
        }
        guard candidates.count < maximumCandidates else { throw error("comparison candidate budget exceeded; no truncated plan published") }
        candidates.append(.init(baseFrame: UInt64(i), donorPass: pass, donorFrame: UInt64(j),
          baseSHA256: b.hash, donorSHA256: d.hash, metadataSHA256: b.metadata, anchors: proof,
          before: b.quality, after: d.quality, eligible: reason == nil,
          reason: reason ?? "Unique bracketed byte alignment; complete donor frame; measured errors cleared; other bytes unchanged"))
        if reason != nil { appendRange(i, to: &unresolved) }
        if i % 128 == 0 { progress("Compare donor \(pass)", UInt64(i), UInt64(base.frames.count)) }
      }
      comparisons.append(.init(donorPass: pass, uniqueExactFrames: UInt64(monotonic ? exact.count : 0),
        monotonicAnchors: monotonic, unresolvedBaseRanges: unresolved,
        unmatchedDonorFrames: UInt64(donor.frames.count - mapped.count),
        policy: "Unmatched/ambiguous frames stay original; extra donor frames are never inserted. Unique metadata bytes alone do not authorize merging."))
    }
    // Divergent otherwise eligible donors cannot be ranked by fewer flags: no
    // majority vote or arbitrary tie break manufactures a recovered truth.
    for group in Dictionary(grouping: candidates.indices, by: { candidates[$0].baseFrame }).values {
      let eligible = group.filter { candidates[$0].eligible }
      if Set(eligible.map { candidates[$0].donorSHA256 }).count > 1 {
        for i in eligible { candidates[i].eligible = false; candidates[i].reason = "Conflicting eligible donor bytes; no unique recovered value" }
      }
    }
    // Conflict disqualification happens after each donor comparison. Include
    // those newly refused frames in the donor's unresolved summary as well.
    for i in comparisons.indices {
      let refused = candidates.filter { $0.donorPass == comparisons[i].donorPass && !$0.eligible }
        .map { Range(first: $0.baseFrame, endExclusive: $0.baseFrame + 1) }
      let sorted = (comparisons[i].unresolvedBaseRanges + refused).sorted { $0.first < $1.first }
      var merged: [Range] = []
      for range in sorted {
        if let last = merged.last, range.first <= last.endExclusive {
          merged[merged.count - 1].endExclusive = max(last.endExclusive, range.endExclusive)
        } else { merged.append(range) }
      }
      comparisons[i].unresolvedBaseRanges = merged
    }
    let reviewFrames = Set(candidates.filter(\.eligible).map(\.baseFrame)).sorted()
    for input in inputs {
      try await input.source.verifyUnchanged()
      _ = try await input.map.page(input.map.binding.pageCount - 1)
    }
    let plan = Plan(version: algorithm, inputs: bindings, comparisons: comparisons, candidates: candidates,
      reviews: reviewFrames.map { .init(baseFrame: $0, choice: nil, note: "") })
    guard try encode(plan).count <= 67_108_864 else { throw error("portable review budget exceeded") }
    progress("Comparison complete", total, total); return plan
  }
  static func validatedReview(_ plan: Plan, against fresh: Plan) throws {
    guard plan.reviews.count == fresh.reviews.count else { throw error("review set differs") }
    let eligible = Dictionary(uniqueKeysWithValues: fresh.candidates.filter(\.eligible).map { ($0.id, $0.baseFrame) })
    var neutral = plan
    for i in neutral.reviews.indices {
      let review = neutral.reviews[i]
      guard review.baseFrame == fresh.reviews[i].baseFrame, review.note.utf8.count <= 4096 else { throw error("invalid review") }
      if let choice = review.choice, choice != "original" {
        guard eligible[choice] == review.baseFrame else { throw error("ineligible donor selection") }
      }
      neutral.reviews[i].choice = nil; neutral.reviews[i].note = ""
    }
    guard neutral == fresh else { throw error("plan differs from rederived original-byte evidence") }
  }
  public static func restore(_ url: URL, against fresh: Plan) throws -> Plan {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw error("review unavailable") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size > 0, s.st_size <= 67_108_864,
      let data = try handle.read(upToCount: Int(s.st_size) + 1), data.count == s.st_size else { throw error("review is not bounded regular JSON") }
    let restored = try JSONDecoder().decode(Plan.self, from: data)
    var neutral = fresh
    for i in neutral.reviews.indices { neutral.reviews[i].choice = nil; neutral.reviews[i].note = "" }
    try validatedReview(restored, against: neutral); return restored
  }
  static func provenance(_ ordinal: UInt64, plan: Plan, choices: [UInt64: Candidate], baseHash: String) throws -> Provenance {
    let chosen = choices[ordinal], pass = chosen?.donorPass ?? 0, sourceFrame = chosen?.donorFrame ?? ordinal
    let base = try plan.inputs[0].source.frame(ordinal)
    let selected = try plan.inputs[pass].source.frame(sourceFrame)
    guard base.byteCount == selected.byteCount, base.system == selected.system else { throw error("donor recording system differs from base frame") }
    return .init(outputFrame: ordinal, outputByteOffset: base.byteOffset, byteCount: base.byteCount,
      sourcePass: pass, sourceSHA256: plan.inputs[pass].source.sourceSHA256, sourceFrame: sourceFrame,
      sourceByteOffset: selected.byteOffset, frameSHA256: chosen?.donorSHA256 ?? baseHash,
      choice: chosen?.id ?? "original")
  }
  public static func publish(plan: Plan, inputs: [Input], destination: URL, exportDV: Bool,
    progress: @Sendable (String, UInt64, UInt64) -> Void = { _,_,_ in }) async throws -> Receipt {
    guard !exportDV || plan.pending == 0 else { throw error("review all eligible replacements first") }
    for input in inputs {
      guard !DVGentleRecovery.isWithin(destination, directory: input.map.mapDirectory) else { throw error("output must be outside source maps") }
    }
    let fresh = try await compare(inputs, progress: progress)
    try validatedReview(plan, against: fresh)
    guard !exportDV || plan.inputs[0].source.recordingEpochs.count == 1 else {
      throw error("mixed-system merge output requires segmented publication; export verified source epoch ranges instead")
    }
    let directory = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { directory.close() }
    try directory.writeExclusive(named: "intent.json", data: try encode(["state": "incomplete_until_merge_json"]), synchronize: true)
    let review = try encode(plan), reviewHash = hash(review)
    try directory.writeExclusive(named: "review.json.partial", data: review, synchronize: true)
    var mediaHash: String?, ledgerHash: String?, ledgerBytes: UInt64 = 0
    let count = plan.inputs[0].source.frameCount
    if exportDV {
      let byID = Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.id, $0) })
      let choices = Dictionary(uniqueKeysWithValues: plan.reviews.compactMap { review -> (UInt64, Candidate)? in
        guard let choice = review.choice, let value = byID[choice] else { return nil }; return (review.baseFrame, value)
      })
      let media = try directory.makeExclusiveWriter(named: "merged.dv.partial")
      let ledger = try directory.makeExclusiveWriter(named: "provenance.ndjson.partial")
      defer { try? media.close(); try? ledger.close() }
      var mediaDigest = SHA256(), ledgerDigest = SHA256(), written: UInt64 = 0
      var donorCursors = Array(repeating: FrameCursor(), count: inputs.count)
      for page in 0..<inputs[0].map.binding.pageCount {
        for record in try await inputs[0].map.page(page).records {
          try Task.checkCancellation()
          let ordinal = record.boundaryEvidence.frameOrdinal
          let p = try provenance(ordinal, plan: plan, choices: choices, baseHash: record.boundaryEvidence.frameSHA256)
          let selected = p.sourcePass == 0 ? try await inputs[0].source.frame(record)
            : try await donorCursors[p.sourcePass].read(inputs[p.sourcePass], ordinal: p.sourceFrame)
          guard hash(selected.bytes) == p.frameSHA256, selected.bytes.count == p.byteCount else { throw error("chosen source changed") }
          let line = try encode(p) + Data([10])
          try media.write(contentsOf: selected.bytes); try ledger.write(contentsOf: line)
          mediaDigest.update(data: selected.bytes); ledgerDigest.update(data: line); ledgerBytes += UInt64(line.count); written += 1
          if written % 128 == 0 || written == count { progress("Write separate derivative", written, count) }
        }
      }
      guard written == count else { throw error("incomplete output frame coverage") }
      try media.synchronize(); try ledger.synchronize(); try media.close(); try ledger.close()
      mediaHash = mediaDigest.finalize().map { String(format: "%02x", $0) }.joined()
      ledgerHash = ledgerDigest.finalize().map { String(format: "%02x", $0) }.joined()
      // Independently reread each output frame and canonical provenance line
      // against the rederived choices. Aggregate hashes alone are not enough.
      try await verifyWritten(directory: directory, plan: plan, inputs: inputs, choices: choices, progress: progress)
      let m = try directory.hashRegularFile(named: "merged.dv.partial"), l = try directory.hashRegularFile(named: "provenance.ndjson.partial")
      guard m.bytes == plan.inputs[0].source.sourceByteCount, m.sha256 == mediaHash,
        l.bytes == ledgerBytes, l.sha256 == ledgerHash else { throw error("output reread mismatch") }
      try directory.promoteExclusive(from: "merged.dv.partial", to: "merged.dv", expectedBytes: m.bytes, expectedSHA256: m.sha256)
      try directory.promoteExclusive(from: "provenance.ndjson.partial", to: "provenance.ndjson", expectedBytes: l.bytes, expectedSHA256: l.sha256)
    }
    try directory.promoteExclusive(from: "review.json.partial", to: "review.json", expectedBytes: UInt64(review.count), expectedSHA256: reviewHash)
    let receipt = Receipt(version: algorithm, state: exportDV ? "verified_reviewed_derivative" : "comparison_review_only",
      inputs: plan.inputs, frames: count, replacements: exportDV ? plan.replacements : 0, reviewSHA256: reviewHash,
      mediaSHA256: mediaHash, provenanceSHA256: ledgerHash,
      policy: "Whole-frame original-byte selection only. Base frame order/count retained; no insertion, trimming, re-encode, resampling, block/sample synthesis or source overwrite. Unresolved/conflicting regions remain original. Measured error reduction is not proof of pristine content or physical tape identity. Alignment is unique within selected inputs under the recorded algorithm, not absolute historical proof.")
    let bytes = try encode(receipt)
    try directory.writeExclusive(named: "merge.json.partial", data: bytes, synchronize: true)
    for input in inputs {
      try await input.source.verifyUnchanged()
      _ = try await input.map.page(input.map.binding.pageCount - 1)
    }
    try Task.checkCancellation(); try directory.requireCurrentDestinationPath(); try directory.synchronize()
    try directory.promoteExclusive(from: "merge.json.partial", to: "merge.json", expectedBytes: UInt64(bytes.count), expectedSHA256: hash(bytes))
    do { try directory.synchronize() }
    catch { directory.withdrawCompletionMarkerBestEffort(from: "merge.json", to: "merge.json.partial"); throw error }
    return receipt
  }
  static func verifyWritten(directory: DVTapeEvidenceMapExporter.EvidenceDirectory, plan: Plan, inputs: [Input],
    choices: [UInt64: Candidate], progress: @Sendable (String, UInt64, UInt64) -> Void) async throws {
    func open(_ name: String) throws -> FileHandle {
      let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { throw error("cannot reread derivative") }
      var s = stat(); guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); throw error("nonregular output") }
      return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    let media = try open("merged.dv.partial"), ledger = try open("provenance.ndjson.partial")
    defer { try? media.close(); try? ledger.close() }
    for page in 0..<inputs[0].map.binding.pageCount {
      for record in try await inputs[0].map.page(page).records {
        try Task.checkCancellation()
        let ordinal = record.boundaryEvidence.frameOrdinal
        let p = try provenance(ordinal, plan: plan, choices: choices, baseHash: record.boundaryEvidence.frameSHA256)
        let line = try encode(p) + Data([10])
        guard let bytes = try media.read(upToCount: p.byteCount), bytes.count == p.byteCount,
          hash(bytes) == p.frameSHA256, try ledger.read(upToCount: line.count) == line else { throw error("frame-by-frame provenance reread failed") }
        if ordinal % 128 == 0 { progress("Reread every frame and provenance", ordinal, plan.inputs[0].source.frameCount) }
      }
    }
    guard try media.read(upToCount: 1)?.isEmpty != false, try ledger.read(upToCount: 1)?.isEmpty != false else { throw error("unexpected output tail") }
  }
}
