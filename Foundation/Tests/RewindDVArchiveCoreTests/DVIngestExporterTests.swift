// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Synthetic transport only; these tests do not qualify hardware continuity.
import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

func ingestPut<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}

func ingestFrame(pal: Bool) -> Data {
  var frame = Data()
  for sequence in 0..<(pal ? 12 : 10) {
    func block(_ section: UInt8, _ number: Int) -> Data {
      var bytes = Data(repeating: 0xff, count: 80)
      bytes[0] = section << 5 | 0x1f
      bytes[1] = UInt8(sequence << 4) | 7
      bytes[2] = UInt8(number)
      if section == 0 {
        bytes[3] = pal ? 0x80 : 0
        for index in 4...7 { bytes[index] = 0 }
      }
      if section == 3 { bytes.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, 0]) }
      return bytes
    }
    frame.append(block(0, 0))
    for index in 0..<2 { frame.append(block(1, index)) }
    for index in 0..<3 { frame.append(block(2, index)) }
    for group in 0..<9 {
      frame.append(block(3, group))
      for index in group * 15..<(group + 1) * 15 { frame.append(block(4, index)) }
    }
  }
  return frame
}

func ingestPackets(_ frame: Data, blocksPerPacket: Int = 1) -> [Data] {
  var packets: [Data] = []
  for offset in stride(from: 0, to: frame.count, by: 480 * blocksPerPacket) {
    var packet = Data([0, 0, 0, 0, 0, 0, 0, 0, 7, 120, 0,
      UInt8(truncatingIfNeeded: offset / 480), 0x80, 0, 0xff, 0xff])
    packet.append(frame[offset..<min(frame.count, offset + 480 * blocksPerPacket)])
    packets.append(packet)
  }
  return packets
}

struct IngestFixture {
  let url: URL
  let raw: Data
  init(packets: [Data], losses: [Int: UInt64] = [:], tailDrops: UInt64 = 0,
    oversized: UInt64 = 0, closed: Bool = true, acknowledged: UInt64? = nil,
    finalStatus: Bool = true, finalDiagnostics: Bool = false, mutateStatus: ((inout Data) -> Void)? = nil,
    mutateHeader: ((Int, inout Data) -> Void)? = nil) throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("DVIngest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    var route = Data(repeating: 0, count: 48)
    ingestPut(UInt32(1), into: &route, at: 0)
    ingestPut(UInt32(48), into: &route, at: 4)
    for offset in [8, 16, 24, 32] { ingestPut(UInt64(offset), into: &route, at: offset) }
    ingestPut(UInt32(1), into: &route, at: 40)
    ingestPut(UInt16(7), into: &route, at: 44)
    var records = Data(), drops: UInt64 = 0
    for (index, packet) in packets.enumerated() {
      drops += losses[index] ?? 0
      let sequence = UInt64(index + 1)
      var header = Data(repeating: 0, count: 64)
      ingestPut(sequence, into: &header, at: 0)
      ingestPut(UInt64(1), into: &header, at: 8)
      ingestPut(sequence * 100, into: &header, at: 16)
      ingestPut(UInt16(0x11), into: &header, at: 32)
      ingestPut(UInt32(packet.count), into: &header, at: 36)
      ingestPut(sequence + drops, into: &header, at: 40)
      ingestPut(drops, into: &header, at: 48)
      ingestPut(UInt32(1), into: &header, at: 56)
      mutateHeader?(index, &header)
      records.append(header)
      records.append(packet)
    }
    raw = Data("RDRXLOG1".utf8) + records
    try raw.write(to: url.appendingPathComponent("receive.records.raw"))
    var status = Data(repeating: 0, count: 128)
    ingestPut(UInt32(0x58524452), into: &status, at: 0)
    ingestPut(UInt16(1), into: &status, at: 4)
    ingestPut(UInt16(256), into: &status, at: 6)
    ingestPut(UInt32(4160), into: &status, at: 8)
    ingestPut(UInt32(8192), into: &status, at: 12)
    ingestPut(UInt64(1), into: &status, at: 16)
    status.replaceSubrange(24..<72, with: route)
    ingestPut(UInt32(2), into: &status, at: 80)
    ingestPut(UInt64(packets.count), into: &status, at: 88)
    ingestPut(UInt64(packets.count) + drops + tailDrops, into: &status, at: 96)
    ingestPut(drops + tailDrops, into: &status, at: 104)
    ingestPut(oversized, into: &status, at: 112)
    ingestPut(acknowledged ?? UInt64(packets.count), into: &status, at: 120)
    mutateStatus?(&status)
    let sha = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
    func event(_ name: String, _ wire: Data) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "event": name,
        "wireBase64": wire.base64EncodedString(), "recordBytes": records.count,
        "recordSHA256": sha], options: [.sortedKeys]) + Data([10])
    }
    var journal = try event("receive_start_intent", route)
    if finalDiagnostics { journal.append(try event("receive_final_statistics", Data())) }
    journal.append(try event(finalStatus ? "receive_final_status" : "receive_stop_returned", status))
    if closed { journal.append(try event("receive_closed", Data())) }
    try journal.write(to: url.appendingPathComponent("flight.ndjson"))
  }
  func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DVIngestProgress] = []
  func append(_ value: DVIngestProgress) { lock.withLock { values.append(value) } }
  func snapshot() -> [DVIngestProgress] { lock.withLock { values } }
}

