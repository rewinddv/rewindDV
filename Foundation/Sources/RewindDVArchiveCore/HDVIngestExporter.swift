// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Offline software-integrity evidence. It does not qualify source-media
/// condition, hardware continuity, or an exact count of packets never observed.
public struct HDVIngestVerification: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let transportPacketCount: UInt64
  public let transportBytes: UInt64
  public let rawRecordCount: UInt64
  public let rawRecordBytes: UInt64
  public let rawRecordSHA256: String
  public let nativeTSSHA256: String?
  public let journalSHA256: String
  public let packetManifestSHA256: String
  public let packetManifestBytes: UInt64
  public let hostRingDrops: UInt64
  public let oversizedPackets: UInt64
  public let knownDroppedPackets: UInt64
  public let rawTransportGapEvents: UInt64
  public let transportSummary: HDVTransportSummary
  public let diagnosticSample: [HDVTransportDiagnostic]
  public let diagnosticSampleTruncated: Bool
  public let finalAcknowledgementConfirmed: Bool
  public let integritySHA256Verified: Bool
  public let nativeTSRereadVerified: Bool
  public let hardwareContinuity: String
  public let exactLostTransportPacketCount: UInt64?
  public let sourceMediaDamage: String
  public let captureFile: String?
  public let packetManifestFile: String
  public let verificationFile: String
  public let finalStatusWireBase64: String

  /// A verified reset segment is still an interrupted acquisition.
  public var busResetTerminated: Bool {
    guard let bytes = Data(base64Encoded: finalStatusWireBase64), bytes.count == 128 else { return false }
    return bytes[80..<84].elementsEqual([3, 0, 0, 0])
  }
  public var needsLossReview: Bool {
    busResetTerminated || captureFile == nil || knownDroppedPackets > 0 || rawTransportGapEvents > 0 ||
      transportSummary.rejectedPreservedPackets > 0 ||
      transportSummary.CIPDBCDiscontinuities > 0 ||
      transportSummary.leadingSourceFragments > 0 ||
      transportSummary.discardedSourceFragments > 0 ||
      transportSummary.transportSyncByteErrors > 0 ||
      transportSummary.transportErrorIndicatorPackets > 0 ||
      transportSummary.transportStructureErrors > 0 ||
      transportSummary.continuityCounterObservations > 0 ||
      !integritySHA256Verified || !nativeTSRereadVerified
  }
}

public enum HDVIngestError: Error, LocalizedError, Sendable {
  case invalidEvidence(String)
  case destinationExists(String)
  case fileOperation(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidEvidence(let reason): "HDV ingest refused: \(reason)"
    case .destinationExists(let path): "HDV ingest destination already exists: \(path)"
    case .fileOperation(let operation, let code): "HDV ingest \(operation) failed (errno \(code))"
    }
  }
}

public enum HDVIngestProgressPhase: String, Codable, Sendable {
  case validatingEvidence
  case reconstructingMPEG2Transport
  case rereadingMPEG2Transport
  case rereadingRawEvidence
  case rereadingPacketManifest
  case publishingVerifiedFiles
  case complete
}

public struct HDVIngestProgress: Equatable, Sendable {
  public let phase: HDVIngestProgressPhase
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let overallCompletedBytes: UInt64
  public let overallTotalBytes: UInt64

