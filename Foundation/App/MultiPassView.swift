// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import CoreImage

@MainActor final class MultiPassModel: ObservableObject {
  @Published private(set) var bindings: [DVMultiPass.Binding] = []
  @Published private(set) var plan: DVMultiPass.Plan?
  @Published private(set) var busy = false
  @Published private(set) var progress: Double?
  @Published private(set) var message = "Select a verified base map, then add donor maps and their original DV files. No tape commands."
  @Published private(set) var output: URL?
  @Published private(set) var inspected: DVMultiPass.Candidate?
  @Published private(set) var originalImage: NSImage?
  @Published private(set) var donorImage: NSImage?
  @Published private(set) var inspectionMessage = ""
  private var inputs: [DVMultiPass.Input] = []
  private var access: [URL] = []
  private var task: Task<Void, Never>?
  private var inspection: Task<Void, Never>?
  private var inspectionID = UUID()
  private var operationID = UUID()
  private var clearWhenIdle = false
  private let decoder = LiveDVFrameDecoder()
  func reset(base: DVMultiPass.Input? = nil) {
    guard !busy else {
      if base == nil { clearWhenIdle = true; cancel() }
      return
    }
    clearWhenIdle = false
    inspection?.cancel(); inspectionID = UUID()
    operationID = UUID()
    inspected = nil; originalImage = nil; donorImage = nil
    inputs = base.map { [$0] } ?? []; bindings = inputs.map(\.binding)
    plan = nil; output = nil; progress = nil
    for url in access { url.stopAccessingSecurityScopedResource() }; access = []
    message = base == nil ? "Choose and verify a base DV/map first." : "Base selected. Add separately captured donor passes; selecting a file does not prove it is the same tape."
  }
  private func finishWork() {
    busy = false; progress = nil; task = nil
    if clearWhenIdle { reset() }
  }
  func add(mapURL: URL, sourceURL: URL) {
    guard !busy, !inputs.isEmpty, inputs.count < DVMultiPass.maximumInputs else { return }
    busy = true; plan = nil; output = nil
    let grants = [mapURL,sourceURL].filter { $0.startAccessingSecurityScopedResource() }
    task = Task {
      defer { finishWork() }
      let worker = Task.detached(priority: .utility) {
        let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
        let source = try DVVerifiedFrameSource(url: sourceURL, snapshot: map.binding.mapReceipt.sourceSnapshot)
        return DVMultiPass.Input(map: map, source: source)
      }
      do {
        message = "Verifying donor map and whole-file SHA-256…"
        let input = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard input.binding.source.videoSystem == bindings[0].source.videoSystem,
          input.binding.source.frameByteCount == bindings[0].source.frameByteCount else { throw DVMultiPass.error("donor video system differs from base") }
        inputs.append(input); bindings = inputs.map(\.binding); access += grants
        message = "\(inputs.count) passes loaded and verified. Compare their original bytes before making any merge choice."
      } catch {
        for url in grants { url.stopAccessingSecurityScopedResource() }
        message = "Donor not added: \(error.localizedDescription)"
      }
    }
  }
  func compare(restoring url: URL? = nil) {
    guard !busy, inputs.count >= 2 else { return }
    inspection?.cancel(); inspected = nil; originalImage = nil; donorImage = nil
    busy = true; progress = 0; plan = nil; output = nil
    operationID = UUID(); let operation = operationID
    let current = inputs
    let granted = url?.startAccessingSecurityScopedResource() == true
    task = Task {
      defer { finishWork(); if granted { url?.stopAccessingSecurityScopedResource() } }
      let owner = self
      let worker = Task.detached(priority: .utility) {
        let fresh = try await DVMultiPass.compare(current) { stage, done, total in
          Task { @MainActor [weak self = owner] in
            guard let self, self.busy, self.operationID == operation else { return }
            self.message = stage; self.progress = Double(done) / Double(max(1,total))
          }
        }
        return try url.map { try DVMultiPass.restore($0, against: fresh) } ?? fresh
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); plan = result
        message = "Comparison complete: \(result.reviews.count) base frames have eligible donors; \(result.candidates.filter { !$0.eligible }.count) candidates refused. Unmatched regions stay original. Review every eligible frame before export."
      } catch { message = "Comparison incomplete: \(error.localizedDescription)" }
    }
  }
  func choose(frame: UInt64, candidate: String) {
    guard !busy, var plan, let i = plan.reviews.firstIndex(where: { $0.baseFrame == frame }),
      candidate == "original" || plan.candidates.contains(where: { $0.id == candidate && $0.baseFrame == frame && $0.eligible }) else { return }
    plan.reviews[i].choice = candidate; self.plan = plan; output = nil
  }
  func keepOriginals() {
    guard !busy, var plan else { return }
    for i in plan.reviews.indices { plan.reviews[i].choice = "original" }
    self.plan = plan; output = nil
  }
  func note(frame: UInt64, text: String) {
    guard !busy, var plan, let i = plan.reviews.firstIndex(where: { $0.baseFrame == frame }) else { return }
    plan.reviews[i].note = String(text.prefix(1000)); self.plan = plan; output = nil
  }
  func inspect(_ candidate: DVMultiPass.Candidate) {
    guard !busy else { return }
    inspection?.cancel(); inspectionID = UUID(); let id = inspectionID, current = inputs
    inspected = candidate; originalImage = nil; donorImage = nil; inspectionMessage = "Verifying original bytes and decoding inspection stills…"
    inspection = Task {
      do {
        for pass in [0,candidate.donorPass] {
          let ordinal = pass == 0 ? candidate.baseFrame : candidate.donorFrame
          let value = try await DVMultiPass.frame(current[pass], ordinal: ordinal)
          try Task.checkCancellation(); guard inspectionID == id else { return }
          let expected = pass == 0 ? candidate.baseSHA256 : candidate.donorSHA256
          guard DVMultiPass.hash(value.bytes) == expected else { throw DVMultiPass.error("inspection frame changed") }
          // Decoded appearance is a review aid, not merge/alignment authority.
          if let decoded = try? await decoder.decode(value.bytes, ordinal: ordinal, timecode: nil, viewingMode: .weave) {
            try Task.checkCancellation(); guard inspectionID == id else { return }
            let image = CIImage(cvPixelBuffer: decoded.pixelBuffer)
            if let cg = CIContext().createCGImage(image, from: image.extent) {
              let still = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
              if pass == 0 { originalImage = still } else { donorImage = still }
            }
          }
        }
        inspectionMessage = "Both frame hashes match original bytes. Decoder concealment may mask defects; these pictures do not establish recovered truth."
      } catch { if inspectionID == id { inspectionMessage = error.localizedDescription } }
    }
  }
  func publish(parent: URL, exportDV: Bool) {
    guard !busy, let plan else { return }
    busy = true; progress = 0; output = nil
    operationID = UUID(); let operation = operationID
    let granted = parent.startAccessingSecurityScopedResource(), current = inputs
    let destination = parent.appendingPathComponent("rewindDV-Merge-\(UUID())")
    task = Task {
      defer { finishWork(); if granted { parent.stopAccessingSecurityScopedResource() } }
      let owner = self
      let worker = Task.detached(priority: .utility) {
        try await DVMultiPass.publish(plan: plan, inputs: current, destination: destination, exportDV: exportDV) { stage, done, total in
          Task { @MainActor [weak self = owner] in
            guard let self, self.busy, self.operationID == operation else { return }
            self.message = stage; self.progress = Double(done) / Double(max(1,total))
          }
        }
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); output = destination
        message = exportDV ? "Verified derivative complete: \(result.replacements) whole-frame selections; every output frame and provenance line reread. Unresolved regions remain original. No source was changed."
          : "Source-bound comparison/review saved. No media exported."
      } catch { message = "Not complete: \(error.localizedDescription). Any partial output is not a verified derivative." }
    }
  }
  func cancel() { task?.cancel(); inspection?.cancel() }
}

