import CryptoKit
import Darwin
import Foundation

public enum TransportExtentKind: String, Codable, Equatable, Sendable {
  case ohciIsochronousReceive = "ohci_isochronous_receive"
  case unclassifiedReceive = "unclassified_receive"
}

public struct TransportByteRange: Codable, Equatable, Sendable {
  public let offset: UInt32
  public let length: UInt32

  public init(offset: UInt32, length: UInt32) {
    self.offset = offset
    self.length = length
  }
}

/// Observations remain separate coordinates. Optional fields are not inferred
/// from one another, and an absent field remains absent.
public struct RawTransportObservation: Codable, Equatable, Sendable {
  public let captureOrdinal: UInt64
  public let kind: TransportExtentKind
  public let hostMonotonicNanoseconds: UInt64
  public let utcTimestamp: String?
  public let busGeneration: UInt32?
  public let ohciDMASequence: UInt64?
  public let cycleTimestamp: UInt16?
  public let cipDBC: UInt8?
  public let cipSYT: UInt16?
  public let rawReceiveHeader: [UInt8]
  public let rawCIPHeader: [UInt8]
  public let identifiableDVPayloadRange: TransportByteRange?

  public init(
    captureOrdinal: UInt64,
    kind: TransportExtentKind,
    hostMonotonicNanoseconds: UInt64,
    utcTimestamp: String? = nil,
    busGeneration: UInt32? = nil,
    ohciDMASequence: UInt64? = nil,
    cycleTimestamp: UInt16? = nil,
    cipDBC: UInt8? = nil,
    cipSYT: UInt16? = nil,
    rawReceiveHeader: [UInt8] = [],
    rawCIPHeader: [UInt8] = [],
    identifiableDVPayloadRange: TransportByteRange? = nil
  ) {
    self.captureOrdinal = captureOrdinal
    self.kind = kind
    self.hostMonotonicNanoseconds = hostMonotonicNanoseconds
    self.utcTimestamp = utcTimestamp
    self.busGeneration = busGeneration
    self.ohciDMASequence = ohciDMASequence
    self.cycleTimestamp = cycleTimestamp
    self.cipDBC = cipDBC
    self.cipSYT = cipSYT
    self.rawReceiveHeader = rawReceiveHeader
    self.rawCIPHeader = rawCIPHeader
    self.identifiableDVPayloadRange = identifiableDVPayloadRange
  }
}

/// Exact full receive extent. This is transport evidence, not presumed native DV.
public struct RawTransportExtent: Equatable, Sendable {
  public let bytes: Data
  public let observation: RawTransportObservation

  public init(bytes: Data, observation: RawTransportObservation) {
    self.bytes = bytes
    self.observation = observation
  }
}

public struct ArchiveSessionIdentity: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let sessionID: String
  public let createdUTC: String
  public let capturePolicy: CapturePolicy
  public let softwareVersion: String
  public let controllerIdentity: String?
  public let deckIdentity: String?
  public let admissionLimits: ArchiveAdmissionLimits

  public init(
    sessionID: String,
    createdUTC: String,
    softwareVersion: String,
    controllerIdentity: String? = nil,
    deckIdentity: String? = nil,
    admissionLimits: ArchiveAdmissionLimits = .conservativeTransport
  ) {
    schemaVersion = 1
    self.sessionID = sessionID
    self.createdUTC = createdUTC
    capturePolicy = .operatorControlledContinuous
    self.softwareVersion = softwareVersion
    self.controllerIdentity = controllerIdentity
    self.deckIdentity = deckIdentity
    self.admissionLimits = admissionLimits
  }
}

public enum LossAccountingStatus: String, Codable, Equatable, Sendable {
  case unknown
  case completeNoHostLossObserved = "complete_no_host_loss_observed"
  case completeWithRecordedHostLoss = "complete_with_recorded_host_loss"
}

public struct ArchiveFinalizationEvidence: Codable, Equatable, Sendable {
  public let producerEndedAndQuiesced: Bool
  public let producerEndReason: String
  public let lossAccounting: LossAccountingStatus
  public let recordedHostLossExtentCount: UInt64

  public init(
    producerEndedAndQuiesced: Bool,
    producerEndReason: String,
    lossAccounting: LossAccountingStatus,
    recordedHostLossExtentCount: UInt64
  ) {
    self.producerEndedAndQuiesced = producerEndedAndQuiesced
    self.producerEndReason = producerEndReason
    self.lossAccounting = lossAccounting
    self.recordedHostLossExtentCount = recordedHostLossExtentCount
  }
}

