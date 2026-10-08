// OFFLINE ONLY. Replays an immutable flight into a NEW local evidence directory.
// No DriverBridge, IOKit, service, connection, or tape control is linked.
import CryptoKit
import Foundation

// Value-only boundary fixture for the production writer; no live ring mapping.
struct LiveReceiveRecord {
  let header: Data
  let payload: Data
  let sequence: UInt64
  let transferStatus: UInt16
}
enum DriverBridgeError: Error { case receiptUnavailable(String) }

@main struct LiveReceiveThroughputRegression {
  static func main() async throws {
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    precondition(raw.prefix(8) == Data("RDRXLOG1".utf8))
    let parent = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
    let flight = try LiveReceiveFlight(route: Data(repeating: 0, count: 48), destinationParent: parent)
    if let parent { precondition(flight.directory.deletingLastPathComponent() == parent) }
    _ = flight.event("OFFLINE_REPLAY_NO_HARDWARE", message: "Not a hardware flight; synthetic zero route")
    let began = Date()
    var offset = 8, records: UInt64 = 0, frames: UInt64 = 0
    var previousObserved: UInt64 = 0, previousLoss: UInt64 = 0
    var assembler = DVPreviewPacketAssembler()
    var highestBatchSeconds = 0.0
    var mediaSeconds = 0.0
    while offset < raw.count {
      let batchBegan = Date()
      var batch: [LiveReceiveRecord] = []
      batch.reserveCapacity(2048)
      for _ in 0..<2048 where offset < raw.count {
        precondition(raw.count - offset >= 64)
        let header = Data(raw[offset..<offset + 64])
        let count = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self).littleEndian })
        precondition(count <= 4096 && raw.count - offset - 64 >= count)
        let seq = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        let status = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt16.self).littleEndian }
        precondition(seq == records + 1)
        batch.append(LiveReceiveRecord(header: header, payload: Data(raw[offset + 64..<offset + 64 + count]),
          sequence: seq, transferStatus: status))
        offset += 64 + count; records += 1
      }
      while !flight.enqueue(batch) { try await Task.sleep(for: .milliseconds(1)) }
      let mediaBegan = Date()
      for record in batch {
        let observed = record.header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self).littleEndian }
        let loss = record.header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: UInt64.self).littleEndian }
        if observed != previousObserved + 1 || loss != previousLoss { assembler.markTransportGap() }
        previousObserved = observed; previousLoss = loss
        for frame in assembler.consumePreservedPacket(record.payload, transferStatus: record.transferStatus, expectedSourceNode: 1) {
          precondition(LiveDVMedia(frame: frame) != nil)
          frames += 1
        }
      }
      mediaSeconds += Date().timeIntervalSince(mediaBegan)
      highestBatchSeconds = max(highestBatchSeconds, Date().timeIntervalSince(batchBegan))
    }
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == records)
    try await flight.finish("OFFLINE replay completed; source losses retained, not repaired")
    let seconds = Date().timeIntervalSince(began)
    let output = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"), options: .mappedIfSafe)
    precondition(SHA256.hash(data: raw) == SHA256.hash(data: output))
    print("RECORDS=\(records) FRAMES=\(frames) SECONDS=\(seconds) RECORDS_PER_SECOND=\(Double(records)/seconds)")
    print("MAX_BATCH_SECONDS=\(highestBatchSeconds) CLASSIFY_SECONDS=\(mediaSeconds)")
    print("BYTE_EXACT_RAW_REPLAY_PASS \(flight.directory.path)")
    precondition(Double(records) / seconds > 32000, "Offline throughput lacks 4x nominal packet headroom")
  }
}
