// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Low-rate app diagnostics never run on the receive/preview executor.
actor AlphaSessionRecorder {
  static let shared = AlphaSessionRecorder()
  private var journal: SessionDiagnosticJournal?
  private var sequence: UInt64 = 0
  private var failed: String?
  static var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("RewindDV/AlphaSessions")
  }
  func record(_ snapshot: RewindDVAutomationSnapshot) -> String? {
    if let failed { return failed }
    do {
      try openJournalIfNeeded()
      struct Observation: Encodable { let sequence: UInt64; let uptimeNanoseconds: UInt64; let state: RewindDVAutomationSnapshot }
      let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
      let bytes = try encoder.encode(Observation(sequence: sequence, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, state: snapshot))
      try journal!.append(bytes)
      sequence += 1
      return nil
    } catch {
      failed = "Black box needs attention: \(error.localizedDescription)"
      return failed
    }
  }
  // A start rejection is a single immutable event, retained even if a later
  // start replaces UI state before the next one-second observation.
  func recordReceiveAdmission(_ diagnostic: ReceiveStartDiagnostic) {
    guard failed == nil else { return }
    do {
      try openJournalIfNeeded()
      struct Event: Encodable {
        let event = "receive_start_failed"
        let sequence: UInt64
        let admission: ReceiveStartDiagnostic
      }
      try journal!.append(JSONEncoder().encode(Event(sequence: sequence, admission: diagnostic)))
      sequence += 1
    } catch { failed = "Black box needs attention: \(error.localizedDescription)" }
  }

  private func openJournalIfNeeded() throws {
    if journal == nil {
      let info: [String: String] = ["schema": "rewinddv.alpha-session.v1", "startedUTC": Date().ISO8601Format(),
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "productVersion": ProductIdentity.version, "releaseChannel": ProductIdentity.channel,
        "appBuild": ProductIdentity.appBuild, "driverBuild": ProductIdentity.driverBuild,
        "alpha": Bundle.main.object(forInfoDictionaryKey: "RewindDVAlphaVersion") as? String ?? "development",
        "revision": Bundle.main.object(forInfoDictionaryKey: "RewindDVCandidateRevision") as? String ?? "development",
        "memoryBytes": String(ProcessInfo.processInfo.physicalMemory),
        "architecture": "arm64", "requiredDriver": DriverBuildRequirement.display, "hardwareDisabled": String(RewindDVRuntimeOptions.hardwareDisabled),
        "limitations": "One-second UI observations, five-second sync. Crash/power loss may lose recent samples. Detailed command/receive evidence is in separate flights. No packet payloads here. No automatic upload."]
      journal = try SessionDiagnosticJournal(root: Self.root, metadata: JSONEncoder().encode(info))
    }
  }
  func flush() throws { try journal?.flush() }
}

@MainActor final class AlphaDiagnosticsModel: ObservableObject {
  static let shared = AlphaDiagnosticsModel()
  @Published var warning: String?
  @Published var exporting = false
  @Published var exportStatus = ""
  @Published var notes = ""
  @Published var captureFolder: URL?
  var latestCaptureFolder: URL?
  var latestAccessRoot: URL?

  func chooseCaptureFolder() {
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.prompt = "Include diagnostics"; panel.message = "Choose a capture or WholeTape folder. Only JSON/NDJSON reports are exported, not video."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    captureFolder = url
  }

