// Synthetic offline evidence only. No hardware or acquisition-quality claim.
import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private struct PrefixFixture {
  let flight: IngestFixture
  let destination: URL
  init(pal: Bool = false) throws {
    flight = try IngestFixture(packets: ingestPackets(ingestFrame(pal: pal)), closed: false)
    destination = flight.url.deletingLastPathComponent().appendingPathComponent("prefix-\(UUID().uuidString)")
  }
  func clean() { flight.cleanup(); try? FileManager.default.removeItem(at: destination) }
  var raw: URL { flight.url.appendingPathComponent("receive.records.raw") }
  var log: URL { flight.url.appendingPathComponent("flight.ndjson") }
  func export() throws -> DVForensicPrefix.Receipt {
    try DVForensicPrefix.export(source: flight.url, destination: destination)
  }
  func rewriteJournal(_ change: (inout [[String: Any]]) -> Void) throws {
    var events = try Data(contentsOf: log).split(separator: 10).map {
      try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
    }
    change(&events)
    let data = try events.reduce(into: Data()) { data, e in
      data.append(try JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])); data.append(10)
    }
    try data.write(to: log)
  }
}

@Test(arguments: [false, true]) func forensicPrefixSeparatelyVerifiedAndAlwaysIncomplete(pal: Bool) throws {
  let f = try PrefixFixture(pal: pal); defer { f.clean() }
  let original = try Data(contentsOf: f.raw), journal = try Data(contentsOf: f.log)
  let r = try f.export()
  #expect(r.state == "INCOMPLETE_ACQUISITION_VERIFIED_PREFIX")
  #expect(r.completeFrames == 1 && r.unverifiedTailBytes == 0)
  #expect(try Data(contentsOf: f.raw) == original)
  #expect(try Data(contentsOf: f.log) == journal)
  #expect(try Data(contentsOf: f.destination.appendingPathComponent("verified-prefix.raw")) == original)
  #expect(try Data(contentsOf: f.destination.appendingPathComponent("recovered-complete-frames.dv")) == ingestFrame(pal: pal))
  #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("verification.json").path))
  // Salvage never makes the original admissible to the normal clean exporter.
  #expect(throws: (any Error).self) {
    _ = try DVIngestExporter.exportClosedFlight(at: f.flight.url)
  }
}

@Test func forensicPrefixExcludesUnverifiedTailAndTornJournalLine() throws {
  let f = try PrefixFixture(); defer { f.clean() }
  var data = try Data(contentsOf: f.raw); data.append(Data(repeating: 0xab, count: 173)); try data.write(to: f.raw)
  var log = try Data(contentsOf: f.log); log.append(Data("{\"event\":\"torn".utf8)); try log.write(to: f.log)
  let r = try f.export()
  #expect(r.unverifiedTailBytes == 173 && r.completeFrames == 1)
  #expect(try Data(contentsOf: f.destination.appendingPathComponent("source-flight.ndjson")) == log)
}

