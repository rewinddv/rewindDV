// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Separate salvage namespace. Never manufactures a clean stopped status or
/// calls/loosens exportClosedFlight. Unknown tails remain unknown.
public enum DVForensicPrefix {
  public struct Receipt: Codable, Sendable {
    public let state: String
    public let sourceRawBytes: UInt64
    public let verifiedPrefixRecordBytes: UInt64
    public let unverifiedTailBytes: UInt64
    public let prefixSHA256: String
    public let journalSHA256: String
    public let routeBase64: String
    public let epoch: UInt64
    public let records: UInt64
    public let completeFrames: UInt64
    public let knownDroppedPackets: UInt64
    public let continuityEvents: UInt64
    public let incompleteFrames: UInt64
    public let rejectedPackets: UInt64
    public let dbcAfterEmpty: UInt64
    public let dbcDiscardedPartial: UInt64
    public let terminalPartialFrames: UInt64
    public let nativeDVSHA256: String?
    public let provenanceSHA256: String
    public let policy: String
  }
  struct Event: Decodable {
    let schemaVersion: Int; let event: String; let wireBase64: String
    let recordBytes: UInt64; let recordSHA256: String
  }
  struct FrameProof: Codable {
    let frame: UInt64; let outputOffset: UInt64; let byteCount: Int; let sha256: String
    let firstRecord: UInt64; let lastRecord: UInt64
    let rawStart: UInt64; let rawEndExclusive: UInt64
  }
  final class Source {
    let handle: FileHandle, url: URL, initial: stat
    var size: UInt64 { UInt64(initial.st_size) }
    init(_ url: URL) throws {
      let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw failure("cannot open regular original") }
      var s = stat()
      guard fstat(fd,&s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size >= 0 else { Darwin.close(fd); throw failure("nonregular original") }
      handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); self.url = url; initial = s
    }
    func check() throws {
      try Task.checkCancellation()
      var a = stat(), b = stat()
      guard fstat(handle.fileDescriptor,&a) == 0, lstat(url.path,&b) == 0,
        a.st_dev == initial.st_dev, a.st_ino == initial.st_ino, b.st_dev == a.st_dev, b.st_ino == a.st_ino,
        a.st_size == initial.st_size, a.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
        a.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
        a.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
        a.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw failure("original changed; stop using an active flight") }
    }
    func read(_ count: Int) throws -> Data {
      var data = Data()
      while data.count < count {
        guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { throw failure("truncated original or checkpoint") }
        data.append(part)
      }
      return data
    }
  }
  static func failure(_ message: String) -> DVIngestError { .invalidEvidence("forensic prefix: " + message) }
  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
  static func encode<T: Encodable>(_ x: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(x) }
  static func value<T: FixedWidthInteger>(_ d: Data, _ at: Int, _ type: T.Type) -> T {
    d[at..<(at + MemoryLayout<T>.size)].enumerated().reduce(T(0)) { $0 | T($1.element) << ($1.offset * 8) }
  }
  static func journal(_ data: Data) throws -> (route: Data, epoch: UInt64, checkpoint: Event) {
    var route: Data?, epoch: UInt64?, checkpoint: Event?, prior: UInt64 = 0
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    guard lines.count <= 500_001 else { throw failure("journal event budget exceeded") }
    // Only an unterminated final line can be ignored. It is retained verbatim.
    for line in lines.dropLast() {
      try Task.checkCancellation()
      guard !line.isEmpty, line.count <= 1_048_576 else { throw failure("invalid journal line size") }
      let e = try JSONDecoder().decode(Event.self, from: Data(line))
      guard e.schemaVersion == 1, e.recordBytes >= prior, e.recordSHA256.count == 64,
        e.recordSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw failure("invalid journal checkpoint") }
      prior = e.recordBytes
      if e.event == "receive_start_intent" {
        guard route == nil, let r = Data(base64Encoded: e.wireBase64), r.count == 48,
          value(r,0,UInt32.self) == 1, value(r,4,UInt32.self) == 48,
          [8,16,24,32].allSatisfy({ value(r,$0,UInt64.self) != 0 }),
          value(r,46,UInt16.self) == 0, value(r,44,UInt16.self) & 0x3f < 63 else { throw failure("ambiguous or invalid initial route") }
        route = r
      }
      guard route != nil else { throw failure("journal lacks initial route") }
      if e.event == "receive_start_returned" {
        guard let s = Data(base64Encoded: e.wireBase64), s.count == 24,
          value(s,0,UInt32.self) == 1, value(s,4,UInt32.self) == 24,
          value(s,8,UInt64.self) > 0, value(s,16,UInt32.self) <= 4,
          value(s,20,UInt32.self) == 0,
          epoch == nil || epoch == value(s,8,UInt64.self) else { throw failure("invalid receive-session reply") }
        epoch = value(s,8,UInt64.self)
      }
      if ["receive_status", "receive_stop_returned", "receive_cleanup_completed", "receive_final_status", "receive_cleanup_status", "receive_cleanup_last_observed_status"].contains(e.event) {
        guard let s = Data(base64Encoded: e.wireBase64), s.count == 128,
          value(s,0,UInt32.self) == 0x58524452, value(s,4,UInt16.self) == 1,
          value(s,6,UInt16.self) == 256, value(s,8,UInt32.self) == 4160,
          [UInt32(8192),65536].contains(value(s,12,UInt32.self)), s.subdata(in:24..<72) == route,
          value(s,16,UInt64.self) != 0 else { throw failure("invalid status/route/epoch evidence") }
        let observedEpoch = value(s,16,UInt64.self)
        guard epoch == nil || epoch == observedEpoch else { throw failure("journal spans receive epochs") }
        epoch = observedEpoch
      }
      if let previous = checkpoint, previous.recordBytes == e.recordBytes,
        previous.recordSHA256 != e.recordSHA256 { throw failure("conflicting equal-length checkpoints") }
      checkpoint = e
    }
    guard let route, let epoch, let checkpoint, checkpoint.recordBytes > 0 else { throw failure("no bound epoch and nonempty durable-prefix checkpoint; bytes alone are not durability proof") }
    return (route,epoch,checkpoint)
  }
  public static func export(source: URL, destination: URL,
    progress: @Sendable (String, UInt64, UInt64) -> Void = { _,_,_ in }) throws -> Receipt {
    guard !DVGentleRecovery.isWithin(destination,directory:source) else { throw failure("choose a new destination outside the original flight") }
    let raw = try Source(source.appendingPathComponent("receive.records.raw"))
    let log = try Source(source.appendingPathComponent("flight.ndjson"))
    guard log.size > 0, log.size <= 67_108_864 else { throw failure("journal exceeds 64 MiB forensic budget") }
    let journalBytes = try log.read(Int(log.size)), evidence = try journal(journalBytes)
    let limit = evidence.checkpoint.recordBytes
    guard raw.size >= 8, limit <= raw.size - 8 else { throw failure("checkpoint extends past available raw bytes") }
    // First verify the bounded prefix before creating any destination.
    guard try raw.read(8) == Data("RDRXLOG1".utf8) else { throw failure("raw magic mismatch") }
    var digest = SHA256(), done: UInt64 = 0
    while done < limit {
      try Task.checkCancellation()
      let bytes = try raw.read(Int(min(1_048_576,limit - done))); digest.update(data:bytes); done += UInt64(bytes.count)
      progress("Verify recorded durable prefix",done,limit)
    }
    guard digest.finalize().map({String(format:"%02x",$0)}).joined() == evidence.checkpoint.recordSHA256 else { throw failure("recorded prefix hash mismatch") }
    try raw.check(); try log.check()
    let output = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { output.close() }
    try output.writeExclusive(named:"intent.json",data:try encode(["state":"incomplete_forensic_work; completion requires forensic-prefix.json"]),synchronize:true)
    try output.writeExclusive(named:"source-flight.ndjson.partial",data:journalBytes,synchronize:true)
    let copy = try output.makeExclusiveWriter(named:"verified-prefix.raw.partial")
    let dv = try output.makeExclusiveWriter(named:"recovered-complete-frames.dv.partial")
    let proofs = try output.makeExclusiveWriter(named:"frames.ndjson.partial")
    defer { try? copy.close(); try? dv.close(); try? proofs.close() }
    try copy.write(contentsOf:Data("RDRXLOG1".utf8))
    var assembler = DVDIFPacketAssembler(), records: UInt64 = 0, offset: UInt64 = 0, epoch: UInt64 = 0
    var seen: UInt64 = 0, loss: UInt64 = 0, frames: UInt64 = 0, nativeBytes: UInt64 = 0
    var firstRecord: UInt64 = 1, firstOffset: UInt64 = 8
    try raw.handle.seek(toOffset:8)
    while offset < limit {
      try Task.checkCancellation()
      guard limit - offset >= 64 else { throw failure("checkpoint splits record header") }
      let header = try raw.read(64), sequence = value(header,0,UInt64.self), currentEpoch = value(header,8,UInt64.self)
      let size = value(header,36,UInt32.self), observed = value(header,40,UInt64.self), dropped = value(header,48,UInt64.self)
      if epoch == 0 { epoch = currentEpoch }
      guard sequence == records + 1, epoch == evidence.epoch, currentEpoch == epoch, size <= 4096,
        UInt64(size) <= limit - offset - 64, value(header,56,UInt32.self) == 1, value(header,60,UInt32.self) == 0,
        observed > seen, dropped >= loss, observed >= sequence, observed - sequence == dropped else { throw failure("invalid sequence/epoch/length/loss or checkpoint boundary") }
      let payload = try raw.read(Int(size)), recordStart = offset + 8
      try copy.write(contentsOf:header); try copy.write(contentsOf:payload)
      offset += 64 + UInt64(size); records = sequence
      if dropped != loss { assembler.markTransportGap() }
      loss = dropped; seen = observed
      for frame in assembler.consumePreservedPacket(payload,transferStatus:value(header,32,UInt16.self),expectedSourceNode:evidence.route[44] & 0x3f) {
        _ = try DVMetadataInventory.inspect(frame:frame,ordinal:frames,byteOffset:nativeBytes)
        let proof = FrameProof(frame:frames,outputOffset:nativeBytes,byteCount:frame.count,sha256:hash(frame),
          firstRecord:firstRecord,lastRecord:sequence,rawStart:firstOffset,rawEndExclusive:8 + offset)
        try dv.write(contentsOf:frame); try proofs.write(contentsOf:try encode(proof) + Data([10]))
        nativeBytes += UInt64(frame.count); frames += 1; firstRecord = sequence; firstOffset = recordStart
      }
      if records % 2048 == 0 { progress("Recover complete frames; acquisition remains incomplete",offset,limit) }
    }
    assembler.finish()
    try copy.synchronize(); try dv.synchronize(); try proofs.synchronize()
    try copy.close(); try dv.close(); try proofs.close()
    let rawCheck = try output.hashRegularFile(named:"verified-prefix.raw.partial")
    let dvCheck = try output.hashRegularFile(named:"recovered-complete-frames.dv.partial")
    let proofCheck = try output.hashRegularFile(named:"frames.ndjson.partial")
    // Second assembly is from the exported raw copy, not the first assembler.
    let reread = try Source(destination.appendingPathComponent("verified-prefix.raw.partial"))
    let media = try Source(destination.appendingPathComponent("recovered-complete-frames.dv.partial"))
    let ledger = try Source(destination.appendingPathComponent("frames.ndjson.partial"))
    guard try reread.read(8) == Data("RDRXLOG1".utf8) else { throw failure("copy magic mismatch") }
    var second = DVDIFPacketAssembler(), secondHash = SHA256(), at: UInt64 = 0, count: UInt64 = 0, previousLoss: UInt64 = 0
    var secondStart: UInt64 = 1, secondOffset: UInt64 = 8, secondDVOffset: UInt64 = 0
    while at < limit {
      try Task.checkCancellation()
      let h = try reread.read(64), n = value(h,36,UInt32.self), seq = value(h,0,UInt64.self), drop = value(h,48,UInt64.self)
      guard n <= 4096, at + 64 + UInt64(n) <= limit else { throw failure("reread length") }
      let p = try reread.read(Int(n)), start = at + 8
      secondHash.update(data:h); secondHash.update(data:p); at += 64 + UInt64(n)
      if drop != previousLoss { second.markTransportGap() }; previousLoss = drop
      for frame in second.consumePreservedPacket(p,transferStatus:value(h,32,UInt16.self),expectedSourceNode:evidence.route[44] & 0x3f) {
        let proof = FrameProof(frame:count,outputOffset:secondDVOffset,byteCount:frame.count,sha256:hash(frame),firstRecord:secondStart,lastRecord:seq,rawStart:secondOffset,rawEndExclusive:8 + at)
        let line = try encode(proof) + Data([10])
        guard try media.read(frame.count) == frame, try ledger.read(line.count) == line else { throw failure("independent DV/provenance reread mismatch") }
        count += 1; secondDVOffset += UInt64(frame.count); secondStart = seq; secondOffset = start
      }
      if seq % 2048 == 0 { progress("Independently reassemble exported prefix",at,limit) }
    }
    guard count == frames, secondDVOffset == nativeBytes, media.size == nativeBytes, ledger.handle.offsetInFile == ledger.size,
      reread.size == limit + 8, secondHash.finalize().map({String(format:"%02x",$0)}).joined() == evidence.checkpoint.recordSHA256 else { throw failure("independent prefix coverage mismatch") }
    try raw.check(); try log.check(); try reread.check(); try media.check(); try ledger.check()
    let receipt = Receipt(state:"INCOMPLETE_ACQUISITION_VERIFIED_PREFIX",sourceRawBytes:raw.size,verifiedPrefixRecordBytes:limit,
      unverifiedTailBytes:raw.size - 8 - limit,prefixSHA256:evidence.checkpoint.recordSHA256,journalSHA256:hash(journalBytes),routeBase64:evidence.route.base64EncodedString(),epoch:epoch,records:records,completeFrames:frames,
      knownDroppedPackets:loss,continuityEvents:assembler.discontinuities,incompleteFrames:assembler.incompleteFrames,rejectedPackets:assembler.rejectedPackets,
      dbcAfterEmpty:assembler.dbcDiscontinuitiesAfterEmptyPackets,dbcDiscardedPartial:assembler.dbcDiscontinuitiesDiscardingPartialFrames,terminalPartialFrames:assembler.terminalPartialFrames,
      nativeDVSHA256:frames == 0 ? nil : dvCheck.sha256,provenanceSHA256:proofCheck.sha256,
      policy:"Incomplete acquisition, never a clean/full-tape capture. Prefix matches a recorded post-sync checkpoint and was independently reread/reassembled. Unverified tail is excluded, never declared lost/empty. Original flight unchanged. Record provenance is a conservative inclusive range; packets may be shared. Hashes are consistency evidence, not authenticated history or a guarantee against hardware loss.")
    for (name,bytes,sha) in [("verified-prefix.raw",rawCheck.bytes,rawCheck.sha256),("frames.ndjson",proofCheck.bytes,proofCheck.sha256),("source-flight.ndjson",UInt64(journalBytes.count),hash(journalBytes))] {
      try output.promoteExclusive(from:name + ".partial",to:name,expectedBytes:bytes,expectedSHA256:sha)
    }
    if frames > 0 { try output.promoteExclusive(from:"recovered-complete-frames.dv.partial",to:"recovered-complete-frames.dv",expectedBytes:dvCheck.bytes,expectedSHA256:dvCheck.sha256) }
    let receiptBytes = try encode(receipt)
    try output.writeExclusive(named:"forensic-prefix.json.partial",data:receiptBytes,synchronize:true)
    try raw.check(); try log.check(); try output.requireCurrentDestinationPath(); try output.synchronize()
    try output.promoteExclusive(from:"forensic-prefix.json.partial",to:"forensic-prefix.json",expectedBytes:UInt64(receiptBytes.count),expectedSHA256:hash(receiptBytes))
    do { try output.synchronize() } catch { output.withdrawCompletionMarkerBestEffort(from:"forensic-prefix.json",to:"forensic-prefix.json.partial"); throw error }
    return receipt
  }
}