@Test func ingestReportsMeasuredReconstructionRereadAndPublicationProgress() throws {
  let frame = ingestFrame(pal: false)
  let fixture = try IngestFixture(packets: ingestPackets(frame, blocksPerPacket: 7))
  defer { fixture.cleanup() }
  let recorder = ProgressRecorder()
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url) { recorder.append($0) }
  let updates = recorder.snapshot()
  #expect(result.completeDVFrames == 1)
  #expect(updates.first?.phase == .validatingEvidence)
  for phase: DVIngestProgressPhase in [.reconstructingNativeDV, .rereadingNativeDV,
    .rereadingRawEvidence, .rereadingFrameManifest, .publishingVerifiedFiles, .complete] {
    #expect(updates.contains { $0.phase == phase })
  }
  #expect(updates.last?.fractionCompleted == 1)
  #expect(updates.allSatisfy { $0.overallCompletedBytes <= $0.overallTotalBytes || $0.overallTotalBytes == 0 })
}

@Test func postDrainDiagnosticsBeforeFinalStatusPreserveExactExportAndIntegrity() throws {
  let frame = ingestFrame(pal: false)
  let fixture = try IngestFixture(packets: ingestPackets(frame), finalDiagnostics: true)
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 1)
  #expect(result.finalAcknowledgementConfirmed && result.integritySHA256Verified)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.dv")) == frame)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
}

@Test(arguments: [false, true])
func ingestExportsExactNTSCAndPALAndVerifiesReread(pal: Bool) throws {
  let frame = ingestFrame(pal: pal)
  // Frames may share one raw record; packetization crosses the frame boundary.
  let fixture = try IngestFixture(packets: ingestPackets(frame + frame, blocksPerPacket: 7))
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 2)
  #expect(!result.needsLossReview)
  #expect(result.completionHeadline == "Capture complete — saved bytes verified")
  #expect(result.dvBytes == UInt64(frame.count * 2))
  #expect(result.nativeDVRereadVerified && result.integritySHA256Verified)
  #expect(result.CIPDiscontinuities == 0 && result.rejectedPackets == 0 && result.incompleteFrames == 0)
  #expect(result.hardwareContinuity == "unknown" && result.exactLostFrameCount == nil)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.dv")) == frame + frame)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
  let manifest = try String(contentsOf: fixture.url.appendingPathComponent("frames.ndjson"), encoding: .utf8)
  let manifestBytes = Data(manifest.utf8)
  #expect(result.frameManifestBytes == UInt64(manifestBytes.count))
  #expect(result.frameManifestSHA256 == SHA256.hash(data: manifestBytes).map {
    String(format: "%02x", $0)
  }.joined())
  // Same-length tampering cannot evade the verification.json digest binding.
  var alteredManifest = manifestBytes
  alteredManifest[alteredManifest.count - 2] ^= 1
  #expect(alteredManifest.count == manifestBytes.count)
  #expect(result.frameManifestSHA256 != SHA256.hash(data: alteredManifest).map {
    String(format: "%02x", $0)
  }.joined())
  let lines = manifest.split(separator: "\n")
  #expect(lines.count == 2)
  let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
  let metadata = first["sourceMetadata"] as! [String: Any]
  #expect(metadata["audio_sample_rate"] as? String == "known_48000_hz")
  #expect((first["firstRecordSequence"] as? NSNumber)?.uint64Value == 1)
  let persisted = try JSONDecoder().decode(DVIngestVerification.self,
    from: Data(contentsOf: fixture.url.appendingPathComponent("verification.json")))
  #expect(persisted == result)
  #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.dv")) == frame + frame)
}

