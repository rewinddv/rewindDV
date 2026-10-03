// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Local monitor evidence, NOT a finalized archival capture or a native .dv file.
import CryptoKit
import Darwin
import Foundation

struct DurableWriterFaults: Sendable {
  var rawDelayNanoseconds: UInt64 = 0
  var diagnosticDelayNanoseconds: UInt64 = 0
  var failRawWriteNumber: UInt64?
  var failRawSyncNumber: UInt64?
  var failDiagnosticWriteNumber: UInt64?
}

struct RawWriterProgress: Sendable {
  let durableThrough: UInt64
  let retainedRecords: Int
  let pressure: Bool
  let failure: String?
  let idle: Bool
}

/// One ordered raw extent may be flushing while later records coalesce into one
/// pending extent. App copies stay bounded at 8192 records, independently of
/// the larger driver ring. No worker calls back into DriverBridge.
final class LiveReceiveFlight: @unchecked Sendable {
  static let maximumRetainedRecords = 8192
  let directory: URL

  private let raw: FileHandle
  private let journal: FileHandle
  private let rawQueue = DispatchQueue(label: "net.rewinddigital.RewindDV.raw-writer", qos: .userInitiated)
  private let diagnosticQueue = DispatchQueue(label: "net.rewinddigital.RewindDV.receive-diagnostics", qos: .utility)
  private let lock = NSLock()
  private var pending: [LiveReceiveRecord] = []
  private var failedExtent: [LiveReceiveRecord] = []
  private var inFlightRecords = 0
  private var writerRunning = false
  private var acceptingRaw = true
  private var durableThrough: UInt64 = 0
  private var rawFailure: String?
  private var hash = SHA256()
  private var bytes: UInt64 = 0
  private var rawWriteCount: UInt64 = 0
  private var diagnosticWriteCount: UInt64 = 0
  private var queuedDiagnostics = 0
  private var omittedTransportDiagnostics: UInt64 = 0
  private var diagnosticFailureValue: String?
  private let faults: DurableWriterFaults