public enum VerifiedAcquisitionOutcome: String, Codable, Equatable, Sendable {
  case unknown
  case noHostLossObserved = "no_host_loss_observed"
  case completedWithRecordedHostLoss = "completed_with_recorded_host_loss"
}

public enum ArchiveLifecycleState: String, Codable, Equatable, Sendable {
  case incomplete
  case finalized
}

public enum ArchiveByteIntegrity: String, Codable, Equatable, Sendable {
  case acknowledgedExtentsVerified = "acknowledged_extents_verified"
  case finalizedArchiveVerified = "finalized_archive_verified"
}

public struct RawArchiveVerification: Equatable, Sendable {
  public let lifecycle: ArchiveLifecycleState
  public let byteIntegrity: ArchiveByteIntegrity
  public let acquisitionOutcome: VerifiedAcquisitionOutcome
  public let acknowledgedExtentCount: UInt64
  public let acknowledgedByteCount: UInt64
  public let orphanByteCount: UInt64
  public let incompleteObservationTailBytes: Int
  public let transportSHA256: String

  public init(
    lifecycle: ArchiveLifecycleState,
    byteIntegrity: ArchiveByteIntegrity,
    acquisitionOutcome: VerifiedAcquisitionOutcome,
    acknowledgedExtentCount: UInt64,
    acknowledgedByteCount: UInt64,
    orphanByteCount: UInt64,
    incompleteObservationTailBytes: Int,
    transportSHA256: String
  ) {
    self.lifecycle = lifecycle
    self.byteIntegrity = byteIntegrity
    self.acquisitionOutcome = acquisitionOutcome
    self.acknowledgedExtentCount = acknowledgedExtentCount
    self.acknowledgedByteCount = acknowledgedByteCount
    self.orphanByteCount = orphanByteCount
    self.incompleteObservationTailBytes = incompleteObservationTailBytes
    self.transportSHA256 = transportSHA256
  }
}

public enum RawArchiveError: Error, Equatable, LocalizedError, Sendable {
  case destinationExists(String)
  case invalidExtent(String)
  case sequenceMismatch(expected: UInt64, actual: UInt64)
  case admissionRejected(ArchiveAdmissionRejection)
  case writerUnavailable
  case invalidFinalization(String)
  case hashMismatch(expected: String, actual: String)
  case invalidArchive(String)
  case system(operation: String, code: Int32)
  case injectedWriteFailure

  public var errorDescription: String? {
    switch self {
    case .destinationExists(let path): "archive destination already exists: \(path)"
    case .invalidExtent(let reason): "invalid transport extent: \(reason)"
    case .sequenceMismatch(let expected, let actual):
      "capture ordinal mismatch: expected \(expected), received \(actual)"
    case .admissionRejected(let reason): "archive admission rejected: \(reason.rawValue)"
    case .writerUnavailable: "archive writer is finalized or failed"
    case .invalidFinalization(let reason): "invalid finalization: \(reason)"
    case .hashMismatch(let expected, let actual):
      "persisted transport hash mismatch: expected \(expected), observed \(actual)"
    case .invalidArchive(let reason): "invalid archive: \(reason)"
    case .system(let operation, let code): "\(operation) failed with errno \(code)"
    case .injectedWriteFailure: "injected archive write failure"
    }
  }
}

private struct PersistedTransportObservation: Codable, Equatable {
  let schemaVersion: UInt16
  let captureOrdinal: UInt64
  let rawOffset: UInt64
  let rawLength: UInt32
  let rawSHA256: String
  let observation: RawTransportObservation
}

private struct RawArchiveManifest: Codable, Equatable {
  let schemaVersion: UInt16
  let sessionIdentitySHA256: String
  let transportSHA256: String
  let persistedRereadSHA256: String
  let observationsSHA256: String
  let acknowledgedExtentCount: UInt64
  let acknowledgedByteCount: UInt64
  let finalizationEvidence: ArchiveFinalizationEvidence
}

struct RawArchiveFaultInjection: Sendable {
  var failRawWriteAtOrdinal: UInt64?
  var failObservationWriteAtOrdinal: UInt64?

  static let none = RawArchiveFaultInjection()
}

/// Append-only archival writer for use only after a bounded realtime handoff.
/// It performs file I/O, hashing, allocation, and synchronization and therefore
/// must never execute on the realtime acquisition callback.
public final class RawArchiveWriter {
  public static let identityFilename = "session.json"
  public static let transportFilename = "capture.transport.raw"
  public static let observationsFilename = "observations.ndjson"
  public static let manifestFilename = "manifest.json"
  private static let maximumObservationLineBytes = 64 * 1_024