@Test(arguments: ["hash", "short", "split", "epoch", "sequence", "reserved", "oversize", "flags", "loss", "route", "duplicate", "checkpointRegression", "conflicting", "missing", "malformed"])
func forensicPrefixRejectsHostileEvidence(kind: String) throws {
  let f = try PrefixFixture(); defer { f.clean() }
  if ["hash", "short", "epoch", "sequence", "reserved", "oversize", "flags", "loss"].contains(kind) {
    var data = try Data(contentsOf: f.raw)
    switch kind {
    case "hash": data[100] ^= 1
    case "short": data.removeLast()
    case "epoch": ingestPut(UInt64(2), into: &data, at: 8 + 560 + 8)
    case "sequence": ingestPut(UInt64(8), into: &data, at: 8)
    case "reserved": data[8 + 60] = 1
    case "oversize": ingestPut(UInt32(4097), into: &data, at: 8 + 36)
    case "flags": data[8 + 56] = 0
    default: ingestPut(UInt64(2), into: &data, at: 8 + 48)
    }
    try data.write(to: f.raw)
    if kind != "hash" && kind != "short" {
      let hash = SHA256.hash(data: data.dropFirst(8)).map { String(format: "%02x", $0) }.joined()
      try f.rewriteJournal { for i in $0.indices { $0[i]["recordSHA256"] = hash } }
    }
  } else if kind == "malformed" { try Data("{bad}\n".utf8).write(to: f.log) }
  else {
    try f.rewriteJournal { events in
      switch kind {
      case "split": for i in events.indices { events[i]["recordBytes"] = 1; events[i]["recordSHA256"] = DVForensicPrefix.hash(Data([1])) }
      case "route": events[0]["wireBase64"] = Data(repeating: 0, count: 48).base64EncodedString()
      case "duplicate": events.append(events[0])
      case "checkpointRegression": events[1]["recordBytes"] = 1
      case "conflicting": events[1]["recordSHA256"] = String(repeating: "a", count: 64)
      default: events.removeFirst()
      }
    }
  }
  #expect(throws: (any Error).self) { _ = try f.export() }
  #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("forensic-prefix.json").path))
}

@Test func forensicPrefixRejectsSymlinkAndExistingDestination() throws {
  let f = try PrefixFixture(); defer { f.clean() }
  try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { _ = try f.export() }
  let original = f.flight.url.appendingPathComponent("saved.raw")
  try FileManager.default.moveItem(at: f.raw, to: original)
  try FileManager.default.createSymbolicLink(at: f.raw, withDestinationURL: original)
  #expect(throws: (any Error).self) { _ = try f.export() }
}

@Test func forensicPrefixRejectsActiveSourceMutation() throws {
  let f = try PrefixFixture(); defer { f.clean() }
  let raw = f.raw
  #expect(throws: (any Error).self) {
    _ = try DVForensicPrefix.export(source: f.flight.url, destination: f.destination) { _, _, _ in
      if let handle = try? FileHandle(forWritingTo: raw) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data([0])); try? handle.close() }
    }
  }
  #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("forensic-prefix.json").path))
}

@Test func forensicPrefixWithNoCompleteFrameDoesNotFabricateVideo() throws {
  let flight = try IngestFixture(packets: Array(ingestPackets(ingestFrame(pal: false)).prefix(1)), closed: false)
  let destination = flight.url.deletingLastPathComponent().appendingPathComponent("prefix-empty-\(UUID().uuidString)")
  defer { flight.cleanup(); try? FileManager.default.removeItem(at: destination) }
  let receipt = try DVForensicPrefix.export(source: flight.url, destination: destination)
  #expect(receipt.completeFrames == 0 && receipt.nativeDVSHA256 == nil && receipt.terminalPartialFrames == 1)
  #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("recovered-complete-frames.dv").path))
}

@Test func forensicPrefixCancellationHasNoCompletionMarker() async throws {
  let f = try PrefixFixture(); defer { f.clean() }
  let worker = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try f.export()
  }
  await #expect(throws: CancellationError.self) { _ = try await worker.value }
  #expect(!FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("forensic-prefix.json").path))
}

@Test(arguments: [false,true]) func forensicPrefixValidatesSessionReply(badEpoch: Bool) throws {
  let f = try PrefixFixture(); defer { f.clean() }
  var reply = Data(repeating: 0, count: 24)
  ingestPut(UInt32(1), into: &reply, at: 0); ingestPut(UInt32(24), into: &reply, at: 4)
  ingestPut(UInt64(badEpoch ? 99 : 1), into: &reply, at: 8)
  try f.rewriteJournal { rows in
    var event = rows[0]; event["event"] = "receive_start_returned"; event["wireBase64"] = reply.base64EncodedString()
    rows.insert(event, at: 1)
  }
  if badEpoch { #expect(throws: (any Error).self) { _ = try f.export() } }
  else { #expect(try f.export().completeFrames == 1) }
}