@Test func ingestReportsTailHostLossAndOversizedWithoutInventingLostFrames() throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)), tailDrops: 4, oversized: 1)
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 1)
  #expect(result.hostRingDrops == 3 && result.oversizedPackets == 1 && result.knownDroppedPackets == 4)
  #expect(result.needsLossReview)
  #expect(result.completionHeadline == "Saved bytes verified — capture needs review")
  #expect(result.rawTransportGapEvents == 1 && result.CIPDiscontinuities == 0)
  #expect(result.exactLostFrameCount == nil)
}

@Test func ingestDistinguishesCIPGapAndPartialTailFromRawLoss() throws {
  var packets = ingestPackets(ingestFrame(pal: false))
  packets.remove(at: 20)
  packets.append(contentsOf: ingestPackets(ingestFrame(pal: false)).prefix(12))
  let fixture = try IngestFixture(packets: packets)
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 0 && result.captureFile == nil)
  #expect(result.CIPDiscontinuities == 2 && result.incompleteFrames == 2)
  #expect(result.hostRingDrops == 0 && !result.nativeDVRereadVerified)
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv").path))
}

@Test func ingestMarksRawRingGapEvenIfCIPSequenceLooksContinuous() throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)), losses: [12: 256])
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.hostRingDrops == 256 && result.rawTransportGapEvents == 1)
  #expect(result.CIPDiscontinuities == 0 && result.incompleteFrames == 1 && result.completeDVFrames == 0)
}

@Test func continuityContextNeverUpgradesLossAuthorityAndOldReportsStillDecode() throws {
  let framePackets = ingestPackets(ingestFrame(pal: false))
  let empty = Data([0,0,0,0,0,0,0,0,7,120,0,250,0x80,0,0xff,0xff])
  let fixture = try IngestFixture(packets: framePackets + [empty] + framePackets + Array(framePackets.prefix(12)))
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.CIPDiscontinuities == 2 && result.incompleteFrames == 1)
  #expect(result.dbcDiscontinuitiesAfterEmptyPackets == 1)
  #expect(result.dbcDiscontinuitiesDiscardingPartialFrames == 0)
  #expect(result.terminalPartialFrames == 1)
  #expect(result.needsLossReview && result.exactLostFrameCount == nil && result.hardwareContinuity == "unknown")
  #expect(result.completionContext.contains("0 incomplete frames before receive ended; 1 partial frames at receive end"))
  #expect(result.completionContext.contains("1 of 2 counter changes followed empty packets; 0 discarded a partial frame"))
  #expect(result.completionContext.contains("cause and exact loss remain unverified"))
  let current = try Data(contentsOf: fixture.url.appendingPathComponent("verification.json"))
  var old = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
  for key in ["dbcDiscontinuitiesAfterEmptyPackets", "dbcDiscontinuitiesDiscardingPartialFrames", "terminalPartialFrames"] { old.removeValue(forKey: key) }
  let decoded = try JSONDecoder().decode(DVIngestVerification.self, from: JSONSerialization.data(withJSONObject: old))
  #expect(decoded.terminalPartialFrames == nil && decoded.needsLossReview)
  #expect(decoded.completionContext.contains("receive-end detail unavailable"))
  #expect(decoded.completionContext.contains("counter changes; context unavailable"))
  var inconsistent = result
  inconsistent.terminalPartialFrames = UInt64.max
  inconsistent.dbcDiscontinuitiesAfterEmptyPackets = UInt64.max
  #expect(inconsistent.completionContext.contains("receive-end detail unavailable"))
  #expect(inconsistent.completionContext.contains("counter changes; context unavailable"))
  #expect(inconsistent.needsLossReview && inconsistent.exactLostFrameCount == nil)
}