  public init(
    phase: HDVIngestProgressPhase, completedBytes: UInt64, totalBytes: UInt64,
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

/// Strict current-schema export of one finalized HDV-only raw receive flight.
/// The source files are opened read-only and never moved or replaced. Output is
/// exclusive-create, reread/hash verified, and the verification marker is
/// published only after the payload files and first directory barrier succeed.
public enum HDVIngestExporter {
  private static let outputName = "capture.m2t"
  private static let manifestName = "hdv-packets.ndjson"
  private static let verificationName = "hdv-verification.json"
  private static let diagnosticSampleLimit = 256

  public static func exportClosedFlight(
    at directory: URL, allowBusResetSegment: Bool = false,
    progress: (@Sendable (HDVIngestProgress) -> Void)? = nil
  ) throws -> HDVIngestVerification {
    try Task.checkCancellation()
    let directoryFD = Darwin.open(directory.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard directoryFD >= 0 else { throw HDVIngestError.fileOperation("open capture directory", errno) }
    defer { Darwin.close(directoryFD) }
    var directoryInfo = stat()
    guard fstat(directoryFD, &directoryInfo) == 0 else {
      throw HDVIngestError.fileOperation("inspect capture directory", errno)
    }
    for name in [outputName, manifestName, verificationName].flatMap({ [$0, $0 + ".partial"] }) {
      var info = stat()
      if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        throw HDVIngestError.destinationExists(directory.appendingPathComponent(name).path)
      }
      guard errno == ENOENT else { throw HDVIngestError.fileOperation("inspect destination", errno) }
    }

    progress?(.init(phase: .validatingEvidence, completedBytes: 0, totalBytes: 0,
      overallCompletedBytes: 0, overallTotalBytes: 0))
    let journalHandle = try regularReader(directoryFD: directoryFD, name: "flight.ndjson")
    defer { try? journalHandle.close() }
    let journal = try readJournal(journalHandle, allowBusResetSegment: allowBusResetSegment)
    let rawHandle = try regularReader(directoryFD: directoryFD, name: "receive.records.raw")
    defer { try? rawHandle.close() }
    let rawInitialInfo = try fileInfo(rawHandle, operation: "inspect raw flight")
    let journalInitialInfo = try fileInfo(journalHandle, operation: "inspect flight journal")
    let reader = RecordReader(rawHandle)
    guard try reader.readExactly(8) == Data("RDRXLOG1".utf8) else {
      throw HDVIngestError.invalidEvidence("raw file magic mismatch")
    }

    let manifestHandle = try exclusiveWriter(directoryFD: directoryFD,
      name: manifestName + ".partial")
    defer { try? manifestHandle.close() }
    var outputHandle: FileHandle?
    defer { try? outputHandle?.close() }
    var assembler = HDVTransportAssembler()
    var records: UInt64 = 0, recordBytes: UInt64 = 0
    var lastObserved: UInt64 = 0, lastLoss: UInt64 = 0, rawGapEvents: UInt64 = 0
    var rawHash = SHA256(), outputHash = SHA256(), manifestHash = SHA256()
    var outputBytes: UInt64 = 0, manifestBytes: UInt64 = 0
    var diagnosticSample: [HDVTransportDiagnostic] = []
    var totalDiagnostics: UInt64 = 0
    var nextProgressBoundary: UInt64 = 1_048_576
    let estimatedTotal = safeSum(journal.closed.recordBytes, journal.closed.recordBytes)
    progress?(.init(phase: .reconstructingMPEG2Transport, completedBytes: 0,
      totalBytes: journal.closed.recordBytes, overallCompletedBytes: 0,
      overallTotalBytes: estimatedTotal))

    func recordDiagnostics(_ diagnostics: [HDVTransportDiagnostic]) throws {
      for diagnostic in diagnostics {
        totalDiagnostics &+= 1
        if diagnosticSample.count < diagnosticSampleLimit { diagnosticSample.append(diagnostic) }
        let line = try encode(ManifestEvent(diagnostic: diagnostic)) + Data([10])
        try manifestHandle.write(contentsOf: line)
        manifestHash.update(data: line)
        manifestBytes = try adding(manifestBytes, UInt64(line.count), "manifest byte count")
      }
    }

    // Drain read, assembly and metadata temporaries per record; retain only streaming state.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let header = try reader.readExactly(64) else { return false }
        try Task.checkCancellation()
        let sequence = integer(header, 0, UInt64.self)
        let epoch = integer(header, 8, UInt64.self)
        let transferStatus = integer(header, 32, UInt16.self)
        let payloadCount = integer(header, 36, UInt32.self)
        let observed = integer(header, 40, UInt64.self)
        let loss = integer(header, 48, UInt64.self)
        guard records < UInt64.max, sequence == records + 1, epoch == journal.status.epoch,
          payloadCount <= 4_096, integer(header, 56, UInt32.self) == 1,
          integer(header, 60, UInt32.self) == 0, observed > lastObserved,
          loss >= lastLoss, observed >= sequence, observed - sequence == loss,
          sequence <= journal.status.write, loss <= journal.status.drops else {
          throw HDVIngestError.invalidEvidence("record sequence, epoch, loss or header guard failed")
        }
        guard let payload = try reader.readExactly(Int(payloadCount)) else {
          throw HDVIngestError.invalidEvidence("missing record payload")
        }
        rawHash.update(data: header)
        rawHash.update(data: payload)
        let rawPayloadOffset = try adding(try adding(8, recordBytes, "raw offset"), 64, "raw offset")
        recordBytes = try adding(recordBytes, UInt64(64 + payload.count), "raw record byte count")
        records = sequence

        if loss != lastLoss {
          rawGapEvents &+= 1
          try recordDiagnostics(assembler.markTransportGap(recordSequence: sequence,
            rawPayloadByteOffset: rawPayloadOffset))
        }
        lastObserved = observed
        lastLoss = loss

        if isNonemptyDVPacket(payload, transferStatus: transferStatus,
          expectedSourceNode: journal.status.node) {
          throw HDVIngestError.invalidEvidence(
            "valid nonempty DV media was observed; mixed DV/HDV native export is unsupported and raw evidence is retained")
        }

        let consumed = assembler.consumePreservedPacket(payload,
          transferStatus: transferStatus, expectedSourceNode: journal.status.node,
          recordSequence: sequence, rawPayloadByteOffset: rawPayloadOffset)
        try recordDiagnostics(consumed.diagnostics)
        for unit in consumed.units {
          let unitOutputOffset = outputBytes
          if outputHandle == nil {
            outputHandle = try exclusiveWriter(directoryFD: directoryFD,
              name: outputName + ".partial")
          }
          try outputHandle!.write(contentsOf: unit.transportPacket)
          outputHash.update(data: unit.transportPacket)
          outputBytes = try adding(outputBytes, UInt64(unit.transportPacket.count), "MPEG-2 output byte count")
          let line = try encode(ManifestEvent(unit: unit,
            outputByteOffset: unitOutputOffset)) + Data([10])
          try manifestHandle.write(contentsOf: line)
          manifestHash.update(data: line)
          manifestBytes = try adding(manifestBytes, UInt64(line.count), "manifest byte count")
        }
        if recordBytes >= nextProgressBoundary || recordBytes == journal.closed.recordBytes {
          progress?(.init(phase: .reconstructingMPEG2Transport,
            completedBytes: min(recordBytes, journal.closed.recordBytes),
            totalBytes: journal.closed.recordBytes,
            overallCompletedBytes: min(recordBytes, estimatedTotal), overallTotalBytes: estimatedTotal))
          while nextProgressBoundary <= recordBytes {
            let next = nextProgressBoundary.addingReportingOverflow(1_048_576)
            nextProgressBoundary = next.overflow ? UInt64.max : next.partialValue
            if nextProgressBoundary == UInt64.max { break }
          }
        }
        return true
      }
      if !processed { break }
    }
    if journal.status.drops > lastLoss {
      rawGapEvents &+= 1
      try recordDiagnostics(assembler.markTransportGap())
    }
    let finished = assembler.finish()
    try recordDiagnostics(finished.diagnostics)
    let sourceSHA = hex(rawHash.finalize())
    guard records == journal.status.write, recordBytes == journal.closed.recordBytes,
      sourceSHA == journal.closed.recordSHA256,
      journal.status.seen >= lastObserved, journal.status.drops >= lastLoss else {
      throw HDVIngestError.invalidEvidence("terminal counters or journal raw integrity mismatch")
    }
    guard finished.summary.acceptedTransportPackets > 0 else {
      throw HDVIngestError.invalidEvidence("closed flight contains no complete supported HDV transport packets")
    }
    guard outputBytes == finished.summary.acceptedTransportBytes,
      outputBytes == finished.summary.acceptedTransportPackets * 188 else {
      throw HDVIngestError.invalidEvidence("transport output accounting mismatch")
    }
    try manifestHandle.synchronize()
    try manifestHandle.close()
    try outputHandle?.synchronize()
    try outputHandle?.close()
    outputHandle = nil
    let outputSHA = hex(outputHash.finalize())
    let manifestSHA = hex(manifestHash.finalize())
    let exactTotal = safeSum(recordBytes, outputBytes, recordBytes, manifestBytes)

    progress?(.init(phase: .rereadingMPEG2Transport, completedBytes: 0,
      totalBytes: outputBytes, overallCompletedBytes: recordBytes, overallTotalBytes: exactTotal))
    let outputReread = try hashFile(directoryFD: directoryFD, name: outputName + ".partial") {
      progress?(.init(phase: .rereadingMPEG2Transport, completedBytes: $0,
        totalBytes: outputBytes, overallCompletedBytes: safeSum(recordBytes, $0),
        overallTotalBytes: exactTotal))
    }
    guard outputReread.bytes == outputBytes, outputReread.sha == outputSHA else {
      throw HDVIngestError.invalidEvidence("MPEG-2 transport changed during reread")
    }
    progress?(.init(phase: .rereadingRawEvidence, completedBytes: 0,
      totalBytes: recordBytes, overallCompletedBytes: safeSum(recordBytes, outputBytes),
      overallTotalBytes: exactTotal))
    let rawReread = try hashFile(rawHandle, skipMagic: true) {
      progress?(.init(phase: .rereadingRawEvidence, completedBytes: $0,
        totalBytes: recordBytes, overallCompletedBytes: safeSum(recordBytes, outputBytes, $0),
        overallTotalBytes: exactTotal))
    }
    guard rawReread.bytes == recordBytes, rawReread.sha == sourceSHA else {
      throw HDVIngestError.invalidEvidence("raw flight changed during reread")
    }
    progress?(.init(phase: .rereadingPacketManifest, completedBytes: 0,
      totalBytes: manifestBytes, overallCompletedBytes: safeSum(recordBytes, outputBytes, recordBytes),
      overallTotalBytes: exactTotal))
    let manifestReread = try hashFile(directoryFD: directoryFD,
      name: manifestName + ".partial") { count in
      progress?(.init(phase: .rereadingPacketManifest, completedBytes: count,
        totalBytes: manifestBytes,
        overallCompletedBytes: safeSum(recordBytes, outputBytes, recordBytes, count),
        overallTotalBytes: exactTotal))
    }
    guard manifestReread.bytes == manifestBytes, manifestReread.sha == manifestSHA else {
      throw HDVIngestError.invalidEvidence("packet manifest changed during reread")
    }
    let journalReread = try hashFile(journalHandle)
    guard journalReread.sha == journal.sha else {
      throw HDVIngestError.invalidEvidence("flight journal changed during reread")
    }
    try requireSameFile(rawHandle, initial: rawInitialInfo, directoryFD: directoryFD,
      name: "receive.records.raw", label: "raw flight")
    try requireSameFile(journalHandle, initial: journalInitialInfo, directoryFD: directoryFD,
      name: "flight.ndjson", label: "flight journal")
    try requireDirectoryIdentity(directory, directoryFD: directoryFD, initial: directoryInfo)
    try Task.checkCancellation()

    let result = HDVIngestVerification(schemaVersion: 1,
      transportPacketCount: finished.summary.acceptedTransportPackets,
      transportBytes: outputBytes, rawRecordCount: records, rawRecordBytes: recordBytes,
      rawRecordSHA256: sourceSHA, nativeTSSHA256: outputSHA,
      journalSHA256: journal.sha, packetManifestSHA256: manifestSHA,
      packetManifestBytes: manifestBytes,
      hostRingDrops: journal.status.drops - journal.status.oversized,
      oversizedPackets: journal.status.oversized,
      knownDroppedPackets: journal.status.drops, rawTransportGapEvents: rawGapEvents,
      transportSummary: finished.summary, diagnosticSample: diagnosticSample,
      diagnosticSampleTruncated: totalDiagnostics > UInt64(diagnosticSample.count),
      finalAcknowledgementConfirmed: journal.status.acknowledged == journal.status.write,
      integritySHA256Verified: true, nativeTSRereadVerified: true,
      hardwareContinuity: "unknown", exactLostTransportPacketCount: nil,
      sourceMediaDamage: "unknown", captureFile: outputName,
      packetManifestFile: manifestName, verificationFile: verificationName,
      finalStatusWireBase64: journal.status.wire.base64EncodedString())
    let verificationBytes = try encode(result)
    let verificationHandle = try exclusiveWriter(directoryFD: directoryFD,
      name: verificationName + ".partial")
    do {
      try verificationHandle.write(contentsOf: verificationBytes)
      try verificationHandle.synchronize()
      try verificationHandle.close()
    } catch {
      try? verificationHandle.close()
      throw error
    }
    try Task.checkCancellation()
    try requireDirectoryIdentity(directory, directoryFD: directoryFD, initial: directoryInfo)
    progress?(.init(phase: .publishingVerifiedFiles, completedBytes: 0, totalBytes: 0,
      overallCompletedBytes: exactTotal, overallTotalBytes: exactTotal))
    try promote(directoryFD: directoryFD, from: outputName + ".partial", to: outputName,
      bytes: outputBytes, sha: outputSHA)
    try promote(directoryFD: directoryFD, from: manifestName + ".partial", to: manifestName,
      bytes: manifestBytes, sha: manifestSHA)
    guard fsync(directoryFD) == 0 else { throw HDVIngestError.fileOperation("sync payload directory", errno) }
    let verificationSHA = hex(SHA256.hash(data: verificationBytes))
    try promote(directoryFD: directoryFD, from: verificationName + ".partial", to: verificationName,
      bytes: UInt64(verificationBytes.count), sha: verificationSHA)
    if fsync(directoryFD) != 0 {
      DVPortablePublication.withdrawCompletionMarkerBestEffort(directoryFD: directoryFD,
        from: verificationName, to: verificationName + ".partial")
      throw HDVIngestError.fileOperation("sync verification directory", errno)
    }
    progress?(.init(phase: .complete, completedBytes: exactTotal, totalBytes: exactTotal,
      overallCompletedBytes: exactTotal, overallTotalBytes: exactTotal))
    return result
  }