struct MultiPassView: View {
  @ObservedObject var model: MultiPassModel
  @ObservedObject var map: TapeEvidenceMapModel
  @State private var eligibleOnly = false
  @State private var page = 0
  @State private var acknowledgeUnresolved = false
  var body: some View {
    ArchiveSection("Multi-pass comparison and verified merge") {
      VStack(alignment: .leading, spacing: 12) {
        Text("A separate, reviewed derivative—not a repaired master. Compare up to eight passes. Missing, repeated or conflicting evidence never becomes a guessed alignment.").font(.callout)
        Text(model.message).textSelection(.enabled)
        if let progress = model.progress {
          ProgressView(value: progress).accessibilityLabel("Multi-pass comparison or verification progress")
          Text("Processing — keep the source and destination drives connected. Wait for verification before using any output.").foregroundStyle(.orange)
        }
        HStack {
          Button("Use current verified map as base") { model.reset(base: map.multiPassInput); page = 0; acknowledgeUnresolved = false }
            .disabled(model.busy || map.multiPassInput == nil)
          Button("Add donor map + DV…") { add() }.disabled(model.busy || model.bindings.isEmpty || model.bindings.count >= 8)
          Button("Compare original bytes") { model.compare(); page = 0; acknowledgeUnresolved = false }
            .disabled(model.busy || model.bindings.count < 2)
          if model.busy { Button("Cancel") { model.cancel() } }
        }
        ForEach(Array(model.bindings.enumerated()), id: \.offset) { i, binding in
          Text("\(i == 0 ? "BASE" : "DONOR \(i)") · \(binding.source.frameCount) frames · SHA-256 \(binding.source.sourceSHA256)")
            .font(.caption.monospaced()).textSelection(.enabled)
        }
        if let plan = model.plan {
          ForEach(plan.comparisons, id: \.donorPass) { comparison in
            Text("DONOR \(comparison.donorPass): \(comparison.uniqueExactFrames) uniquely identical frames · \(comparison.unresolvedBaseRanges.reduce(0) { $0 + $1.endExclusive - $1.first }) unresolved base frames · \(comparison.unmatchedDonorFrames) unmatched donor frames" + (comparison.monotonicAnchors ? "" : " · CROSSING ANCHORS — MERGE REFUSED"))
              .font(.caption).foregroundStyle(comparison.monotonicAnchors ? Color.secondary : .red)
            if !comparison.unresolvedBaseRanges.isEmpty {
              ArchiveDisclosure("Unresolved ranges — donor \(comparison.donorPass)") {
                Text(comparison.unresolvedBaseRanges.prefix(100).map { "\($0.first)…\($0.endExclusive - 1)" }.joined(separator: ", "))
                  .font(.caption.monospaced()).textSelection(.enabled)
                if comparison.unresolvedBaseRanges.count > 100 {
                  Text("First 100 ranges shown; the saved comparison contains every range.").font(.caption)
                }
              }
            }
          }
          ArchiveHeading("\(plan.pending) eligible frame decisions pending · \(plan.replacements) donor frames selected. Complete donor frames only; no block/sample fabrication.")
          HStack {
            Button("Keep all originals") { model.keepOriginals() }.disabled(model.busy)
            Toggle("Show eligible candidates only", isOn: $eligibleOnly).onChange(of: eligibleOnly) { _,_ in page = 0 }
            Button("Previous") { page = max(0,page - 1) }.disabled(page == 0)
            Button("Next") { page += 1 }.disabled((page + 1) * 25 >= visible(plan).count)
          }
          ForEach(Array(visible(plan).dropFirst(page * 25).prefix(25))) { candidate in
            VStack(alignment: .leading, spacing: 5) {
              ArchiveHeading("Base frame \(candidate.baseFrame) ← donor \(candidate.donorPass), frame \(candidate.donorFrame)")
              Text(candidate.reason).foregroundStyle(candidate.eligible ? Color.primary : .orange)
              Text("Nonzero video STA: \(candidate.before.videoSTA) → \(candidate.after.videoSTA) · audio error samples: \(candidate.before.audioErrors) → \(candidate.after.audioErrors)").font(.caption)
              HStack {
                Button("Inspect both frames") { model.inspect(candidate) }.disabled(model.busy)
                Button("Use this complete donor frame") { model.choose(frame: candidate.baseFrame, candidate: candidate.id) }
                  .disabled(model.busy || !candidate.eligible)
                Button("Keep original frame") { model.choose(frame: candidate.baseFrame, candidate: "original") }
                  .disabled(model.busy || !plan.reviews.contains(where: { $0.baseFrame == candidate.baseFrame }))
                Text(plan.reviews.first { $0.baseFrame == candidate.baseFrame }?.choice ?? (candidate.eligible ? "Pending" : "Original retained"))
                  .font(.caption.monospaced())
              }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
          }
          if let candidate = model.inspected {
            HStack(alignment: .top) {
              preview(model.originalImage, title: "BASE · frame \(candidate.baseFrame)", hash: candidate.baseSHA256)
              preview(model.donorImage, title: "DONOR \(candidate.donorPass) · frame \(candidate.donorFrame)", hash: candidate.donorSHA256)
            }
            Text(model.inspectionMessage).font(.caption)
            Text("Exact anchors (base → donor): " + candidate.anchors.map { "\($0.base) → \($0.donor)" }.joined(separator: ", ")).font(.caption.monospaced())
            TextField("Review note", text: Binding(get: { model.plan?.reviews.first { $0.baseFrame == candidate.baseFrame }?.note ?? "" },
              set: { model.note(frame: candidate.baseFrame, text: $0) })).disabled(model.busy || !candidate.eligible)
          }
          Toggle("I understand unresolved regions retain the original bytes; fewer error flags do not prove pristine content", isOn: $acknowledgeUnresolved)
          HStack {
            Button("Save comparison / review…") { publish(false) }.disabled(model.busy)
            Button("Restore reviewed choices…") { restore() }.disabled(model.busy)
            Button("Export verified merged DV…") { publish(true) }.buttonStyle(.borderedProminent)
              .disabled(model.busy || plan.pending > 0 || !acknowledgeUnresolved)
              .accessibilityIdentifier("multipass-export-verified-derivative")
            if let output = model.output { Button("Show output and provenance") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
          }
        }
      }
      .onChange(of: map.directory) { _,_ in model.reset(); acknowledgeUnresolved = false; page = 0 }
      .onAppear {
        if model.bindings.first?.mapSHA256 != map.reader?.binding.mapReceiptSHA256 {
          model.reset(); acknowledgeUnresolved = false; page = 0
        }
      }
    }
  }
  private func visible(_ plan: DVMultiPass.Plan) -> [DVMultiPass.Candidate] { eligibleOnly ? plan.candidates.filter(\.eligible) : plan.candidates }
  private func preview(_ image: NSImage?, title: String, hash: String) -> some View {
    VStack(alignment: .leading) {
      ArchiveHeading(title)
      if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 260) }
      else { Text("Decoded inspection still unavailable").frame(height: 260) }
      Text(hash).font(.caption2.monospaced()).textSelection(.enabled)
    }.frame(maxWidth: .infinity)
  }
  private func add() {
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    panel.message = "Choose the donor's tape evidence map folder. Create its map in Archives first if needed."
    guard panel.runModal() == .OK, let map = panel.url else { return }
    let source = NSOpenPanel(); source.canChooseFiles = true; source.canChooseDirectories = false; source.allowsMultipleSelection = false
    source.message = "Choose the original DV file for this donor map. Its entire SHA-256 must match."
    guard source.runModal() == .OK, let file = source.url else { return }
    model.add(mapURL: map, sourceURL: file); acknowledgeUnresolved = false
  }
  private func publish(_ media: Bool) {
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    panel.message = media ? "Choose a separate destination. Original captures stay unchanged; wait for full reread verification." : "Save comparison and reviewed choices separately. No media will be exported."
    if panel.runModal() == .OK, let parent = panel.url { model.publish(parent: parent, exportDV: media) }
  }
  private func restore() {
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    panel.message = "Choose review.json. Every comparison will be rederived before saved choices are accepted."
    if panel.runModal() == .OK, let url = panel.url { model.compare(restoring: url); acknowledgeUnresolved = false }
  }
}
