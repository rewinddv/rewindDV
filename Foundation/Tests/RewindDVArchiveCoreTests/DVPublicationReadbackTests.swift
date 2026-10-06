// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

@Test(arguments: [false, true]) func publicationRejectsChangedPartialOnEveryFilesystemPath(portable: Bool) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let original = Data(repeating: 0x11, count: 4096), changed = Data(repeating: 0x22, count: 4096)
  let sha = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
  let partial = root.appendingPathComponent("capture.dv.partial")
  try changed.write(to: partial)
  #expect(throws: DVIngestError.self) {
    try DVIngestExporter.promote("capture.dv", in: root, expectedBytes: UInt64(original.count),
      expectedSHA256: sha, forcePortableCopy: portable)
  }
  #expect(try Data(contentsOf: partial) == changed)
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("capture.dv").path))
}

@Test(arguments: [false, true]) func publicationCancellationIsOptIn(portable: Bool) async throws {
  for cancellable in [false, true] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(repeating: 0x11, count: 4096)
    let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try bytes.write(to: root.appendingPathComponent("capture.dv.partial"))
    let published = try await Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try DVIngestExporter.promote("capture.dv", in: root, expectedBytes: UInt64(bytes.count),
          expectedSHA256: sha, forcePortableCopy: portable, cancellable: cancellable)
        return true
      } catch is CancellationError { return false }
    }.value
    #expect(published == !cancellable)
    let name = published ? "capture.dv" : "capture.dv.partial"
    #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes)
  }
}

@Test func dvIngestCannotPublishStaleReceiptAfterOutputChange() throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
  defer { fixture.cleanup() }
  #expect(throws: DVIngestError.self) {
    _ = try DVIngestExporter.exportClosedFlight(at: fixture.url) { progress in
      if progress.phase == .publishingVerifiedFiles {
        do {
          let path = fixture.url.appendingPathComponent("capture.dv.partial")
          var changed = try Data(contentsOf: path)
          changed[100] ^= 1
          try changed.write(to: path, options: .atomic)
        } catch { Issue.record(error) }
      }
    }
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  #expect(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv.partial").path))
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
}
