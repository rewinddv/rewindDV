// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Creates byte-for-byte DV25 range derivatives from a separately reviewed
/// source. A successful scan proves the bytes and DIF structure observed by
/// this process; it does not qualify acquisition continuity or source quality.
public enum DVReviewedRangeExporter {
  public static let outputFileName = "reviewed-range.dv"
  public static let intentFileName = "export-intent.json"
  public static let completionMarkerName = "provenance.json"

  public struct Snapshot: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let sourceSHA256: String
    public let frameCount: UInt64
    public let frameByteCount: Int
    public let sourceByteCount: UInt64
    public let videoSystem: DVBoundaryEvidence.VideoSystem

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case sourceSHA256 = "source_sha256"
      case frameCount = "frame_count"
      case frameByteCount = "frame_byte_count"
      case sourceByteCount = "source_byte_count"
      case videoSystem = "video_system"
    }
  }

  /// `provenance.json` is both this receipt's serialized form and the final
  /// completion marker. Its absence means the destination is incomplete.
  public struct Receipt: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let completionState: String
    public let outputFile: String
    public let sourceSHA256: String
    public let sourceByteCount: UInt64
    public let sourceFrameCount: UInt64
    public let sourceFrameByteCount: Int
    public let sourceVideoSystem: DVBoundaryEvidence.VideoSystem
    public let firstSourceFrameOrdinal: UInt64
    public let endSourceFrameOrdinalExclusive: UInt64
    public let exportedFrameCount: UInt64
    public let sourceByteOffset: UInt64
    public let sourceByteEndExclusive: UInt64
    public let outputByteCount: UInt64
    public let outputSHA256: String
    public let omittedLeadingFrameCount: UInt64
    public let omittedTrailingFrameCount: UInt64
    public let ordinalMapping: String
    public let derivativeClassification: String
    public let bytesReencoded: Bool
    public let audioResampled: Bool
    public let timecodeRewritten: Bool
    public let captureQuality: String
    public let acquisitionLoss: String
    public let archivalQualification: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case completionState = "completion_state"
      case outputFile = "output_file"
      case sourceSHA256 = "source_sha256"
      case sourceByteCount = "source_byte_count"
      case sourceFrameCount = "source_frame_count"
      case sourceFrameByteCount = "source_frame_byte_count"
      case sourceVideoSystem = "source_video_system"
      case firstSourceFrameOrdinal = "first_source_frame_ordinal"
      case endSourceFrameOrdinalExclusive = "end_source_frame_ordinal_exclusive"
      case exportedFrameCount = "exported_frame_count"
      case sourceByteOffset = "source_byte_offset"
      case sourceByteEndExclusive = "source_byte_end_exclusive"
      case outputByteCount = "output_byte_count"
      case outputSHA256 = "output_sha256"
      case omittedLeadingFrameCount = "omitted_leading_frame_count"
      case omittedTrailingFrameCount = "omitted_trailing_frame_count"
      case ordinalMapping = "ordinal_mapping"
      case derivativeClassification = "derivative_classification"
      case bytesReencoded = "bytes_reencoded"
      case audioResampled = "audio_resampled"
      case timecodeRewritten = "timecode_rewritten"
      case captureQuality = "capture_quality"
      case acquisitionLoss = "acquisition_loss"
      case archivalQualification = "archival_qualification"
    }
  }

  /// Fully scans a regular DV25 file in frame-sized memory, validates every
  /// frame through the native metadata inventory, and independently rereads
  /// the file before returning its identity snapshot.
  public static func inspect(source: URL) throws -> Snapshot {
    try Task.checkCancellation()
    let reader = try RegularSource(source)
    defer { reader.close() }
    guard reader.byteCount > 0 else {
      throw DVIngestError.invalidEvidence("reviewed range source is empty")
    }

    let prefix = try reader.readExactly(80)
    let frameByteCount = prefix[3] & 0x80 == 0 ? 120_000 : 144_000
    guard reader.byteCount % UInt64(frameByteCount) == 0 else {
      throw DVIngestError.invalidEvidence("reviewed range source ends with an incomplete DV25 frame")
    }
    let frameCount = reader.byteCount / UInt64(frameByteCount)
    let videoSystem: DVBoundaryEvidence.VideoSystem =
      frameByteCount == 120_000 ? .ntsc525_60 : .pal625_50
    var digest = SHA256()

    for ordinal in 0..<frameCount {
      try Task.checkCancellation()
      let frame: Data
      if ordinal == 0 {
        var first = prefix
        first.append(try reader.readExactly(frameByteCount - prefix.count))
        frame = first
      } else {
        frame = try reader.readExactly(frameByteCount)
      }
      _ = try DVMetadataInventory.inspect(
        frame: frame,
        ordinal: ordinal,
        byteOffset: try multiplied(ordinal, UInt64(frameByteCount), "frame source offset"))
      try validateCanonicalOrder(frame, sequenceCount: frameByteCount == 120_000 ? 10 : 12)
      digest.update(data: frame)
    }
    guard try reader.isAtEOF() else {
      throw DVIngestError.invalidEvidence("reviewed range source grew during inspection")
    }
    let firstSHA = hex(digest.finalize())
    try reader.requireStableAndCurrentPath(source)
    try reader.rewind()
    let reread = try reader.hashToEOF()
    try reader.requireStableAndCurrentPath(source)
    guard reread.bytes == reader.byteCount, reread.sha256 == firstSHA else {
      throw DVIngestError.invalidEvidence("reviewed range source changed during inspection")
    }
    return Snapshot(
      schemaVersion: 1,
      sourceSHA256: firstSHA,
      frameCount: frameCount,
      frameByteCount: frameByteCount,
      sourceByteCount: reader.byteCount,
      videoSystem: videoSystem)
  }

  /// Exports a nonempty half-open frame range into a newly-created directory.
  /// Source frames are copied unchanged. Failures before the commit phase leave
  /// the intent plus any partial payload and no `provenance.json`. If the final
  /// directory sync fails after marker publication, the marker is withdrawn on
  /// a best-effort basis and the thrown error means durability is uncertain.
  public static func export(
    source: URL,
    snapshot: Snapshot,
    first: UInt64,
    endExclusive: UInt64,
    destination: URL
  ) throws -> Receipt {
    try Task.checkCancellation()
    try validate(snapshot: snapshot, first: first, endExclusive: endExclusive)
    let sourceReader = try RegularSource(source)
    defer { sourceReader.close() }
    guard sourceReader.byteCount == snapshot.sourceByteCount else {
      throw DVIngestError.invalidEvidence("reviewed range source size no longer matches snapshot")
    }

    let destinationDirectory = try DestinationDirectory.create(destination)
    defer { destinationDirectory.close() }
    let intent = ExportIntent(
      schemaVersion: 1,
      state: "incomplete_until_provenance_json_is_published",
      sourceSnapshot: snapshot,
      firstSourceFrameOrdinal: first,
      endSourceFrameOrdinalExclusive: endExclusive,
      intendedOutputFile: outputFileName,
      completionMarker: completionMarkerName)
    try destinationDirectory.writeExclusive(
      named: intentFileName, data: try encode(intent) + Data([10]), synchronize: true)
    try destinationDirectory.synchronize()

    let partialName = outputFileName + ".partial"
    let output = try destinationDirectory.makeExclusiveWriter(named: partialName)
    var outputClosed = false
    defer { if !outputClosed { try? output.close() } }
    var sourceDigest = SHA256()
    var outputDigest = SHA256()
    var outputBytes: UInt64 = 0

    for ordinal in 0..<snapshot.frameCount {
      try Task.checkCancellation()
      let frame = try sourceReader.readExactly(snapshot.frameByteCount)
      sourceDigest.update(data: frame)
      if ordinal >= first && ordinal < endExclusive {
        try output.write(contentsOf: frame)
        outputDigest.update(data: frame)
        outputBytes = try added(outputBytes, UInt64(frame.count), "reviewed output byte count")
      }
    }
    guard try sourceReader.isAtEOF() else {
      throw DVIngestError.invalidEvidence("reviewed range source grew during export")
    }
    let sourceSHA = hex(sourceDigest.finalize())
    let expectedOutputSHA = hex(outputDigest.finalize())
    try sourceReader.requireStableAndCurrentPath(source)
    guard sourceSHA == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("reviewed range source no longer matches snapshot")
    }
    try output.synchronize()
    try output.close()
    outputClosed = true

    try sourceReader.rewind()
    let sourceReread = try sourceReader.hashToEOF()
    try sourceReader.requireStableAndCurrentPath(source)
    guard sourceReread.bytes == snapshot.sourceByteCount,
      sourceReread.sha256 == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("reviewed range source changed during export reread")
    }
    let outputReread = try destinationDirectory.hashRegularFile(named: partialName)
    // Output reread can be long. Bind the source descriptor and pathname once
    // more immediately before the non-cancellable publication phase.
    try sourceReader.requireStableAndCurrentPath(source)
    guard outputReread.bytes == outputBytes, outputReread.sha256 == expectedOutputSHA else {
      throw DVIngestError.invalidEvidence("reviewed range output reread mismatch")
    }
    let expectedOutputBytes = try multiplied(
      endExclusive - first, UInt64(snapshot.frameByteCount), "expected reviewed output byte count")
    guard outputBytes == expectedOutputBytes else {
      throw DVIngestError.invalidEvidence("reviewed range output byte count does not match frame range")
    }

    let sourceByteOffset = try multiplied(first, UInt64(snapshot.frameByteCount), "range byte offset")
    let sourceByteEnd = try multiplied(endExclusive, UInt64(snapshot.frameByteCount), "range byte end")
    let receipt = Receipt(
      schemaVersion: 1,
      completionState: "complete",
      outputFile: outputFileName,
      sourceSHA256: snapshot.sourceSHA256,
      sourceByteCount: snapshot.sourceByteCount,
      sourceFrameCount: snapshot.frameCount,
      sourceFrameByteCount: snapshot.frameByteCount,
      sourceVideoSystem: snapshot.videoSystem,
      firstSourceFrameOrdinal: first,
      endSourceFrameOrdinalExclusive: endExclusive,
      exportedFrameCount: endExclusive - first,
      sourceByteOffset: sourceByteOffset,
      sourceByteEndExclusive: sourceByteEnd,
      outputByteCount: outputBytes,
      outputSHA256: expectedOutputSHA,
      omittedLeadingFrameCount: first,
      omittedTrailingFrameCount: snapshot.frameCount - endExclusive,
      ordinalMapping: "output frame n maps to source frame first_source_frame_ordinal + n; complete source frame bytes copied unchanged",
      derivativeClassification: "reviewed_range_derivative_not_unmodified_master",
      bytesReencoded: false,
      audioResampled: false,
      timecodeRewritten: false,
      captureQuality: "unknown_not_established_by_raw_dv_scan",
      acquisitionLoss: "unknown_not_established_by_raw_dv_scan",
      archivalQualification: "not_established; this derivative does not replace or qualify an unmodified source master")

    // This is the final cancellation boundary. Once commit begins, completion
    // is driven to a terminal success or durability error without observing a
    // newly-arriving task cancellation.
    try Task.checkCancellation()
    let markerPartial = completionMarkerName + ".partial"
    let markerBytes = try encode(receipt) + Data([10])
    let markerSHA = hex(SHA256.hash(data: markerBytes))
    try destinationDirectory.writeExclusive(named: markerPartial, data: markerBytes, synchronize: true)
    try destinationDirectory.promoteExclusive(from: partialName, to: outputFileName,
      expectedBytes: outputBytes, expectedSHA256: expectedOutputSHA)
    try destinationDirectory.synchronize()
    // The completion marker is deliberately the final published entry.
    try destinationDirectory.promoteExclusive(from: markerPartial, to: completionMarkerName,
      expectedBytes: UInt64(markerBytes.count), expectedSHA256: markerSHA)
    do {
      try destinationDirectory.synchronize()
    } catch {
      destinationDirectory.withdrawCompletionMarkerBestEffort(
        from: completionMarkerName, to: markerPartial)
      throw error
    }
    return receipt
  }

  private struct ExportIntent: Codable {
    let schemaVersion: UInt16
    let state: String
    let sourceSnapshot: Snapshot
    let firstSourceFrameOrdinal: UInt64
    let endSourceFrameOrdinalExclusive: UInt64
    let intendedOutputFile: String
    let completionMarker: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case state
      case sourceSnapshot = "source_snapshot"
      case firstSourceFrameOrdinal = "first_source_frame_ordinal"
      case endSourceFrameOrdinalExclusive = "end_source_frame_ordinal_exclusive"
      case intendedOutputFile = "intended_output_file"
      case completionMarker = "completion_marker"
    }
  }

  private static func validate(snapshot: Snapshot, first: UInt64, endExclusive: UInt64) throws {
    guard snapshot.schemaVersion == 1,
      snapshot.frameByteCount == 120_000 || snapshot.frameByteCount == 144_000,
      snapshot.videoSystem == (snapshot.frameByteCount == 120_000 ? .ntsc525_60 : .pal625_50),
      snapshot.frameCount > 0,
      first < endExclusive,
      endExclusive <= snapshot.frameCount,
      snapshot.sourceSHA256.count == 64,
      snapshot.sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      try multiplied(snapshot.frameCount, UInt64(snapshot.frameByteCount), "snapshot byte count")
        == snapshot.sourceByteCount else {
      throw DVIngestError.invalidEvidence("reviewed range snapshot or requested frame bounds are invalid")
    }
  }

  private static func validateCanonicalOrder(_ frame: Data, sequenceCount: Int) throws {
    var offset = 0
    func require(_ section: UInt8, _ block: UInt8, _ sequence: UInt8) throws {
      guard frame[offset] >> 5 == section,
        frame[offset + 1] >> 4 == sequence,
        frame[offset + 2] == block else {
        throw DVIngestError.invalidEvidence("reviewed range source has out-of-order DIF blocks")
      }
      offset += 80
    }
    for sequence in 0..<sequenceCount {
      try require(0, 0, UInt8(sequence))
      for block in 0..<2 { try require(1, UInt8(block), UInt8(sequence)) }
      for block in 0..<3 { try require(2, UInt8(block), UInt8(sequence)) }
      for group in 0..<9 {
        try require(3, UInt8(group), UInt8(sequence))
        for block in group * 15..<(group + 1) * 15 {
          try require(4, UInt8(block), UInt8(sequence))
        }
      }
    }
    guard offset == frame.count else {
      throw DVIngestError.invalidEvidence("reviewed range source frame layout mismatch")
    }
  }

  private final class RegularSource {
    let fd: Int32
    let initialStatus: stat
    let byteCount: UInt64
    private var closed = false

    init(_ url: URL) throws {
      fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw DVIngestError.fileOperation("open reviewed DV source", errno) }
      var status = stat()
      guard fstat(fd, &status) == 0 else {
        let code = errno
        Darwin.close(fd)
        throw DVIngestError.fileOperation("inspect reviewed DV source", code)
      }
      guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
        Darwin.close(fd)
        throw DVIngestError.invalidEvidence("reviewed DV source is not a regular file")
      }
      initialStatus = status
      byteCount = UInt64(status.st_size)
    }

    func close() {
      if !closed { Darwin.close(fd); closed = true }
    }

    func readExactly(_ count: Int) throws -> Data {
      guard count >= 0 else { throw DVIngestError.invalidEvidence("negative source read refused") }
      var result = Data(count: count)
      var filled = 0
      while filled < count {
        try Task.checkCancellation()
        let amount: Int = try result.withUnsafeMutableBytes { bytes in
          let value = Darwin.read(fd, bytes.baseAddress!.advanced(by: filled), count - filled)
          if value < 0 { throw DVIngestError.fileOperation("read reviewed DV source", errno) }
          return value
        }
        guard amount > 0 else {
          throw DVIngestError.invalidEvidence("reviewed DV source is truncated")
        }
        filled += amount
      }
      return result
    }

    func isAtEOF() throws -> Bool {
      var byte: UInt8 = 0
      let amount = Darwin.read(fd, &byte, 1)
      guard amount >= 0 else { throw DVIngestError.fileOperation("check reviewed DV source end", errno) }
      return amount == 0
    }

    func rewind() throws {
      guard lseek(fd, 0, SEEK_SET) == 0 else {
        throw DVIngestError.fileOperation("rewind reviewed DV source", errno)
      }
    }

    func hashToEOF() throws -> (bytes: UInt64, sha256: String) {
      var hash = SHA256()
      var count: UInt64 = 0
      while true {
        try Task.checkCancellation()
        var buffer = Data(count: 1_048_576)
        let amount: Int = try buffer.withUnsafeMutableBytes { bytes in
          let value = Darwin.read(fd, bytes.baseAddress!, bytes.count)
          if value < 0 { throw DVIngestError.fileOperation("reread reviewed DV source", errno) }
          return value
        }
        if amount == 0 { break }
        buffer.removeSubrange(amount..<buffer.count)
        hash.update(data: buffer)
        count = try added(count, UInt64(amount), "source reread byte count")
      }
      return (count, hex(hash.finalize()))
    }

    func requireStableAndCurrentPath(_ url: URL) throws {
      var current = stat()
      guard fstat(fd, &current) == 0 else {
        throw DVIngestError.fileOperation("reinspect reviewed DV source", errno)
      }
      var pathStatus = stat()
      guard lstat(url.path, &pathStatus) == 0 else {
        throw DVIngestError.fileOperation("reinspect reviewed DV source path", errno)
      }
      guard current.st_mode & S_IFMT == S_IFREG,
        pathStatus.st_mode & S_IFMT == S_IFREG,
        current.st_dev == initialStatus.st_dev,
        current.st_ino == initialStatus.st_ino,
        current.st_size == initialStatus.st_size,
        current.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
        current.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec,
        current.st_ctimespec.tv_sec == initialStatus.st_ctimespec.tv_sec,
        current.st_ctimespec.tv_nsec == initialStatus.st_ctimespec.tv_nsec,
        pathStatus.st_dev == initialStatus.st_dev,
        pathStatus.st_ino == initialStatus.st_ino else {
        throw DVIngestError.invalidEvidence("reviewed DV source identity or metadata changed during operation")
      }
    }
  }

  private final class DestinationDirectory {
    let fd: Int32
    let parentFD: Int32
    private var closed = false

    static func create(_ url: URL) throws -> DestinationDirectory {
      let name = url.lastPathComponent
      guard !name.isEmpty, name != ".", name != ".." else {
        throw DVIngestError.invalidEvidence("reviewed range destination name is invalid")
      }
      let parentFD = Darwin.open(
        url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard parentFD >= 0 else {
        throw DVIngestError.fileOperation("open reviewed range destination parent", errno)
      }
      guard mkdirat(parentFD, name, 0o700) == 0 else {
        let code = errno
        Darwin.close(parentFD)
        if code == EEXIST { throw DVIngestError.destinationExists(url.path) }
        throw DVIngestError.fileOperation("create reviewed range destination", code)
      }
      let fd = openat(
        parentFD, name, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else {
        let code = errno
        Darwin.close(parentFD)
        throw DVIngestError.fileOperation("open reviewed range destination", code)
      }
      var directoryStatus = stat()
      var pathStatus = stat()
      guard fstat(fd, &directoryStatus) == 0,
        fstatat(parentFD, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
        let code = errno
        Darwin.close(fd)
        Darwin.close(parentFD)
        throw DVIngestError.fileOperation("bind reviewed range destination", code)
      }
      guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
        pathStatus.st_mode & S_IFMT == S_IFDIR,
        pathStatus.st_dev == directoryStatus.st_dev,
        pathStatus.st_ino == directoryStatus.st_ino else {
        Darwin.close(fd)
        Darwin.close(parentFD)
        throw DVIngestError.invalidEvidence("reviewed range destination identity mismatch")
      }
      guard fsync(parentFD) == 0 else {
        let code = errno
        Darwin.close(fd)
        Darwin.close(parentFD)
        throw DVIngestError.fileOperation("synchronize reviewed range destination parent", code)
      }
      return DestinationDirectory(fd: fd, parentFD: parentFD)
    }

    init(fd: Int32, parentFD: Int32) {
      self.fd = fd
      self.parentFD = parentFD
    }

    func close() {
      if !closed {
        Darwin.close(fd)
        Darwin.close(parentFD)
        closed = true
      }
    }

    func makeExclusiveWriter(named name: String) throws -> FileHandle {
      let child = openat(
        fd, name, O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard child >= 0 else {
        throw DVIngestError.fileOperation("create exclusive reviewed range file", errno)
      }
      return FileHandle(fileDescriptor: child, closeOnDealloc: true)
    }

    func writeExclusive(named name: String, data: Data, synchronize: Bool) throws {
      let writer = try makeExclusiveWriter(named: name)
      defer { try? writer.close() }
      try writer.write(contentsOf: data)
      if synchronize { try writer.synchronize() }
      try writer.close()
    }

    func hashRegularFile(named name: String) throws -> (bytes: UInt64, sha256: String) {
      let child = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else { throw DVIngestError.fileOperation("open reviewed range reread", errno) }
      defer { Darwin.close(child) }
      var status = stat()
      guard fstat(child, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        throw DVIngestError.invalidEvidence("reviewed range output is not a regular file")
      }
      var hash = SHA256()
      var count: UInt64 = 0
      while true {
        try Task.checkCancellation()
        var buffer = Data(count: 1_048_576)
        let amount: Int = try buffer.withUnsafeMutableBytes { bytes in
          let value = Darwin.read(child, bytes.baseAddress!, bytes.count)
          if value < 0 { throw DVIngestError.fileOperation("reread reviewed range output", errno) }
          return value
        }
        if amount == 0 { break }
        buffer.removeSubrange(amount..<buffer.count)
        hash.update(data: buffer)
        count = try added(count, UInt64(amount), "output reread byte count")
      }
      var finalStatus = stat()
      var pathStatus = stat()
      guard fstat(child, &finalStatus) == 0,
        fstatat(fd, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw DVIngestError.fileOperation("reinspect reviewed range output", errno)
      }
      guard status.st_size >= 0,
        UInt64(status.st_size) == count,
        finalStatus.st_dev == status.st_dev,
        finalStatus.st_ino == status.st_ino,
        finalStatus.st_size == status.st_size,
        finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
        finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
        finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
        finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec,
        pathStatus.st_mode & S_IFMT == S_IFREG,
        pathStatus.st_dev == status.st_dev,
        pathStatus.st_ino == status.st_ino else {
        throw DVIngestError.invalidEvidence("reviewed range output identity or size changed during reread")
      }
      return (count, hex(hash.finalize()))
    }

    func promoteExclusive(
      from: String, to: String, expectedBytes: UInt64, expectedSHA256: String
    ) throws {
      try DVPortablePublication.promoteExclusive(
        directoryFD: fd, from: from, to: to,
        expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
    }

    func synchronize() throws {
      guard fsync(fd) == 0 else {
        throw DVIngestError.fileOperation("synchronize reviewed range directory", errno)
      }
    }

    func withdrawCompletionMarkerBestEffort(from: String, to: String) {
      DVPortablePublication.withdrawCompletionMarkerBestEffort(
        directoryFD: fd, from: from, to: to)
    }
  }

  private static func multiplied(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func added(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}
