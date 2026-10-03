// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// Serialized by its owning actor. Supplemental diagnostics, never an ingest
/// durability barrier. No deletion of previous evidence and no tape operations.
public final class SessionDiagnosticJournal {
  public struct Limits: Sendable {
    public var retainedBytes = 512 * 1024 * 1024
    public var sessionBytes = 128 * 1024 * 1024
    public var segmentBytes = 4 * 1024 * 1024
    public init() {}
  }
  public let directory: URL
  private let limits: Limits
  private var file: FileHandle?
  private var segment = 0, segmentBytes = 0, totalBytes = 0, records = 0
  private var failure: String?
  public init(root: URL, metadata: Data, limits: Limits = Limits()) throws {
    self.limits = limits
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var retained = 0
    if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) {
      for case let url as URL in walker {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        if values.isSymbolicLink == true { walker.skipDescendants(); continue }
        if values.isRegularFile == true { retained += values.fileSize ?? 0 }
        if retained >= limits.retainedBytes { throw JournalError("Session diagnostics storage limit reached. Export/archive older AlphaSessions before another test.") }
      }
    }
    guard limits.segmentBytes > 0, limits.sessionBytes >= metadata.count,
      limits.retainedBytes - retained >= metadata.count else { throw JournalError("Session diagnostics storage budget exhausted.") }
    directory = root.appendingPathComponent(UUID().uuidString)
    guard mkdir(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    try metadata.write(to: directory.appendingPathComponent("session.json"), options: .withoutOverwriting)
    totalBytes = metadata.count
  }
  public func append(_ json: Data) throws {
    if let failure { throw JournalError(failure) }
    do {
      guard json.count < 1024 * 1024 else { throw JournalError("Diagnostic observation exceeded 1 MiB; refusing unbounded write.") }
      guard totalBytes + json.count + 1 <= limits.sessionBytes else { throw JournalError("Session diagnostic limit reached. Capture is unaffected; export and restart after capture.") }
      if file == nil || segmentBytes >= limits.segmentBytes {
        try flush(); try file?.close(); file = nil
        let url = directory.appendingPathComponent(String(format: "observations-%04d.ndjson", segment))
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); segment += 1; segmentBytes = 0
      }
      let line = json + Data([10])
      try file!.write(contentsOf: line)
      if records % 5 == 0 { try flush() }
      records += 1; segmentBytes += line.count; totalBytes += line.count
    } catch { failure = error.localizedDescription; throw error }
  }
  public func flush() throws { try file?.synchronize() }
  deinit { try? file?.close() }
  private struct JournalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
