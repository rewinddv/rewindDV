// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Synthetic closed flights only; these tests do not qualify hardware capture.
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func hdvPut<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}

private struct HDVFlightFixture {
  let url: URL
  let raw: Data

  init(
    packets: [Data], losses: [Int: UInt64] = [:], tailDrops: UInt64 = 0,
    oversized: UInt64 = 0, acknowledged: UInt64? = nil, state: UInt32 = 2
  ) throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("HDVIngest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    var route = Data(repeating: 0, count: 48)
    hdvPut(UInt32(1), into: &route, at: 0); hdvPut(UInt32(48), into: &route, at: 4)
    for offset in [8, 16, 24, 32] { hdvPut(UInt64(offset), into: &route, at: offset) }
    hdvPut(UInt32(1), into: &route, at: 40); hdvPut(UInt16(7), into: &route, at: 44)
    var records = Data(), drops: UInt64 = 0
    for (index, packet) in packets.enumerated() {
      drops += losses[index] ?? 0
      let sequence = UInt64(index + 1)
      var header = Data(repeating: 0, count: 64)
      hdvPut(sequence, into: &header, at: 0); hdvPut(UInt64(1), into: &header, at: 8)
      hdvPut(sequence * 100, into: &header, at: 16); hdvPut(UInt16(0x11), into: &header, at: 32)
      hdvPut(UInt32(packet.count), into: &header, at: 36)
      hdvPut(sequence + drops, into: &header, at: 40); hdvPut(drops, into: &header, at: 48)
      hdvPut(UInt32(1), into: &header, at: 56)
      records.append(header); records.append(packet)
    }
    raw = Data("RDRXLOG1".utf8) + records
    try raw.write(to: url.appendingPathComponent("receive.records.raw"))
    var status = Data(repeating: 0, count: 128)
    hdvPut(UInt32(0x58524452), into: &status, at: 0)
    hdvPut(UInt16(1), into: &status, at: 4); hdvPut(UInt16(256), into: &status, at: 6)
    hdvPut(UInt32(4160), into: &status, at: 8); hdvPut(UInt32(8192), into: &status, at: 12)
    hdvPut(UInt64(1), into: &status, at: 16); status.replaceSubrange(24..<72, with: route)
    hdvPut(state, into: &status, at: 80)
    hdvPut(UInt64(packets.count), into: &status, at: 88)
    hdvPut(UInt64(packets.count) + drops + tailDrops, into: &status, at: 96)
    hdvPut(drops + tailDrops, into: &status, at: 104); hdvPut(oversized, into: &status, at: 112)
    hdvPut(acknowledged ?? UInt64(packets.count), into: &status, at: 120)
    let sha = SHA256.hash(data: records).map { String(format: "%02x", $0) }.joined()
    func event(_ name: String, _ wire: Data) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "event": name,
        "wireBase64": wire.base64EncodedString(), "recordBytes": records.count,
        "recordSHA256": sha], options: [.sortedKeys]) + Data([10])
    }
    var journal = try event("receive_start_intent", route)
    journal.append(try event("receive_final_status", status))
    journal.append(try event("receive_closed", Data()))
    try journal.write(to: url.appendingPathComponent("flight.ndjson"))
  }

  func cleanup() { try? FileManager.default.removeItem(at: url) }
}

private func hdvDVPacket() -> Data {
  var packet = Data([0, 0, 0, 0, 0, 0, 0, 0, 7, 120, 0, 0, 0x80, 0, 0xff, 0xff])
  packet.append(Data(repeating: 0xff, count: 480))
  return packet
}