  private struct ManifestEvent: Encodable {
    let schemaVersion = 1
    let kind: String
    let unit: UnitEntry?
    let diagnostic: HDVTransportDiagnostic?
    init(unit: HDVTransportStreamUnit, outputByteOffset: UInt64) {
      kind = "transport_packet"
      self.unit = UnitEntry(unit, outputByteOffset: outputByteOffset)
      diagnostic = nil
    }
    init(diagnostic: HDVTransportDiagnostic) {
      kind = "diagnostic"
      unit = nil
      self.diagnostic = diagnostic
    }
  }

  private struct UnitEntry: Encodable {
    let ordinal: UInt64
    let outputByteOffset: UInt64
    let byteCount = 188
    let SHA256: String
    let sourcePacketHeaderHex: String
    let firstCIPDBC: UInt8
    let provenance: [HDVRawProvenanceExtent]
    let PID: UInt16
    let transportErrorIndicator: Bool
    let payloadUnitStartIndicator: Bool
    let adaptationFieldControl: UInt8
    let continuityCounter: UInt8
    init(_ unit: HDVTransportStreamUnit, outputByteOffset: UInt64) {
      ordinal = unit.ordinal
      self.outputByteOffset = outputByteOffset
      SHA256 = unit.SHA256
      sourcePacketHeaderHex = unit.sourcePacketHeader.map { String(format: "%02x", $0) }.joined()
      firstCIPDBC = unit.firstCIPDBC
      provenance = unit.provenance
      PID = unit.PID
      transportErrorIndicator = unit.transportErrorIndicator
      payloadUnitStartIndicator = unit.payloadUnitStartIndicator
      adaptationFieldControl = unit.adaptationFieldControl
      continuityCounter = unit.continuityCounter
    }
  }

