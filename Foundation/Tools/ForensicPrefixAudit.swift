// Read-only, hash-bound replay of a recovered prefix. No driver/IOKit calls.
import CryptoKit
import Foundation
@main struct ForensicPrefixAudit {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { throw DVIngestError.invalidEvidence("Supply a forensic-prefix output folder") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let receipt = try JSONDecoder().decode(DVForensicPrefix.Receipt.self,
      from: Data(contentsOf: directory.appendingPathComponent("forensic-prefix.json")))
    guard receipt.state == "INCOMPLETE_ACQUISITION_VERIFIED_PREFIX",
      let route = Data(base64Encoded: receipt.routeBase64), route.count == 48 else { throw DVIngestError.invalidEvidence("Not a prefix receipt") }
    let source = try DVForensicPrefix.Source(directory.appendingPathComponent("verified-prefix.raw"))
    guard try source.read(8) == Data("RDRXLOG1".utf8), source.size == receipt.verifiedPrefixRecordBytes + 8 else { throw DVIngestError.invalidEvidence("prefix length/magic") }
    var assembler = DVDIFPacketAssembler(), digest = SHA256(), videoHash = SHA256()
    var at: UInt64 = 0, records: UInt64 = 0, frames: UInt64 = 0, loss: UInt64 = 0
    var events: [[String: Any]] = [], previousDBC = -1, previousLength = 0
    while at < receipt.verifiedPrefixRecordBytes {
      let h = try source.read(64), size = DVForensicPrefix.value(h,36,UInt32.self)
      guard size <= 4096, at + 64 + UInt64(size) <= receipt.verifiedPrefixRecordBytes else { throw DVIngestError.invalidEvidence("record length") }
      let p = try source.read(Int(size)), seq = DVForensicPrefix.value(h,0,UInt64.self), nextLoss = DVForensicPrefix.value(h,48,UInt64.self)
      guard seq == records + 1, DVForensicPrefix.value(h,8,UInt64.self) == receipt.epoch, nextLoss >= loss else { throw DVIngestError.invalidEvidence("record epoch/sequence") }
      let before = assembler.discontinuities, discarded = assembler.dbcDiscontinuitiesDiscardingPartialFrames
      let afterEmpty = assembler.dbcDiscontinuitiesAfterEmptyPackets
      if nextLoss > loss { assembler.markTransportGap() }
      let decoded = assembler.consumePreservedPacket(p, transferStatus: DVForensicPrefix.value(h,32,UInt16.self), expectedSourceNode: route[44] & 0x3f)
      if assembler.discontinuities != before {
        guard events.count < 10000 else { throw DVIngestError.invalidEvidence("event budget exceeded; report is incomplete") }
        events.append(["event":"continuity", "recordSequence":seq,"rawRecordOffset":at + 8,
          "hostTicks":DVForensicPrefix.value(h,16,UInt64.self),"completedFramesBefore":frames,
          "previousDBC":previousDBC,"observedDBC":p.count >= 12 ? Int(p[11]) : -1,
          "previousPayloadBytes":previousLength,"currentPayloadBytes":p.count,
          "afterEmpty":assembler.dbcDiscontinuitiesAfterEmptyPackets - afterEmpty,
          "discardedPartial":assembler.dbcDiscontinuitiesDiscardingPartialFrames - discarded,
          "knownLossDelta":nextLoss - loss])
      }
      for frame in decoded { videoHash.update(data: frame); frames += 1 }
      digest.update(data:h); digest.update(data:p); at += 64 + UInt64(size); records = seq; loss = nextLoss
      previousDBC = p.count >= 12 ? Int(p[11]) : -1; previousLength = p.count
    }
    assembler.finish(); try source.check()
    let hash = digest.finalize().map { String(format:"%02x",$0) }.joined()
    let dvHash = videoHash.finalize().map { String(format:"%02x",$0) }.joined()
    guard hash == receipt.prefixSHA256, frames == receipt.completeFrames, records == receipt.records,
      loss == receipt.knownDroppedPackets, assembler.discontinuities == receipt.continuityEvents,
      assembler.incompleteFrames == receipt.incompleteFrames,
      receipt.nativeDVSHA256 == nil || dvHash == receipt.nativeDVSHA256 else { throw DVIngestError.invalidEvidence("reread differs from prefix receipt") }
    let output: [String:Any] = ["events":events,"records":records,"frames":frames,
      "terminalPartialFrames":assembler.terminalPartialFrames,"prefixSHA256":hash,
      "scope":"Hash-bound prefix only. Empty-packet DBC changes and terminal partial frames are observations, not proof of physical cause or zero source loss."]
    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output, options:[.sortedKeys,.prettyPrinted]) + Data([10]))
  }
}
