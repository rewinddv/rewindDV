// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Pins a user-selected regular file, verifies its whole-file digest against the
/// map, then hashes every selected frame before exposing bytes. No mapped path
/// is followed automatically. Replacement, truncation and in-place edits fail.
public actor DVVerifiedFrameSource {
  public struct Frame: Sendable {
    public let bytes: Data
    public let evidence: DVFrameForensics
  }
  private let fd: Int32
  private let url: URL
  private let status: stat
  private let snapshot: DVReviewedRangeExporter.Snapshot

  public init(url: URL, snapshot: DVReviewedRangeExporter.Snapshot,
    progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) throws {
    try snapshot.validate()
    let opened = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0 else { throw DVIngestError.fileOperation("open original DV", errno) }
    var keep = false
    defer { if !keep { Darwin.close(opened) } }
    var initial = stat()
    guard fstat(opened, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
      initial.st_size >= 0, UInt64(initial.st_size) == snapshot.sourceByteCount else {
      throw DVIngestError.invalidEvidence("source is not a regular file of the map's exact size")
    }
    var digest = SHA256(), offset: UInt64 = 0
    while offset < snapshot.sourceByteCount {
      try Task.checkCancellation()
      let bytes = try Self.read(opened, offset: offset, count: Int(min(1_048_576, snapshot.sourceByteCount - offset)))
      digest.update(data: bytes); offset += UInt64(bytes.count)
      progress(offset, snapshot.sourceByteCount)
    }
    guard Self.hex(digest.finalize()) == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("wrong original DV: whole-file SHA-256 does not match this map")
    }
    try Self.check(opened, url: url, original: initial)
    self.fd = opened; self.url = url; self.status = initial; self.snapshot = snapshot
    keep = true
  }
  deinit { Darwin.close(fd) }

  public func verifyUnchanged() throws {
    try Task.checkCancellation()
    try Self.check(fd, url: url, original: status)
  }

  public func requireSnapshot(_ expected: DVReviewedRangeExporter.Snapshot) throws {
    guard snapshot == expected else { throw DVIngestError.invalidEvidence("report source binding differs from map") }
    try verifyUnchanged()
  }

  public func frame(_ record: DVTapeEvidenceMapExporter.FrameRecord) throws -> Frame {
    try Task.checkCancellation()
    try Self.check(fd, url: url, original: status)
    let b = record.boundaryEvidence
    let identity = try snapshot.frame(b.frameOrdinal)
    guard b.frameByteCount == identity.byteCount, b.videoSystem == identity.system,
      b.frameSourceByteOffset == identity.byteOffset,
      record.sourceFrameIdentity == nil || record.sourceFrameIdentity == identity else {
      throw DVIngestError.invalidEvidence("frame is outside verified source")
    }
    let bytes = try Self.read(fd, offset: b.frameSourceByteOffset, count: b.frameByteCount)
    guard Self.hex(SHA256.hash(data: bytes)) == b.frameSHA256 else {
      throw DVIngestError.invalidEvidence("selected frame hash differs from evidence map")
    }
    let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: b.frameOrdinal, byteOffset: b.frameSourceByteOffset)
    guard try DVBoundaryEvidence.inspect(frame: bytes, ordinal: b.frameOrdinal, sourceByteOffset: b.frameSourceByteOffset) == b,
      DVTapeEvidenceMapExporter.rawSubcodeEvidence(inventory) == record.rawSubcode,
      inventory.extents.count == record.metadataExtentCount else {
      throw DVIngestError.invalidEvidence("frame metadata differs from original bytes")
    }
    let evidence = DVFrameForensics.inspectValidated(frame: bytes, inventory: inventory)
    if let timeline = record.timeline,
      timeline.point != DVFrameTimelineEvidence.inspect(inventory, report: evidence.semantics) {
      throw DVIngestError.invalidEvidence("recorded timeline labels differ from original bytes")
    }
    if let persisted = record.quality, persisted != evidence.summary {
      throw DVIngestError.invalidEvidence("frame quality evidence differs from original bytes")
    }
    try Self.check(fd, url: url, original: status)
    try Task.checkCancellation()
    return Frame(bytes: bytes, evidence: evidence)
  }

  private static func read(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
    var result = Data(count: count), done = 0
    while done < count {
      try Task.checkCancellation()
      let amount = result.withUnsafeMutableBytes {
        Darwin.pread(fd, $0.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
      }
      if amount < 0 && errno == EINTR { continue }
      guard amount > 0 else { throw DVIngestError.invalidEvidence("original DV read failed or was truncated") }
      done += amount
    }
    return result
  }
  private static func check(_ fd: Int32, url: URL, original: stat) throws {
    var current = stat(), path = stat()
    guard fstat(fd, &current) == 0, lstat(url.path, &path) == 0,
      same(original, current), same(original, path) else {
      throw DVIngestError.invalidEvidence("original DV changed or was replaced; reconnect and verify it again")
    }
  }
  private static func same(_ a: stat, _ b: stat) -> Bool {
    b.st_mode & S_IFMT == S_IFREG && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
