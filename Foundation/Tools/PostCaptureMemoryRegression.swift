// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// OFFLINE ONLY: synthetic raw evidence, production exporter and (optionally) real
// LiveMonitorModel finalization with a fake bridge. Never links the real bridge.
import Foundation
import CryptoKit
import Darwin
#if MEMORY_APP_HARNESS
import AppKit
import Combine
#endif

private func put<T: FixedWidthInteger>(_ value: T, _ data: inout Data, _ offset: Int) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}
private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
  digest.map { String(format: "%02x", $0) }.joined()
}
private func routeBytes() -> Data {
  var route = Data(repeating: 0, count: 48)
  put(UInt32(1), &route, 0); put(UInt32(48), &route, 4)
  for offset in [8, 16, 24, 32] { put(UInt64(offset), &route, offset) }
  put(UInt32(1), &route, 40); put(UInt16(7), &route, 44)
  return route
}

// Generate a frame at a time. Video payload is deterministic pseudorandom data,
// not sparse/zero-filled; only DIF structure and metadata headers are synthetic.
private func frame(_ ordinal: UInt64) -> Data {
  var result = Data(), random = ordinal &+ 0x123456789abcdef
  for sequence in 0..<12 {
    func block(_ section: UInt8, _ number: Int) -> Data {
      var bytes = Data(repeating: 0xff, count: 80)
      bytes[0] = section << 5 | 0x1f; bytes[1] = UInt8(sequence << 4) | 7; bytes[2] = UInt8(number)
      if section == 0 { bytes[3] = 0x80; for index in 4...7 { bytes[index] = 0 } }
      if section == 3 { bytes.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, 0]) }
      if section == 4 {
        for index in 3..<80 {
          random ^= random << 13; random ^= random >> 7; random ^= random << 17
          bytes[index] = UInt8(truncatingIfNeeded: random)
        }
      }
      return bytes
    }
    result.append(block(0, 0))
    for index in 0..<2 { result.append(block(1, index)) }
    for index in 0..<3 { result.append(block(2, index)) }
    for group in 0..<9 {
      result.append(block(3, group))
      for index in group * 15..<(group + 1) * 15 { result.append(block(4, index)) }
    }
  }
  return result
}

private func generate(_ directory: URL, mebibytes: UInt64) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  let rawURL = directory.appendingPathComponent("receive.records.raw")
  let fd = open(rawURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  defer { try? handle.close() }
  try handle.write(contentsOf: Data("RDRXLOG1".utf8))
  var rawHash = SHA256(), dvHash = SHA256(), bytes: UInt64 = 0, records: UInt64 = 0, frames: UInt64 = 0
  while bytes < mebibytes * 1_048_576 {
    try autoreleasepool {
      let data = frame(frames)
      dvHash.update(data: data)
      for offset in stride(from: 0, to: data.count, by: 480 * 7) {
        var packet = Data([0, 0, 0, 0, 0, 0, 0, 0, 7, 120, 0,
          UInt8(truncatingIfNeeded: offset / 480), 0x80, 0, 0xff, 0xff])
        packet.append(data[offset..<min(data.count, offset + 480 * 7)])
        records += 1
        var header = Data(repeating: 0, count: 64)
        put(records, &header, 0); put(UInt64(1), &header, 8); put(records * 100, &header, 16)
        put(UInt16(0x11), &header, 32); put(UInt32(packet.count), &header, 36)
        put(records, &header, 40); put(UInt32(1), &header, 56)
        try handle.write(contentsOf: header); try handle.write(contentsOf: packet)
        rawHash.update(data: header); rawHash.update(data: packet)
        bytes += UInt64(header.count + packet.count)
      }
      frames += 1
    }
  }
  try handle.synchronize()
  let route = routeBytes()
  var status = Data(repeating: 0, count: 128)
  put(UInt32(0x58524452), &status, 0); put(UInt16(1), &status, 4); put(UInt16(256), &status, 6)
  put(UInt32(4160), &status, 8); put(UInt32(8192), &status, 12); put(UInt64(1), &status, 16)
  status.replaceSubrange(24..<72, with: route); put(UInt32(2), &status, 80)
  for offset in [88, 96, 120] { put(records, &status, offset) }
  let digest = hex(rawHash.finalize())
  func event(_ name: String, _ wire: Data) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "event": name,
      "wireBase64": wire.base64EncodedString(), "recordBytes": bytes, "recordSHA256": digest],
      options: [.sortedKeys]) + Data([10])
  }
  let journal = try event("receive_start_intent", route) + event("receive_final_status", status) + event("receive_closed", Data())
  try journal.write(to: directory.appendingPathComponent("flight.ndjson"), options: .withoutOverwriting)
  let expected: [String: Any] = ["rawRecordBytes": bytes, "rawRecordCount": records,
    "completeDVFrames": frames, "dvBytes": frames * 144_000,
    "rawRecordSHA256": digest, "nativeDVSHA256": hex(dvHash.finalize())]
  try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .prettyPrinted])
    .write(to: directory.appendingPathComponent("synthetic-expected.json"), options: .withoutOverwriting)
}

