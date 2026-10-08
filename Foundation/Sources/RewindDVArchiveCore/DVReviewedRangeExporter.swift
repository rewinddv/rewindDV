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
    public let frameByteCount: Int?
    public let sourceByteCount: UInt64
    public let videoSystem: DVBoundaryEvidence.VideoSystem?
    public var epochs: [DVRecordingEpoch]? = nil
    public var unknownRegions: [DVUnknownSourceRegion]? = nil
    public var interpretationVersion: Int? = nil

    private enum CodingKeys: String, CodingKey {
      case epochs
      case unknownRegions = "unknown_regions"
      case interpretationVersion = "interpretation_version"
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
    public let outputFile: String?
    public let sourceSHA256: String
    public let sourceByteCount: UInt64
    public let sourceFrameCount: UInt64
    public let sourceFrameByteCount: Int?
    public let sourceVideoSystem: DVBoundaryEvidence.VideoSystem?
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

    public var segments: [Segment]? = nil
    public var sourceSnapshot: Snapshot? = nil

    private enum CodingKeys: String, CodingKey {
      case segments
      case sourceSnapshot = "source_snapshot"
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

  public struct Segment: Codable, Equatable, Sendable {
    public let file: String
    public let epochID: String
    public let system: DVBoundaryEvidence.VideoSystem
    public let firstSourceFrame: UInt64
    public let endSourceFrameExclusive: UInt64
    public let sourceByteOffset: UInt64
    public let sourceByteEndExclusive: UInt64
    public let bytes: UInt64
    public let sha256: String
  }

  /// Fully scans a regular DV25 file in frame-sized memory, validates every
  /// frame through ordered DIF structure checks, and independently rereads
  /// the file before returning its identity snapshot.
  public static func inspect(source: URL, preserveUnknownRegions: Bool = false) throws -> Snapshot {
    try Task.checkCancellation()
    let reader = try RegularSource(source)
    defer { reader.close() }
    guard reader.byteCount > 0 else { throw DVIngestError.invalidEvidence("reviewed range source is empty") }
    var epochs: [DVRecordingEpoch] = [], unknown: [DVUnknownSourceRegion] = []
    var offset: UInt64 = 0, ordinal: UInt64 = 0, tick: UInt64 = 0
    while offset < reader.byteCount {
      try Task.checkCancellation()
      do {
        guard reader.byteCount - offset >= 80 else {
          throw DVIngestError.invalidEvidence("incomplete DIF header at byte \(offset)")
        }
        let prefix = try reader.readExactly(80)
        let pal = prefix[3] & 0x80 != 0, size = pal ? 144_000 : 120_000
        guard prefix[0] >> 5 == 0, prefix[1] >> 4 == 0, prefix[2] == 0 else {
          throw DVIngestError.invalidEvidence("unknown DIF boundary at byte \(offset)")
        }
        guard UInt64(size) <= reader.byteCount - offset else {
          throw DVIngestError.invalidEvidence("incomplete \(pal ? "PAL" : "NTSC") DIF frame at byte \(offset)")
        }
        var frame = prefix
        frame.append(try reader.readExactly(size - 80))
        try DVRecordingEpoch.validateFrame(frame, offset: offset)
        let system: DVBoundaryEvidence.VideoSystem = pal ? .pal625_50 : .ntsc525_60
        if epochs.last?.system != system {
          guard epochs.count < 100_000 else { throw DVIngestError.invalidEvidence("epoch inventory exceeds the 100000-transition resource budget") }
          epochs.append(DVRecordingEpoch(first: ordinal, offset: offset, tick: tick, pal: pal))
        }
        ordinal += 1; offset += UInt64(size); tick += pal ? 1200 : 1001
        epochs[epochs.count - 1].endFrameExclusive = ordinal
        epochs[epochs.count - 1].byteEndExclusive = offset
      } catch is CancellationError { throw CancellationError() }
      catch {
        guard preserveUnknownRegions else { throw error }
        unknown.append(DVUnknownSourceRegion(byteOffset: offset, byteEndExclusive: reader.byteCount,
          reason: error.localizedDescription + "; remaining extent unindexed; no resynchronization inferred", frameCount: nil))
        break
      }
    }
    try reader.requireStableAndCurrentPath(source)
    try reader.rewind()
    let first = try reader.hashToEOF()
    try reader.requireStableAndCurrentPath(source)
    try reader.rewind()
    let second = try reader.hashToEOF()
    try reader.requireStableAndCurrentPath(source)
    guard first == second, first.bytes == reader.byteCount else {
      throw DVIngestError.invalidEvidence("reviewed source changed during inspection")
    }
    // Uniform complete sources retain the immutable schema-1 wire contract.
    // Schema 2 omits those global fields entirely rather than overloading them.
    let uniform = epochs.count == 1 && unknown.isEmpty
    var result = Snapshot(schemaVersion: uniform ? 1 : 2, sourceSHA256: first.sha256,
      frameCount: ordinal, frameByteCount: uniform ? epochs[0].frameByteCount : nil,
      sourceByteCount: reader.byteCount, videoSystem: uniform ? epochs[0].system : nil)
    if !uniform { result.epochs = epochs; result.unknownRegions = unknown; result.interpretationVersion = DVIEC61834.interpretationVersion }
    try result.validate()
    return result
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
      schemaVersion: snapshot.schemaVersion,
      state: "incomplete_until_provenance_json_is_published",
      sourceSnapshot: snapshot,
      firstSourceFrameOrdinal: first,
      endSourceFrameOrdinalExclusive: endExclusive,
      intendedOutputFile: "verified uniform selection: reviewed-range.dv; cross-epoch selection: ordered segment-NNNNNN.dv files",
      completionMarker: completionMarkerName)
    try destinationDirectory.writeExclusive(
      named: intentFileName, data: try encode(intent) + Data([10]), synchronize: true)
    try destinationDirectory.synchronize()

    let selectedEpochs = snapshot.recordingEpochs.filter { $0.firstFrame < endExclusive && $0.endFrameExclusive > first }
    let split = selectedEpochs.count > 1
    var segments: [Segment] = []
    var sourceDigest = SHA256(), outputDigest = SHA256(), segmentDigest = SHA256()
    var outputBytes: UInt64 = 0, segmentBytes: UInt64 = 0
    var output: FileHandle?
    defer { try? output?.close() }
    for ordinal in 0..<snapshot.frameCount {
      try Task.checkCancellation()
      let identity = try snapshot.frame(ordinal)
      let frame = try sourceReader.readExactly(identity.byteCount)
      try DVRecordingEpoch.validateFrame(frame, offset: identity.byteOffset)
      sourceDigest.update(data: frame)
      if ordinal >= first && ordinal < endExclusive {
        let epoch = selectedEpochs[segments.count]
        let name = split ? String(format: "segment-%06d.dv", segments.count + 1) : outputFileName
        if output == nil { output = try destinationDirectory.makeExclusiveWriter(named: name + ".partial") }
        try output!.write(contentsOf: frame)
        outputDigest.update(data: frame); segmentDigest.update(data: frame)
        outputBytes += UInt64(frame.count); segmentBytes += UInt64(frame.count)
        let end = min(endExclusive, epoch.endFrameExclusive)
        if ordinal + 1 == end {
          try output!.synchronize(); try output!.close(); output = nil
          let digest = hex(segmentDigest.finalize())
          let reread = try destinationDirectory.hashRegularFile(named: name + ".partial")
          guard reread.bytes == segmentBytes, reread.sha256 == digest else {
            throw DVIngestError.invalidEvidence("lossless segment reread mismatch")
          }
          let start = max(first, epoch.firstFrame)
          segments.append(Segment(file: name, epochID: epoch.id, system: epoch.system,
            firstSourceFrame: start, endSourceFrameExclusive: end,
            sourceByteOffset: try snapshot.byteOffset(atBoundary: start),
            sourceByteEndExclusive: try snapshot.byteOffset(atBoundary: end), bytes: segmentBytes, sha256: digest))
          segmentDigest = SHA256(); segmentBytes = 0
        }
      }
    }
    // Unknown bytes remain part of master identity, even when no ordinal can
    // safely be assigned to them. They are never included in a verified range.
    var remaining = snapshot.sourceByteCount - snapshot.verifiedByteCount
    while remaining > 0 {
      let bytes = try sourceReader.readExactly(Int(min(remaining, 1_048_576)))
      sourceDigest.update(data: bytes); remaining -= UInt64(bytes.count)
    }
    guard try sourceReader.isAtEOF(), hex(sourceDigest.finalize()) == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("reviewed range source no longer matches snapshot")
    }
    try sourceReader.requireStableAndCurrentPath(source)
    try sourceReader.rewind()
    let sourceReread = try sourceReader.hashToEOF()
    try sourceReader.requireStableAndCurrentPath(source)
    guard sourceReread.bytes == snapshot.sourceByteCount, sourceReread.sha256 == snapshot.sourceSHA256 else {
      throw DVIngestError.invalidEvidence("reviewed range source changed during export reread")
    }
    let sourceByteOffset = try snapshot.byteOffset(atBoundary: first)
    let sourceByteEnd = try snapshot.byteOffset(atBoundary: endExclusive)
    guard segments.count == selectedEpochs.count, outputBytes == sourceByteEnd - sourceByteOffset else {
      throw DVIngestError.invalidEvidence("export does not cover exactly the selected frame sequence")
    }
    let expectedOutputSHA = hex(outputDigest.finalize())

    var receipt = Receipt(
      schemaVersion: snapshot.schemaVersion,
      completionState: "complete",
      outputFile: split ? nil : outputFileName,
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
      ordinalMapping: "frame n in the ordered concatenation of output segments maps to source frame first_source_frame_ordinal + n; complete source frame bytes copied unchanged",
      derivativeClassification: "reviewed_range_derivative_not_unmodified_master",
      bytesReencoded: false,
      audioResampled: false,
      timecodeRewritten: false,
      captureQuality: "unknown_not_established_by_raw_dv_scan",
      acquisitionLoss: "unknown_not_established_by_raw_dv_scan",
      archivalQualification: "not_established; this derivative does not replace or qualify an unmodified source master")

    if snapshot.schemaVersion == 2 || split { receipt.segments = segments; receipt.sourceSnapshot = snapshot }

    // This is the final cancellation boundary. Once commit begins, completion
    // is driven to a terminal success or durability error without observing a
    // newly-arriving task cancellation.
    try Task.checkCancellation()
    let markerPartial = completionMarkerName + ".partial"
    let markerBytes = try encode(receipt) + Data([10])
    let markerSHA = hex(SHA256.hash(data: markerBytes))
    try destinationDirectory.writeExclusive(named: markerPartial, data: markerBytes, synchronize: true)
    for segment in segments {
      try destinationDirectory.promoteExclusive(from: segment.file + ".partial", to: segment.file,
        expectedBytes: segment.bytes, expectedSHA256: segment.sha256)
    }
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
    try snapshot.validate()
    guard first < endExclusive, endExclusive <= snapshot.frameCount else {
      throw DVIngestError.invalidEvidence("reviewed range bounds are outside verified source frames")
    }
  }

  static func validateCanonicalOrder(_ frame: Data, sequenceCount: Int) throws {
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

  // Shared by offline byte-preserving exporters.
  final class RegularSource {
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
