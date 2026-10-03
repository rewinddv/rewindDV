// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

@MainActor private final class DVFilmModel: ObservableObject {
  @Published var scan: DVFilmScan?
  @Published var busy = false
  @Published var message = "Analyze DVX100A/B recording modes and cadence."
  @Published var progress: Double?
  @Published var output: URL?
  @Published var mode: DVFilmMode = .ntsc60i
  @Published var aspect: DVFilmDisplayAspect = .decoder
  @Published var reviewed = false
  @Published var cyclePictures: [NSImage] = []
  @Published var first = "0"
  @Published var count = "0"
  private var task: Task<Void, Never>?
  private var generation = UUID()

  func analyze(_ source: URL?) {
    task?.cancel(); generation = UUID(); scan = nil; output = nil; progress = nil
    reviewed = false
    cyclePictures = []
    guard let source else { busy = false; return }
    let id = generation, lease = DVFilmLease(source)
    busy = true; message = "Reading recording-mode evidence across the complete file…"
    task = Task {
      let worker = Task.detached(priority: .utility) {
        defer { withExtendedLifetime(lease) {} }
        return try DVFilmScan.scan(url: source)
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard generation == id else { return }
        scan = result; first = "0"; count = String(result.frameCount)
        if result.systems == ["625/50 PAL"] { mode = .pal50i }
        else { mode = .ntsc60i }
        message = "Analysis complete. Suggestions describe metadata patterns; review the recording mode and cycle origin before creating a progressive copy."
      } catch {
        guard generation == id else { return }
        message = error is CancellationError ? "Analysis cancelled." : error.localizedDescription
      }
      busy = false
    }
  }
  func cancel() { task?.cancel() }
  func invalidateReview() { reviewed = false; cyclePictures = [] }
  func preview(_ source: URL?) {
    guard let source, let plan, !busy else { return }
    busy = true; reviewed = false; cyclePictures = []
    let id = generation, lease = DVFilmLease(source)
    task = Task {
      let worker = Task.detached(priority: .utility) {
        defer { withExtendedLifetime(lease) {} }
        return try await DVFilmExporter.previewCycle(source: source, plan: plan)
      }
      do {
        let pictures = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard id == generation else { return }
        cyclePictures = pictures.compactMap(NSImage.init(data:))
        message = "First reconstructed pictures shown below. Inspect moving subjects for mixed fields; thumbnails alone cannot prove cadence throughout a clip."
      } catch {
        guard id == generation else { return }
        message = error.localizedDescription
      }
      busy = false
    }
  }
  var plan: DVFilmPlan? {
    guard let scan, let start = UInt64(first), let count = UInt64(count),
      start <= scan.frameCount, count <= scan.frameCount - start,
      scan.systems == [mode.isPAL ? "625/50 PAL" : "525/60 NTSC"] else { return nil }
    return try? DVFilmPlan(mode: mode, firstSourceFrame: start, sourceFrameCount: count, sourceSHA256: scan.sourceSHA256, displayAspect: aspect)
  }
  func export(_ source: URL, parent: URL) {
    guard !busy, reviewed, let plan else { return }
    let id = generation, leases = [DVFilmLease(source), DVFilmLease(parent)]
    let destination = parent.appendingPathComponent("RewindDV-Progressive-\(UUID().uuidString)")
    busy = true; progress = 0; output = nil
    message = "Verifying source and creating the progressive derivative…"
    task = Task { [self] in
      let worker = Task.detached(priority: .utility) { [self] in
        defer { withExtendedLifetime(leases) {} }
        return try await DVFilmExporter.export(source: source, plan: plan, destination: destination) { fraction in
          Task { @MainActor [weak self] in
            guard let self, self.generation == id else { return }
            self.progress = fraction
          }
        }
      }
      do {
        let receipt = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard generation == id else { return }
        output = destination
        message = "Progressive copy complete: \(receipt.outputVideoFrames.formatted()) frames, original audio timing, frame/field provenance included."
      } catch {
        guard generation == id else { return }
        message = "Export incomplete: \(error.localizedDescription). Any partial files are retained at \(destination.path)."
      }
      busy = false; progress = nil
    }
  }
}

private final class DVFilmLease: @unchecked Sendable {
  let url: URL
  let active: Bool
  init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
  deinit { if active { url.stopAccessingSecurityScopedResource() } }
}

