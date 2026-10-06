// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// Exclusive derivative publication. No source writes, codec, remux or hardware.
public enum DVSurgeryByteExporter {
  public struct Range: Codable, Sendable, Equatable {
    public let firstFrame: Int
    public let endFrameExclusive: Int
    public let byteOffset: UInt64
    public let byteCount: UInt64
    public let startSeconds: Double
    public let endSeconds: Double
    public let format: String
    public init(firstFrame: Int, endFrameExclusive: Int, byteOffset: UInt64, byteCount: UInt64,
      startSeconds: Double, endSeconds: Double, format: String) {
      self.firstFrame = firstFrame; self.endFrameExclusive = endFrameExclusive
      self.byteOffset = byteOffset; self.byteCount = byteCount
      self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.format = format
    }
  }
  public enum Layout: String, Sendable { case separate, merged }
  public struct Piece: Codable, Sendable {
    public let range: Range
    public let outputByteOffset: UInt64
    public let outputFirstFrame: Int
  }
  public struct Output: Codable, Sendable {
    public let file: String
    public let pieces: [Piece]
    public let byteCount: UInt64
    public let sha256: String
  }
  public struct Receipt: Encodable, Sendable {
    public let schemaVersion = 2
    public let state = "complete_verified"
    public let sourceSHA256: String
    public let sourceBytes: UInt64
    public let layout: String
    public let outputs: [Output]
    public let policy = "Original DV frame bytes copied unchanged; no re-encoding, audio resampling or metadata rewrite. End frame is exclusive. Pieces map disjoint source ranges into each output in source order. Source timecode and recording metadata are retained and may jump at joins. Saved outputs reread and SHA-256 verified. This is offline byte verification, not capture/hardware qualification."
  }
  public static func export(source: URL, expectedSHA256: String, ranges: [Range], destination: URL, layout: Layout = .separate,
    progress: (Double) -> Void = { _ in }) throws -> Receipt {
    guard !ranges.isEmpty else { throw DVIngestError.invalidEvidence("no ranges selected") }
    let input = try DVReviewedRangeExporter.RegularSource(source)
    defer { input.close() }
    var previousEnd = 0, previousByteEnd: UInt64 = 0
    for r in ranges {
      guard r.firstFrame >= previousEnd, r.firstFrame < r.endFrameExclusive,
        r.byteOffset >= previousByteEnd, r.byteOffset <= input.byteCount,
        r.byteCount > 0, r.byteCount <= input.byteCount - r.byteOffset,
        r.startSeconds.isFinite, r.endSeconds.isFinite, r.startSeconds >= 0, r.endSeconds > r.startSeconds else {
        throw DVIngestError.invalidEvidence("invalid, overlapping or out-of-source Surgery range")
      }
      previousEnd = r.endFrameExclusive; previousByteEnd = r.byteOffset + r.byteCount
    }
    let before = try input.hashToEOF()
    guard before.sha256 == expectedSHA256 else { throw DVIngestError.invalidEvidence("source bytes changed since analysis; reopen the clip") }
    try input.requireStableAndCurrentPath(source)
    try input.rewind()
    let directory = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { directory.close() }
    try directory.writeExclusive(named: "export-intent.json", data: Data("{\"state\":\"incomplete_until_surgery.json\"}".utf8), synchronize: true)
    var index = 0, ordinal = 0, offset: UInt64 = 0, ticks: Int64 = 0
    var writer: FileHandle?, outputHash = SHA256(), sourceHash = SHA256(), outputBytes: UInt64 = 0
    var outputs: [Output] = [], pieces: [Piece] = []
    var rangeBytes: UInt64 = 0, outputFrames = 0
    var mergedProfile: Int?
    func finishOutput(_ name: String) throws {
      try writer?.synchronize(); try writer?.close(); writer = nil
      let digest = hex(outputHash.finalize()), reread = try directory.hashRegularFile(named: name + ".partial")
      guard reread.bytes == outputBytes, reread.sha256 == digest else { throw DVIngestError.invalidEvidence("saved Surgery output failed verification") }
      outputs.append(Output(file: name, pieces: pieces, byteCount: outputBytes, sha256: digest))
      outputHash = SHA256(); outputBytes = 0; outputFrames = 0; pieces = []
    }
    defer { try? writer?.close() }
    while offset < input.byteCount {
      try Task.checkCancellation()
      let header = try input.readExactly(80)
      let pal = header[3] & 128 != 0, count = pal ? 144000 : 120000
      let bytes = header + (try input.readExactly(count - 80))
      try DVReviewedRangeExporter.validateCanonicalOrder(bytes, sequenceCount: pal ? 12 : 10)
      sourceHash.update(data: bytes)
      if index < ranges.count {
        let r = ranges[index], name = layout == .merged ? "merged.dv" : String(format: "clip-%03d.dv", index + 1)
        if ordinal == r.firstFrame {
          guard offset == r.byteOffset, abs(Double(ticks) / 30000 - r.startSeconds) < 0.000001 else { throw DVIngestError.invalidEvidence("range start does not match a source frame boundary") }
          if writer == nil { writer = try directory.makeExclusiveWriter(named: name + ".partial") }
          rangeBytes = 0
          pieces.append(Piece(range: r, outputByteOffset: outputBytes, outputFirstFrame: outputFrames))
        }
        if ordinal >= r.firstFrame && ordinal < r.endFrameExclusive {
          guard let writer else { throw DVIngestError.invalidEvidence("missing output writer") }
          if layout == .merged {
            let profile = try mergeProfile(bytes, pal: pal)
            guard mergedProfile == nil || mergedProfile == profile else {
              throw DVIngestError.invalidEvidence("Merged segments must share the same NTSC/PAL and DV application profile. Export different formats separately.")
            }
            mergedProfile = profile
          }
          try writer.write(contentsOf: bytes); outputHash.update(data: bytes); outputBytes += UInt64(count)
          rangeBytes += UInt64(count); outputFrames += 1
        }
        if ordinal + 1 == r.endFrameExclusive {
          guard rangeBytes == r.byteCount,
            abs(Double(ticks + (pal ? 1200 : 1001)) / 30000 - r.endSeconds) < 0.000001 else { throw DVIngestError.invalidEvidence("range end does not match a source frame boundary") }
          index += 1
          if layout == .separate || index == ranges.count { try finishOutput(name) }
        }
      }
      ordinal += 1; offset += UInt64(count); ticks += pal ? 1200 : 1001
      if ordinal % 128 == 0 { progress(Double(offset) / Double(max(1, input.byteCount))) }
    }
    guard index == ranges.count, hex(sourceHash.finalize()) == expectedSHA256, try input.isAtEOF() else {
      throw DVIngestError.invalidEvidence("source changed or selected frame range is incomplete")
    }
    try input.requireStableAndCurrentPath(source)
    for output in outputs {
      try Task.checkCancellation()
      try directory.promoteExclusive(from: output.file + ".partial", to: output.file,
        expectedBytes: output.byteCount, expectedSHA256: output.sha256)
    }
    let receipt = Receipt(sourceSHA256: expectedSHA256, sourceBytes: input.byteCount, layout: layout.rawValue, outputs: outputs)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt)
    try directory.writeExclusive(named: "surgery.json.partial", data: data, synchronize: true)
    try input.requireStableAndCurrentPath(source)
    try Task.checkCancellation()
    try directory.synchronize()
    try directory.promoteExclusive(from: "surgery.json.partial", to: "surgery.json", expectedBytes: UInt64(data.count), expectedSHA256: hex(SHA256.hash(data: data)))
    do { try directory.synchronize() }
    catch { directory.withdrawCompletionMarkerBestEffort(from: "surgery.json", to: "surgery.json.partial"); throw error }
    progress(1)
    return receipt
  }
  /// Check actual selected frame bytes, never the caller's display labels.
  private static func mergeProfile(_ data: Data, pal: Bool) throws -> Int {
    try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      let apt = p[4] & 7
      guard apt <= 1 else { throw DVIngestError.invalidEvidence("Unsupported DV application profile for merging") }
      for at in stride(from: 0, to: p.count, by: 80) {
        let section = p[at] >> 5
        guard p[at + 1] & 12 == 4 else { throw DVIngestError.invalidEvidence("Multichannel DVCPRO merging is unsupported") }
        if section == 0 {
          guard (4...7).allSatisfy({ p[at + $0] & 7 == apt }) else { throw DVIngestError.invalidEvidence("Conflicting DV application profiles") }
        }
        if section == 2 {
          for slot in stride(from: 3, through: 73, by: 5) where p[at + slot] == 0x60 {
            guard p[at + slot + 3] & 31 == 0, (p[at + slot + 3] & 32 != 0) == pal else {
              throw DVIngestError.invalidEvidence("Unsupported or conflicting DV25 video profile")
            }
          }
        }
      }
      return (pal ? 8 : 0) + Int(apt)
    }
  }
  private static func hex<D: Sequence>(_ value: D) -> String where D.Element == UInt8 { value.map { String(format: "%02x", $0) }.joined() }
}
