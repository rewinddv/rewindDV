// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// OFFLINE ONLY: synthetic transport around an unchanged real local DV fixture.
// Never constructs DriverBridge, maps driver memory, or opens an IOKit service.
import AVFoundation
import CryptoKit
import Foundation

@main struct LiveReceiveFlightRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide the local 817-frame NTSC fixture") }
    let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(fixture.count == 817 * 120_000)
    let began = Date()
    // This route is deliberately synthetic and cannot authorize hardware.
    var route = Data(repeating: 0, count: 48)
    put(UInt32(1), in: &route, at: 0)
    put(UInt32(48), in: &route, at: 4)
    let flight = try LiveReceiveFlight(route: route)
    _ = flight.event("offline_synthetic_transport_fixture",
      message: "NOT HARDWARE EVIDENCE; synthetic OHCI/CIP/record headers around unchanged local DV bytes")
    let decoder = LiveDVFrameDecoder()
    var assembler = DVPreviewPacketAssembler()
    var expectedHash = SHA256()
    var expectedBytes: UInt64 = 0
    var frameCount = 0
    var recordCount: UInt64 = 0
    var firstTimecode: String?
    var finalTimecode: String?
    var pending: [LiveReceiveRecord] = []
    let packetCount = fixture.count / 480
    for packetIndex in 0..<packetCount {
      let sequence = UInt64(packetIndex + 1)
      var payload = Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 120, 0,
        UInt8(truncatingIfNeeded: packetIndex), 0x80, 0, 0xff, 0xff])
      payload.append(fixture[(packetIndex * 480)..<((packetIndex + 1) * 480)])
      var header = Data(repeating: 0, count: 64)
      put(sequence, in: &header, at: 0)
      put(UInt64(1), in: &header, at: 8)
      put(sequence * 1000, in: &header, at: 16) // Synthetic host ticks.
      put(UInt32(truncatingIfNeeded: sequence), in: &header, at: 24)
      put(UInt32(packetIndex % 8192), in: &header, at: 28)
      put(UInt16(0x11), in: &header, at: 32)
      put(UInt32(payload.count), in: &header, at: 36)
      put(sequence, in: &header, at: 40)
      put(UInt32(1), in: &header, at: 56) // Continuity unknown.
      pending.append(LiveReceiveRecord(header: header, payload: payload,
        sequence: sequence, transferStatus: 0x11))
      if pending.count == 128 || packetIndex + 1 == packetCount {
        // Production writer must return from synchronization before ANY parse.
        while !flight.enqueue(pending) { try await Task.sleep(for: .milliseconds(1)) }
        for record in pending {
          expectedHash.update(data: record.header)
          expectedHash.update(data: record.payload)
          expectedBytes += UInt64(record.header.count + record.payload.count)
          recordCount += 1
          for frame in assembler.consumePreservedPacket(record.payload,
            transferStatus: record.transferStatus, expectedSourceNode: 1) {
            precondition(frame == fixture[(frameCount * 120_000)..<((frameCount + 1) * 120_000)])
            let facts = DVCaptureMetadataEpochAnalyzer.analyze(data: frame)
            let timecode = facts.frames.first.flatMap {
              MonitorSourceTimecode.display(packs: $0.sourceTimecodePacks.map(\.rawBytes), isPAL: false)
            }
            precondition(timecode != nil, "Source timecode absent at frame \(frameCount)")
            let image = try await decoder.decode(frame, ordinal: UInt64(frameCount), timecode: timecode)
            precondition(image.timecode == timecode && image.sourceOrdinal == UInt64(frameCount))
            precondition(CVPixelBufferGetWidth(image.pixelBuffer) == 720)
            precondition(CVPixelBufferGetHeight(image.pixelBuffer) == 480)
            if firstTimecode == nil { firstTimecode = timecode }
            finalTimecode = timecode
            frameCount += 1
          }
        }
        pending.removeAll(keepingCapacity: true)
      }
    }
    precondition(frameCount == 817 && recordCount == 204_250)
    precondition(assembler.rejectedPackets == 0 && assembler.discontinuities == 0
      && assembler.incompleteFrames == 0)
    await decoder.reset()
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == recordCount)
    try await flight.finish("OFFLINE SYNTHETIC TRANSPORT REGRESSION ONLY; source frames=\(frameCount)")

    // Independently reread the production writer's compact records, including
    // metadata and the actual payload lengths. Do not trust the journal hash.
    let reader = try FileHandle(forReadingFrom: flight.directory.appendingPathComponent("receive.records.raw"))
    defer { try? reader.close() }
    check(try reader.read(upToCount: 8) == Data("RDRXLOG1".utf8))
    var persistedHash = SHA256()
    var persistedBytes: UInt64 = 0
    var persistedRecords: UInt64 = 0
    while let batch = try reader.read(upToCount: 560 * 128), !batch.isEmpty {
      precondition(batch.count.isMultiple(of: 560))
      persistedHash.update(data: batch)
      persistedBytes += UInt64(batch.count)
      for offset in stride(from: 0, to: batch.count, by: 560) {
        let raw = Data(batch[offset..<(offset + 560)])
        let wire = WireReader(data: raw)
        let sequence = persistedRecords + 1
        check(try wire.integer(0, as: UInt64.self) == sequence)
        check(try wire.integer(8, as: UInt64.self) == 1)
        check(try wire.integer(16, as: UInt64.self) == sequence * 1000)
        check(try wire.integer(24, as: UInt32.self) == UInt32(truncatingIfNeeded: sequence))
        check(try wire.integer(28, as: UInt32.self) == UInt32(persistedRecords % 8192))
        check(try wire.integer(32, as: UInt16.self) == 0x11)
        check(try wire.integer(34, as: UInt16.self) == 0)
        check(try wire.integer(36, as: UInt32.self) == 496)
        check(try wire.integer(40, as: UInt64.self) == sequence)
        check(try wire.integer(48, as: UInt64.self) == 0)
        check(try wire.integer(56, as: UInt32.self) == 1)
        check(try wire.integer(60, as: UInt32.self) == 0)
        precondition(raw[75] == UInt8(truncatingIfNeeded: persistedRecords))
        let start = Int(persistedRecords) * 480
        precondition(raw[80..<560] == fixture[start..<(start + 480)])
        persistedRecords += 1
      }
    }
    let expectedSHA = expectedHash.finalize().map { String(format: "%02x", $0) }.joined()
    let persistedSHA = persistedHash.finalize().map { String(format: "%02x", $0) }.joined()
    precondition(persistedRecords == recordCount && persistedBytes == expectedBytes && persistedSHA == expectedSHA)
    let journal = try String(contentsOf: flight.directory.appendingPathComponent("flight.ndjson"), encoding: .utf8)
    let lines = journal.split(separator: "\n")
    let final = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
    precondition(final["event"] as? String == "receive_closed")
    precondition(final["recordSHA256"] as? String == persistedSHA)
    precondition((final["recordBytes"] as? NSNumber)?.uint64Value == persistedBytes)
    precondition(journal.contains("offline_synthetic_transport_fixture"))
    print("OFFLINE_LIVE_RECEIVE_FLIGHT_PASS frames=\(frameCount) records=\(recordCount) recordBytes=\(persistedBytes)")
    print("RAW_RECORD_SHA256=\(persistedSHA)")
    print("SOURCE_TIMECODE_FIRST=\(firstTimecode!) LAST=\(finalTimecode!)")
    print("LOCAL_ONLY_FLIGHT=\(flight.directory.path)")
    print("SECONDS=\(Date().timeIntervalSince(began)); synthetic transport, NOT hardware qualification")
  }

  private static func check(_ value: Bool) { precondition(value) }

  private static func put<T: FixedWidthInteger>(_ value: T, in data: inout Data, at offset: Int) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
  }
}