  private struct JournalEvent: Decodable {
    let schemaVersion: Int
    let event: String
    let wireBase64: String
    let recordBytes: UInt64
    let recordSHA256: String
  }

  private struct Terminal {
    let wire: Data, route: Data
    let epoch: UInt64, write: UInt64, seen: UInt64, drops: UInt64, oversized: UInt64
    let acknowledged: UInt64
    let node: UInt8
    init(_ bytes: Data, allowBusResetSegment: Bool = false) throws {
      guard bytes.count == 128, integer(bytes, 0, UInt32.self) == 0x58524452,
        integer(bytes, 4, UInt16.self) == 1, integer(bytes, 6, UInt16.self) == 256,
        integer(bytes, 8, UInt32.self) == 4160,
        [UInt32(8192), 65536].contains(integer(bytes, 12, UInt32.self)),
        integer(bytes, 24, UInt32.self) == 1, integer(bytes, 28, UInt32.self) == 48,
        [16, 32, 40, 48, 56].allSatisfy({ integer(bytes, $0, UInt64.self) != 0 }),
        integer(bytes, 70, UInt16.self) == 0, bytes[68] & 0x3f < 63,
        [UInt32(2), allowBusResetSegment ? 3 : 2].contains(integer(bytes, 80, UInt32.self)), integer(bytes, 84, UInt32.self) == 0 else {
        throw HDVIngestError.invalidEvidence("missing clean stopped status or receive ABI/route mismatch")
      }
      wire = bytes; route = bytes.subdata(in: 24..<72)
      epoch = integer(bytes, 16, UInt64.self); node = bytes[68] & 0x3f
      write = integer(bytes, 88, UInt64.self); seen = integer(bytes, 96, UInt64.self)
      drops = integer(bytes, 104, UInt64.self); oversized = integer(bytes, 112, UInt64.self)
      acknowledged = integer(bytes, 120, UInt64.self)
      guard seen >= write, seen - write == drops, drops >= oversized,
        acknowledged == write else {
        throw HDVIngestError.invalidEvidence("terminal receive counters do not reconcile")
      }
    }
  }

