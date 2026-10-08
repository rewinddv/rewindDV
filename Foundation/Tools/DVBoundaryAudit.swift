// Read-only native decoded-picture audit; no hardware or source writes.
import Foundation
import CoreVideo
import CryptoKit
import Darwin

@main struct DVBoundaryAudit {
  static func main() async throws {
    do { try await run() }
    catch {
      try? FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  static func run() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw DVIngestError.invalidEvidence("Provide a raw DV25 file")
    }
    let input = try DVAuditInput(URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { input.close() }
    let decoder = LiveDVFrameDecoder()
    var ordinal: UInt64 = 0
    var sourceOffset: UInt64 = 0
    var sourceHash = SHA256()
    var previousPixels: String?
    while let header = try input.readExactly(80) {
      guard header.count == 80 else { throw DVIngestError.invalidEvidence("Partial header") }
      let size = header[3] & 0x80 == 0 ? 120_000 : 144_000
      guard let tail = try input.readExactly(size - 80), tail.count == size - 80 else {
        throw DVIngestError.invalidEvidence("Partial frame")
      }
      let frame = header + tail
      let evidence = try DVBoundaryEvidence.inspect(frame: frame, ordinal: ordinal,
        sourceByteOffset: sourceOffset)
      let decoded = try await decoder.decode(frame, ordinal: ordinal, timecode: LiveDVMedia(frame: frame)?.timecode)
      let pixel = decoded.pixelBuffer
      guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
        throw DVIngestError.invalidEvidence("Cannot lock decoded image")
      }
      defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
      guard CVPixelBufferGetWidth(pixel) == 720,
        CVPixelBufferGetHeight(pixel) == (size == 144_000 ? 576 : 480),
        CVPixelBufferGetBytesPerRow(pixel) >= 720 * 2,
        CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_422YpCbCr8,
        let base = CVPixelBufferGetBaseAddress(pixel) else {
        throw DVIngestError.invalidEvidence("Unexpected native pixel layout")
      }
      var hash = SHA256()
      var low = 255, high = 0
      for row in 0..<CVPixelBufferGetHeight(pixel) {
        let bytes = Data(bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)),
          count: CVPixelBufferGetWidth(pixel) * 2)
        hash.update(data: bytes)
        for x in stride(from: 1, to: bytes.count, by: 2) {
          low = min(low, Int(bytes[x])); high = max(high, Int(bytes[x]))
        }
      }
      let sha = hash.finalize().map { String(format: "%02x", $0) }.joined()
      let result: [String: Any] = ["event": "frame_boundary_evidence", "schemaVersion": 2,
        "ordinal": ordinal, "timecode": decoded.timecode ?? "unknown",
        "decoded422SHA256": sha, "sameDecodedPixelsAsPrevious": previousPixels == sha,
        "lumaMinimum": low, "lumaMaximum": high,
        "sourceEvidence": try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))]
      try emit(result)
      sourceHash.update(data: frame); sourceOffset += UInt64(frame.count)
      previousPixels = sha; ordinal += 1
    }
    guard ordinal > 0 else { throw DVIngestError.invalidEvidence("No complete DV frames") }
    let sourceSHA = sourceHash.finalize().map { String(format: "%02x", $0) }.joined()
    guard UInt64(input.byteCount) == sourceOffset,
      try DVAuditInput.hash(URL(fileURLWithPath: CommandLine.arguments[1])) == sourceSHA else {
      throw DVIngestError.invalidEvidence("DV source changed during audit")
    }
    let summary: [String: Any] = ["event": "boundary_audit_complete", "schemaVersion": 2,
      "completeFrames": ordinal, "sourceBytes": sourceOffset,
      "sourceSHA256": sourceSHA,
      "policy": "Observations only; no automatic blank/duplicate removal or source rewrite. Prior lines are provisional without this completion event."]
    try emit(summary)
  }
  static func emit(_ value: [String: Any]) throws {
    try FileHandle.standardOutput.write(contentsOf:
      JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10]))
  }
}
