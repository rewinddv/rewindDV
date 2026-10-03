import Foundation
import Testing
@testable import RewindDVArchiveCore

struct SessionDiagnosticJournalTests {
  @Test func rotationKeepsEveryLineAndFailureIsSticky() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = SessionDiagnosticJournal.Limits()
    limits.segmentBytes = 10; limits.sessionBytes = 100
    let journal = try SessionDiagnosticJournal(root: root, metadata: Data("{}".utf8), limits: limits)
    for i in 0..<4 { try journal.append(Data("{\"n\":\(i)}".utf8)) }
    try journal.flush()
    let segments = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(segments.count == 2)
    let bytes = try segments.reduce(Data()) { try $0 + Data(contentsOf: $1) }
    #expect(String(data: bytes, encoding: .utf8) == "{\"n\":0}\n{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    #expect(throws: (any Error).self) { try journal.append(Data(repeating: 65, count: 100)) }
    #expect(throws: (any Error).self) { try journal.append(Data("{}".utf8)) }
    #expect(try segments.reduce(Data()) { try $0 + Data(contentsOf: $1) } == bytes)
  }
  @Test func storageLimitPreservesOldEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old.ndjson")
    let data = Data(repeating: 65, count: 40)
    try data.write(to: old)
    var limits = SessionDiagnosticJournal.Limits(); limits.retainedBytes = 40
    #expect(throws: (any Error).self) { try SessionDiagnosticJournal(root: root, metadata: Data(), limits: limits) }
    #expect(try Data(contentsOf: old) == data)
  }
}
