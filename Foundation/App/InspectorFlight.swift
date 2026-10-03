// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit

/// Append-only, synchronized evidence. Never shares the receive/preview hot path.
final class InspectorFlight: @unchecked Sendable {
  private static let creationExecutor = DurableSerialExecutor(
    label: "net.rewinddigital.RewindDV.inspector-evidence-create")
  let directoryURL: URL
  let observationID = UUID()
  // Confined to creationExecutor; each store's data is confined to its writer.
  private nonisolated(unsafe) static var passiveStore: PassiveInspectorStore?
  private var compact: PassiveInspectorStore?
  private var compactStart: UInt64 = 0
  private var compactBytes: UInt64 = 0
  private var finished = false
  private var handle: FileHandle?
  private var journalHash = SHA256()
  private let capabilityProbe: Bool
  private let tapeStateProbe: Bool
  private let writer: DurableSerialExecutor

  static func open(parentDirectory: URL? = nil, capabilityProbe: Bool = false,
                   tapeStateProbe: Bool = false, passiveTransport: Bool = false) async throws -> InspectorFlight {
    if passiveTransport {
      guard tapeStateProbe, !capabilityProbe, parentDirectory == nil else {
        throw ControlWireError.invalid("Compact evidence is only for passive transport STATUS")
      }
      let store = try await creationExecutor.run {
        if let passiveStore { return passiveStore }
        let new = try PassiveInspectorStore()
        passiveStore = new
        return new
      }
      return try await store.writer.run { try InspectorFlight(compact: store) }
    }
    return try await creationExecutor.run {
      try InspectorFlight(parentDirectory: parentDirectory, capabilityProbe: capabilityProbe,
                          tapeStateProbe: tapeStateProbe)
    }
  }