  public let rootURL: URL
  public let identity: ArchiveSessionIdentity
  public private(set) var status: CaptureStatus

  private let identitySHA256: String
  private let rawHandle: FileHandle
  private let observationsHandle: FileHandle
  private let faultInjection: RawArchiveFaultInjection
  private var transportHasher = SHA256()
  private var acknowledgedExtentCount: UInt64 = 0
  private var acknowledgedByteCount: UInt64 = 0
  private var closed = false

  public convenience init(
    createAt rootURL: URL,
    identity: ArchiveSessionIdentity
  ) throws {
    try self.init(createAt: rootURL, identity: identity, faultInjection: .none)
  }

  init(
    createAt rootURL: URL,
    identity: ArchiveSessionIdentity,
    faultInjection: RawArchiveFaultInjection
  ) throws {
    // mkdir is an atomic exclusive destination claim; a check-then-create
    // FileManager sequence can accept a directory created by another writer.
    guard Darwin.mkdir(rootURL.path, 0o700) == 0 else {
      if errno == EEXIST { throw RawArchiveError.destinationExists(rootURL.path) }
      throw Self.systemError("create exclusive archive directory")
    }

    self.rootURL = rootURL
    self.identity = identity
    self.faultInjection = faultInjection
    status = CaptureStatus(intake: .ready, archive: .incomplete)

    let identityData = try Self.canonicalJSON(identity)
    identitySHA256 = Self.sha256Hex(identityData)
    rawHandle = try Self.createExclusiveFile(
      rootURL.appendingPathComponent(Self.transportFilename))
    observationsHandle = try Self.createExclusiveFile(
      rootURL.appendingPathComponent(Self.observationsFilename))
    try Self.writeExclusiveFile(
      rootURL.appendingPathComponent(Self.identityFilename), data: identityData)
    try Self.synchronizeDirectory(rootURL)
    try Self.synchronizeDirectory(rootURL.deletingLastPathComponent())
  }

  deinit {
    try? rawHandle.close()
    try? observationsHandle.close()
  }

  public func setOperationalState(
    driver: DriverState,
    deck: DeckState,
    intake: IntakeState
  ) {
    status.driver = driver
    status.deck = deck
    status.intake = intake
  }

  public func recordFailure(phase: String, message: String) {
    if status.firstError == nil {
      status.firstError = CaptureFailure(phase: phase, message: message)
    }
    status.intake = .rejected
    status.archive = .failed
  }

  public func recordCleanupFailure(phase: String, message: String) {
    status.cleanupErrors.append(CaptureFailure(phase: phase, message: message))
  }

  public func append(_ extent: RawTransportExtent) throws {
    guard !closed, status.archive == .incomplete, status.firstError == nil else {
      throw RawArchiveError.writerUnavailable
    }
    let actualOrdinal = extent.observation.captureOrdinal
    guard actualOrdinal == acknowledgedExtentCount else {
      throw RawArchiveError.sequenceMismatch(
        expected: acknowledgedExtentCount, actual: actualOrdinal)
    }
    let decision = ArchiveAdmissionDecision.evaluate(
      extentByteCount: extent.bytes.count,
      outstandingExtentCount: 0,
      outstandingByteCount: 0,
      limits: identity.admissionLimits)
    if case .rejected(let reason) = decision {
      throw RawArchiveError.admissionRejected(reason)
    }
    if let range = extent.observation.identifiableDVPayloadRange {
      let end = UInt64(range.offset) + UInt64(range.length)
      guard range.length > 0, end <= UInt64(extent.bytes.count) else {
        throw RawArchiveError.invalidExtent(
          "identifiable DV payload range is outside the raw transport extent")
      }
    }
    guard extent.observation.rawReceiveHeader.count <= 256,
      extent.observation.rawCIPHeader.count <= 256
    else {
      throw RawArchiveError.invalidExtent("raw header observation exceeds 256 bytes")
    }
    guard extent.bytes.count <= Int(UInt32.max) else {
      throw RawArchiveError.invalidExtent("raw transport extent exceeds UInt32 length")
    }

    let record = PersistedTransportObservation(
      schemaVersion: 1,
      captureOrdinal: actualOrdinal,
      rawOffset: acknowledgedByteCount,
      rawLength: UInt32(extent.bytes.count),
      rawSHA256: Self.sha256Hex(extent.bytes),
      observation: extent.observation)
    let recordData = try Self.canonicalJSON(record)
    guard recordData.count <= Self.maximumObservationLineBytes else {
      throw RawArchiveError.invalidExtent("encoded observation exceeds fixed limit")
    }

    do {
      if faultInjection.failRawWriteAtOrdinal == actualOrdinal {
        throw RawArchiveError.injectedWriteFailure
      }
      try rawHandle.write(contentsOf: extent.bytes)
      try rawHandle.synchronize()
      transportHasher.update(data: extent.bytes)
      if faultInjection.failObservationWriteAtOrdinal == actualOrdinal {
        throw RawArchiveError.injectedWriteFailure
      }
      try observationsHandle.write(contentsOf: recordData)
      try observationsHandle.synchronize()
    } catch {
      closed = true
      recordFailure(phase: "archive_write", message: String(describing: error))
      throw error
    }
    acknowledgedExtentCount += 1
    acknowledgedByteCount += UInt64(extent.bytes.count)
    status.intake = .accepting
  }

