// Explicit operator-reviewed frame-range derivative, never an archival-master rewrite.
// Native Foundation/CryptoKit; offline only. No automatic blank/duplicate deletion.
import Foundation
import CryptoKit
import Darwin

@main struct DVReviewedRangeExport {
  static func main() throws {
    do { try run() }
    catch {
      try? FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  static func run() throws {
    guard CommandLine.arguments.count == 5,
      let first = UInt64(CommandLine.arguments[3]), let end = UInt64(CommandLine.arguments[4]),
      first < end else { throw DVIngestError.invalidEvidence("source directory, NEW destination, first ordinal, exclusive end required") }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let destination = URL(fileURLWithPath: CommandLine.arguments[2])
    let reportData = try Data(contentsOf: source.appendingPathComponent("verification.json"))
    let report = try JSONDecoder().decode(DVIngestVerification.self, from: reportData)
    guard report.integritySHA256Verified, report.nativeDVRereadVerified,
      report.captureFile == "capture.dv", end <= report.completeDVFrames,
      let sourceSHA = report.nativeDVSHA256 else { throw DVIngestError.invalidEvidence("source verification/range invalid") }
    // withIntermediateDirectories=false refuses any existing destination.
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let input = try FileHandle(forReadingFrom: source.appendingPathComponent("capture.dv"))
    defer { try? input.close() }
    let partial = destination.appendingPathComponent("reviewed.dv.partial")
    try Data().write(to: partial, options: .withoutOverwriting)
    let output = try FileHandle(forWritingTo: partial)
    defer { try? output.close() }
    var originalHash = SHA256(), selectedHash = SHA256()
    var originalBytes: UInt64 = 0, selectedBytes: UInt64 = 0
    for ordinal in 0..<report.completeDVFrames {
      guard let header = try input.read(upToCount: 80), header.count == 80,
        header[0] >> 5 == 0, header[1] >> 4 == 0, header[2] == 0 else {
        throw DVIngestError.invalidEvidence("missing DV frame header")
      }
      let size = header[3] & 0x80 == 0 ? 120_000 : 144_000
      guard let tail = try input.read(upToCount: size - 80), tail.count == size - 80 else {
        throw DVIngestError.invalidEvidence("truncated DV frame")
      }
      let frame = header + tail
      originalHash.update(data: frame); originalBytes += UInt64(size)
      if ordinal >= first && ordinal < end {
        try output.write(contentsOf: frame)
        selectedHash.update(data: frame); selectedBytes += UInt64(size)
      }
    }
    guard try input.read(upToCount: 1)?.isEmpty != false,
      originalBytes == report.dvBytes, hex(originalHash.finalize()) == sourceSHA else {
      throw DVIngestError.invalidEvidence("source reread hash/extent mismatch; partial derivative retained")
    }
    try output.synchronize(); try output.close()
    let reread = try FileHandle(forReadingFrom: partial)
    defer { try? reread.close() }
    var readHash = SHA256(), readBytes: UInt64 = 0
    while let data = try reread.read(upToCount: 1_048_576), !data.isEmpty {
      readHash.update(data: data); readBytes += UInt64(data.count)
    }
    let selectedSHA = hex(selectedHash.finalize())
    guard readBytes == selectedBytes, hex(readHash.finalize()) == selectedSHA else {
      throw DVIngestError.invalidEvidence("derivative reread mismatch")
    }
    let provenance: [String: Any] = [
      "schemaVersion": 1, "kind": "operator-reviewed derivative; NOT unmodified archival master",
      "sourceDirectory": source.path, "sourceDVSHA256": sourceSHA,
      "sourceVerificationSHA256": hex(SHA256.hash(data: reportData)),
      "sourceFrameCount": report.completeDVFrames, "firstSourceOrdinal": first,
      "exclusiveEndSourceOrdinal": end, "omittedLeadingFrames": first,
      "omittedTrailingFrames": report.completeDVFrames - end,
      "frameCount": end - first, "byteCount": selectedBytes, "SHA256": selectedSHA,
      "mapping": "output ordinal n = source ordinal firstSourceOrdinal + n; frame bytes unchanged",
      "sourceTimecodeRewritten": false, "audioResampled": false, "reencoded": false,
      "selection": "Explicit reviewed range, not automated gray/duplicate detection",
      "sourceQuality": report.sourceMediaDamage, "sourceCIPDiscontinuities": report.CIPDiscontinuities]
    try FileManager.default.moveItem(at: partial, to: destination.appendingPathComponent("reviewed.dv"))
    try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
      .write(to: destination.appendingPathComponent("provenance.json"), options: .withoutOverwriting)
    print("REVIEWED_RANGE_PASS frames=\(end - first) bytes=\(selectedBytes) sha256=\(selectedSHA); originals unchanged")
  }
  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