// Constant-space measurement: stream JSON lines, retain only the current phase
// and maxima. Safety limits cover this disposable process, never the live app.
private final class Meter: @unchecked Sendable {
  private let lock = NSLock()
  private let start = Date()
  private let output: FileHandle
  private let scratch: String
  private let ceiling: UInt64
  private var phase = "startup", bytes: UInt64 = 0, job = 0
  private var peak: UInt64 = 0, residentPeak: UInt64 = 0
  private var phaseBytes: [String: UInt64] = [:]
  private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "memory.guard"))
  init(log: String, scratch: String, ceiling: UInt64) throws {
    let fd = open(log, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
    output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    self.scratch = scratch; self.ceiling = ceiling
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.sample("timer") }
    timer.resume()
  }
  func set(_ phase: String, bytes: UInt64 = 0, job: Int? = nil) {
    lock.withLock { self.phase = phase; self.bytes = bytes; if let job { self.job = job; phaseBytes.removeAll(keepingCapacity: true) } }
    sample("phase")
  }
  func progress(_ progress: DVIngestProgress) {
    let changed = lock.withLock { () -> Bool in
      let next = progress.phase.rawValue
      precondition(progress.completedBytes >= phaseBytes[next, default: 0], "Phase progress regressed")
      phaseBytes[next] = progress.completedBytes
      let changed = next != phase || progress.completedBytes / 67_108_864 != bytes / 67_108_864
      phase = next; bytes = progress.completedBytes
      return changed
    }
    if changed { sample("progress") }
  }
  func verifyDeliveredProgress() {
    lock.withLock {
      precondition(phaseBytes[DVIngestProgressPhase.reconstructingNativeDV.rawValue] != nil)
      precondition(phaseBytes[DVIngestProgressPhase.rereadingRawEvidence.rawValue] != nil)
      precondition(phaseBytes[DVIngestProgressPhase.complete.rawValue] != nil)
    }
  }
  func sample(_ reason: String) {
    autoreleasepool {
      lock.withLock {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
          }
        }
        guard result == KERN_SUCCESS else { exit(91) }
        peak = max(peak, info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))); residentPeak = max(residentPeak, info.resident_size)
        var pressure: Int32 = 0, pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        var filesystem = statfs()
        let diskResult = statfs(scratch, &filesystem)
        let free = UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize)
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let elapsed = Date().timeIntervalSince(start)
        let breach = peak > ceiling || elapsed > 1_800 ||
          pressureResult != 0 || pressure != 1 || diskResult != 0 || free < 8_589_934_592
        let row: [String: Any] = ["reason": reason, "phase": phase, "job": job,
          "processedBytes": bytes, "elapsedSeconds": elapsed, "footprintBytes": info.phys_footprint,
          "residentBytes": info.resident_size, "peakFootprintBytes": peak, "peakResidentBytes": residentPeak,
          "pressureLevel": pressure, "scratchFreeBytes": free,
          "systemSwapUsedBytes": swapResult == 0 ? swap.xsu_used : 0, "guardrailBreach": breach]
        do {
          try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
          if breach { try output.synchronize(); exit(90) }
        } catch { exit(92) }
      }
    }
  }
  func finish() { sample("finished"); timer.cancel(); try? output.synchronize() }
}

#if MEMORY_APP_HARNESS
struct LiveReceiveStatus: Sendable {
  var state: UInt32 = 1
  let lastStatus: Int32 = 0
  // This bridge receives no new packets; it finalizes separately generated evidence.
  let writeSequence: UInt64 = 0, acknowledged: UInt64 = 0
  let packetsSeen: UInt64 = 0, dropped: UInt64 = 0, oversized: UInt64 = 0
}
struct LivePersistenceHealth: Sendable {
  let pendingRecords = 0, durableThrough: UInt64 = 0
  let writerPressure = false
  let diagnosticFailure: String? = nil
}
actor DriverBridge {
  let directory: URL
  private var terminal = false
  func finishReceive() { terminal = true }
  init(_ directory: URL) { self.directory = directory }
  func beginLiveReceive(_ deck: DiscoveredDeck, destinationParent: URL?,
    captureFolderKind: CaptureDirectory.Kind = .manual, expectedRoute: FoundationRoute?,
    existingStopObligation: Bool? = nil) async throws -> URL { directory }
  func readLiveBatch() -> LiveReceiveBatch {
    .init(status: .init(state: terminal ? 2 : 1), frames: [], drained: true, rejectedPackets: 0,
      assembledFrames: 0, discontinuities: 0, incompleteFrames: 0)
  }
  func livePersistenceHealth() -> LivePersistenceHealth { .init() }
  func receivedMediaFormats() -> ReceiveMediaFormatEvidence { .init() }
  func recordMonitorDiagnostics(_ message: String) throws {}
  func inspectDevice(_ deck: DiscoveredDeck, transportOnly: Bool, expectedRoute: FoundationRoute?) throws -> DeviceInspectionReport {
    throw ControlWireError.invalid("Offline memory harness must not inspect or operate a deck")
  }
  func endLiveReceive() -> LivePreservedFrame? { nil }
  func completedReceiveStatistics() -> LiveReceiveBatch? { nil }
  func receiveRequiresLockout() -> Bool { false }
}
#endif

