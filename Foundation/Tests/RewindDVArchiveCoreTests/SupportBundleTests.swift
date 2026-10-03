import Foundation
import Testing
import CryptoKit
@testable import RewindDVArchiveCore

struct SupportBundleTests {
  @Test func defaultApplicationRootsRetainPassiveTransportEvidence() throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let support = parent.appendingPathComponent("RewindDV")
    let flight = support.appendingPathComponent("PassiveTransportFlights/session")
    try FileManager.default.createDirectory(at: flight, withIntermediateDirectories: true)
    let bytes = Data("{\"event\":\"passive_status_failed\"}\n".utf8)
    let original = flight.appendingPathComponent("flight.ndjson")
    try bytes.write(to: original)
    let output = parent.appendingPathComponent("export")
    let manifest = try SupportBundleCollector.collect(
      roots: SupportBundleCollector.applicationRoots(in: support), into: output)
    let entry = try #require(manifest.entries.first {
      $0.exported?.hasSuffix("/session/flight.ndjson") == true
    }, "\(manifest.entries)")
    let exported = try #require(entry.exported)
    #expect(entry.outcome == "copied snapshot")
    #expect(try Data(contentsOf: output.appendingPathComponent(exported)) == bytes)
    #expect(try Data(contentsOf: original) == bytes)
  }

  @Test func inspectionEnumerationCannotStarveReceiveEvidence() throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let inspection = parent.appendingPathComponent("InspectorFlights"), receive = parent.appendingPathComponent("LiveFlights")
    for root in [inspection, receive] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    for index in 0..<10 { try Data("{}".utf8).write(to: inspection.appendingPathComponent("\(index).json")) }
    let evidence = Data("{\"event\":\"receive_failed\"}".utf8)
    try evidence.write(to: receive.appendingPathComponent("flight.ndjson"))
    var limits = SupportBundleCollector.Limits(); limits.inspectedEntries = 2
    let out = parent.appendingPathComponent("export")
    let manifest = try SupportBundleCollector.collect(roots: [inspection, receive], into: out, limits: limits)
    #expect(manifest.entries.contains { $0.outcome.contains("enumeration limit") })
    #expect(try Data(contentsOf: out.appendingPathComponent("root-1/flight.ndjson")) == evidence)
  }
  @Test func evidenceIsCopiedAndMediaAndSymlinksExcluded() throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("flight")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let bytes = Data("{\"event\":\"test\"}\n".utf8)
    try bytes.write(to: source.appendingPathComponent("flight.ndjson"))
    try bytes.write(to: source.appendingPathComponent("capture.dv"))
    try bytes.write(to: source.appendingPathComponent("receive.records.raw"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("secret.json"), withDestinationURL: source.appendingPathComponent("capture.dv"))
    let out = parent.appendingPathComponent("export")
    let manifest = try SupportBundleCollector.collect(roots: [source], into: out)
    let copied = manifest.entries.filter { $0.exported != nil }
    #expect(copied.count == 1)
    #expect(copied[0].exported == "root-0/flight.ndjson")
    #expect(copied[0].sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    #expect(try Data(contentsOf: out.appendingPathComponent("root-0/flight.ndjson")) == bytes)
    #expect(try Data(contentsOf: source.appendingPathComponent("flight.ndjson")) == bytes)
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("root-0/capture.dv").path))
    #expect(manifest.entries.contains { $0.outcome.contains("symbolic link") })
    #expect(throws: (any Error).self) { try SupportBundleCollector.collect(roots: [source], into: out) }
  }
  @Test func truncationIsExplicitAndBudgetBounded() throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data(repeating: 65, count: 100).write(to: source.appendingPathComponent("flight.ndjson"))
    var limits = SupportBundleCollector.Limits(); limits.fileBytes = 16; limits.totalBytes = 10
    let manifest = try SupportBundleCollector.collect(roots: [source, parent.appendingPathComponent("missing")], into: parent.appendingPathComponent("export"), limits: limits)
    #expect(manifest.entries.compactMap(\.bytes).reduce(0, +) == 10)
    #expect(manifest.entries.filter { $0.outcome.hasPrefix("partial:") }.count == 2)
    #expect(manifest.entries.compactMap(\.offset) == [0, 95])
    #expect(manifest.entries.contains { $0.outcome.contains("unavailable") })
  }
  @Test func symbolicRootIsRejected() throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let link = parent.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
    let manifest = try SupportBundleCollector.collect(roots: [link], into: parent.appendingPathComponent("export"))
    #expect(manifest.entries.count == 1)
    #expect(manifest.entries[0].outcome.contains("symbolic-link root"))
  }
}