  init(parentDirectory: URL? = nil, capabilityProbe: Bool = false, tapeStateProbe: Bool = false) throws {
    guard !(capabilityProbe && tapeStateProbe) else { throw ControlWireError.invalid("Conflicting inspector flight modes") }
    self.capabilityProbe = capabilityProbe
    self.tapeStateProbe = tapeStateProbe
    writer = DurableSerialExecutor(label: "net.rewinddigital.RewindDV.inspector-evidence")
    let manager = FileManager.default
    let support = try parentDirectory ?? manager.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    let root = support.appendingPathComponent("RewindDV/InspectorFlights", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    directoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directoryURL, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let url = directoryURL.appendingPathComponent("flight.ndjson")
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    for directory in [support, root.deletingLastPathComponent(), root, directoryURL] {
      let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let status = fsync(fd)
      Darwin.close(fd)
      guard status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
  }

  /// Internal injection seam for offline storage/rotation tests.
  init(compact: PassiveInspectorStore) throws {
    self.compact = compact; writer = compact.writer
    directoryURL = compact.directory
    capabilityProbe = false; tapeStateProbe = true
    compactStart = try compact.begin(observationID)
  }

  func append(event: String, query: InspectorQuery?, route: Data?, request: Data? = nil,
    result: Data? = nil, status: Int32? = nil, message: String? = nil,
    hostDeadlineUptimeNanoseconds: UInt64? = nil, command: DeckCommand? = nil) throws {
    let bytes = try encodedRecord(event: event, query: query, route: route, request: request,
      result: result, status: status, message: message,
      hostDeadlineUptimeNanoseconds: hostDeadlineUptimeNanoseconds, command: command)
    try appendLocked(bytes)
  }

  func appendAsync(event: String, query: InspectorQuery?, route: Data?, request: Data? = nil,
    result: Data? = nil, status: Int32? = nil, message: String? = nil,
    hostDeadlineUptimeNanoseconds: UInt64? = nil, command: DeckCommand? = nil) async throws {
    let bytes = try encodedRecord(event: event, query: query, route: route, request: request,
      result: result, status: status, message: message,
      hostDeadlineUptimeNanoseconds: hostDeadlineUptimeNanoseconds, command: command)
    try await writer.run { [self, bytes] in
      try appendLocked(bytes)
    }
  }

  private func appendLocked(_ bytes: Data) throws {
    guard !finished else { throw CocoaError(.fileWriteUnknown) }
    if let compact {
      try compact.append(bytes, observation: observationID)
      compactBytes += UInt64(bytes.count)
    } else {
      guard let handle else { throw CocoaError(.fileWriteUnknown) }
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
    }
    journalHash.update(data: bytes)
  }

  private func encodedRecord(event: String, query: InspectorQuery?, route: Data?, request: Data?,
    result: Data?, status: Int32?, message: String?, hostDeadlineUptimeNanoseconds: UInt64?,
    command: DeckCommand?) throws -> Data {
    struct Record: Encodable {
      let schema: String
      let observationID: UUID?
      let parser: String
      let protocolReference: String
      let utc: String
      let hostUptimeNanoseconds: UInt64?
      let event: String
      let query: String?
      let route: Data?
      let request: Data?
      let result: Data?
      let ioStatus: Int32?
      let message: String?
      let hostDeadlineUptimeNanoseconds: UInt64?
    }
    let record = Record(
      schema: tapeStateProbe ? "rewinddv.tape-state.v1" : capabilityProbe ? "rewinddv.transport-capabilities.v1" : "rewinddv.device-inspector.v1",
      observationID: compact == nil ? nil : observationID,
      parser: tapeStateProbe ? "typed-tape-status.v3" : capabilityProbe ? "specific-inquiry.v1" : "inventory-status.v1",
      protocolReference: tapeStateProbe
        ? "TA2004005 Tape Recorder/Player2.4 sections4.3/4.12/4.28/4.29; PDF SHA256 1feebabb10c03772124e88b375c47a12a6ef3a1d9ca3d25c5c07473077b048a1; typed DV ATN/medium/transport/current-timecode STATUS; BOT/EOT unqualified; wire ABI v1; no implementation code imported"
        : capabilityProbe
        ? "Behavioral standards references, no implementation code imported: AV/C General4.0 TA1999026 section9.3; Tape Recorder/Player2.4 TA2004005 section4.30 Table47; closed transport catalog wireABI1"
        : "AV/C General 4.0 TA1999026 sections11.2/11.3/12.1.1.3; Apple IOFireWireAVC fc4fb8ef578f9cb4d7ec74e32726d9b5bdb15425 UNIT/SUBUNIT; ASFW ac8a124a683d2f8201cd14ee0d2de8265e4834f0 unit PLUG INFO; wire ABI v1",
      utc: Date().ISO8601Format(),
      hostUptimeNanoseconds: compact == nil ? nil : DispatchTime.now().uptimeNanoseconds,
      event: event, query: command?.title ?? query?.title,
      route: route, request: request, result: result, ioStatus: status, message: message,
      hostDeadlineUptimeNanoseconds: hostDeadlineUptimeNanoseconds)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(record) + Data([10])
  }

  func finish() throws {
    try finishLocked()
  }

  func finishAsync() async throws {
    try await writer.run { [self] in
      try finishLocked()
    }
  }

  private func finishLocked() throws {
    if finished { return }
    if let compact {
      try compact.finish(observationID, offset: compactStart, count: compactBytes,
        expectedSHA256: Data(journalHash.finalize()))
      finished = true
      return
    }
    guard let handle else { return }
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    let fd = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    // Verify each committed journal line can be independently read back.
    let bytes = try Data(contentsOf: directoryURL.appendingPathComponent("flight.ndjson"))
    guard SHA256.hash(data: bytes) == journalHash.finalize() else { throw CocoaError(.fileReadCorruptFile) }
    guard bytes.last == 10 else { throw CocoaError(.fileReadCorruptFile) }
    for line in bytes.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
    finished = true
  }
}

/// Compact passive polling only. Each observation keeps its own UUID, raw
/// request/result, durable pre-submit intent and bounded reread/hash check.
/// Rotation happens BETWEEN observations. Existing evidence is never deleted.
/// Explicit inspections and whole-tape proof keep their immutable per-flight
/// files; this journal never serves as a whole-tape boundary proof artifact.
final class PassiveInspectorStore: @unchecked Sendable {
  struct Limits {
    var segmentBytes = 4 * 1024 * 1024
    var sessionBytes = 128 * 1024 * 1024
    var retainedBytes = 512 * 1024 * 1024
  }
  let writer = DurableSerialExecutor(label: "net.rewinddigital.RewindDV.passive-inspector-evidence")
  let directory: URL
  private let limits: Limits
  private let retainedAtStart: Int
  private let segmentDirectoryBarrier: (URL) throws -> Void
  private var file: FileHandle?, fileURL: URL?
  private var segment = 0, segmentBytes = 0, sessionBytes = 0
  private var active: UUID?
  private var observationBytes = 0
  private var failed = false

  init(root: URL? = nil, limits: Limits = Limits(),
       segmentDirectoryBarrier: ((URL) throws -> Void)? = nil) throws {
    guard limits.segmentBytes > 0, limits.sessionBytes >= 64 * 1024,
      limits.retainedBytes >= limits.sessionBytes else { throw ControlWireError.invalid("Invalid passive evidence limits") }
    self.limits = limits
    self.segmentDirectoryBarrier = segmentDirectoryBarrier ?? Self.syncDirectory
    let fm = FileManager.default
    let root = try root ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("RewindDV/PassiveTransportFlights")
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var retained = 0
    if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
      for case let url as URL in walker {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if v.isSymbolicLink == true { walker.skipDescendants(); continue }
        if v.isRegularFile == true { retained += v.fileSize ?? 0 }
        guard retained < limits.retainedBytes else { throw ControlWireError.invalid("Passive status evidence storage full; export/archive it before resuming observations. Existing evidence retained.") }
      }
    }
    retainedAtStart = retained
    directory = root.appendingPathComponent(UUID().uuidString)
    guard mkdir(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
    for url in [root.deletingLastPathComponent(), root, directory] { try Self.syncDirectory(url) }
  }

  func begin(_ id: UUID) throws -> UInt64 {
    guard !failed, active == nil else { throw ControlWireError.invalid("Passive evidence unavailable or prior observation unfinished") }
    // Reserve a full bounded observation BEFORE any STATUS can be submitted.
    guard limits.sessionBytes - sessionBytes >= 64 * 1024,
      limits.retainedBytes - retainedAtStart - sessionBytes >= 64 * 1024 else {
      throw ControlWireError.invalid("Passive status evidence budget full; no query submitted; export/archive retained evidence")
    }
    if file == nil || segmentBytes >= limits.segmentBytes {
      do {
        try file?.synchronize(); try file?.close(); file = nil
        let url = directory.appendingPathComponent(String(format: "observations-%05d.ndjson", segment))
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try segmentDirectoryBarrier(directory) }
        catch { try? opened.close(); throw error }
        // Publish a writable segment only after its creation is durable.
        file = opened; fileURL = url
        segment += 1; segmentBytes = 0
      } catch { failed = true; throw error }
    }
    active = id
    observationBytes = 0
    return UInt64(segmentBytes)
  }
  func append(_ bytes: Data, observation: UUID) throws {
    guard !failed, active == observation, let file,
      observationBytes + bytes.count <= 64 * 1024, sessionBytes + bytes.count <= limits.sessionBytes,
      retainedAtStart + sessionBytes + bytes.count <= limits.retainedBytes else {
      failed = true
      throw ControlWireError.invalid("Passive status evidence budget exhausted or unavailable; original evidence retained")
    }
    do {
      try file.write(contentsOf: bytes); try file.synchronize()
      segmentBytes += bytes.count; sessionBytes += bytes.count
      observationBytes += bytes.count
    } catch { failed = true; throw error }
  }
  func finish(_ id: UUID, offset: UInt64, count: UInt64, expectedSHA256: Data) throws {
    do {
      guard !failed, active == id, count > 0, count <= 1024 * 1024, let fileURL else { throw CocoaError(.fileReadCorruptFile) }
      let input = try FileHandle(forReadingFrom: fileURL)
      defer { try? input.close() }
      try input.seek(toOffset: offset)
      let bytes = try input.read(upToCount: Int(count)) ?? Data()
      guard bytes.count == count, bytes.last == 10, Data(SHA256.hash(data: bytes)) == expectedSHA256 else { throw CocoaError(.fileReadCorruptFile) }
      for line in bytes.split(separator: 10) {
        let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        guard event?["observationID"] as? String == id.uuidString else { throw CocoaError(.fileReadCorruptFile) }
      }
      active = nil
    } catch { failed = true; throw error }
  }
  private static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }
}
