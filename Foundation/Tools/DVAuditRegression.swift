// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline native regression. Generated fixtures are synthetic, NOT hardware proof.
import Foundation
import CryptoKit
import Darwin

@main struct DVAuditRegression {
  static func main() throws {
    guard CommandLine.arguments.count == 4 else {
      throw DVIngestError.invalidEvidence("transport tool, boundary tool, verified capture directory required")
    }
    let transport = CommandLine.arguments[1], boundary = CommandLine.arguments[2]
    let source = URL(fileURLWithPath: CommandLine.arguments[3])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-Audit-Tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    // Retained on success/failure for inspection; no destructive cleanup.
    var checks = 0
    func expectFailure(_ action: () throws -> Void) throws {
      do { try action() } catch { checks += 1; return }
      throw DVIngestError.invalidEvidence("Expected rejection")
    }
    func run(_ program: String, _ argument: String, pass: Bool) throws -> String {
      let process = Process(), pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: program); process.arguments = [argument]
      process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(decoding: output, as: UTF8.self)
      guard (process.terminationStatus == 0) == pass,
        pass || !text.contains("audit_complete") else {
        throw DVIngestError.invalidEvidence("Unexpected tool result")
      }
      checks += 1
      return text
    }
    let tiny = root.appendingPathComponent("tiny")
    try Data([1,2,3]).write(to: tiny, options: .withoutOverwriting)
    let input = try DVAuditInput(tiny)
    guard try input.readExactly(3) == Data([1,2,3]), try input.readExactly(1) == nil else {
      throw DVIngestError.invalidEvidence("Exact read/EOF mismatch")
    }
    input.close(); checks += 1
    let short = try DVAuditInput(tiny)
    try expectFailure { _ = try short.readExactly(4) }; short.close()
    try expectFailure { _ = try DVAuditInput(tiny, maximumBytes: 2) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tiny)
    try expectFailure { _ = try DVAuditInput(link) }
    let fifo = root.appendingPathComponent("fifo")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw DVIngestError.fileOperation("test FIFO", errno) }
    try expectFailure { _ = try DVAuditInput(fifo) }
    let empty = root.appendingPathComponent("empty.dv")
    try Data().write(to: empty, options: .withoutOverwriting)
    _ = try run(boundary, empty.path, pass: false)
    _ = try run(boundary, tiny.path, pass: false)
    _ = try run(boundary, link.path, pass: false)

    let data = try DVAuditInput.boundedMetadata(source.appendingPathComponent("verification.json"))
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    for key in ["legacyStoppedSnapshotUsed", "finalAcknowledgementConfirmed", "schemaVersion"] {
      let directory = root.appendingPathComponent(key)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      var value = original
      value[key] = key == "schemaVersion" ? 9 : key == "legacyStoppedSnapshotUsed"
      try JSONSerialization.data(withJSONObject: value).write(
        to: directory.appendingPathComponent("verification.json"), options: .withoutOverwriting)
      _ = try run(transport, directory.path, pass: false)
    }
    // Synthetic final-record loss around unchanged local fixture bytes. This
    // exercises separate raw-gap/CIP accounting, not a physical-loss assertion.
    let lossDirectory = root.appendingPathComponent("SYNTHETIC-tail-loss")
    try FileManager.default.createDirectory(at: lossDirectory, withIntermediateDirectories: false)
    for name in ["capture.dv", "receive.records.raw"] {
      try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: lossDirectory.appendingPathComponent(name))
    }
    var value = original
    guard (value["knownDroppedPackets"] as? Int) == 0 else {
      throw DVIngestError.invalidEvidence("Regression fixture must start with zero raw loss")
    }
    var status = Data(base64Encoded: value["finalStatusWireBase64"] as! String)!
    func word(_ offset: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(status[offset+$1]) << (8*$1) } }
    func put(_ number: UInt64, _ offset: Int) {
      for n in 0..<8 { status[offset+n] = UInt8(truncatingIfNeeded: number >> (8*n)) }
    }
    put(word(96) + 1, 96); put(1, 104)
    value["knownDroppedPackets"] = 1; value["hostRingDrops"] = 1; value["rawTransportGapEvents"] = 1
    value["finalStatusWireBase64"] = status.base64EncodedString()
    let journal = try String(contentsOf: source.appendingPathComponent("flight.ndjson"), encoding: .utf8)
    var changedJournal = Data()
    for line in journal.split(separator: "\n") {
      var event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
      if event["event"] as? String == "receive_final_status" { event["wireBase64"] = status.base64EncodedString() }
      changedJournal.append(try JSONSerialization.data(withJSONObject: event)); changedJournal.append(10)
    }
    try changedJournal.write(to: lossDirectory.appendingPathComponent("flight.ndjson"), options: .withoutOverwriting)
    value["journalSHA256"] = SHA256.hash(data: changedJournal).map { String(format: "%02x", $0) }.joined()
    try JSONSerialization.data(withJSONObject: value).write(
      to: lossDirectory.appendingPathComponent("verification.json"), options: .withoutOverwriting)
    let result = try run(transport, lossDirectory.path, pass: true)
    guard result.contains("terminal_raw_gap"), result.contains("\"rawTransportGapEvents\":1") else {
      throw DVIngestError.invalidEvidence("Tail loss not reported separately")
    }
    print("AUDIT_REGRESSION_PASS checks=\(checks); synthetic fixtures retained at \(root.path); NOT hardware proof")
  }
}