@Test func hdvExporterWritesExactTransportAndHashBoundProvenance() throws {
  let packets = (0..<4).map { hdvTSPacket(pid: 0x101, counter: UInt8($0), fill: UInt8($0)) }
  let sourcePackets = packets.map { hdvSourcePacket($0) }
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: sourcePackets[0] + sourcePackets[1], dbc: 0),
    hdvCIP(blocks: Data(sourcePackets[2].prefix(72)), dbc: 16),
    hdvCIP(blocks: Data(sourcePackets[2].dropFirst(72)) + sourcePackets[3], dbc: 19,
      timeShifted: true)
  ])
  defer { fixture.cleanup() }
  let result = try HDVIngestExporter.exportClosedFlight(at: fixture.url)
  let expected = packets.reduce(into: Data()) { $0.append($1) }
  let output = try Data(contentsOf: fixture.url.appendingPathComponent("capture.m2t"))
  #expect(output == expected)
  #expect(result.transportPacketCount == 4 && result.transportBytes == 4 * 188)
  #expect(result.nativeTSSHA256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
  #expect(result.integritySHA256Verified && result.nativeTSRereadVerified)
  #expect(result.finalAcknowledgementConfirmed && !result.needsLossReview)
  #expect(result.captureFile == "capture.m2t")
  let persisted = try JSONDecoder().decode(HDVIngestVerification.self,
    from: Data(contentsOf: fixture.url.appendingPathComponent("hdv-verification.json")))
  #expect(persisted == result)
  let manifest = try Data(contentsOf: fixture.url.appendingPathComponent("hdv-packets.ndjson"))
  #expect(result.packetManifestBytes == UInt64(manifest.count))
  #expect(result.packetManifestSHA256 == SHA256.hash(data: manifest).map {
    String(format: "%02x", $0)
  }.joined())
}

@Test func hdvExporterReportsRawLossAndPartialTailWithoutInventingMissingTSCount() throws {
  let source = hdvSourcePacket(hdvTSPacket())
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: source + Data(source.prefix(48)), dbc: 0)
  ], tailDrops: 3, oversized: 1)
  defer { fixture.cleanup() }
  let result = try HDVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.transportPacketCount == 1)
  #expect(result.knownDroppedPackets == 3 && result.hostRingDrops == 2)
  #expect(result.rawTransportGapEvents == 1)
  #expect(result.transportSummary.discardedSourceFragments == 1)
  #expect(result.exactLostTransportPacketCount == nil && result.needsLossReview)
}

@Test func hdvExporterFailsClosedOnMixedDVAndHDVAndRetainsRaw() throws {
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0), hdvDVPacket()
  ])
  defer { fixture.cleanup() }
  #expect(throws: HDVIngestError.self) { try HDVIngestExporter.exportClosedFlight(at: fixture.url) }
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
  #expect(!FileManager.default.fileExists(atPath:
    fixture.url.appendingPathComponent("hdv-verification.json").path))
}

@Test func hdvExporterDoesNotOverwriteExistingDestination() throws {
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)
  ])
  defer { fixture.cleanup() }
  let sentinel = Data("existing".utf8)
  try sentinel.write(to: fixture.url.appendingPathComponent("capture.m2t"))
  #expect(throws: HDVIngestError.self) { try HDVIngestExporter.exportClosedFlight(at: fixture.url) }
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.m2t")) == sentinel)
}

@Test func hdvExporterRejectsRawHashMismatch() throws {
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)
  ])
  defer { fixture.cleanup() }
  let rawURL = fixture.url.appendingPathComponent("receive.records.raw")
  var changed = try Data(contentsOf: rawURL)
  changed[changed.count - 1] ^= 1
  try changed.write(to: rawURL)
  #expect(throws: HDVIngestError.self) { try HDVIngestExporter.exportClosedFlight(at: fixture.url) }
  #expect(!FileManager.default.fileExists(atPath:
    fixture.url.appendingPathComponent("hdv-verification.json").path))
}

@Test(arguments: [false, true])
func hdvExporterRejectsSymlinkAndFIFOInput(useFIFO: Bool) throws {
  let fixture = try HDVFlightFixture(packets: [
    hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)
  ])
  defer { fixture.cleanup() }
  let rawURL = fixture.url.appendingPathComponent("receive.records.raw")
  try FileManager.default.removeItem(at: rawURL)
  if useFIFO {
    #expect(mkfifo(rawURL.path, 0o600) == 0)
  } else {
    let target = fixture.url.appendingPathComponent("elsewhere.raw")
    try fixture.raw.write(to: target)
    try FileManager.default.createSymbolicLink(at: rawURL, withDestinationURL: target)
  }
  #expect(throws: HDVIngestError.self) { try HDVIngestExporter.exportClosedFlight(at: fixture.url) }
}