@main struct PostCaptureMemoryRegression {
  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    guard args.count >= 5 else {
      fatalError("Usage: executable generate|export|app|app-stop LOG CEILING_MIB DIRECTORY [MIB for generate, or additional directories]")
    }
    let directory = URL(fileURLWithPath: args[4], isDirectory: true)
    let meter = try Meter(log: args[2], scratch: directory.deletingLastPathComponent().path,
      ceiling: UInt64(args[3])! * 1_048_576)
    defer { meter.finish() }
    if args[1] == "generate" {
      meter.set("generating")
      try await Task.detached { try generate(directory, mebibytes: UInt64(args[5])!) }.value
    } else {
      #if MEMORY_APP_HARNESS
      _ = NSApplication.shared
      let live = LiveMonitorModel(muteAudio: true)
      #endif
      for (index, path) in args.dropFirst(4).enumerated() {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        meter.set("beforeJob", job: index + 1)
        let result: DVIngestVerification
        if args[1] == "app" || args[1] == "app-stop" {
          #if MEMORY_APP_HARNESS
          let subscription = live.$verificationProgress.sink { if let update = $0 { meter.progress(update) } }
          let bridge = DriverBridge(url)
          let route = try FoundationRoute(data: routeBytes())
          let deck = DiscoveredDeck(guid: 1, generation: 1, node: 7, state: 1, vendor: "Synthetic", model: "Offline")
          live.start(bridge: bridge, deck: deck, ingestParent: url.deletingLastPathComponent(), expectedRoute: route)
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          while !live.receiverReady {
            precondition(ContinuousClock.now < deadline, "Fake receive did not start")
            try await Task.sleep(for: .milliseconds(10))
          }
          if args[1] == "app-stop" {
            // Retain coverage of the existing cancelled receive-task stop path.
            await live.stopAndWait()
          } else {
            await bridge.finishReceive()
            // Join by observing completion, without cancelling the real task's
            // bounded progress stream. No synthetic exporter replaces it.
            while live.verification == nil && (live.active || live.hasReceiveSession || live.busy) {
              try await Task.sleep(for: .milliseconds(10))
            }
            meter.verifyDeliveredProgress()
          }
          precondition(!live.active && !live.busy && live.verificationProgress == nil)
          guard let verification = live.verification else { fatalError(live.ingestDetail) }
          precondition(live.verifiedCaptureURL == url.appendingPathComponent("capture.dv"))
          result = verification
          subscription.cancel()
          #else
          fatalError("Compile with MEMORY_APP_HARNESS and the production app sources")
          #endif
        } else {
          precondition(args[1] == "export")
          result = try await Task.detached(priority: .utility) {
            try DVIngestExporter.exportClosedFlight(at: url) { meter.progress($0) }
          }.value
        }
        precondition(result.integritySHA256Verified && result.nativeDVRereadVerified && result.finalAcknowledgementConfirmed)
        let expected = url.appendingPathComponent("synthetic-expected.json")
        if FileManager.default.fileExists(atPath: expected.path) {
          let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: expected)) as! [String: Any]
          precondition(result.nativeDVSHA256 == fields["nativeDVSHA256"] as? String)
          precondition(result.rawRecordSHA256 == fields["rawRecordSHA256"] as? String)
          precondition(result.completeDVFrames == (fields["completeDVFrames"] as! NSNumber).uint64Value)
          precondition(result.rawRecordCount == (fields["rawRecordCount"] as! NSNumber).uint64Value)
        }
        meter.set("afterJob", bytes: result.rawRecordBytes)
        print("PASS job=\(index + 1) rawBytes=\(result.rawRecordBytes) frames=\(result.completeDVFrames) nativeSHA256=\(result.nativeDVSHA256 ?? "none")")
      }
    }
  }
}
