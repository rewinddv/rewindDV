// OFFLINE ONLY. No IOKit, driver service, deck command, or saved evidence input.
import CryptoKit
import Foundation

struct LiveReceiveRecord: Sendable {
  let header: Data
  let payload: Data
  let sequence: UInt64
  let transferStatus: UInt16
}
enum DriverBridgeError: Error { case receiptUnavailable(String) }

@main struct LiveReceiveWriterRegression {
  static func main() async throws {
    for delay: UInt64 in [50, 100, 250, 350] {
      try await exercise(delayMilliseconds: delay)
    }
    for delay: UInt64 in [50, 100, 250] {
      try await pacedReceive(delayMilliseconds: delay)
    }
    for delay: UInt64 in [350, 1500] { try await pressureIsHonest(delayMilliseconds: delay) }
    try await diagnosticsCannotStopRaw()
    try await diagnosticObservationTimePrecedesDelayedWrite()
    try await optionalTransportDiagnosticsYieldUnderPressure()
    try await rawFailureNeverAdvancesOrRetries()
    try await failedSyncPreservesCheckpoint()
    print("LIVE_RECEIVE_WRITER_ORDER_DURABILITY_PRESSURE_AND_FAULTS_PASS")
  }

  private static func exercise(delayMilliseconds: UInt64) async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-writer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(repeating: 0, count: 48),
      destinationParent: parent,
      faults: DurableWriterFaults(rawDelayNanoseconds: delayMilliseconds * 1_000_000))
    var expected = Data("RDRXLOG1".utf8)
    var presented = 0
    let began = ContinuousClock.now
    for base in stride(from: 1, through: 768, by: 64) {
      let records = (base..<base + 64).map { record($0) }
      for item in records { expected.append(item.header); expected.append(item.payload) }
      precondition(flight.enqueue(records))
      // Presentation owns immutable copied bytes and advances while durable ACK
      // remains behind during the injected flush.
      presented += records.count
      precondition(flight.progress().durableThrough <= UInt64(presented))
    }
    precondition(presented == 768)
    precondition(ContinuousClock.now - began < .milliseconds(40),
      "enqueue/presentation path waited for injected fsync")
    var acknowledged: UInt64 = 0
    while !flight.progress().idle {
      let progress = flight.progress()
      acknowledged = max(acknowledged, progress.durableThrough)
      precondition(acknowledged <= progress.durableThrough)
      try await Task.sleep(for: .milliseconds(5))
    }
    let joined = await flight.joinRaw()
    acknowledged = max(acknowledged, joined.durableThrough)
    precondition(joined.failure == nil && joined.idle && acknowledged == 768)
    try await flight.finish("offline writer regression")
    let actual = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(actual == expected)
    precondition(SHA256.hash(data: actual) == SHA256.hash(data: expected))
  }

  private static func pressureIsHonest(delayMilliseconds: UInt64) async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-pressure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(rawDelayNanoseconds: delayMilliseconds * 1_000_000))
    let full = (1...LiveReceiveFlight.maximumRetainedRecords).map {
      record($0, payloadSize: 4096)
    }
    var copiedThrough: UInt64 = 0
    precondition(flight.enqueue(full)); copiedThrough = UInt64(full.count)
    precondition(!flight.enqueue([
      record(LiveReceiveFlight.maximumRetainedRecords + 1, payloadSize: 4096)
    ]))
    precondition(copiedThrough == UInt64(full.count), "refusal must not advance copied cursor")
    precondition(flight.progress().pressure)
    precondition(flight.progress().durableThrough == 0, "Capacity pressure must never acknowledge undurable bytes")
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == UInt64(full.count))
    try await flight.finish("offline pressure regression")
    print("BOUNDED_WRITER_PRESSURE_PASS delay_ms=\(delayMilliseconds) capacity=\(full.count); refusal preserved cursor; not lossless-wire qualification")
  }

  private static func pacedReceive(delayMilliseconds: UInt64) async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-paced-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(rawDelayNanoseconds: delayMilliseconds * 1_000_000))
    var expected = Data("RDRXLOG1".utf8)
    var copiedThrough: UInt64 = 0
    var acknowledgedThrough: UInt64 = 0
    var maximumOccupancy = 0
    // Three modeled seconds at 8,000 records/second: 64 immutable records
    // arrive every 8 ms while raw durability completes independently.
    for _ in 0..<375 {
      let first = Int(copiedThrough + 1)
      let records = (first..<first + 64).map { record($0) }
      precondition(flight.enqueue(records), "paced writer exhausted honest ring headroom")
      copiedThrough = records.last!.sequence
      for item in records { expected.append(item.header); expected.append(item.payload) }
      let progress = flight.progress()
      acknowledgedThrough = max(acknowledgedThrough, progress.durableThrough)
      precondition(acknowledgedThrough <= progress.durableThrough)
      precondition(progress.durableThrough <= copiedThrough)
      maximumOccupancy = max(maximumOccupancy, progress.retainedRecords)
      precondition(maximumOccupancy <= LiveReceiveFlight.maximumRetainedRecords)
      try await Task.sleep(for: .milliseconds(8))
    }
    // Descriptors completed at STOP are copied/enqueued after the paced body.
    let finalFirst = Int(copiedThrough + 1)
    let finalRecords = (finalFirst..<finalFirst + 128).map { record($0) }
    precondition(flight.enqueue(finalRecords))
    copiedThrough = finalRecords.last!.sequence
    for item in finalRecords { expected.append(item.header); expected.append(item.payload) }
    let joined = await flight.joinRaw()
    acknowledgedThrough = max(acknowledgedThrough, joined.durableThrough)
    precondition(joined.failure == nil && joined.idle)
    precondition(copiedThrough == 24_128 && joined.durableThrough == copiedThrough)
    precondition(acknowledgedThrough == copiedThrough)
    try await flight.finish("paced offline receive with final STOP descriptors")
    let actual = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(actual == expected && SHA256.hash(data: actual) == SHA256.hash(data: expected))
  }

  private static func diagnosticsCannotStopRaw() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-diagnostic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(failDiagnosticWriteNumber: 1))
    precondition(flight.event("injected_diagnostic_failure"))
    precondition(flight.enqueue((1...64).map { record($0) }))
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == 64)
    try await Task.sleep(for: .milliseconds(10))
    precondition(flight.diagnosticFailure != nil)
    do {
      try await flight.finish("must not finalize")
      preconditionFailure("diagnostic failure falsely finalized success")
    } catch {}
    let journal = try String(contentsOf:
      flight.directory.appendingPathComponent("flight.ndjson"), encoding: .utf8)
    precondition(!journal.contains("receive_closed\""))
  }

  private static func diagnosticObservationTimePrecedesDelayedWrite() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-observation-time-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(diagnosticDelayNanoseconds: 250_000_000))
    let before = DispatchTime.now().uptimeNanoseconds
    precondition(flight.event("transport_status_observed", data: Data([0x0c,0x20,0xc3,0x75])))
    let after = DispatchTime.now().uptimeNanoseconds
    precondition(after - before < 100_000_000, "observation waited for diagnostic I/O")
    precondition(flight.enqueue((1...64).map { record($0) }))
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == 64)
    try await flight.finish("offline observation clock regression")
    let journal = try Data(contentsOf: flight.directory.appendingPathComponent("flight.ndjson"))
    let events = try journal.split(separator: 10).map {
      try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
    let event = events.first { $0["event"] as? String == "transport_status_observed" }!
    let observed = (event["hostUptimeNanoseconds"] as! NSNumber).uint64Value
    precondition(observed >= before && observed <= after,
      "diagnostic timestamp used delayed write time instead of observation time")
    precondition(event["observedUTC"] is String)
    precondition((events[0]["message"] as! String).contains("raw_host_ticks_timebase_denominator="))
    precondition(events.last?["event"] as? String == "receive_closed")
    var expected = Data("RDRXLOG1".utf8)
    for item in (1...64).map({ record($0) }) { expected.append(item.header); expected.append(item.payload) }
    let raw = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(raw == expected)
    print("DIAGNOSTIC_OBSERVATION_CLOCK_AND_RAW_ISOLATION_PASS")
  }

  private static func optionalTransportDiagnosticsYieldUnderPressure() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-optional-pressure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(diagnosticDelayNanoseconds: 100_000_000))
    var accepted = 0
    for _ in 0..<400 {
      if flight.event("transport_status_observed", transportDiagnostic: true) { accepted += 1 }
    }
    precondition(accepted < 400 && flight.diagnosticFailure == nil)
    precondition(flight.event("receive_final_status", data: Data(count: 128)),
      "optional annotations crowded out required receive evidence")
    precondition(flight.enqueue((1...64).map { record($0) }))
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == 64)
    try await flight.finish("offline optional diagnostic pressure")
    let journal = try Data(contentsOf: flight.directory.appendingPathComponent("flight.ndjson"))
    let events = try journal.split(separator: 10).map {
      try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
    let closed = events.last!
    precondition(closed["event"] as? String == "receive_closed")
    precondition(events[events.count - 2]["event"] as? String == "receive_final_status")
    precondition((closed["omittedTransportDiagnostics"] as! NSNumber).intValue == 400 - accepted)
    precondition(events.filter { $0["event"] as? String == "transport_status_observed" }.count == accepted)
    precondition(flight.diagnosticFailure == nil)
    print("OPTIONAL_TRANSPORT_DIAGNOSTICS_YIELD_WITH_EXPLICIT_OMISSIONS_PASS")
  }

  private static func rawFailureNeverAdvancesOrRetries() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("rewinddv-raw-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(rawDelayNanoseconds: 50_000_000, failRawWriteNumber: 2))
    precondition(flight.enqueue((1...64).map { record($0) }))
    while flight.progress().durableThrough != 64 { try await Task.sleep(for: .milliseconds(2)) }
    precondition(flight.enqueue((65...128).map { record($0) }))
    let joined = await flight.joinRaw()
    precondition(joined.failure != nil && joined.durableThrough == 64)
    precondition(!flight.enqueue((65...128).map { record($0) }), "uncertain extent must not retry")
    let raw = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(raw.count == 8 + 64 * (64 + 512))
  }

  private static func failedSyncPreservesCheckpoint() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rewinddv-sync-fault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: parent,
      faults: DurableWriterFaults(failRawSyncNumber: 2))
    precondition(flight.enqueue((1...64).map { record($0) }))
    while flight.progress().durableThrough != 64 { try await Task.sleep(for: .milliseconds(2)) }
    precondition(flight.enqueue((65...128).map { record($0) }))
    let joined = await flight.joinRaw()
    precondition(joined.failure != nil && joined.durableThrough == 64)
    precondition(!flight.enqueue((65...128).map { record($0) }))
    // Written bytes beyond 64 are NOT acknowledged or included in a checkpoint.
    let raw = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(raw.count == 8 + 128 * (64 + 512))
    do { try await flight.finish("must not succeed"); preconditionFailure("sync failure falsely finalized") } catch {}
    print("WRITTEN_BUT_UNDURABLE_TAIL_NO_ACK_NO_RETRY_PASS")
  }

  private static func record(_ value: Int, payloadSize: Int = 512) -> LiveReceiveRecord {
    var sequence = UInt64(value).littleEndian
    let header = withUnsafeBytes(of: &sequence) { Data($0) } + Data(repeating: 0, count: 56)
    return LiveReceiveRecord(header: header,
      payload: Data(repeating: UInt8(truncatingIfNeeded: value), count: payloadSize),
      sequence: UInt64(value), transferStatus: 0x11)
  }
}