@Test func completionContextRetainsNonterminalIncompleteFrames() throws {
  let packets = ingestPackets(ingestFrame(pal: false))
  let fixture = try IngestFixture(packets: Array(packets.prefix(12)) + packets)
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.incompleteFrames == 1 && result.terminalPartialFrames == 0)
  #expect(result.completionContext.contains("1 incomplete frames before receive ended; 0 partial frames at receive end"))
  #expect(result.needsLossReview && result.exactLostFrameCount == nil)
}

@Test func transportJournalAnnotationsDoNotChangeArchiveAuthority() throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
  defer { fixture.cleanup() }
  let journalURL = fixture.url.appendingPathComponent("flight.ndjson")
  var lines = try Data(contentsOf: journalURL).split(separator: 10).map { Data($0) }
  var annotation = try #require(JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
  annotation["event"] = "transport_status_observed"
  annotation["wireBase64"] = Data([0x0c,0x20,0xc3,0x75]).base64EncodedString()
  annotation["observedUTC"] = "2026-09-28T00:00:00Z"
  annotation["hostUptimeNanoseconds"] = UInt64(1234)
  lines.insert(try JSONSerialization.data(withJSONObject: annotation), at: 1)
  var journal = Data()
  for line in lines { journal.append(line); journal.append(10) }
  try journal.write(to: journalURL)
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 1 && result.integritySHA256Verified)
  #expect(result.hardwareContinuity == "unknown" && result.exactLostFrameCount == nil)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
}

@Test func ingestEmptyOrRejectedFlightCreatesNoEmptyDV() throws {
  for packets in [[], [Data([0, 1, 2])]] {
    let fixture = try IngestFixture(packets: packets)
    defer { fixture.cleanup() }
    let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
    #expect(result.completeDVFrames == 0 && result.nativeDVSHA256 == nil)
    #expect(result.rejectedPackets == UInt64(packets.count))
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv.partial").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv").path))
  }
}

@Test func ingestRejectsMissingCloseTamperAndTruncation() throws {
  for mode in 0..<4 {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)), closed: mode != 0)
    defer { fixture.cleanup() }
    if mode > 0 {
      var changed = fixture.raw
      if mode == 1 { changed[changed.count - 1] ^= 1 }
      if mode == 2 { changed.removeLast() }
      if mode == 3 { changed.append(0) }
      try changed.write(to: fixture.url.appendingPathComponent("receive.records.raw"))
    }
    #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv").path))
  }
}

@Test func ingestRejectsHashConsistentInvalidHeadersAndEpochs() throws {
  for offset in [0, 8, 40, 48, 56, 60] {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)),
      mutateHeader: { index, header in if index == 10 { header[offset] ^= 1 } })
    defer { fixture.cleanup() }
    #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
  }
}

@Test func ingestLegacyAcknowledgementIsExplicitAndNewFinalStatusIsStrict() throws {
  for finalStatus in [false, true] {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)),
      acknowledged: 0, finalStatus: finalStatus)
    defer { fixture.cleanup() }
    if finalStatus {
      #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
    } else {
      #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
      let result = try DVIngestExporter.exportClosedFlight(at: fixture.url, allowLegacyStoppedSnapshot: true)
      #expect(!result.finalAcknowledgementConfirmed && result.legacyStoppedSnapshotUsed && result.completeDVFrames == 1)
    }
  }
}