@Test func hdvExporterIgnoresEmptyCallbackButRequiresAtLeastOneCompleteHDVPacket() throws {
  let fixture = try HDVFlightFixture(packets: [Data(),
    hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)])
  defer { fixture.cleanup() }
  let result = try HDVIngestExporter.exportClosedFlight(at: fixture.url)
  #expect(result.transportPacketCount == 1)
  #expect(result.transportSummary.rejectedPreservedPackets == 0)
}

@Test func hdvExporterTenThousandPacketHashAndManifestScaleCheckpoint() throws {
  let transportPackets = (0..<10_000).map { index in
    hdvTSPacket(pid: 0x101, counter: UInt8(index & 0x0f), fill: UInt8(truncatingIfNeeded: index))
  }
  var preserved: [Data] = []
  var dbc: UInt8 = 0
  for start in stride(from: 0, to: transportPackets.count, by: 20) {
    let end = min(start + 20, transportPackets.count)
    var blocks = Data()
    for packet in transportPackets[start..<end] { blocks.append(hdvSourcePacket(packet)) }
    preserved.append(hdvCIP(blocks: blocks, dbc: dbc))
    dbc &+= UInt8((end - start) * 8)
  }
  let fixture = try HDVFlightFixture(packets: preserved)
  defer { fixture.cleanup() }
  let expected = transportPackets.reduce(into: Data()) { $0.append($1) }
  let start = ContinuousClock.now
  let result = try HDVIngestExporter.exportClosedFlight(at: fixture.url)
  let elapsed = start.duration(to: .now)
  #expect(result.transportPacketCount == 10_000)
  #expect(result.transportBytes == UInt64(expected.count))
  #expect(result.nativeTSSHA256 == SHA256.hash(data: expected).map {
    String(format: "%02x", $0)
  }.joined())
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("capture.m2t")) == expected)
  print("HDV_SCALE packets=10000 manifestBytes=\(result.packetManifestBytes) bytesPerTS=\(Double(result.packetManifestBytes) / 10_000) elapsed=\(elapsed)")
}

@Test func hdvExporterCancellationInsideProcessingPreservesRawAndWithholdsCompletion() async throws {
  let source = hdvSourcePacket(hdvTSPacket())
  let fixture = try HDVFlightFixture(packets: (0..<5_000).map {
    hdvCIP(blocks: source, dbc: UInt8(truncatingIfNeeded: $0 * 8))
  })
  defer { fixture.cleanup() }
  let cancelled = await Task.detached {
    do {
      _ = try HDVIngestExporter.exportClosedFlight(at: fixture.url) { update in
        if update.phase == .reconstructingMPEG2Transport && update.completedBytes > 0 {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
      return false
    } catch is CancellationError { return true }
    catch { return false }
  }.value
  #expect(cancelled)
  let partial = fixture.url.appendingPathComponent("capture.m2t.partial")
  #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as! NSNumber).uint64Value > 0)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("hdv-verification.json").path))
}

@Test func hdvResetSegmentKeepsInterruptionAndRejectsUncertainACK() throws {
  let packets = [hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)]
  let f = try HDVFlightFixture(packets: packets, state: 3); defer { f.cleanup() }
  #expect(throws: (any Error).self) { try HDVIngestExporter.exportClosedFlight(at: f.url) }
  let r = try HDVIngestExporter.exportClosedFlight(at: f.url, allowBusResetSegment: true)
  #expect(r.busResetTerminated && r.needsLossReview && r.integritySHA256Verified)
  #expect(r.transportPacketCount == 1 && r.nativeTSRereadVerified)
  let unacked = try HDVFlightFixture(packets: packets, acknowledged: 0, state: 3)
  defer { unacked.cleanup() }
  #expect(throws: (any Error).self) {
    try HDVIngestExporter.exportClosedFlight(at: unacked.url, allowBusResetSegment: true)
  }
  for state: UInt32 in [0, 1, 4, 5, 6] {
    let bad = try HDVFlightFixture(packets: packets, state: state); defer { bad.cleanup() }
    #expect(throws: (any Error).self) { try HDVIngestExporter.exportClosedFlight(at: bad.url, allowBusResetSegment: true) }
  }
}