  public func finalize(with evidence: ArchiveFinalizationEvidence) throws {
    guard !closed, status.archive == .incomplete, status.firstError == nil else {
      throw RawArchiveError.writerUnavailable
    }
    guard acknowledgedExtentCount > 0 else {
      throw RawArchiveError.invalidFinalization("no raw transport extent was acknowledged")
    }
    guard evidence.producerEndedAndQuiesced,
      !evidence.producerEndReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw RawArchiveError.invalidFinalization(
        "producer end and positive quiescence evidence are required")
    }
    switch evidence.lossAccounting {
    case .unknown:
      throw RawArchiveError.invalidFinalization("loss accounting remains unknown")
    case .completeNoHostLossObserved:
      guard evidence.recordedHostLossExtentCount == 0 else {
        throw RawArchiveError.invalidFinalization(
          "no-loss declaration conflicts with recorded host loss")
      }
    case .completeWithRecordedHostLoss:
      guard evidence.recordedHostLossExtentCount > 0 else {
        throw RawArchiveError.invalidFinalization(
          "recorded-loss declaration has a zero loss count")
      }
    }

    status.archive = .finalizing
    status.intake = .stopped
    let streamingDigest = Self.hexDigest(transportHasher.finalize())
    let rereadDigest: String
    do {
      try rawHandle.synchronize()
      try observationsHandle.synchronize()
      rereadDigest = try Self.sha256File(
        rootURL.appendingPathComponent(Self.transportFilename))
    } catch {
      closed = true
      recordFailure(phase: "archive_reread", message: String(describing: error))
      throw error
    }
    guard streamingDigest == rereadDigest else {
      let mismatch = RawArchiveError.hashMismatch(
        expected: streamingDigest, actual: rereadDigest)
      closed = true
      recordFailure(phase: "archive_reread", message: mismatch.localizedDescription)
      throw mismatch
    }

    let prefinal: RawArchiveVerification
    do {
      prefinal = try Self.verify(at: rootURL)
    } catch {
      closed = true
      recordFailure(
        phase: "archive_evidence_verification", message: String(describing: error))
      throw error
    }
    guard prefinal.lifecycle == .incomplete,
      prefinal.acknowledgedExtentCount == acknowledgedExtentCount,
      prefinal.acknowledgedByteCount == acknowledgedByteCount,
      prefinal.orphanByteCount == 0,
      prefinal.incompleteObservationTailBytes == 0,
      prefinal.transportSHA256 == streamingDigest
    else {
      let error = RawArchiveError.invalidFinalization(
        "retained transport and observation evidence is incomplete or inconsistent")
      closed = true
      recordFailure(
        phase: "archive_evidence_verification", message: error.localizedDescription)
      throw error
    }

    let manifest = RawArchiveManifest(
      schemaVersion: 1,
      sessionIdentitySHA256: identitySHA256,
      transportSHA256: streamingDigest,
      persistedRereadSHA256: rereadDigest,
      observationsSHA256: try Self.sha256File(
        rootURL.appendingPathComponent(Self.observationsFilename)),
      acknowledgedExtentCount: acknowledgedExtentCount,
      acknowledgedByteCount: acknowledgedByteCount,
      finalizationEvidence: evidence)
    do {
      try Self.writeExclusiveFile(
        rootURL.appendingPathComponent(Self.manifestFilename),
        data: try Self.canonicalJSON(manifest))
      try Self.synchronizeDirectory(rootURL)
    } catch {
      closed = true
      recordFailure(phase: "archive_finalization", message: String(describing: error))
      throw error
    }