  init(route: Data, destinationParent: URL? = nil,
       captureFolderKind: CaptureDirectory.Kind = .manual,
       faults: DurableWriterFaults = DurableWriterFaults()) throws {
    self.faults = faults
    let support = destinationParent ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RewindDV/LiveFlights", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination: URL
    if destinationParent != nil {
      destination = try CaptureDirectory.create(parent: support, kind: captureFolderKind)
    } else {
      destination = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
      guard mkdir(destination.path, 0o700) == 0 else {
        throw DriverBridgeError.receiptUnavailable("Live flight directory creation failed")
      }
    }
    directory = destination
    func exclusive(_ name: String) throws -> FileHandle {
      let fd = Darwin.open(destination.appendingPathComponent(name).path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw DriverBridgeError.receiptUnavailable("Live flight file creation failed") }
      return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    raw = try exclusive("receive.records.raw")
    journal = try exclusive("flight.ndjson")
    let directories = destinationParent == nil
      ? [support.deletingLastPathComponent(), support, destination] : [support, destination]
    for url in directories {
      let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw DriverBridgeError.receiptUnavailable("Directory open failed") }
      let result = fsync(fd); Darwin.close(fd)
      guard result == 0 else { throw DriverBridgeError.receiptUnavailable("Directory sync failed") }
    }
    try raw.write(contentsOf: Data("RDRXLOG1".utf8))
    try raw.synchronize()
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    try writeEvent("receive_start_intent", data: route,
                   message: "raw_host_ticks_timebase_numerator=\(timebase.numer); raw_host_ticks_timebase_denominator=\(timebase.denom)", recordBytes: 0,
                   recordHash: SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
  }

  /// Copies are already immutable here. Refusal means the caller must not move
  /// copiedThrough or parse/claim this extent; it remains owned by the ring.
  func enqueue(_ records: [LiveReceiveRecord]) -> Bool {
    guard !records.isEmpty else { return true }
    lock.lock()
    defer { lock.unlock() }
    guard acceptingRaw, rawFailure == nil,
      inFlightRecords + pending.count + records.count <= Self.maximumRetainedRecords else { return false }
    pending.append(contentsOf: records)
    if !writerRunning {
      writerRunning = true
      rawQueue.async { [self] in drainRawQueue() }
    }
    return true
  }

  func progress() -> RawWriterProgress {
    lock.lock(); defer { lock.unlock() }
    let retained = inFlightRecords + pending.count + failedExtent.count
    return RawWriterProgress(durableThrough: durableThrough, retainedRecords: retained,
      pressure: retained >= Self.maximumRetainedRecords, failure: rawFailure,
      idle: !writerRunning && retained == 0)
  }

  /// Stops intake and joins the owned worker even if the awaiting task was
  /// cancelled. Completion reports the immutable durable prefix or failure.
  func joinRaw() async -> RawWriterProgress {
    lock.withLock { acceptingRaw = false }
    return await withCheckedContinuation { continuation in
      rawQueue.async { [self] in continuation.resume(returning: progress()) }
    }
  }

  @discardableResult
  func event(_ name: String, data: Data = Data(), message: String = "",
             transportDiagnostic: Bool = false) -> Bool {
    let observedAt = Date()
    let hostUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    // Optional correlation must leave capacity for required receive evidence.
    // Primary command/STATUS receipts remain separate; omissions are explicit.
    if transportDiagnostic, queuedDiagnostics >= 8 {
      omittedTransportDiagnostics += 1
      lock.unlock()
      return false
    }
    guard diagnosticFailureValue == nil, queuedDiagnostics < 64 else {
      if diagnosticFailureValue == nil { diagnosticFailureValue = "Diagnostic queue capacity exceeded" }
      lock.unlock()
      return false
    }
    queuedDiagnostics += 1
    lock.unlock()
    diagnosticQueue.async { [self] in
      do {
        delay(faults.diagnosticDelayNanoseconds)
        lock.lock()
        if diagnosticFailureValue != nil {
          queuedDiagnostics -= 1
          lock.unlock()
          return
        }
        diagnosticWriteCount += 1
        let number = diagnosticWriteCount
        let eventBytes = bytes
        let eventHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let omitted = omittedTransportDiagnostics
        lock.unlock()
        if faults.failDiagnosticWriteNumber == number { throw CocoaError(.fileWriteUnknown) }
        try writeEvent(name, data: data, message: message,
                       recordBytes: eventBytes, recordHash: eventHash,
                       observedAt: observedAt, hostUptimeNanoseconds: hostUptimeNanoseconds,
                       omittedTransportDiagnostics: omitted)
      } catch {
        lock.lock()
        if diagnosticFailureValue == nil { diagnosticFailureValue = String(describing: error) }
        lock.unlock()
      }
      lock.lock(); queuedDiagnostics -= 1; lock.unlock()
    }
    return true
  }

  var diagnosticFailure: String? {
    lock.lock(); defer { lock.unlock() }
    return diagnosticFailureValue
  }

  func finish(_ message: String) async throws {
    let rawProgress = await joinRaw()
    guard rawProgress.failure == nil, rawProgress.idle else {
      throw DriverBridgeError.receiptUnavailable("Raw writer did not close cleanly")
    }
    try await withCheckedThrowingContinuation { continuation in
      rawQueue.async { [raw] in
        do { try raw.close(); continuation.resume() }
        catch { continuation.resume(throwing: error) }
      }
    }
    guard diagnosticFailure == nil,
      event("receive_closed", message: message + "; hardware continuity unknown; not a finalized archive") else {
      _ = event("receive_closed_incomplete_evidence",
        message: message + "; diagnostic evidence incomplete; raw requires independent verification")
      await joinDiagnostics()
      await closeDiagnostics()
      throw DriverBridgeError.receiptUnavailable("Receive diagnostics incomplete")
    }
    await joinDiagnostics()
    guard diagnosticFailure == nil else {
      await closeDiagnostics()
      throw DriverBridgeError.receiptUnavailable("Receive closing evidence failed")
    }
    await closeDiagnostics()
  }

  private func joinDiagnostics() async {
    await withCheckedContinuation { continuation in
      diagnosticQueue.async { continuation.resume() }
    }
  }

  private func closeDiagnostics() async {
    await withCheckedContinuation { continuation in
      diagnosticQueue.async { [journal] in try? journal.close(); continuation.resume() }
    }
  }

  private func drainRawQueue() {
    while true {
      lock.lock()
      if rawFailure != nil || pending.isEmpty {
        writerRunning = false
        lock.unlock()
        return
      }
      let records = pending
      pending.removeAll(keepingCapacity: true)
      inFlightRecords = records.count
      lock.unlock()

      do {
        delay(faults.rawDelayNanoseconds)
        lock.lock(); rawWriteCount += 1; let number = rawWriteCount; lock.unlock()
        if faults.failRawWriteNumber == number { throw CocoaError(.fileWriteUnknown) }
        var batch = Data()
        batch.reserveCapacity(records.reduce(0) { $0 + $1.header.count + $1.payload.count })
        for record in records { batch.append(record.header); batch.append(record.payload) }
        try raw.write(contentsOf: batch)
        // Tests distinguish a write failure from bytes written but not proved
        // durable. Neither may advance the hash/checkpoint or driver ACK.
        if faults.failRawSyncNumber == number { throw CocoaError(.fileWriteUnknown) }
        try raw.synchronize()
        lock.lock()
        hash.update(data: batch)
        bytes += UInt64(batch.count)
        durableThrough = records.last!.sequence
        inFlightRecords = 0
        lock.unlock()
      } catch {
        lock.lock()
        rawFailure = String(describing: error)
        failedExtent = records
        inFlightRecords = 0
        writerRunning = false
        lock.unlock()
        // Best effort only: a failed destination may also reject this journal
        // entry. Earlier post-sync checkpoints remain usable independently.
        _ = event("receive_raw_writer_failed", message: "Raw persistence uncertain; no ACK/retry. Physical tape STOP may be required.")
        return
      }
    }
  }

  private func writeEvent(_ name: String, data: Data, message: String,
                          recordBytes: UInt64, recordHash: String,
                          observedAt: Date = Date(),
                          hostUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
                          omittedTransportDiagnostics: UInt64 = 0) throws {
    let event = Event(event: name, utc: ISO8601DateFormatter().string(from: Date()),
      wireBase64: data.base64EncodedString(), message: message, recordBytes: recordBytes,
      recordSHA256: recordHash,
      observedUTC: ISO8601DateFormatter().string(from: observedAt),
      hostUptimeNanoseconds: hostUptimeNanoseconds,
      omittedTransportDiagnostics: omittedTransportDiagnostics)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try journal.write(contentsOf: try encoder.encode(event) + Data([10]))
    try journal.synchronize()
  }

  private func delay(_ nanoseconds: UInt64) {
    guard nanoseconds != 0 else { return }
    var request = timespec(tv_sec: Int(nanoseconds / 1_000_000_000),
                           tv_nsec: Int(nanoseconds % 1_000_000_000))
    var remaining = timespec()
    while nanosleep(&request, &remaining) == -1 && errno == EINTR { request = remaining }
  }

  private struct Event: Encodable {
    let schemaVersion = 1
    let event: String
    let utc: String
    let wireBase64: String
    let message: String
    let recordBytes: UInt64
    let recordSHA256: String
    // Observation time precedes asynchronous diagnostic writes. The existing
    // recordBytes/hash cursor still describes persistence at write time.
    let observedUTC: String
    let hostUptimeNanoseconds: UInt64
    let omittedTransportDiagnostics: UInt64
  }
}
