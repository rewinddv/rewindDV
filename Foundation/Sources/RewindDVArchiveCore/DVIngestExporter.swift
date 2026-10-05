// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Software integrity evidence only. Zero reported defects cannot establish
/// wire continuity or prove that the source recording contains pristine media.
public struct DVIngestVerification: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let completeDVFrames: UInt64
  public let dvBytes: UInt64
  public let rawRecordCount: UInt64
  public let rawRecordBytes: UInt64
  public let rawRecordSHA256: String
  public let nativeDVSHA256: String?
  public let journalSHA256: String
  public let frameManifestSHA256: String
  public let frameManifestBytes: UInt64
  public let hostRingDrops: UInt64
  public let oversizedPackets: UInt64
  public let knownDroppedPackets: UInt64
  public let CIPDiscontinuities: UInt64
  public let rejectedPackets: UInt64
  public let incompleteFrames: UInt64
  public let finalAcknowledgementConfirmed: Bool
  public let legacyStoppedSnapshotUsed: Bool
  public let rawTransportGapEvents: UInt64
  public let integritySHA256Verified: Bool
  public let nativeDVRereadVerified: Bool
  public let hardwareContinuity: String
  public let exactLostFrameCount: UInt64?
  public let sourceMediaDamage: String
  public let captureFile: String?
  public let frameManifestFile: String
  public let verificationFile: String
  public let finalStatusWireBase64: String
  // Optional for backwards-compatible reading of earlier verification records.
  public var dbcDiscontinuitiesAfterEmptyPackets: UInt64? = nil
  public var dbcDiscontinuitiesDiscardingPartialFrames: UInt64? = nil
  public var terminalPartialFrames: UInt64? = nil

  /// A verified reset segment is still an interrupted acquisition.
  public var busResetTerminated: Bool {
    guard let bytes = Data(base64Encoded: finalStatusWireBase64), bytes.count == 128 else { return false }
    return bytes[80..<84].elementsEqual([3, 0, 0, 0])
  }
  public var needsLossReview: Bool {
    busResetTerminated || captureFile == nil || knownDroppedPackets > 0 || incompleteFrames > 0 ||
      CIPDiscontinuities > 0 || rejectedPackets > 0 || rawTransportGapEvents > 0 ||
      !integritySHA256Verified || !nativeDVRereadVerified
  }
  public var completionHeadline: String {
    if !integritySHA256Verified || (captureFile != nil && !nativeDVRereadVerified) {
      return "Capture needs attention — file verification incomplete"
    }
    if captureFile == nil { return "Verification complete — no complete DV frames" }
    return needsLossReview ? "Saved bytes verified — capture needs review" : "Capture complete — saved bytes verified"
  }

  /// Context only. Does not relax review or infer that boundary events are harmless.
  public var completionContext: String {
    var parts: [String] = []
    if let terminal = terminalPartialFrames, terminal <= incompleteFrames {
      parts.append("\(incompleteFrames - terminal) incomplete frames before receive ended; \(terminal) partial frames at receive end.")
    } else {
      parts.append("\(incompleteFrames) incomplete frames; receive-end detail unavailable.")
    }
    if let afterEmpty = dbcDiscontinuitiesAfterEmptyPackets,
      let discarded = dbcDiscontinuitiesDiscardingPartialFrames,
      afterEmpty <= CIPDiscontinuities, discarded <= CIPDiscontinuities {
      parts.append("\(afterEmpty) of \(CIPDiscontinuities) counter changes followed empty packets; \(discarded) discarded a partial frame.")
    } else {
      parts.append("\(CIPDiscontinuities) counter changes; context unavailable.")
    }
    parts.append("Transport transitions can produce these events; cause and exact loss remain unverified.")
    return parts.joined(separator: " ")
  }
}

public enum DVIngestError: Error, LocalizedError, Sendable {
  case invalidEvidence(String)
  case destinationExists(String)
  case fileOperation(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidEvidence(let reason): "DV ingest refused: \(reason)"
    case .destinationExists(let path): "DV ingest destination already exists: \(path)"
    case .fileOperation(let operation, let code): "DV ingest \(operation) failed (errno \(code))"
    }
  }
}

public enum DVIngestProgressPhase: String, Codable, Sendable {
  case validatingEvidence
  case reconstructingNativeDV
  case rereadingNativeDV
  case rereadingRawEvidence
  case rereadingFrameManifest
  case publishingVerifiedFiles
  case complete
}

