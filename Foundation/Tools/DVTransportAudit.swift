// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline replay of an already verified capture. No hardware access or writes.
import Foundation
import CryptoKit
import Darwin

@main struct DVTransportAudit {
  static func main() throws {
    do { try run() }
    catch {
      try? FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
  static func run() throws {
    guard CommandLine.arguments.count == 2 else {
      throw DVIngestError.invalidEvidence("Provide a verified closed capture directory")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let verification = try JSONDecoder().decode(DVIngestVerification.self,
      from: DVAuditInput.boundedMetadata(directory.appendingPathComponent("verification.json")))
    guard verification.schemaVersion == 1,
      verification.integritySHA256Verified, verification.nativeDVRereadVerified,
      verification.finalAcknowledgementConfirmed, !verification.legacyStoppedSnapshotUsed,
      verification.captureFile == "capture.dv", verification.frameManifestFile == "frames.ndjson",
      verification.verificationFile == "verification.json", verification.nativeDVSHA256 != nil,
      let status = Data(base64Encoded: verification.finalStatusWireBase64), status.count == 128 else {
      throw DVIngestError.invalidEvidence("Missing bound final status or verified source")
    }
    func word(_ offset: Int, _ size: Int) -> UInt64 {
      (0..<size).reduce(0) { $0 | UInt64(status[offset + $1]) << ($1 * 8) }
    }
    // Same final status and counter contract as DVIngestExporter.Terminal.
    let node = status[68] & 0x3f
    let epoch = word(16, 8), written = word(88, 8), seen = word(96, 8)
    let dropped = word(104, 8), oversized = word(112, 8), acknowledged = word(120, 8)
    guard word(0, 4) == 0x58524452, word(4, 2) == 1, word(6, 2) == 256,
      word(8, 4) == 4160, [8192, 65536].contains(word(12, 4)),
      word(24, 4) == 1, word(28, 4) == 48,
      [16,32,40,48,56].allSatisfy({ word($0, 8) != 0 }),
      word(70, 2) == 0, node < 63, word(80, 4) == 2, word(84, 4) == 0,
      seen >= written, seen - written == dropped, dropped >= oversized,
      acknowledged == written, written == verification.rawRecordCount,
      dropped == verification.knownDroppedPackets, oversized == verification.oversizedPackets,
      dropped - oversized == verification.hostRingDrops else {
      throw DVIngestError.invalidEvidence("Final status/route/counter contract rejected")
    }
    guard try DVAuditInput.hash(directory.appendingPathComponent("flight.ndjson")) == verification.journalSHA256 else {
      throw DVIngestError.invalidEvidence("Current journal hash mismatch")
    }
    let input = try DVAuditInput(directory.appendingPathComponent("receive.records.raw"))
    defer { input.close() }
    guard try input.readExactly(8) == Data("RDRXLOG1".utf8) else {
      throw DVIngestError.invalidEvidence("Raw magic mismatch")
    }
    var assembler = DVDIFPacketAssembler()
    var count: UInt64 = 0, bytes: UInt64 = 0, frameCount: UInt64 = 0, frameBytes: UInt64 = 0, loss: UInt64 = 0
    var rawGapEvents: UInt64 = 0, lastObserved: UInt64 = 0
    var rawHash = SHA256(), dvHash = SHA256()
    while let header = try input.readExactly(64) {
      guard header.count == 64 else { throw DVIngestError.invalidEvidence("Partial record header") }
      func number(_ offset: Int, _ size: Int) -> UInt64 {
        (0..<size).reduce(0) { $0 | UInt64(header[offset + $1]) << ($1 * 8) }
      }
      let length = number(36, 4), sequence = number(0, 8), nextLoss = number(48, 8)
      let observed = number(40, 8)
      guard length <= 4096, sequence == count + 1, nextLoss >= loss,
        number(8, 8) == epoch, number(56, 4) == 1, number(60, 4) == 0,
        observed > lastObserved, observed >= sequence, observed - sequence == nextLoss,
        sequence <= written, nextLoss <= dropped else {
        throw DVIngestError.invalidEvidence("Invalid record sequence/length/loss")
      }
      let payload = try input.readExactly(Int(length))
      guard let payload, payload.count == Int(length) else {
        throw DVIngestError.invalidEvidence("Partial record payload")
      }
      let before = assembler.discontinuities
      if nextLoss != loss { assembler.markTransportGap(); rawGapEvents += 1 }
      let frames = assembler.consumePreservedPacket(payload,
        transferStatus: UInt16(number(32, 2)), expectedSourceNode: node)
      if assembler.discontinuities != before {
        try emit(["event": "discontinuity", "recordSequence": sequence,
          "rawRecordByteOffset": bytes + 8, "completedFramesBeforeRecord": frameCount,
          "newDiscontinuities": assembler.discontinuities - before,
          "hostLossCounterIncreased": nextLoss != loss, "observedDBC": payload.count >= 12 ? Int(payload[11]) : -1,
          "scope": "Assembler discontinuity observation; not an exact lost-frame count or cause diagnosis"])
      }
      for frame in frames { dvHash.update(data: frame); frameCount += 1; frameBytes += UInt64(frame.count) }
      rawHash.update(data: header); rawHash.update(data: payload)
      count += 1; bytes += UInt64(64 + payload.count); loss = nextLoss; lastObserved = observed
    }
    if dropped > loss {
      assembler.markTransportGap(); rawGapEvents += 1
      try emit(["event": "terminal_raw_gap", "completedFrames": frameCount,
        "additionalKnownLostPackets": dropped - loss])
    }
    assembler.finish()
    let rawSHA = hex(rawHash.finalize()), dvSHA = hex(dvHash.finalize())
    guard count == verification.rawRecordCount, bytes == verification.rawRecordBytes,
      rawSHA == verification.rawRecordSHA256, dvSHA == verification.nativeDVSHA256,
      frameCount == verification.completeDVFrames, frameBytes == verification.dvBytes,
      seen >= lastObserved, assembler.discontinuities >= rawGapEvents,
      assembler.discontinuities - rawGapEvents == verification.CIPDiscontinuities,
      rawGapEvents == verification.rawTransportGapEvents,
      assembler.incompleteFrames == verification.incompleteFrames,
      assembler.rejectedPackets == verification.rejectedPackets else {
      throw DVIngestError.invalidEvidence("Replay differs from verified source; earlier output is provisional")
    }
    guard try DVAuditInput.hash(directory.appendingPathComponent("capture.dv")) == dvSHA,
      try DVAuditInput.hash(directory.appendingPathComponent("flight.ndjson")) == verification.journalSHA256 else {
      throw DVIngestError.invalidEvidence("Current DV or journal hash mismatch")
    }
    try emit(["event": "transport_audit_complete", "rawSHA256": rawSHA,
      "dvSHA256": dvSHA, "records": count, "frames": frameCount,
      "CIPDiscontinuities": assembler.discontinuities - rawGapEvents, "rawTransportGapEvents": rawGapEvents,
      "scope": "Hash-bound offline replay; does not establish hardware continuity"])
  }
  static func emit(_ value: [String: Any]) throws {
    try FileHandle.standardOutput.write(contentsOf:
      JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10]))
  }
  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