  private static func readJournal(_ handle: FileHandle, allowBusResetSegment: Bool) throws ->
    (closed: JournalEvent, status: Terminal, sha: String) {
    try handle.seek(toOffset: 0)
    var buffer = Data(), hash = SHA256()
    var startRoute: Data?, final: JournalEvent?, finalWire: Data?, closed: JournalEvent?
    // The read and all line/JSON work belong to the same bounded cleanup scope.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { return false }
        try Task.checkCancellation()
        hash.update(data: chunk); buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
          guard closed == nil else { throw HDVIngestError.invalidEvidence("journal events follow receive_closed") }
          let line = Data(buffer[..<newline])
          buffer = Data(buffer[buffer.index(after: newline)...])
          guard line.count <= 1_048_576 else { throw HDVIngestError.invalidEvidence("oversized journal event") }
          let event: JournalEvent
          do { event = try JSONDecoder().decode(JournalEvent.self, from: line) }
          catch { throw HDVIngestError.invalidEvidence("journal JSON is invalid") }
          guard event.schemaVersion == 1, let wire = Data(base64Encoded: event.wireBase64) else {
            throw HDVIngestError.invalidEvidence("journal schema or base64 mismatch")
          }
          guard final == nil || event.event == "receive_closed" else {
            throw HDVIngestError.invalidEvidence("intervening event follows final status")
          }
          if event.event == "receive_start_intent" {
            guard startRoute == nil, wire.count == 48 else {
              throw HDVIngestError.invalidEvidence("duplicate or invalid receive start intent")
            }
            startRoute = wire
          } else if event.event == "receive_final_status" {
            guard final == nil, wire.count == 128 else {
              throw HDVIngestError.invalidEvidence("duplicate or invalid final status")
            }
            final = event; finalWire = wire
          } else if event.event == "receive_closed" {
            guard closed == nil else { throw HDVIngestError.invalidEvidence("duplicate receive_closed") }
            closed = event
          }
        }
        guard buffer.count <= 1_048_576 else { throw HDVIngestError.invalidEvidence("oversized journal event") }
        return true
      }
      if !processed { break }
    }
    guard buffer.isEmpty, let final, let finalWire, let closed else {
      throw HDVIngestError.invalidEvidence("missing final status/closure or truncated journal")
    }
    guard final.recordBytes == closed.recordBytes,
      final.recordSHA256 == closed.recordSHA256,
      closed.wireBase64.isEmpty || closed.wireBase64 == final.wireBase64 else {
      throw HDVIngestError.invalidEvidence("receive_closed does not bind final status")
    }
    let status = try Terminal(finalWire, allowBusResetSegment: allowBusResetSegment)
    guard let startRoute, startRoute == status.route else {
      throw HDVIngestError.invalidEvidence("terminal route does not match receive start intent")
    }
    return (closed, status, hex(hash.finalize()))
  }

  private final class RecordReader {
    let handle: FileHandle
    var buffer = Data(), cursor = 0
    init(_ handle: FileHandle) { self.handle = handle }
    func readExactly(_ count: Int) throws -> Data? {
      var result = Data(); result.reserveCapacity(count)
      while result.count < count {
        if cursor == buffer.count {
          // The owned Data survives this scope; autoreleased read temporaries do not.
          buffer = try autoreleasepool { try handle.read(upToCount: 1_048_576) ?? Data() }; cursor = 0
          if buffer.isEmpty {
            if result.isEmpty { return nil }
            throw HDVIngestError.invalidEvidence("truncated raw record")
          }
        }
        let amount = min(count - result.count, buffer.count - cursor)
        result.append(buffer[cursor..<(cursor + amount)]); cursor += amount
      }
      return result
    }
  }

  private static func regularReader(directoryFD: Int32, name: String) throws -> FileHandle {
    let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw HDVIngestError.fileOperation("open \(name)", errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(fd); throw HDVIngestError.invalidEvidence("\(name) is not a regular file")
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  private static func exclusiveWriter(directoryFD: Int32, name: String) throws -> FileHandle {
    let fd = openat(directoryFD, name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      if errno == EEXIST { throw HDVIngestError.destinationExists(name) }
      throw HDVIngestError.fileOperation("create exclusive \(name)", errno)
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  private static func hashFile(
    directoryFD: Int32, name: String, progress: ((UInt64) -> Void)? = nil
  ) throws -> (bytes: UInt64, sha: String) {
    let handle = try regularReader(directoryFD: directoryFD, name: name)
    defer { try? handle.close() }
    return try hashFile(handle, progress: progress)
  }

  private static func hashFile(
    _ handle: FileHandle, skipMagic: Bool = false,
    progress: ((UInt64) -> Void)? = nil
  ) throws -> (bytes: UInt64, sha: String) {
    try handle.seek(toOffset: 0)
    if skipMagic {
      guard try readExactly(handle, count: 8) == Data("RDRXLOG1".utf8) else {
        throw HDVIngestError.invalidEvidence("raw magic changed during reread")
      }
    }
    var hash = SHA256(), bytes: UInt64 = 0
    // Include the read itself, hashing and progress in each synchronous chunk scope.
    while true {
      let processed = try autoreleasepool { () throws -> Bool in
        guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
        try Task.checkCancellation()
        hash.update(data: chunk); bytes = try adding(bytes, UInt64(chunk.count), "reread byte count")
        progress?(bytes)
        return true
      }
      if !processed { break }
    }
    return (bytes, hex(hash.finalize()))
  }

  private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data? {
    // Callers request bounded magic/report data, never a capture-sized result.
    return try autoreleasepool {
      var result = Data()
      while result.count < count {
        let chunk = try handle.read(upToCount: count - result.count) ?? Data()
        if chunk.isEmpty {
          if result.isEmpty { return nil }
          throw HDVIngestError.invalidEvidence("truncated file")
        }
        result.append(chunk)
      }
      return result
    }
  }

  private static func requireSameFile(
    _ handle: FileHandle, initial: stat, directoryFD: Int32, name: String, label: String
  ) throws {
    var current = stat(), path = stat()
    guard fstat(handle.fileDescriptor, &current) == 0,
      fstatat(directoryFD, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
      current.st_mode & S_IFMT == S_IFREG, path.st_mode & S_IFMT == S_IFREG,
      current.st_dev == initial.st_dev, current.st_ino == initial.st_ino,
      current.st_size == initial.st_size, current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
      current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
      path.st_dev == initial.st_dev, path.st_ino == initial.st_ino else {
      throw HDVIngestError.invalidEvidence("\(label) identity or metadata changed during export")
    }
  }

  private static func requireDirectoryIdentity(
    _ url: URL, directoryFD: Int32, initial: stat
  ) throws {
    var held = stat(), path = stat()
    guard fstat(directoryFD, &held) == 0, lstat(url.path, &path) == 0,
      held.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
      held.st_dev == initial.st_dev, held.st_ino == initial.st_ino,
      path.st_dev == initial.st_dev, path.st_ino == initial.st_ino else {
      throw HDVIngestError.invalidEvidence("capture directory identity changed during export")
    }
  }

  private static func fileInfo(_ handle: FileHandle, operation: String) throws -> stat {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else {
      throw HDVIngestError.fileOperation(operation, errno)
    }
    return info
  }

  private static func promote(
    directoryFD: Int32, from: String, to: String, bytes: UInt64, sha: String
  ) throws {
    do {
      try DVPortablePublication.promoteExclusive(directoryFD: directoryFD,
        from: from, to: to, expectedBytes: bytes, expectedSHA256: sha)
    } catch let error as DVIngestError {
      switch error {
      case .invalidEvidence(let reason): throw HDVIngestError.invalidEvidence(reason)
      case .destinationExists(let path): throw HDVIngestError.destinationExists(path)
      case .fileOperation(let operation, let code): throw HDVIngestError.fileOperation(operation, code)
      }
    }
  }

  private static func isNonemptyDVPacket(
    _ packet: Data, transferStatus: UInt16, expectedSourceNode: UInt8
  ) -> Bool {
    guard packet.count > 16, packet.count <= 4_096, transferStatus & 0x1f == 0x11,
      expectedSourceNode < 64, packet[8] & 0xc0 == 0,
      packet[8] & 0x3f == expectedSourceNode, packet[12] & 0xc0 == 0x80,
      packet[12] & 0x3f == 0, packet[10] & 0xfb == 0, packet[9] == 120 else { return false }
    let sourceHeaderBytes = packet[10] & 4 == 0 ? 0 : 4
    return (packet.count - 16).isMultiple(of: 480 + sourceHeaderBytes)
  }

  private static func integer<T: FixedWidthInteger>(
    _ data: Data, _ offset: Int, _ type: T.Type
  ) -> T {
    data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
  }

  private static func adding(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let value = lhs.addingReportingOverflow(rhs)
    guard !value.overflow else { throw HDVIngestError.invalidEvidence("\(label) overflow") }
    return value.partialValue
  }

  private static func safeSum(_ values: UInt64...) -> UInt64 {
    values.reduce(0) { partial, value in
      let sum = partial.addingReportingOverflow(value)
      return sum.overflow ? UInt64.max : sum.partialValue
    }
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}