    closed = true
    status.archive = .finalized
    do { try rawHandle.close() } catch {
      recordCleanupFailure(phase: "close_transport", message: String(describing: error))
    }
    do { try observationsHandle.close() } catch {
      recordCleanupFailure(phase: "close_observations", message: String(describing: error))
    }
  }

  public static func verify(at rootURL: URL) throws -> RawArchiveVerification {
    let identityURL = rootURL.appendingPathComponent(identityFilename)
    let rawURL = rootURL.appendingPathComponent(transportFilename)
    let observationsURL = rootURL.appendingPathComponent(observationsFilename)
    let identityData = try readBoundedMetadata(identityURL)
    let identity = try decodeCanonical(ArchiveSessionIdentity.self, from: identityData)
    guard identity.schemaVersion == 1,
      identity.admissionLimits.maximumExtentBytes > 0,
      identity.admissionLimits.maximumOutstandingExtents > 0,
      identity.admissionLimits.maximumOutstandingBytes
        >= identity.admissionLimits.maximumExtentBytes
    else {
      throw RawArchiveError.invalidArchive("unsupported session schema or invalid limits")
    }

    let rawHandle = try FileHandle(forReadingFrom: rawURL)
    defer { try? rawHandle.close() }
    let rawSize = try rawHandle.seekToEnd()
    let journal = try ObservationLineReader(url: observationsURL)
    var acknowledgedBytes: UInt64 = 0
    var acknowledgedCount: UInt64 = 0
    while let line = try journal.nextLine() {
      let record = try decodeCanonical(
        PersistedTransportObservation.self,
        from: line + Data([0x0a]))
      guard record.schemaVersion == 1,
        record.captureOrdinal == acknowledgedCount,
        record.observation.captureOrdinal == acknowledgedCount,
        record.rawOffset == acknowledgedBytes,
        record.rawLength > 0,
        record.rawLength <= identity.admissionLimits.maximumExtentBytes,
        record.rawOffset <= rawSize,
        UInt64(record.rawLength) <= rawSize - record.rawOffset
      else {
        throw RawArchiveError.invalidArchive("non-contiguous observation record")
      }
      guard record.observation.rawReceiveHeader.count <= 256,
        record.observation.rawCIPHeader.count <= 256
      else {
        throw RawArchiveError.invalidArchive("oversized raw header observation")
      }
      if let range = record.observation.identifiableDVPayloadRange {
        guard range.length > 0,
          UInt64(range.offset) + UInt64(range.length) <= UInt64(record.rawLength)
        else {
          throw RawArchiveError.invalidArchive("DV payload range outside retained extent")
        }
      }
      try rawHandle.seek(toOffset: record.rawOffset)
      // Even a self-consistent untrusted manifest cannot choose our allocation.
      var remaining = UInt64(record.rawLength)
      var extentHasher = SHA256()
      while remaining > 0 {
        let count = Int(min(remaining, 64 * 1_024))
        guard let bytes = try rawHandle.read(upToCount: count), !bytes.isEmpty else {
          throw RawArchiveError.invalidArchive("truncated raw transport extent")
        }
        extentHasher.update(data: bytes)
        remaining -= UInt64(bytes.count)
      }
      let digest = hexDigest(extentHasher.finalize())
      guard digest == record.rawSHA256 else {
        throw RawArchiveError.hashMismatch(expected: record.rawSHA256, actual: digest)
      }
      acknowledgedBytes += UInt64(record.rawLength)
      acknowledgedCount += 1
    }
    let incompleteTailBytes = journal.incompleteTailBytes
    let fullDigest = try sha256File(rawURL)
    let manifestURL = rootURL.appendingPathComponent(manifestFilename)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      return RawArchiveVerification(
        lifecycle: .incomplete,
        byteIntegrity: .acknowledgedExtentsVerified,
        acquisitionOutcome: .unknown,
        acknowledgedExtentCount: acknowledgedCount,
        acknowledgedByteCount: acknowledgedBytes,
        orphanByteCount: rawSize - acknowledgedBytes,
        incompleteObservationTailBytes: incompleteTailBytes,
        transportSHA256: fullDigest)
    }

    let manifest = try decodeCanonical(
      RawArchiveManifest.self, from: readBoundedMetadata(manifestURL))
    guard manifest.schemaVersion == 1,
      manifest.sessionIdentitySHA256 == sha256Hex(identityData),
      manifest.acknowledgedExtentCount == acknowledgedCount,
      manifest.acknowledgedByteCount == acknowledgedBytes,
      rawSize == acknowledgedBytes,
      incompleteTailBytes == 0,
      manifest.transportSHA256 == manifest.persistedRereadSHA256,
      manifest.observationsSHA256 == journal.digest
    else {
      throw RawArchiveError.invalidArchive("final manifest disagrees with retained evidence")
    }
    guard manifest.transportSHA256 == fullDigest else {
      throw RawArchiveError.hashMismatch(
        expected: manifest.transportSHA256, actual: fullDigest)
    }
    let outcome: VerifiedAcquisitionOutcome
    switch manifest.finalizationEvidence.lossAccounting {
    case .unknown:
      throw RawArchiveError.invalidArchive("final manifest has unknown loss accounting")
    case .completeNoHostLossObserved:
      guard manifest.finalizationEvidence.recordedHostLossExtentCount == 0 else {
        throw RawArchiveError.invalidArchive("final manifest has conflicting loss accounting")
      }
      outcome = .noHostLossObserved
    case .completeWithRecordedHostLoss:
      guard manifest.finalizationEvidence.recordedHostLossExtentCount > 0 else {
        throw RawArchiveError.invalidArchive("final manifest has conflicting loss accounting")
      }
      outcome = .completedWithRecordedHostLoss
    }
    guard manifest.finalizationEvidence.producerEndedAndQuiesced,
      !manifest.finalizationEvidence.producerEndReason.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else {
      throw RawArchiveError.invalidArchive("final manifest lacks producer quiescence")
    }
    return RawArchiveVerification(
      lifecycle: .finalized,
      byteIntegrity: .finalizedArchiveVerified,
      acquisitionOutcome: outcome,
      acknowledgedExtentCount: acknowledgedCount,
      acknowledgedByteCount: acknowledgedBytes,
      orphanByteCount: 0,
      incompleteObservationTailBytes: 0,
      transportSHA256: fullDigest)
  }

  /// The journal grows with tape duration; verification memory must not.
  private final class ObservationLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var cursor = 0
    private var ended = false
    private var hasher = SHA256()
    private(set) var incompleteTailBytes = 0
    var digest: String { hexDigest(hasher.finalize()) }

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    func nextLine() throws -> Data? {
      var line = Data()
      while true {
        if cursor == buffer.count {
          if ended {
            incompleteTailBytes = line.count
            return nil
          }
          buffer = try handle.read(upToCount: 64 * 1_024) ?? Data()
          cursor = 0
          if buffer.isEmpty {
            ended = true
            continue
          }
          hasher.update(data: buffer)
        }
        let remaining = buffer[cursor...]
        let newline = remaining.firstIndex(of: 0x0a)
        let end = newline ?? buffer.endIndex
        guard end - cursor <= maximumObservationLineBytes - line.count else {
          throw RawArchiveError.invalidArchive("oversized observation journal record")
        }
        line.append(buffer[cursor..<end])
        cursor = end
        if newline != nil {
          cursor += 1
          return line
        }
      }
    }
  }

  private static func readBoundedMetadata(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let maximum = 1_024 * 1_024
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    guard data.count <= maximum else {
      throw RawArchiveError.invalidArchive("oversized archive metadata")
    }
    return data
  }

  private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0a])
  }

  private static func decodeCanonical<T: Codable>(
    _ type: T.Type, from data: Data
  ) throws -> T {
    let decoded: T
    do { decoded = try JSONDecoder().decode(type, from: data) } catch {
      throw RawArchiveError.invalidArchive("JSON decode failed: \(error)")
    }
    guard data == (try canonicalJSON(decoded)) else {
      throw RawArchiveError.invalidArchive("JSON is not canonical or contains unknown fields")
    }
    return decoded
  }

  private static func createExclusiveFile(_ url: URL) throws -> FileHandle {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw systemError("create \(url.lastPathComponent)") }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func writeExclusiveFile(_ url: URL, data: Data) throws {
    let handle = try createExclusiveFile(url)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw systemError("open directory for synchronization") }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw systemError("synchronize directory") }
  }

  private static func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1 * 1_024 * 1_024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hexDigest(hasher.finalize())
  }

  private static func sha256Hex(_ data: Data) -> String {
    hexDigest(SHA256.hash(data: data))
  }

  private static func hexDigest<D: Sequence>(_ digest: D) -> String
  where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func systemError(_ operation: String) -> RawArchiveError {
    .system(operation: operation, code: errno)
  }
}
