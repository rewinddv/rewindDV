// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A local, read-only observation channel for development and UI automation.
/// It contains presentation state only and can never submit a driver, deck,
/// receive, archive, activation, or file-selection operation.
struct RewindDVAutomationSnapshot: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let generatedAt: Date
  let build: String
  let page: String
  let monitorSource: String
  let driverState: String
  let driverReady: Bool
  let selectedDeckName: String?
  let selectedDeckGUID: String?
  let handshake: String
  let modelBusy: Bool
  let controlLockedOut: Bool
  let stopNeedsSupervision: Bool
  let liveActive: Bool
  let liveBusy: Bool
  let ingestRequested: Bool
  let liveStatus: String
  let packetsSeen: UInt64
  let completeFrames: UInt64
  let captureElapsed: String?
  let captureElapsedRunning: Bool
  let captureElapsedSystem: String
  let playbackState: String
  let playbackSourceName: String?
  let wholeTapeActive: Bool
  let wholeTapeStatus: String
  var alphaDiagnostics: [String: String] = [:]
}

enum RewindDVAutomationStatus {
  private static let writer = RewindDVAutomationStatusWriter()

  static var enabled: Bool {
    ProcessInfo.processInfo.arguments.contains("--automation-status")
      || ProcessInfo.processInfo.environment["REWINDDV_AUTOMATION_STATUS"] == "1"
  }

  static var destination: URL {
    if let supplied = ProcessInfo.processInfo.environment["REWINDDV_AUTOMATION_STATUS_PATH"],
      supplied.hasPrefix("/") {
      return URL(fileURLWithPath: supplied).standardizedFileURL
    }
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("RewindDV/Automation/current-status.json")
  }

  @MainActor
  static func recordWhileVisible(
    snapshot: @escaping @MainActor () -> RewindDVAutomationSnapshot
  ) async {
    while !Task.isCancelled {
      let value = snapshot()
      let warning = await AlphaSessionRecorder.shared.record(value)
      if AlphaDiagnosticsModel.shared.warning != warning {
        AlphaDiagnosticsModel.shared.warning = warning
      }
      if enabled { try? await writer.write(value, to: destination) }
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
    }
  }
}

enum RewindDVRuntimeOptions {
  /// Safe UI-development mode: the app renders normally but never opens the
  /// driver user client or begins automatic device discovery.
  static let hardwareDisabled = Bundle.main.object(forInfoDictionaryKey: "RewindDVOfflineOnly") as? Bool == true
    || ProcessInfo.processInfo.arguments.contains("--ui-automation-no-driver")
}

private actor RewindDVAutomationStatusWriter {
  func write(_ snapshot: RewindDVAutomationSnapshot, to url: URL) throws {
    let manager = FileManager.default
    let parent = url.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(snapshot).write(to: url, options: .atomic)
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