@Test func ingestFinalStatusMustBeUniqueExactAndBoundToClose() throws {
  for mode in 0..<8 {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
    defer { fixture.cleanup() }
    let journalURL = fixture.url.appendingPathComponent("flight.ndjson")
    let original = try String(contentsOf: journalURL, encoding: .utf8)
    var events = try original.split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    switch mode {
    case 0: events[1]["event"] = "unrelated_event_with_status_bytes"
    case 1: events.insert(events[1], at: 2)
    case 2: events[1]["wireBase64"] = ""
    case 3: events[1]["recordBytes"] = 0
    case 4: events[1]["recordSHA256"] = String(repeating: "0", count: 64)
    case 6, 7:
      var wire = Data(base64Encoded: events[1]["wireBase64"] as! String)!
      // Owned CMP cleanup pending / quarantined must never finalize an archive.
      wire[80] = mode == 6 ? 6 : 5
      events[1]["wireBase64"] = wire.base64EncodedString()
    default:
      var unrelated = events[1]
      unrelated["event"] = "unrelated_event_with_status_bytes"
      events.insert(unrelated, at: 2)
    }
    var rewritten = Data()
    for event in events {
      rewritten.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
      rewritten.append(10)
    }
    try rewritten.write(to: journalURL)
    #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  }
}

@Test func ingestPublicationMakesPayloadNamesDurableBeforeCompletionMarker() throws {
  for hasNativeDV in [false, true] {
    var calls: [String] = []
    try DVIngestExporter.publishVerifiedOutputs(hasNativeDV: hasNativeDV,
      promote: { calls.append($0) }, syncDirectory: { calls.append("directory_barrier") }, withdrawMarker: { calls.append("withdraw") })
    let payloads = hasNativeDV ? ["capture.dv", "frames.ndjson"] : ["frames.ndjson"]
    #expect(calls == payloads + ["directory_barrier", "verification.json", "directory_barrier"])
  }
  for failingBarrier in [1, 2] {
    var calls: [String] = [], barriers = 0
    #expect(throws: (any Error).self) {
      try DVIngestExporter.publishVerifiedOutputs(hasNativeDV: true,
        promote: { calls.append($0) }, syncDirectory: {
          barriers += 1
          calls.append("directory_barrier")
          if barriers == failingBarrier { throw DVIngestError.fileOperation("injected barrier failure", 5) }
        }, withdrawMarker: { calls.append("withdraw") })
    }
    if failingBarrier == 1 {
      #expect(!calls.contains("verification.json"))
      #expect(calls == ["capture.dv", "frames.ndjson", "directory_barrier"])
    } else {
      #expect(calls == ["capture.dv", "frames.ndjson", "directory_barrier", "verification.json", "directory_barrier", "withdraw"])
    }
  }
}

@Test(arguments: [false, true]) func failedFinalDirectoryBarrierWithdrawsActualMarker(portable: Bool) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let bytes = Data("verified synthetic bytes".utf8)
  let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  for name in ["capture.dv", "frames.ndjson", "verification.json"] {
    try bytes.write(to: root.appendingPathComponent(name + ".partial"))
  }
  var barriers = 0
  #expect(throws: (any Error).self) {
    try DVIngestExporter.publishVerifiedOutputs(hasNativeDV: true, promote: {
      try DVIngestExporter.promote($0, in: root, expectedBytes: UInt64(bytes.count), expectedSHA256: sha, forcePortableCopy: portable)
    }, syncDirectory: {
      barriers += 1
      if barriers == 2 { throw DVIngestError.fileOperation("injected final directory barrier", 5) }
    }, withdrawMarker: { DVIngestExporter.withdrawCompletionMarker(in: root) })
  }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("verification.json").path))
  #expect(try Data(contentsOf: root.appendingPathComponent("verification.json.partial")) == bytes)
  #expect(try Data(contentsOf: root.appendingPathComponent("capture.dv")) == bytes)
  #expect(try Data(contentsOf: root.appendingPathComponent("frames.ndjson")) == bytes)
}

@Test func portablePublicationCopiesExclusivelyVerifiesAndRemovesPartial() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("DVPortablePublish-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let bytes = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
  let partial = root.appendingPathComponent("capture.dv.partial")
  try bytes.write(to: partial)
  let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  try DVIngestExporter.promote("capture.dv", in: root, expectedBytes: UInt64(bytes.count),
    expectedSHA256: sha, forcePortableCopy: true)
  #expect(!FileManager.default.fileExists(atPath: partial.path))
  #expect(try Data(contentsOf: root.appendingPathComponent("capture.dv")) == bytes)
}

