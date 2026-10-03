// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class DVPackMetadataModel: ObservableObject {
  @Published private(set) var source: URL?
  @Published private(set) var report: DVPackSemanticReport?
  @Published private(set) var busy = false
  @Published private(set) var message = "Inspect recorded metadata without changing the original DV file."
  private var task: Task<Void, Never>?

  func read(source: URL, ordinal: UInt64) {
    guard !busy else { return }
    let access = source.startAccessingSecurityScopedResource()
    self.source = source
    report = nil
    busy = true
    message = "Reading frame \(ordinal)…"
    task = Task {
      defer {
        if access { source.stopAccessingSecurityScopedResource() }
        busy = false
        task = nil
      }
      let worker = Task.detached(priority: .utility) {
        DVPackSemanticReport.inspect(try DVMetadataFrameReader.read(url: source, ordinal: ordinal))
      }
      do {
        let value = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        report = value
        message = "Recorded metadata, not independently verified camera settings or tape position."
      } catch is CancellationError {
        message = "Inspection cancelled. Original DV is unchanged."
      } catch {
        message = "Inspection unavailable: \(error.localizedDescription)"
      }
    }
  }
  func cancel() { task?.cancel() }
}

struct DVPackMetadataView: View {
  @ObservedObject var archiveModel: RewindDVModel
  let interactionLocked: Bool
  @StateObject private var model = DVPackMetadataModel()
  @State private var frameNumber = "0"

  var body: some View {
    ArchiveSection("Native DV metadata") {
      VStack(alignment: .leading, spacing: 12) {
        Text("One source-bound result: complete-file facts, audio-rate epochs, and human-readable metadata for the selected frame.")
          .foregroundStyle(.secondary)
        HStack {
          Button("Choose Native DV…", systemImage: "doc.text.magnifyingglass") { choose() }
            .disabled(model.busy || interactionLocked)
          TextField("Frame (starts at 0)", text: $frameNumber)
            .textFieldStyle(.roundedBorder).frame(width: 155)
            .disabled(model.busy || interactionLocked)
          Button("Read frame") {
            if let source = model.source, let ordinal = UInt64(frameNumber) {
              model.read(source: source, ordinal: ordinal)
            }
          }.disabled(model.busy || interactionLocked || model.source == nil || UInt64(frameNumber) == nil)
          if model.busy {
            ProgressView().controlSize(.small)
            Button("Cancel") { model.cancel() }
          }
        }
        if let source = archiveModel.metadataSource ?? model.source {
          Text(source.path).font(.caption).textSelection(.enabled)
        }
        if archiveModel.isBusy, archiveModel.metadataSource != nil {
          HStack {
            ProgressView().controlSize(.small)
            Text("Analyzing complete-file metadata…").foregroundStyle(.secondary)
          }
        }
        if let manifest = archiveModel.metadata {
          ArchiveDisclosure("Complete-file summary") {
          metadataRow("Source bytes", value: manifest.sourceByteCount.formatted())
          metadataRow("Complete frames", value: manifest.completeFrameCount.formatted())
          metadataRow("Source SHA-256", value: manifest.sourceSHA256)
            .font(.caption.monospaced())
          }
          Divider()
          ArchiveDisclosure("Audio-rate epochs") {
          ForEach(manifest.audioSampleRateEpochs, id: \.epochOrdinal) { epoch in
            metadataRow(
              "Epoch \(epoch.epochOrdinal + 1)",
              value: epoch.classification.rawValue.replacingOccurrences(of: "_", with: " ")
                + " · frames \(epoch.firstSourceFrameOrdinal)…\(epoch.lastSourceFrameOrdinal)")
              .font(.callout.monospacedDigit())
          }
          Text("32 kHz, 44.1 kHz, and 48 kHz remain separate observations. Unknown, absent, malformed, and conflicting epochs never inherit a default rate.")
            .font(.caption).foregroundStyle(.secondary)
          }
          Divider()
        }
        DVFilmView(source: archiveModel.metadataSource ?? model.source, interactionLocked: interactionLocked)
        Text(model.message).foregroundStyle(.secondary)
        if let report = model.report {
          ArchiveDisclosure("Selected-frame metadata") {
          DVMetadataInspector(report: report)
          }
        }
        Text("IEC and SMPTE fields are interpreted separately. Reserved, unavailable and unknown codes are retained. No tape commands are sent.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }.onDisappear { model.cancel() }
  }

  /// One visual grammar for every metadata name/value pair. Styling is kept
  /// here, not in the decoded strings or the preserved evidence.
  private func metadataRow(_ name: String, value: String, valueColor: Color = .white) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(name.uppercased())
        .fontWeight(.bold)
        .foregroundStyle(.yellow)
        .fixedSize(horizontal: false, vertical: true)
      Text(value)
        .fontWeight(.regular)
        .foregroundStyle(valueColor)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.title = "Choose native DV to inspect recorded metadata"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    if let dvType = UTType(filenameExtension: "dv") {
      panel.allowedContentTypes = [dvType]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    frameNumber = "0"
    model.read(source: url, ordinal: 0)
    archiveModel.analyzeNativeDV(url)
  }
}