  func export() {
    guard !exporting else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.prompt = "Save support ZIP here"; panel.message = "Choose where to save. Review the ZIP before sharing: reports can include paths, deck IDs and tape metadata. Nothing is uploaded."
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    exporting = true; exportStatus = "Collecting reports and verifying copied bytes…"
    let chosenCapture = captureFolder ?? latestCaptureFolder
    let accessRoot = captureFolder ?? latestAccessRoot
    let testerNotes = notes + "\nSupplemental session recorder warning: \(warning ?? "none reported")\n"
    Task {
      do {
        var flushNotice = ""
        do { try await AlphaSessionRecorder.shared.flush() }
        catch { flushNotice = "\nSession flush failed during export: \(error.localizedDescription). Available files exported as snapshots.\n" }
        let exportedNotes = testerNotes + flushNotice
        let result = try await Task.detached(priority: .utility) {
          let scopes = [destination, accessRoot].compactMap { $0 }
          let accessed = scopes.filter { $0.startAccessingSecurityScopedResource() }
          defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
          let support = AlphaSessionRecorder.root.deletingLastPathComponent()
          var roots = SupportBundleCollector.applicationRoots(in: support)
          if let chosenCapture { roots.insert(chosenCapture, at: 0) }
          // Stage on the chosen destination, so a full startup disk need not
          // prevent exporting the very evidence needed to diagnose it.
          let stage = destination.appendingPathComponent(".rewindDV-support-stage-" + UUID().uuidString)
          try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
          defer { try? FileManager.default.removeItem(at: stage) }
          let reports = stage.appendingPathComponent("rewindDV-support")
          let manifest = try SupportBundleCollector.collect(roots: roots, into: reports)
          try exportedNotes.data(using: .utf8)!.write(to: reports.appendingPathComponent("Tester notes.txt"))
          let zip = destination.appendingPathComponent("rewindDV-support-" + UUID().uuidString + ".zip")
          let temporaryZip = stage.appendingPathComponent("support.zip")
          let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
          process.arguments = ["-c", "-k", "--keepParent", reports.path, temporaryZip.path]
          let logURL = stage.appendingPathComponent("zip.log")
          FileManager.default.createFile(atPath: logURL.path, contents: nil)
          let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
          process.standardOutput = log; process.standardError = log
          try process.run(); process.waitUntilExit()
          guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
          try FileManager.default.copyItem(at: temporaryZip, to: zip)
          let incomplete = manifest.entries.filter { $0.outcome != "copied snapshot" }.count
          return (zip, incomplete)
        }.value
        exportStatus = "Support ZIP saved. \(result.1) omission/partial/error notices listed in manifest.json. Review before sharing; original captures remain unchanged."
        NSWorkspace.shared.activateFileViewerSelecting([result.0])
      } catch { exportStatus = "Export failed: \(error.localizedDescription). Original evidence is unchanged. Use the included Collect Support command if needed." }
      exporting = false
    }
  }
}

struct AlphaDiagnosticsView: View {
  @ObservedObject private var diagnostics = AlphaDiagnosticsModel.shared
  let captureBusy: Bool
  var body: some View {
    ArchiveSection("Alpha testing · flight recorder") {
      Text(diagnostics.warning ?? "Session observations are recorded automatically. Detailed command and capture flight records are retained separately.")
        .foregroundStyle(diagnostics.warning == nil ? Color.secondary : Color.orange)
      Text("No automatic upload. The support ZIP excludes raw recordings/video, but can contain file paths, deck GUIDs and tape metadata. Keep original capture folders for follow-up.")
        .font(.caption)
      TextField("What happened? Deck/model, adapter chain, steps and approximate time", text: $diagnostics.notes, axis: .vertical)
        .textFieldStyle(.roundedBorder).accessibilityIdentifier("support-notes")
      HStack {
        Button("Include capture folder…") { diagnostics.chooseCaptureFolder() }
        Button("Export support ZIP…") { diagnostics.export() }.buttonStyle(.borderedProminent)
          .accessibilityIdentifier("export-support-zip")
        if diagnostics.exporting { ProgressView().controlSize(.small) }
      }.disabled(captureBusy || diagnostics.exporting)
      if let folder = diagnostics.captureFolder ?? diagnostics.latestCaptureFolder {
        Text("Capture reports: \(folder.lastPathComponent)").font(.caption)
      }
      if captureBusy { Text("Finish capture/verification before exporting to avoid competing with capture storage.").foregroundStyle(.orange) }
      Text(diagnostics.exportStatus).font(.caption).textSelection(.enabled)
    }
  }
}