struct DVFilmView: View {
  let source: URL?
  let interactionLocked: Bool
  @StateObject private var model = DVFilmModel()
  var body: some View {
    ArchiveDisclosure("DVX100A / DVX100B · recording mode and progressive copies") {
      VStack(alignment: .leading, spacing: 10) {
        Text("NTSC: 60i, 30P, 24P and 24PA. PAL: 50i and 25P. The playback deck does not identify the recording camera.")
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("Analyze recording modes") { model.analyze(source) }.disabled(source == nil || model.busy || interactionLocked)
          if model.busy {
            if let progress = model.progress { ProgressView(value: progress).frame(width: 160) }
            else { ProgressView().controlSize(.small) }
            Button("Cancel") { model.cancel() }
          }
        }
        Text(model.message).font(.callout).textSelection(.enabled)
        if let scan = model.scan {
          row("Stored DV", scan.systems.joined(separator: ", ") + " · \(scan.frameCount.formatted()) frames")
          row("Source identity", scan.sourceSHA256).font(.caption.monospaced())
          row("Source status", "\(scan.sourceDamageFrames) frames with video status flags; \(scan.unqualifiedMetadataFrames) frames without qualified scan-type metadata")
          ArchiveDisclosure("Cadence observations and recording boundaries (\(scan.segmentCount))") {
            ForEach(scan.segments.prefix(200)) { segment in
              VStack(alignment: .leading, spacing: 3) {
                row("Frames \(segment.firstFrame)…\(segment.endFrameExclusive - 1)", segment.candidate?.label ?? "Unresolved cadence")
                if let a = segment.candidateAFrame { row("Candidate A frame", String(a)) }
                if !segment.reasons.isEmpty { Text(segment.reasons.joined(separator: "; ")).foregroundStyle(.red).font(.caption) }
              }
            }
            if scan.segmentCount > 200 { Text("Showing the first 200 segments; command-line cadence output provides every frame observation.").font(.caption) }
          }
          Divider()
          Picker("Recorded mode", selection: $model.mode) {
            ForEach(DVFilmMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
          }.disabled(model.busy || interactionLocked)
          Picker("Display aspect", selection: $model.aspect) {
            ForEach(DVFilmDisplayAspect.allCases, id: \.self) { aspect in Text(aspect.label).tag(aspect) }
          }.disabled(model.busy || interactionLocked)
          HStack {
            TextField("First source frame (0-based)", text: $model.first).frame(width: 210)
            TextField("Source frame count", text: $model.count).frame(width: 160)
          }.textFieldStyle(.roundedBorder).disabled(model.busy || interactionLocked)
          if model.mode.isFilm {
            Text("Start on the reviewed A frame and select a multiple of 5 source frames. 24P reconstructs fields; 24PA omits the mixed BC picture from each cycle. Audio from all five frames stays on its original clock.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let plan = model.plan {
            row("Progressive copy", "\(plan.outputFrameCount.formatted()) pictures · \(String(format: "%.3f", Double(plan.durationTicks) / 120_000)) seconds")
          } else { Text("Choose a range and mode matching this file; 24P/24PA requires complete five-frame cycles.").foregroundStyle(.red).font(.caption) }
          Button("Preview first reconstructed pictures") { model.preview(source) }
            .disabled(model.plan == nil || !model.mode.isProgressive || model.busy || interactionLocked)
          if !model.cyclePictures.isEmpty {
            HStack(alignment: .top) {
              ForEach(model.cyclePictures.indices, id: \.self) { index in
                VStack {
                  Image(nsImage: model.cyclePictures[index]).resizable().scaledToFit()
                  Text("Picture \(index + 1)").font(.caption)
                }
              }
            }
            Text("Display-only RGB thumbnails show the unscaled raster. The ProRes writer uses native YCbCr, not these thumbnails.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Toggle("I reviewed the recording mode, A-frame origin, range and display aspect against the source pictures", isOn: $model.reviewed)
            .disabled(model.busy || interactionLocked)
          Button("Create progressive copy…", systemImage: "film") { export() }
            .disabled(model.plan == nil || !model.mode.isProgressive || !model.reviewed || model.busy || interactionLocked)
          Text("Creates Apple ProRes 422 HQ with PCM audio and a frame/field map. Your selected interpretation is recorded in its provenance. Keep the original DV as the preservation master. Mixed recording modes should be exported as separate reviewed ranges.")
            .font(.caption).foregroundStyle(.secondary)
          if let output = model.output {
            Button("Show progressive copy", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
          }
        }
      }.padding(.vertical, 8)
    }
    .onChange(of: source) { _, _ in model.analyze(nil) }
    .onChange(of: model.mode) { _, _ in model.invalidateReview() }
    .onChange(of: model.aspect) { _, _ in model.invalidateReview() }
    .onChange(of: model.first) { _, _ in model.invalidateReview() }
    .onChange(of: model.count) { _, _ in model.invalidateReview() }
    .onDisappear { model.cancel() }
  }
  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label.uppercased()).bold().foregroundStyle(.yellow)
      Text(value).foregroundStyle(.white).textSelection(.enabled)
    }
  }
  private func export() {
    guard let source else { return }
    let panel = NSOpenPanel(); panel.title = "Choose a folder for the progressive copy"
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { model.export(source, parent: url) }
  }
}