@Test func portablePublicationNeverReplacesExistingDestination() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("DVPortableCollision-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let retained = Data("retained".utf8), existing = Data("existing".utf8)
  try retained.write(to: root.appendingPathComponent("capture.dv.partial"))
  try existing.write(to: root.appendingPathComponent("capture.dv"))
  let sha = SHA256.hash(data: retained).map { String(format: "%02x", $0) }.joined()
  #expect(throws: (any Error).self) {
    try DVIngestExporter.promote("capture.dv", in: root,
      expectedBytes: UInt64(retained.count), expectedSHA256: sha, forcePortableCopy: true)
  }
  #expect(try Data(contentsOf: root.appendingPathComponent("capture.dv")) == existing)
  #expect(try Data(contentsOf: root.appendingPathComponent("capture.dv.partial")) == retained)
}

@Test func interruptedVerifiedPublicationCanBeResumedWithoutReconstruction() throws {
  let frame = ingestFrame(pal: false)
  let fixture = try IngestFixture(packets: ingestPackets(frame))
  defer { fixture.cleanup() }
  let original = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  for name in ["capture.dv", "frames.ndjson", "verification.json"] {
    try FileManager.default.moveItem(at: fixture.url.appendingPathComponent(name),
      to: fixture.url.appendingPathComponent(name + ".partial"))
  }
  let resumed = try DVIngestExporter.resumeVerifiedPublication(at: fixture.url)
  #expect(resumed == original)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.dv")) == frame)
  #expect(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json.partial").path))
}

@Test func ingestLegacyStopBindsExactRawPrefixAndIgnoresUnrelatedStatusBytes() throws {
  for mode in 0..<7 {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)),
      acknowledged: 0, finalStatus: false)
    defer { fixture.cleanup() }
    let journalURL = fixture.url.appendingPathComponent("flight.ndjson")
    let original = try String(contentsOf: journalURL, encoding: .utf8)
    var events = try original.split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    // The quiesced status can precede the final ring drain in a legacy journal.
    // Its own journal integrity fields bind the bytes saved at that moment.
    let prefixBytes = [4, 5].contains(mode) ? 0 : 560 * 10 + (mode == 3 ? 1 : 0)
    let prefix = fixture.raw.subdata(in: 8..<(8 + prefixBytes))
    events[1]["recordBytes"] = prefixBytes
    events[1]["recordSHA256"] = SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
    if [1, 5].contains(mode) { events[1]["recordSHA256"] = String(repeating: "0", count: 64) }
    if mode == 2 { events.insert(events[1], at: 2) }
    if mode == 6 {
      var unrelated = events[1]
      unrelated["event"] = "receive_cleanup_status"
      var status = Data(base64Encoded: unrelated["wireBase64"] as! String)!
      ingestPut(UInt32(4), into: &status, at: 80)
      unrelated["wireBase64"] = status.base64EncodedString()
      events.insert(unrelated, at: 2)
    }
    var rewritten = Data()
    for event in events {
      rewritten.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
      rewritten.append(10)
    }
    try rewritten.write(to: journalURL)
    if [0, 4, 6].contains(mode) {
      let result = try DVIngestExporter.exportClosedFlight(at: fixture.url, allowLegacyStoppedSnapshot: true)
      #expect(result.completeDVFrames == 1 && result.legacyStoppedSnapshotUsed)
      #expect(!result.finalAcknowledgementConfirmed)
    } else {
      #expect(throws: (any Error).self) {
        try DVIngestExporter.exportClosedFlight(at: fixture.url, allowLegacyStoppedSnapshot: true)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
    }
  }
}

@Test func ingestRejectsBadTerminalABIStateRouteAndCounters() throws {
  for offset in [0, 4, 6, 8, 12, 16, 24, 28, 32, 68, 70, 80, 84, 88, 96, 104, 112, 120] {
    let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)),
      mutateStatus: { $0[offset] ^= 1 })
    defer { fixture.cleanup() }
    #expect(throws: (any Error).self) { try DVIngestExporter.exportClosedFlight(at: fixture.url) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  }
}

@Test(arguments: [UInt32(8192), 65536]) func ingestAcceptsQualifiedRingCapacities(capacity: UInt32) throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)),
    mutateStatus: { ingestPut(capacity, into: &$0, at: 12) })
  defer { fixture.cleanup() }
  let result = try DVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.completeDVFrames == 1 && result.integritySHA256Verified && result.nativeDVRereadVerified)
}