/// Measured byte progress from the offline exporter. Estimated work is used
/// only during reconstruction; once frame sizes are known the denominator is
/// replaced by exact reread work. It is presentation evidence, never an
/// integrity result or permission to publish incomplete output.
public struct DVIngestProgress: Equatable, Sendable {
  public let phase: DVIngestProgressPhase
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let overallCompletedBytes: UInt64
  public let overallTotalBytes: UInt64

  public init(
    phase: DVIngestProgressPhase, completedBytes: UInt64, totalBytes: UInt64,
    overallCompletedBytes: UInt64, overallTotalBytes: UInt64
  ) {
    self.phase = phase
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
    self.overallCompletedBytes = overallCompletedBytes
    self.overallTotalBytes = overallTotalBytes
  }

  public var fractionCompleted: Double? {
    guard overallTotalBytes > 0 else { return nil }
    return min(1, Double(overallCompletedBytes) / Double(overallTotalBytes))
  }
}

/// Converts a closed raw flight in bounded memory. The journal binds compact
/// record bytes EXCLUDING the eight-byte RDRXLOG1 magic. ABI offsets mirror
/// Foundation/DriverPolicy/FoundationReceiveWire.hpp and RawSink's counters.
/// Final verification.json is the completion marker; failures retain partial
/// evidence, and neither source captures nor existing destinations are replaced.
public enum DVIngestExporter {
  /// Legacy compatibility is an explicit offline forensic option. App capture
  /// finalization must retain the default, which requires one bound final status.
  public static func exportClosedFlight(
    at directory: URL, allowLegacyStoppedSnapshot: Bool = false, allowBusResetSegment: Bool = false,
    progress: (@Sendable (DVIngestProgress) -> Void)? = nil
  ) throws -> DVIngestVerification {
    let names = ["capture.dv", "frames.ndjson", "verification.json"]
    for name in names.flatMap({ [$0, $0 + ".partial"] }) {
      var info = stat()
      let path = directory.appendingPathComponent(name).path
      if lstat(path, &info) == 0 { throw DVIngestError.destinationExists(path) }
      guard errno == ENOENT else { throw DVIngestError.fileOperation("inspect destination", errno) }
    }
    let journalURL = directory.appendingPathComponent("flight.ndjson")
    progress?(DVIngestProgress(phase: .validatingEvidence, completedBytes: 0, totalBytes: 0,
      overallCompletedBytes: 0, overallTotalBytes: 0))
    let journal = try readJournal(journalURL, allowLegacyStoppedSnapshot: allowLegacyStoppedSnapshot, allowBusResetSegment: allowBusResetSegment)
    let terminal = journal.status
    let rawURL = directory.appendingPathComponent("receive.records.raw")
    let source = try regularReader(rawURL)
    defer { try? source.close() }
    let reader = RecordReader(source)
    guard try reader.readExactly(8) == Data("RDRXLOG1".utf8) else {
      throw DVIngestError.invalidEvidence("raw file magic mismatch")
    }
    let frameURL = directory.appendingPathComponent("frames.ndjson.partial")
    let frameWriter = try exclusiveWriter(frameURL)
    defer { try? frameWriter.close() }
    var dvWriter: FileHandle?
    defer { try? dvWriter?.close() }
    var assembler = DVDIFPacketAssembler()
    var records: UInt64 = 0, recordBytes: UInt64 = 0, frameCount: UInt64 = 0, dvBytes: UInt64 = 0
    var lastObserved: UInt64 = 0, lastLoss: UInt64 = 0
    var transportGapEvents: UInt64 = 0
    var intervalStart: UInt64 = 1, intervalOffset: UInt64 = 8
    var rawHash = SHA256(), dvHash = SHA256(), frameManifestHash = SHA256()
    var frameManifestBytes: UInt64 = 0
    let estimatedWork = journal.closed.recordBytes.multipliedReportingOverflow(by: 3)
    let estimatedOverall = estimatedWork.overflow ? UInt64.max : estimatedWork.partialValue
    var lastReconstructionProgress: UInt64 = 0
    progress?(DVIngestProgress(phase: .reconstructingNativeDV, completedBytes: 0,
      totalBytes: journal.closed.recordBytes, overallCompletedBytes: 0,
      overallTotalBytes: estimatedOverall))
    var legacyPrefixVerified = journal.legacyPrefix == nil
    if let prefix = journal.legacyPrefix, prefix.recordBytes == 0 {
      guard prefix.recordSHA256 == hex(SHA256.hash(data: Data())) else {
        throw DVIngestError.invalidEvidence("legacy stop event empty-prefix hash mismatch")
      }
      legacyPrefixVerified = true
    }
    // Drain read, assembly and metadata temporaries per record; retain only streaming state.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let header = try reader.readExactly(64) else { return false }
        let sequence = integer(header, 0, UInt64.self)
        let epoch = integer(header, 8, UInt64.self)
        let payloadCount = integer(header, 36, UInt32.self)
        let observed = integer(header, 40, UInt64.self)
        let loss = integer(header, 48, UInt64.self)
        guard records < UInt64.max, sequence == records + 1, epoch == terminal.epoch,
          payloadCount <= 4096, integer(header, 56, UInt32.self) == 1,
          integer(header, 60, UInt32.self) == 0,
          observed > lastObserved, loss >= lastLoss,
          observed >= sequence, observed - sequence == loss,
          sequence <= terminal.write, loss <= terminal.drops
        else { throw DVIngestError.invalidEvidence("record sequence, epoch, loss or header guard failed") }
        let payload = payloadCount == 0 ? Data() : try reader.readExactly(Int(payloadCount))
        guard let payload else { throw DVIngestError.invalidEvidence("missing record payload") }
        rawHash.update(data: header)
        rawHash.update(data: payload)
        let recordOffset = 8 + recordBytes
        recordBytes += UInt64(64 + payload.count)
        if let prefix = journal.legacyPrefix, !legacyPrefixVerified,
          recordBytes >= prefix.recordBytes {
          guard recordBytes == prefix.recordBytes,
            hex(rawHash.finalize()) == prefix.recordSHA256 else {
            throw DVIngestError.invalidEvidence("legacy stop event prefix boundary or hash mismatch")
          }
          legacyPrefixVerified = true
        }
        records = sequence
        if recordBytes - lastReconstructionProgress >= 1_048_576 {
          lastReconstructionProgress = recordBytes
          progress?(DVIngestProgress(phase: .reconstructingNativeDV,
            completedBytes: min(recordBytes, journal.closed.recordBytes),
            totalBytes: journal.closed.recordBytes,
            overallCompletedBytes: min(recordBytes, estimatedOverall),
            overallTotalBytes: estimatedOverall))
        }
        if loss != lastLoss { assembler.markTransportGap(); transportGapEvents += 1 }
        lastObserved = observed
        lastLoss = loss
        let frames = assembler.consumePreservedPacket(payload,
          transferStatus: integer(header, 32, UInt16.self), expectedSourceNode: terminal.node)
        for frame in frames {
          guard frame.count == 120_000 || frame.count == 144_000 else {
            throw DVIngestError.invalidEvidence("assembler returned a non-DV25 frame")
          }
          if dvWriter == nil {
            dvWriter = try exclusiveWriter(directory.appendingPathComponent("capture.dv.partial"))
          }
          let metadata = DVCaptureMetadataEpochAnalyzer.analyze(data: frame)
          guard metadata.completeFrameCount == 1, let observation = metadata.frames.first else {
            throw DVIngestError.invalidEvidence("complete frame failed independent DIF structure analysis")
          }
          // Per-frame analysis bounds metadata memory regardless of capture length.
          // Pack offsets are relative to this frame, explicitly recorded below.
          let entry = FrameEntry(frameOrdinal: frameCount, fileByteOffset: dvBytes,
            byteCount: UInt64(frame.count), SHA256: hex(SHA256.hash(data: frame)),
            firstRecordSequence: intervalStart, lastRecordSequence: sequence,
            rawIntervalStartByteOffset: intervalOffset,
            rawIntervalEndByteOffsetExclusive: 8 + recordBytes,
            receiveEpoch: terminal.epoch, routeWireBase64: terminal.route.base64EncodedString(),
            sourceMetadata: observation)
          try dvWriter!.write(contentsOf: frame)
          dvHash.update(data: frame)
          let frameManifestLine = try encode(entry) + Data([10])
          try frameWriter.write(contentsOf: frameManifestLine)
          frameManifestHash.update(data: frameManifestLine)
          frameManifestBytes += UInt64(frameManifestLine.count)
          frameCount += 1
          dvBytes += UInt64(frame.count)
          // A packet may contain the end of this frame and the next frame's start.
          intervalStart = sequence
          intervalOffset = recordOffset
        }
        return true
      }
      if !processed { break }
    }
    if terminal.drops > lastLoss { assembler.markTransportGap(); transportGapEvents += 1 }
    assembler.finish()
    let sourceSHA = hex(rawHash.finalize())
    guard legacyPrefixVerified, records == terminal.write, recordBytes == journal.closed.recordBytes,
      sourceSHA == journal.closed.recordSHA256,
      terminal.seen >= lastObserved, terminal.drops >= lastLoss
    else { throw DVIngestError.invalidEvidence("terminal counters or journal raw integrity mismatch") }
    try frameWriter.synchronize()
    try frameWriter.close()
    try dvWriter?.synchronize()
    try dvWriter?.close()
    dvWriter = nil
    let finalRecordBytes = recordBytes
    let finalDVBytes = dvBytes
    let finalFrameManifestBytes = frameManifestBytes
    let nativeSHA = frameCount == 0 ? nil : hex(dvHash.finalize())
    let exactTotal = safeProgressTotal(finalRecordBytes, finalRecordBytes,
      finalDVBytes, finalFrameManifestBytes)
    if let nativeSHA {
      progress?(DVIngestProgress(phase: .rereadingNativeDV, completedBytes: 0,
        totalBytes: finalDVBytes, overallCompletedBytes: finalRecordBytes, overallTotalBytes: exactTotal))
      let reread = try hashFile(directory.appendingPathComponent("capture.dv.partial")) { count in
        progress?(DVIngestProgress(phase: .rereadingNativeDV, completedBytes: count,
          totalBytes: finalDVBytes, overallCompletedBytes: safeProgressTotal(finalRecordBytes, count),
          overallTotalBytes: exactTotal))
      }
      guard reread.bytes == dvBytes, reread.sha == nativeSHA else {
        throw DVIngestError.invalidEvidence("native DV reread mismatch")
      }
    }
    let afterNative = safeProgressTotal(finalRecordBytes, finalDVBytes)
    progress?(DVIngestProgress(phase: .rereadingRawEvidence, completedBytes: 0,
      totalBytes: finalRecordBytes, overallCompletedBytes: afterNative, overallTotalBytes: exactTotal))
    let rawReread = try hashFile(rawURL, skipMagic: true) { count in
      progress?(DVIngestProgress(phase: .rereadingRawEvidence, completedBytes: count,
        totalBytes: finalRecordBytes, overallCompletedBytes: safeProgressTotal(afterNative, count),
        overallTotalBytes: exactTotal))
    }
    let journalReread = try hashFile(journalURL)
    let frameManifestSHA = hex(frameManifestHash.finalize())
    let beforeManifest = safeProgressTotal(afterNative, finalRecordBytes)
    progress?(DVIngestProgress(phase: .rereadingFrameManifest, completedBytes: 0,
      totalBytes: finalFrameManifestBytes, overallCompletedBytes: beforeManifest,
      overallTotalBytes: exactTotal))
    let frameManifestReread = try hashFile(frameURL) { count in
      progress?(DVIngestProgress(phase: .rereadingFrameManifest, completedBytes: count,
        totalBytes: finalFrameManifestBytes, overallCompletedBytes: safeProgressTotal(beforeManifest, count),
        overallTotalBytes: exactTotal))
    }
    guard frameManifestReread.bytes == frameManifestBytes,
      frameManifestReread.sha == frameManifestSHA else {
      throw DVIngestError.invalidEvidence("frame manifest reread mismatch")
    }
    guard rawReread.bytes == recordBytes, rawReread.sha == sourceSHA,
      journalReread.sha == journal.sha else {
      throw DVIngestError.invalidEvidence("source changed during export")
    }
    var result = DVIngestVerification(schemaVersion: 1, completeDVFrames: frameCount,
      dvBytes: dvBytes, rawRecordCount: records, rawRecordBytes: recordBytes,
      rawRecordSHA256: sourceSHA, nativeDVSHA256: nativeSHA, journalSHA256: journal.sha,
      frameManifestSHA256: frameManifestSHA, frameManifestBytes: frameManifestBytes,
      hostRingDrops: terminal.drops - terminal.oversized, oversizedPackets: terminal.oversized,
      knownDroppedPackets: terminal.drops,
      CIPDiscontinuities: assembler.discontinuities - transportGapEvents,
      rejectedPackets: assembler.rejectedPackets, incompleteFrames: assembler.incompleteFrames,
      finalAcknowledgementConfirmed: journal.finalStatusBound && terminal.acknowledged == terminal.write,
      legacyStoppedSnapshotUsed: !journal.finalStatusBound,
      rawTransportGapEvents: transportGapEvents,
      integritySHA256Verified: true, nativeDVRereadVerified: nativeSHA != nil,
      hardwareContinuity: "unknown", exactLostFrameCount: nil,
      sourceMediaDamage: "unknown; complete DIF structure does not prove pristine video or audio; original DIF bytes preserved",
      captureFile: nativeSHA == nil ? nil : "capture.dv", frameManifestFile: "frames.ndjson",
      verificationFile: "verification.json", finalStatusWireBase64: terminal.wire.base64EncodedString())
    result.dbcDiscontinuitiesAfterEmptyPackets = assembler.dbcDiscontinuitiesAfterEmptyPackets
    result.dbcDiscontinuitiesDiscardingPartialFrames = assembler.dbcDiscontinuitiesDiscardingPartialFrames
    result.terminalPartialFrames = assembler.terminalPartialFrames
    let verificationBytes = try encode(result) + Data([10])
    let verificationWriter = try exclusiveWriter(directory.appendingPathComponent("verification.json.partial"))
    defer { try? verificationWriter.close() }
    try verificationWriter.write(contentsOf: verificationBytes)
    try verificationWriter.synchronize()
    try verificationWriter.close()
    progress?(DVIngestProgress(phase: .publishingVerifiedFiles,
      completedBytes: 0, totalBytes: 0,
      overallCompletedBytes: exactTotal > 0 ? exactTotal - 1 : 0,
      overallTotalBytes: exactTotal))
    try publishVerifiedOutputs(hasNativeDV: nativeSHA != nil,
      promote: { name in
        switch name {
        case "capture.dv":
          try promote(name, in: directory, expectedBytes: dvBytes, expectedSHA256: nativeSHA!)
        case "frames.ndjson":
          try promote(name, in: directory, expectedBytes: frameManifestBytes,
            expectedSHA256: frameManifestSHA)
        case "verification.json":
          try promote(name, in: directory, expectedBytes: UInt64(verificationBytes.count),
            expectedSHA256: hex(SHA256.hash(data: verificationBytes)))
        default:
          throw DVIngestError.invalidEvidence("unexpected publication name")
        }
      },
      syncDirectory: { try synchronizeDirectory(directory) },
      withdrawMarker: { withdrawCompletionMarker(in: directory) })
    progress?(DVIngestProgress(phase: .complete, completedBytes: exactTotal,
      totalBytes: exactTotal, overallCompletedBytes: exactTotal,
      overallTotalBytes: exactTotal))
    return result
  }

  /// Completes an interrupted publication without reconstructing or replacing
  /// the raw flight. Every retained partial and its source evidence is reread
  /// and hash-bound before a final name is exposed. Existing final files are
  /// accepted only when they exactly match the verification report.
  public static func resumeVerifiedPublication(at directory: URL) throws -> DVIngestVerification {
    let partialVerification = directory.appendingPathComponent("verification.json.partial")
    let finalVerification = directory.appendingPathComponent("verification.json")
    let partialExists = pathExists(partialVerification)
    let finalExists = pathExists(finalVerification)
    guard partialExists || finalExists else {
      throw DVIngestError.invalidEvidence("no verification report is available to resume publication")
    }
    let partialBytes = partialExists ? try boundedRegularData(partialVerification) : nil
    let finalBytes = finalExists ? try boundedRegularData(finalVerification) : nil
    if let partialBytes, let finalBytes, partialBytes != finalBytes {
      throw DVIngestError.invalidEvidence("final and partial verification reports conflict")
    }
    let verificationBytes = finalBytes ?? partialBytes!
    let result: DVIngestVerification
    do { result = try JSONDecoder().decode(DVIngestVerification.self, from: verificationBytes) }
    catch { throw DVIngestError.invalidEvidence("verification report JSON is invalid") }
    guard result.schemaVersion == 1,
      result.frameManifestFile == "frames.ndjson",
      result.verificationFile == "verification.json",
      result.integritySHA256Verified,
      result.knownDroppedPackets >= result.oversizedPackets,
      result.hostRingDrops == result.knownDroppedPackets - result.oversizedPackets,
      isSHA256(result.rawRecordSHA256), isSHA256(result.journalSHA256),
      isSHA256(result.frameManifestSHA256),
      Data(base64Encoded: result.finalStatusWireBase64)?.count == 128 else {
      throw DVIngestError.invalidEvidence("verification report fields are invalid")
    }
    if result.captureFile == nil {
      guard result.nativeDVSHA256 == nil, result.dvBytes == 0,
        !pathExists(directory.appendingPathComponent("capture.dv")),
        !pathExists(directory.appendingPathComponent("capture.dv.partial")) else {
        throw DVIngestError.invalidEvidence("verification report and native DV outputs conflict")
      }
    } else {
      guard result.captureFile == "capture.dv", let nativeSHA = result.nativeDVSHA256,
        isSHA256(nativeSHA), result.nativeDVRereadVerified else {
        throw DVIngestError.invalidEvidence("native DV verification fields are invalid")
      }
    }
    let raw = try hashFile(directory.appendingPathComponent("receive.records.raw"), skipMagic: true)
    let journal = try hashFile(directory.appendingPathComponent("flight.ndjson"))
    guard raw.bytes == result.rawRecordBytes, raw.sha == result.rawRecordSHA256,
      journal.sha == result.journalSHA256 else {
      throw DVIngestError.invalidEvidence("raw flight or journal changed before resumed publication")
    }

    func publishOrVerify(_ name: String, bytes: UInt64, sha: String) throws {
      let partial = directory.appendingPathComponent(name + ".partial")
      let final = directory.appendingPathComponent(name)
      if pathExists(final) {
        let existing = try hashFile(final)
        guard existing.bytes == bytes, existing.sha == sha else {
          throw DVIngestError.invalidEvidence("existing final \(name) conflicts with verified evidence")
        }
        if pathExists(partial) {
          let retained = try hashFile(partial)
          guard retained.bytes == bytes, retained.sha == sha else {
            throw DVIngestError.invalidEvidence("final and partial \(name) conflict")
          }
          guard unlink(partial.path) == 0 else {
            throw DVIngestError.fileOperation("remove duplicate verified partial \(name)", errno)
          }
        }
        return
      }
      let retained = try hashFile(partial)
      guard retained.bytes == bytes, retained.sha == sha else {
        throw DVIngestError.invalidEvidence("partial \(name) does not match verified evidence")
      }
      try promote(name, in: directory, expectedBytes: bytes, expectedSHA256: sha)
    }

    try publishVerifiedOutputs(hasNativeDV: result.captureFile != nil,
      promote: { name in
        switch name {
        case "capture.dv":
          try publishOrVerify(name, bytes: result.dvBytes, sha: result.nativeDVSHA256!)
        case "frames.ndjson":
          try publishOrVerify(name, bytes: result.frameManifestBytes,
            sha: result.frameManifestSHA256)
        case "verification.json":
          try publishOrVerify(name, bytes: UInt64(verificationBytes.count),
            sha: hex(SHA256.hash(data: verificationBytes)))
        default:
          throw DVIngestError.invalidEvidence("unexpected resumed publication name")
        }
      }, syncDirectory: { try synchronizeDirectory(directory) },
      withdrawMarker: { withdrawCompletionMarker(in: directory) })
    return result
  }

  /// The payload names must become durable before the completion marker can be
  /// visible. Kept as one ordering boundary so failure injection can prove that
  /// a failed first directory barrier prevents publication of the marker.
  static func publishVerifiedOutputs(
    hasNativeDV: Bool, promote: (String) throws -> Void, syncDirectory: () throws -> Void,
    withdrawMarker: () -> Void
  ) throws {
    if hasNativeDV { try promote("capture.dv") }
    try promote("frames.ndjson")
    try syncDirectory()
    try promote("verification.json")
    do { try syncDirectory() }
    catch { withdrawMarker(); throw error }
  }

  static func withdrawCompletionMarker(in directory: URL) {
    let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }
    DVPortablePublication.withdrawCompletionMarkerBestEffort(directoryFD: fd,
      from: "verification.json", to: "verification.json.partial")
  }

  private static func synchronizeDirectory(_ directory: URL) throws {
    let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryFD >= 0 else { throw DVIngestError.fileOperation("open directory", errno) }
    defer { Darwin.close(directoryFD) }
    guard fsync(directoryFD) == 0 else { throw DVIngestError.fileOperation("sync directory", errno) }
  }

  private struct FrameEntry: Encodable {
    let schemaVersion = 1
    let frameOrdinal: UInt64
    let fileByteOffset: UInt64
    let byteCount: UInt64
    let SHA256: String
    let firstRecordSequence: UInt64
    let lastRecordSequence: UInt64
    let rawIntervalStartByteOffset: UInt64
    let rawIntervalEndByteOffsetExclusive: UInt64
    let provenanceInterval = "inclusive conservative record range; may include rejected or earlier frame bytes; boundary record may be shared"
    let receiveEpoch: UInt64
    let routeWireBase64: String
    let metadataCoordinates = "sourceMetadata offsets and ordinal are relative to this frame; add fileByteOffset for capture.dv coordinates"
    let sourceMetadata: DVFrameCaptureMetadata
  }

  private struct Event: Decodable {
    let schemaVersion: Int
    let event: String
    let wireBase64: String
    let recordBytes: UInt64
    let recordSHA256: String
  }

  private struct Terminal {
    let wire: Data
    let route: Data
    let epoch: UInt64
    let node: UInt8
    let write: UInt64
    let seen: UInt64
    let drops: UInt64
    let oversized: UInt64
    let acknowledged: UInt64

    init(_ bytes: Data, allowBusResetSegment: Bool = false) throws {
      guard bytes.count == 128, integer(bytes, 0, UInt32.self) == 0x58524452,
        integer(bytes, 4, UInt16.self) == 1, integer(bytes, 6, UInt16.self) == 256,
        integer(bytes, 8, UInt32.self) == 4160,
        [UInt32(8192), 65536].contains(integer(bytes, 12, UInt32.self)),
        integer(bytes, 24, UInt32.self) == 1, integer(bytes, 28, UInt32.self) == 48,
        [16, 32, 40, 48, 56].allSatisfy({ integer(bytes, $0, UInt64.self) != 0 }),
        integer(bytes, 70, UInt16.self) == 0, bytes[68] & 0x3f < 63,
        [UInt32(2), allowBusResetSegment ? 3 : 2].contains(integer(bytes, 80, UInt32.self)), integer(bytes, 84, UInt32.self) == 0
      else { throw DVIngestError.invalidEvidence("missing clean stopped status or receive ABI/route mismatch") }
      wire = bytes
      route = bytes.subdata(in: 24..<72)
      epoch = integer(bytes, 16, UInt64.self)
      node = bytes[68] & 0x3f
      write = integer(bytes, 88, UInt64.self)
      seen = integer(bytes, 96, UInt64.self)
      drops = integer(bytes, 104, UInt64.self)
      oversized = integer(bytes, 112, UInt64.self)
      acknowledged = integer(bytes, 120, UInt64.self)
      guard seen >= write, seen - write == drops, drops >= oversized,
        acknowledged <= write else {
        throw DVIngestError.invalidEvidence("terminal receive counters do not reconcile")
      }
    }
  }

  private static func readJournal(
    _ url: URL, allowLegacyStoppedSnapshot: Bool, allowBusResetSegment: Bool
  ) throws -> (closed: Event, status: Terminal, sha: String, finalStatusBound: Bool, legacyPrefix: Event?) {
    let handle = try regularReader(url)
    defer { try? handle.close() }
    var buffer = Data(), hash = SHA256()
    var closed: Event?, legacyEvent: Event?, intentRoute: Data?, finalEvent: Event?
    var duplicateLegacyStop = false
    var finalWire: Data?
    // The read and all line/JSON work belong to the same bounded cleanup scope.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { return false }
        hash.update(data: chunk)
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
          guard closed == nil else { throw DVIngestError.invalidEvidence("journal events follow receive_closed") }
          let line = Data(buffer[..<newline])
          buffer = Data(buffer[buffer.index(after: newline)...])
          guard line.count <= 1_048_576 else { throw DVIngestError.invalidEvidence("oversized journal event") }
          let event = try JSONDecoder().decode(Event.self, from: line)
          guard event.schemaVersion == 1, let wire = Data(base64Encoded: event.wireBase64) else {
            throw DVIngestError.invalidEvidence("journal schema or base64 mismatch")
          }
          guard finalEvent == nil || event.event == "receive_closed" else {
            throw DVIngestError.invalidEvidence("duplicate final status or intervening event after final status")
          }
          if event.event == "receive_start_intent" { intentRoute = wire }
          if event.event == "receive_stop_returned" {
            if legacyEvent != nil { duplicateLegacyStop = true }
            legacyEvent = event
          }
          if event.event == "receive_final_status" {
            guard wire.count == 128 else {
              throw DVIngestError.invalidEvidence("final status wire must contain exactly 128 bytes")
            }
            finalEvent = event
            finalWire = wire
          }
          if event.event == "receive_closed" { closed = event }
        }
        guard buffer.count <= 1_048_576 else { throw DVIngestError.invalidEvidence("oversized journal event") }
        return true
      }
      if !processed { break }
    }
    guard buffer.isEmpty, let closed else {
      throw DVIngestError.invalidEvidence("missing terminal event/status or truncated journal")
    }
    guard finalEvent != nil || allowLegacyStoppedSnapshot else {
      throw DVIngestError.invalidEvidence("missing receive_final_status; legacy forensic compatibility was not explicitly enabled")
    }
    let statusWire: Data
    if let finalEvent {
      guard finalEvent.recordBytes == closed.recordBytes,
        finalEvent.recordSHA256 == closed.recordSHA256,
        closed.wireBase64.isEmpty || closed.wireBase64 == finalEvent.wireBase64 else {
        throw DVIngestError.invalidEvidence("receive_closed does not bind the declared final status evidence")
      }
      statusWire = finalWire!
    } else {
      guard !duplicateLegacyStop, let legacyEvent,
        let legacyWire = Data(base64Encoded: legacyEvent.wireBase64), legacyWire.count == 128,
        legacyEvent.recordBytes <= closed.recordBytes else {
        throw DVIngestError.invalidEvidence("legacy export requires one receive_stop_returned with a bounded raw prefix")
      }
      statusWire = legacyWire
    }
    let status = try Terminal(statusWire, allowBusResetSegment: allowBusResetSegment && finalEvent != nil)
    guard finalEvent == nil || status.acknowledged == status.write else {
      throw DVIngestError.invalidEvidence("final acknowledgement does not reach final publication")
    }
    guard let intentRoute, intentRoute == status.route else {
      throw DVIngestError.invalidEvidence("terminal route does not match receive start intent")
    }
    return (closed, status, hex(hash.finalize()), finalEvent != nil,
      finalEvent == nil ? legacyEvent : nil)
  }

  private static func regularReader(_ url: URL) throws -> FileHandle {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open source", errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(fd)
      throw DVIngestError.invalidEvidence("source is not a regular file")
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  private static func exclusiveWriter(_ url: URL) throws -> FileHandle {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DVIngestError.fileOperation("create exclusive partial file", errno) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  /// Amortize disk reads without retaining a capture-sized packet collection.
  private final class RecordReader {
    let handle: FileHandle
    var buffer = Data()
    var cursor = 0
    init(_ handle: FileHandle) { self.handle = handle }
    func readExactly(_ count: Int) throws -> Data? {
      var result = Data()
      result.reserveCapacity(count)
      while result.count < count {
        if cursor == buffer.count {
          // The owned Data survives this scope; autoreleased read temporaries do not.
          buffer = try autoreleasepool { try handle.read(upToCount: 1_048_576) ?? Data() }
          cursor = 0
          if buffer.isEmpty {
            if result.isEmpty { return nil }
            throw DVIngestError.invalidEvidence("truncated raw record")
          }
        }
        let amount = min(count - result.count, buffer.count - cursor)
        result.append(buffer[cursor..<(cursor + amount)])
        cursor += amount
      }
      return result
    }
  }

  private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
    // Callers request bounded magic/report data, never a capture-sized result.
    return try autoreleasepool {
      var result = Data()
      while result.count < count {
        let chunk = try handle.read(upToCount: count - result.count) ?? Data()
        if chunk.isEmpty {
          if result.isEmpty { return nil }
          throw DVIngestError.invalidEvidence("truncated raw record")
        }
        result.append(chunk)
      }
      return result
    }
  }

  private static func safeProgressTotal(_ values: UInt64...) -> UInt64 {
    values.reduce(0) { partial, value in
      let sum = partial.addingReportingOverflow(value)
      return sum.overflow ? UInt64.max : sum.partialValue
    }
  }

  private static func hashFile(
    _ url: URL, skipMagic: Bool = false,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) throws -> (bytes: UInt64, sha: String) {
    let handle = try regularReader(url)
    defer { try? handle.close() }
    if skipMagic {
      guard try readExactly(handle, count: 8) == Data("RDRXLOG1".utf8) else {
        throw DVIngestError.invalidEvidence("raw magic changed during reread")
      }
    }
    var hash = SHA256(), count: UInt64 = 0
    // Include the read itself, hashing and progress in each synchronous chunk scope.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
        hash.update(data: data)
        count += UInt64(data.count)
        progress?(count)
        return true
      }
      if !processed { break }
    }
    return (count, hex(hash.finalize()))
  }

  static func promote(
    _ name: String, in directory: URL, expectedBytes: UInt64,
    expectedSHA256: String, forcePortableCopy: Bool = false
  ) throws {
    let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw DVIngestError.fileOperation("open publication directory", errno) }
    defer { Darwin.close(directoryFD) }
    try DVPortablePublication.promoteExclusive(
      directoryFD: directoryFD, from: name + ".partial", to: name,
      expectedBytes: expectedBytes, expectedSHA256: expectedSHA256,
      forcePortableCopy: forcePortableCopy)
  }

  private static func pathExists(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    return false
  }

  private static func boundedRegularData(_ url: URL) throws -> Data {
    let handle = try regularReader(url)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0,
      info.st_size >= 0, info.st_size <= 1_048_576 else {
      throw DVIngestError.invalidEvidence("verification report exceeds bounded size")
    }
    guard let data = try readExactly(handle, count: Int(info.st_size)),
      try handle.read(upToCount: 1)?.isEmpty != false else {
      throw DVIngestError.invalidEvidence("verification report changed during bounded read")
    }
    return data
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }

  private static func integer<T: FixedWidthInteger>(_ data: Data, _ offset: Int, _ type: T.Type) -> T {
    data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
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
