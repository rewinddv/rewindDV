// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import CoreImage

@MainActor
final class TapeEvidenceMapModel: ObservableObject {
  @Published private(set) var busy = false
  @Published private(set) var receipt: DVTapeEvidenceMapExporter.Receipt?
  @Published private(set) var directory: URL?
  @Published private(set) var message = "Create a read-only, source-bound frame evidence map. Original DV is never changed."
  @Published private(set) var page: DVTapeEvidenceLedgerReader.Page?
  @Published private(set) var summaries: [DVTapeEvidenceLedgerReader.PageSummary] = []
  @Published private(set) var selection: DVTapeDefectInspector.Model?
  @Published private(set) var originalFrame: DVVerifiedFrameSource.Frame?
  @Published private(set) var frameImage: NSImage?
  @Published private(set) var sourceMessage = "Locate the original DV to verify its hash and inspect exact bytes."
  @Published private(set) var sourceProgress: Double?
  @Published private(set) var detailBusy = false
  @Published private(set) var reportProgress: Double?
  @Published private(set) var reportMessage = "Portable reports preserve original-byte provenance. Export requires the original DV to be verified."
  @Published private(set) var reportDirectory: URL?
  @Published private(set) var externalReport: DVExternalReportReader.Result?
  @Published private(set) var scenePlan: DVSceneSegmentation.Plan?
  @Published private(set) var sceneProgress: Double?
  @Published private(set) var sceneMessage = "Propose recording-marker and format boundaries from verified original bytes. All cuts require review."
  @Published private(set) var sceneDirectory: URL?
  var canExportReports: Bool { originalSource != nil && reader != nil && !busy }
  var multiPassInput: DVMultiPass.Input? {
    guard !busy, let reader, let originalSource else { return nil }
    return .init(map: reader, source: originalSource)
  }
  private var originalSource: DVVerifiedFrameSource?
  private var sourceAccess: URL?
  private var selectedRecord: DVTapeEvidenceMapExporter.FrameRecord?
  private var detailTask: Task<Void, Never>?
  private var detailGeneration = UUID()
  private let frameDecoder = LiveDVFrameDecoder()
  private(set) var reader: DVTapeEvidenceLedgerReader?
  @Published private(set) var reviewEvents: [DVRecoveryReviewJournal.Event] = []
  @Published private(set) var reviewRevision: UInt64 = 0
  @Published private(set) var reviewPageNumber: UInt64 = 0
  @Published private(set) var reviewItemCount: UInt64 = 0
  @Published private(set) var reviewDirectory: URL?
  @Published private(set) var reviewMessage = "Create or open a separate review queue. No tape motion or frame replacement is performed."
  private(set) var reviewJournal: DVRecoveryReviewJournal?
  private var reviewAccess: URL?
  private var evidenceAccess: URL?
  private var task: Task<Void, Never>?
  private var generation = UUID()

  /// Recheck the currently verified original and target endpoint bytes before
  /// admitting a supervised pass. This is file provenance, never seek proof.
  func validateRecoveryTarget(_ target: DVGentleRecovery.Target,
    plan: DVGentleRecovery.Plan) async throws {
    guard !busy, let reader, let originalSource,
      plan.targets.contains(target), target.first < target.endExclusive,
      plan.source == receipt?.sourceSnapshot, plan.mapSHA256 == reader.binding.mapReceiptSHA256 else {
      throw DVGentleRecovery.failure("open and verify the original DV for this recovery plan first")
    }
    busy = true
    defer { busy = false }
    try await Task.detached(priority: .utility) {
      try await originalSource.requireSnapshot(plan.source)
      for ordinal in Set([target.first, target.endExclusive - 1]) {
        let page = try await reader.page(ordinal / DVTapeEvidenceLedgerReader.recordsPerPage)
        guard let record = page.records.first(where: { $0.boundaryEvidence.frameOrdinal == ordinal }) else {
          throw DVGentleRecovery.failure("target endpoint is absent from the verified map")
        }
        _ = try await originalSource.frame(record)
      }
    }.value
  }

  func analyzeScenes() {
    guard !busy, let reader, let originalSource else { return }
    clearSelection(); busy = true; scenePlan = nil; sceneDirectory = nil; sceneProgress = 0
    sceneMessage = "Reading original frames for scene proposals… Master DV is never changed."
    let id = generation
    task = Task {
      defer { busy = false; task = nil; sceneProgress = nil }
      let worker = Task.detached(priority: .utility) {
        try await DVSceneSegmentation.analyze(map: reader, source: originalSource) { [weak self] done, total in
          Task { @MainActor [weak self] in
            guard let self, self.generation == id, self.busy else { return }
            self.sceneProgress = Double(done) / Double(total)
          }
        }
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); scenePlan = result
        sceneMessage = "\(result.boundaries.count) proposed cuts. Review before/after frames, then accept or reject. Missing metadata never silently creates a cut."
      } catch { sceneMessage = "Scene analysis incomplete: \(error.localizedDescription)" }
    }
  }

  func decideScene(_ frame: UInt64, decision: DVSceneSegmentation.Decision, note: String? = nil) {
    guard !busy, var plan = scenePlan, let index = plan.boundaries.firstIndex(where: { $0.frame == frame }) else { return }
    plan.boundaries[index].decision = decision
    if let note { plan.boundaries[index].note = String(note.prefix(1000)) }
    scenePlan = plan; sceneDirectory = nil
  }

  func restoreScenes(_ url: URL) {
    guard !busy, let plan = scenePlan else { return }
    busy = true
    let access = url.startAccessingSecurityScopedResource()
    task = Task {
      defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false; task = nil }
      let worker = Task.detached(priority: .utility) { try DVSceneSegmentation.restore(url, against: plan) }
      do {
        let restored = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); scenePlan = restored; sceneDirectory = nil
        sceneMessage = "Saved decisions restored against this original-byte analysis. \(restored.pendingCount) cuts still need review."
      } catch { sceneMessage = "Review not restored: \(error.localizedDescription)" }
    }
  }

  func publishScenes(parent: URL, exportDV: Bool) {
    guard !busy, let reader, let originalSource, let plan = scenePlan else { return }
    guard !exportDV || plan.pendingCount == 0 else { return }
    clearSelection(); busy = true; sceneDirectory = nil; sceneProgress = 0
    let destination = parent.appendingPathComponent("rewindDV-Scenes-\(UUID().uuidString)")
    let access = parent.startAccessingSecurityScopedResource(), id = generation
    sceneMessage = exportDV ? "Revalidating review, copying unchanged DV frames and rereading scene files. Do not disconnect the destination." : "Revalidating and saving a separate review snapshot…"
    task = Task {
      defer { if access { parent.stopAccessingSecurityScopedResource() }; busy = false; task = nil; sceneProgress = nil }
      let worker = Task.detached(priority: .utility) {
        try await DVSceneSegmentation.publish(plan: plan, map: reader, source: originalSource, destination: destination, exportDV: exportDV) { [weak self] done, total in
          Task { @MainActor [weak self] in
            guard let self, self.generation == id, self.busy else { return }
            self.sceneProgress = Double(done) / Double(total)
          }
        }
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); sceneDirectory = destination
        sceneMessage = exportDV ? "\(result.outputs.count) scene files reread-verified. Concatenated source-order bytes match the master SHA-256. Master unchanged." : "Review snapshot saved. No DV files exported; master unchanged."
      } catch { sceneMessage = "Scene publication incomplete: \(error.localizedDescription). Any partial files remain at \(destination.path); only scenes.json marks completion." }
    }
  }

  func exportReports(parent: URL) {
    guard !busy, let reader, let originalSource else { return }
    clearSelection(); busy = true; reportProgress = 0; reportDirectory = nil
    reportMessage = "Exporting JSON, CSV, WebVTT and DVRescue XML; then rereading every output. Do not disconnect the destination."
    let destination = parent.appendingPathComponent("rewindDV-Reports-\(UUID().uuidString)")
    let access = parent.startAccessingSecurityScopedResource(), id = generation
    task = Task {
      defer { if access { parent.stopAccessingSecurityScopedResource() }; busy = false; task = nil; reportProgress = nil }
      let worker = Task.detached(priority: .utility) {
        try await DVAnalysisReportExporter.export(map: reader, source: originalSource, destination: destination) { [weak self] done, total in
          Task { @MainActor [weak self] in
            guard let self, self.generation == id, self.busy else { return }
            self.reportProgress = Double(done) / Double(total)
          }
        }
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        reportDirectory = destination
        reportMessage = "Reports complete and reread-verified: \(result.frameCount) frames, \(result.cueCount) review cues. Source DV unchanged. report.json binds all four outputs."
      } catch { reportMessage = "Report export incomplete: \(error.localizedDescription). Partial outputs, if any, remain at \(destination.path). Only report.json marks completion." }
    }
  }

  func importExternalReport(_ url: URL, parent: URL) {
    guard !busy else { return }
    let destination = parent.appendingPathComponent("rewindDV-External-Report-\(UUID().uuidString)")
    if let reader, DVGentleRecovery.isWithin(destination, directory: reader.mapDirectory) {
      reportMessage = "Choose a destination outside the evidence-map directory. Native evidence must remain unchanged."
      return
    }
    clearSelection(); busy = true; externalReport = nil; reportDirectory = nil
    reportMessage = "Reading untrusted external XML with entity/network expansion disabled. Native evidence will not be changed."
    let inputAccess = url.startAccessingSecurityScopedResource(), outputAccess = parent.startAccessingSecurityScopedResource()
    let expected = receipt?.sourceSnapshot
    task = Task {
      defer { if inputAccess { url.stopAccessingSecurityScopedResource() }; if outputAccess { parent.stopAccessingSecurityScopedResource() }; busy = false; task = nil }
      let worker = Task.detached(priority: .utility) {
        try DVExternalReportReader.preserve(url, destination: destination, expectedSource: expected)
      }
      do {
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); externalReport = result; reportDirectory = destination
        reportMessage = "External report preserved separately. \(result.listedFrameCount) listed frames. Imported claims are not native findings or source-quality certification."
      } catch { reportMessage = "External report refused or incomplete: \(error.localizedDescription)" }
    }
  }

  func open(_ url: URL) {
    guard !busy else { return }
    releaseDirectory()
    directory = url; evidenceAccess = url.startAccessingSecurityScopedResource() ? url : nil
    busy = true; receipt = nil; page = nil; selection = nil; summaries = []; reader = nil
    message = "Verifying the source-bound map and building a bounded navigation index…"
    let id = UUID(); generation = id
    task = Task {
      defer { if generation == id { busy = false; task = nil } }
      let worker = Task.detached(priority: .utility) { try DVTapeEvidenceLedgerReader(mapDirectory: url) }
      do {
        let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == id else { return }
        reader = loaded; receipt = loaded.binding.mapReceipt; summaries = loaded.pageSummaries
        if loaded.binding.pageCount > 0 { page = try await loaded.page(0) }
        message = "Verified evidence map. Colored regions identify observations to review—not automatically proven tape damage."
      } catch { message = "Map unavailable: \(error.localizedDescription)" }
    }
  }

  func loadPage(_ number: UInt64, selecting ordinal: UInt64? = nil) {
    guard !busy, let reader, number < reader.binding.pageCount else { return }
    busy = true; clearSelection()
    task = Task {
      defer { busy = false; task = nil }
      do {
        page = try await reader.page(number)
        if let ordinal, let record = page?.records.first(where: { $0.boundaryEvidence.frameOrdinal == ordinal }) {
          select(record)
        }
      }
      catch { page = nil; message = "Evidence changed or could not be read: \(error.localizedDescription)" }
    }
  }

  func select(_ record: DVTapeEvidenceMapExporter.FrameRecord) {
    guard let reader else { return }
    clearSelection()
    selectedRecord = record
    do { selection = try DVTapeDefectInspector.make(binding: reader.binding, record: record) }
    catch { selection = nil; message = "Frame provenance unavailable: \(error.localizedDescription)" }
    guard selection != nil, let originalSource else { return }
    let id = UUID(); detailGeneration = id; detailBusy = true
    detailTask = Task {
      defer { if detailGeneration == id { detailBusy = false; detailTask = nil } }
      do {
        // Re-read the ledger page as well as the selected original frame.
        let verified = try await reader.page(record.boundaryEvidence.frameOrdinal / DVTapeEvidenceLedgerReader.recordsPerPage)
        guard verified.records.contains(record) else { throw DVIngestError.invalidEvidence("selected map record changed") }
        let frame = try await originalSource.frame(record)
        try Task.checkCancellation()
        guard detailGeneration == id else { return }
        selection = try DVTapeDefectInspector.make(binding: reader.binding, record: record, semanticReport: frame.evidence.semantics)
        originalFrame = frame
        sourceMessage = "Original file verified; selected frame hash matches the map."
        do {
          guard frame.evidence.videoLayout != nil else { throw LiveDVDecodeError.malformedFrame }
          let decoded = try await frameDecoder.decode(frame.bytes, ordinal: record.boundaryEvidence.frameOrdinal,
            timecode: nil, viewingMode: .weave, forensicDVCPROPAL: frame.evidence.videoLayout == .pal411)
          try Task.checkCancellation()
          guard detailGeneration == id else { return }
          let pixels = decoded.pixelBuffer
          let image = CIImage(cvPixelBuffer: pixels)
          // One still, never a playback/capture render queue.
          if let cg = CIContext().createCGImage(image, from: image.extent) {
            frameImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
          }
        } catch {
          if detailGeneration == id { sourceMessage += " Picture decoding unavailable; verified bytes remain inspectable." }
        }
      } catch {
        guard detailGeneration == id else { return }
        originalFrame = nil; frameImage = nil
        sourceMessage = "Original-frame inspection refused: \(error.localizedDescription)"
      }
    }
  }

  private func clearSelection() {
    detailTask?.cancel(); detailGeneration = UUID(); detailBusy = false
    selection = nil; selectedRecord = nil; originalFrame = nil; frameImage = nil
  }

  func connectSource(_ url: URL) {
    guard !busy, let reader else { return }
    let selected = selectedRecord
    clearSelection(); originalSource = nil
    if let sourceAccess { sourceAccess.stopAccessingSecurityScopedResource() }
    sourceAccess = url.startAccessingSecurityScopedResource() ? url : nil
    busy = true; sourceProgress = 0
    sourceMessage = "Verifying the entire original DV against this map. No source bytes will be changed."
    let id = generation
    task = Task {
      defer { busy = false; sourceProgress = nil; task = nil }
      let snapshot = reader.binding.mapReceipt.sourceSnapshot
      let worker = Task.detached(priority: .utility) {
        try DVVerifiedFrameSource(url: url, snapshot: snapshot) { [weak self] done, total in
          // Update at most once per 64 MiB, plus completion.
          guard done == total || done % 67_108_864 == 0 else { return }
          Task { @MainActor [weak self] in
            guard let self, self.generation == id, self.busy else { return }
            self.sourceProgress = Double(done) / Double(total)
          }
        }
      }
      do {
        let source = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        originalSource = source
        sourceMessage = "Original DV verified. Select a frame to inspect picture, blocks, metadata and original bytes."
        if let selected { select(selected) }
        else if let first = page?.records.first { select(first) }
      } catch {
        sourceMessage = "Original DV unavailable: \(error.localizedDescription)"
        if let sourceAccess { sourceAccess.stopAccessingSecurityScopedResource() }; sourceAccess = nil
      }
    }
  }

  func jump(to ordinal: UInt64) {
    guard let receipt, ordinal < receipt.frameLedgerRecordCount else { return }
    loadPage(ordinal / DVTapeEvidenceLedgerReader.recordsPerPage, selecting: ordinal)
  }
  func findIssue(forward: Bool, code: DVTapeEvidenceMapExporter.IssueCode?) {
    guard !busy, let reader else { return }
    let start = selection?.frameOrdinal
    busy = true
    task = Task {
      defer { busy = false; task = nil }
      do {
        if let ordinal = try await reader.findIssue(after: start, forward: forward, code: code) {
          clearSelection()
          page = try await reader.page(ordinal / DVTapeEvidenceLedgerReader.recordsPerPage)
          if let record = page?.records.first(where: { $0.boundaryEvidence.frameOrdinal == ordinal }) { select(record) }
        } else { message = "No further matching observation in that direction. Navigation does not wrap." }
      } catch { message = "Navigation refused: \(error.localizedDescription)" }
    }
  }

  private func releaseDirectory() {
    generation = UUID(); sourceProgress = nil
    scenePlan = nil; sceneDirectory = nil; sceneProgress = nil
    sceneMessage = "Propose recording-marker and format boundaries from verified original bytes. All cuts require review."
    reportProgress = nil; reportDirectory = nil; externalReport = nil
    reportMessage = "Portable reports preserve original-byte provenance. Export requires the original DV to be verified."
    clearSelection(); originalSource = nil
    if let sourceAccess { sourceAccess.stopAccessingSecurityScopedResource() }; sourceAccess = nil
    sourceMessage = "Locate the original DV to verify its hash and inspect exact bytes."
    reader = nil
    reviewJournal = nil; reviewEvents = []; reviewRevision = 0; reviewDirectory = nil
    reviewPageNumber = 0; reviewItemCount = 0
    if let reviewAccess { reviewAccess.stopAccessingSecurityScopedResource() }
    reviewAccess = nil
    if let evidenceAccess { evidenceAccess.stopAccessingSecurityScopedResource() }
    evidenceAccess = nil
  }

  func connectReview(at url: URL, create: Bool, access: URL) {
    guard !busy, let reader, let directory else { return }
    busy = true
    let granted = access.startAccessingSecurityScopedResource()
    task = Task {
      defer { busy = false; task = nil }
      do {
        let binding = reader.binding
        let journal = try await Task.detached(priority: .utility) {
          try create ? DVRecoveryReviewJournal.create(at: url, evidenceMapDirectory: directory, binding: binding)
            : DVRecoveryReviewJournal.open(at: url, evidenceMapDirectory: directory, expectedBinding: binding)
        }.value
        let status = try await journal.status()
        let count = try await journal.currentItemCount()
        let events = count == 0 ? [] : try await journal.currentItemsPage(0).latestEvents
        if let previous = reviewAccess { previous.stopAccessingSecurityScopedResource() }
        reviewAccess = granted ? access : nil
        reviewJournal = journal; reviewDirectory = url; reviewRevision = status.latestRevision
        reviewItemCount = count; reviewPageNumber = 0; reviewEvents = events
        reviewMessage = "Review queue bound to this exact source and map. Original evidence is unchanged."
      } catch {
        if granted { access.stopAccessingSecurityScopedResource() }
        reviewMessage = "Review queue unavailable: \(error.localizedDescription)"
      }
    }
  }

  func addSelectedForReview(note: String) {
    guard let selection else { return }
    do {
      let item = try DVRecoveryReviewJournal.makeItem(from: selection,
        summary: "Review source frame \(selection.frameOrdinal)")
      updateReview(item, state: .unreviewed, note: note)
    } catch { reviewMessage = error.localizedDescription }
  }

  func updateReview(_ item: DVRecoveryReviewJournal.Item, state: DVRecoveryReviewJournal.ReviewState, note: String) {
    guard !busy, let journal = reviewJournal else { return }
    let revision = reviewRevision
    busy = true
    task = Task {
      defer { busy = false; task = nil }
      do {
        let event = try await journal.append(item: item, state: state, operatorNote: note, expectedRevision: revision)
        reviewRevision = event.revision
        reviewItemCount = try await journal.currentItemCount()
        reviewEvents = try await journal.currentItemsPage(reviewPageNumber).latestEvents
        reviewMessage = "Review revision \(event.revision) saved. Source bytes were not changed."
      } catch { reviewMessage = "Review was not confirmed saved: \(error.localizedDescription). Close and reopen the evidence map, then open the review queue before retrying." }
    }
  }
  func loadReviewPage(_ number: UInt64) {
    guard !busy, let journal = reviewJournal, number * 256 < reviewItemCount else { return }
    busy = true
    task = Task {
      defer { busy = false; task = nil }
      do {
        let page = try await journal.currentItemsPage(number)
        reviewEvents = page.latestEvents; reviewPageNumber = number
      } catch { reviewMessage = "Queue page could not be verified: \(error.localizedDescription)" }
    }
  }
  func create(source: URL, parent: URL, archiveVerification: URL? = nil, accessRoot: URL? = nil) {
    guard !busy else { return }
    releaseDirectory()
    let sourceAccess = source.startAccessingSecurityScopedResource()
    let scope = accessRoot ?? parent
    evidenceAccess = scope.startAccessingSecurityScopedResource() ? scope : nil
    busy = true; receipt = nil; page = nil; selection = nil; summaries = []
    let destination = parent.appendingPathComponent("RewindDV-TapeMap-\(UUID().uuidString)", isDirectory: true)
    directory = destination
    message = "Reading every source frame and verifying its identity…"
    task = Task {
      defer {
        if sourceAccess { source.stopAccessingSecurityScopedResource() }
        busy = false; task = nil
      }
      let worker = Task.detached(priority: .utility) {
        try DVTapeEvidenceMapExporter.create(source: source, archiveVerification: archiveVerification, destination: destination)
      }
      do {
        let result = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let indexing = Task.detached(priority: .utility) {
          try DVTapeEvidenceLedgerReader(mapDirectory: destination)
        }
        let loaded = try await withTaskCancellationHandler { try await indexing.value } onCancel: { indexing.cancel() }
        try Task.checkCancellation()
        reader = loaded; receipt = result; summaries = loaded.pageSummaries
        if loaded.binding.pageCount > 0 { page = try await loaded.page(0) }
        message = "Evidence map verified. This describes observed bytes, not a repaired or certified tape."
      } catch {
        message = "Map incomplete: \(error.localizedDescription). Any partial evidence remains at the destination."
      }
    }
  }
  func cancel() { task?.cancel(); detailTask?.cancel() }
}

struct DVSceneReviewView: View {
  @ObservedObject var map: TapeEvidenceMapModel
  @State private var page = 0
  @State private var selected: UInt64?
  @State private var note = ""
  init(map: TapeEvidenceMapModel, initialFrame: UInt64? = nil) {
    self.map = map
    _selected = State(initialValue: initialFrame)
  }
  var body: some View {
    ArchiveSection("Previewed scene segmentation") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Button("Analyze scene boundaries") { page = 0; selected = nil; map.analyzeScenes() }.disabled(!map.canExportReports)
          Button("Restore review…") { restore() }.disabled(map.busy || map.scenePlan == nil)
          Button("Save review…") { destination(exportDV: false) }.disabled(!map.canExportReports || map.scenePlan == nil)
          Button("Export reviewed scenes…") { destination(exportDV: true) }
            .disabled(!map.canExportReports || map.scenePlan == nil || map.scenePlan?.pendingCount != 0)
          if let directory = map.sceneDirectory {
            Button("Show scene output") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
          }
        }
        Text(map.sceneMessage).textSelection(.enabled)
        if let progress = map.sceneProgress, map.busy { ProgressView(value: progress).accessibilityLabel("Scene analysis and export progress") }
        Text("Preview only. No cut is applied to the master. Scene copies retain every source frame once, without re-encoding. Recorded markers propose boundaries—not guaranteed camera takes. Unknown/conflicting metadata is not guessed; timecode gaps do not remove footage.")
          .font(.caption).foregroundStyle(.secondary)
        if let plan = map.scenePlan {
          Text("\(plan.segments.count) reviewed segments · \(plan.pendingCount) pending cuts · \(plan.framesWithIncompleteOrConflictingEvidence) frames with incomplete/conflicting boundary metadata")
          HStack {
            Button("Previous proposals") { page = max(0, page - 1) }.disabled(page == 0 || map.busy)
            Text("Proposal page \(page + 1) / \(max(1, (plan.boundaries.count + 31) / 32))")
            Button("Next proposals") { page += 1 }.disabled((page + 1) * 32 >= plan.boundaries.count || map.busy)
          }
          ForEach(Array(plan.boundaries.dropFirst(page * 32).prefix(32))) { cut in
            HStack {
              Button("Cut before frame \(cut.frame)") { selected = cut.frame; note = cut.note }
              Text(cut.reasons.joined(separator: " · ")).font(.caption).lineLimit(2)
              Spacer()
              Picker("Review frame \(cut.frame)", selection: Binding(get: { cut.decision }, set: { map.decideScene(cut.frame, decision: $0) })) {
                ForEach(DVSceneSegmentation.Decision.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
              }.labelsHidden().frame(width: 125).disabled(map.busy)
            }
          }
          if let selected, let cut = plan.boundaries.first(where: { $0.frame == selected }) {
            Divider()
            ArchiveHeading("Boundary before frame \(cut.frame)")
            HStack {
              Button("Preview before (\(cut.frame - 1))") { preview(cut.frame - 1) }.disabled(map.busy)
              Button("Preview after (\(cut.frame))") { preview(cut.frame) }.disabled(map.busy)
              Text("File ordinals—not recorded timecode. Full byte inspector remains below.").font(.caption)
            }
            if let image = map.frameImage, let ordinal = map.selection?.frameOrdinal, [cut.frame - 1, cut.frame].contains(ordinal) {
              Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 360, height: 288)
                .accessibilityLabel("Verified original frame \(ordinal)")
              Text("Original frame \(ordinal) · \(map.sourceMessage)").font(.caption)
            }
            TextField("Review note (optional)", text: $note).disabled(map.busy)
            Button("Save note") { map.decideScene(cut.frame, decision: cut.decision, note: note) }.disabled(map.busy)
            ArchiveDisclosure("Boundary evidence: original pack bytes and offsets") {
              Text(cut.reasons.joined(separator: "\n")).font(.caption)
              ForEach([cut.before, cut.after], id: \.frame) { evidence in
                Text("Frame \(evidence.frame) · \(evidence.format) · SHA-256 \(evidence.frameSHA256)").font(.caption).textSelection(.enabled)
                ForEach(evidence.packs, id: \.id) { pack in
                  Text("\(pack.id): \(pack.rawHex) · offsets \(pack.sourceByteOffsets.map(String.init).joined(separator: ", "))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                }
              }
            }
          }
          ArchiveDisclosure("Reviewed ranges (complete master coverage)") {
            ScrollView { LazyVStack(alignment: .leading) {
              ForEach(Array(plan.segments.enumerated()), id: \.offset) { index, segment in
                Text("Scene \(index + 1): frames \(segment.first)..<\(segment.endExclusive) · \(segment.endExclusive - segment.first) frames")
                  .font(.caption.monospaced())
              }
            } }.frame(maxHeight: 160)
          }
        }
      }.padding(8)
    }
  }
  private func preview(_ frame: UInt64) { map.loadPage(frame / DVTapeEvidenceLedgerReader.recordsPerPage, selecting: frame) }
  private func destination(exportDV: Bool) {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.allowsMultipleSelection = false; panel.prompt = exportDV ? "Export scene copies" : "Save review"
    panel.message = exportDV ? "Creates a new folder of byte-for-byte DV scene copies plus source-bound review and provenance. The master is never altered." : "Creates a new review snapshot folder. No video is written or changed."
    if panel.runModal() == .OK, let url = panel.url { map.publishScenes(parent: url, exportDV: exportDV) }
  }
  private func restore() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
    panel.message = "Choose review.json from a saved scene review. It must match this original-byte analysis."
    if panel.runModal() == .OK, let url = panel.url { map.restoreScenes(url) }
  }
}

struct TapeEvidenceMapView: View {
  @ObservedObject var map: TapeEvidenceMapModel
  @State private var issuesOnly = false
  @State private var reviewNote = ""
  @State private var issueFilter: DVTapeEvidenceMapExporter.IssueCode?
  @State private var frameEntry = ""
  var body: some View {
    ArchiveSection("Tape evidence map") {
      VStack(alignment: .leading, spacing: 12) {
        Text(map.message)
        HStack {
          Button("Create tape map…", systemImage: "map") { choose() }.disabled(map.busy)
          Button("Open evidence map…", systemImage: "folder") { chooseMap() }.disabled(map.busy)
          if map.busy { ProgressView().controlSize(.small); Button("Cancel") { map.cancel() } }
          if map.receipt != nil, let directory = map.directory {
            Button("Show evidence", systemImage: "folder") {
              NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
          }
        }
        DVSceneReviewView(map: map)
        ArchiveSection("Portable analysis reports") {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Button("Export JSON / CSV / WebVTT / XML…") { chooseReportDestination() }.disabled(!map.canExportReports)
              Button("Import DVRescue XML…") { chooseExternalReport() }.disabled(map.busy)
              if let output = map.reportDirectory {
                Button("Show reports") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
              }
            }
            Text(map.reportMessage).font(.callout).textSelection(.enabled)
            if let progress = map.reportProgress { ProgressView(value: progress).accessibilityLabel("Portable report progress") }
            Text("Exact audio samples are primary in JSON/CSV. XML is a documented compatible subset, not a DVRescue-authored report. Original DV and native findings are never modified. Imported XML may contain the original author's private paths; review before sharing.")
              .font(.caption).foregroundStyle(.secondary)
            if let external = map.externalReport {
              fact("External creator", "\(external.creator) · \(external.creatorVersion)")
              fact("External report SHA-256", external.reportSHA256)
              fact("Source binding claim", external.claimedSourceBinding)
              fact("External totals (not native evidence)", "Video STA observations: \(external.videoSTAObservations.map(String.init) ?? "Not reported"); audio block observations: \(external.audioBlockObservations.map(String.init) ?? "Not reported"). These are different units, not packet-loss counts.")
              ArchiveDisclosure("External XML preview (bounded; exact original retained separately)") {
                ScrollView {
                  LazyVStack(alignment: .leading) {
                    ForEach(Array(external.preview.enumerated()), id: \.offset) { _, element in
                      Text(element.path + " " + element.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    }
                  }
                }.frame(maxHeight: 200)
              }
            }
          }.padding(8)
        }
        if let receipt = map.receipt {
          fact("Source frames covered", receipt.frameLedgerRecordCount.formatted())
          fact("Source SHA-256", receipt.sourceSnapshot.sourceSHA256)
          fact("Uncovered bytes", receipt.uncoveredSourceByteCount.formatted())
          fact("Transport evidence", receipt.acquisitionReport.rawValue.replacingOccurrences(of: "_", with: " "))
          if let transport = receipt.archiveReportProvenance {
            fact("Acquisition totals—not localized to file frames", "Known dropped packets \(transport.knownDroppedPackets); incomplete frames \(transport.incompleteFrames); CIP discontinuities \(transport.CIPDiscontinuities)")
          }
          fact("Detailed quality coverage", "\(map.summaries.reduce(0) { $0 + $1.qualityAssessedFrames })/\(receipt.frameLedgerRecordCount) frames. Older maps can be recreated separately; originals are never upgraded in place.")
          HStack {
            Button("Locate original DV…", systemImage: "link") { chooseOriginal() }.disabled(map.busy)
            Text(map.sourceMessage).font(.caption)
          }
          if let progress = map.sourceProgress { ProgressView(value: progress).accessibilityLabel("Verifying original DV") }
          ForEach(receipt.issueCounts, id: \.code) { item in
            fact(item.code.rawValue.replacingOccurrences(of: "_", with: " "),
              "\(item.affectedFrameCount) frames · \(item.totalObservedCount) observations")
          }
          if !map.summaries.isEmpty { overview }
          if let page = map.page { framePage(page) }
          if map.detailBusy { ProgressView("Verifying selected frame and decoding inspection still…") }
          if let original = map.originalFrame, let selected = map.selection {
            DVFrameForensicsView(frame: original, image: map.frameImage, identity: selected)
              .id(selected.frameOrdinal)
          }
          if let selected = map.selection { provenance(selected) }
          reviewQueue
          Text("Full per-frame raw metadata, hashes and byte offsets are in frames.ndjson; map.json binds the ledger and source. Absent/conflicting metadata is not proof of packet loss.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("ATN/ETN positioning, tape identity, source quality and merge authority remain unverified. This map never seeks, rereads tape, deletes frames or repairs an archive.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }
  private var reviewQueue: some View {
    ArchiveSection("Recovery review queue") {
      VStack(alignment: .leading, spacing: 10) {
        Text(map.reviewMessage).font(.callout)
        HStack {
          Button("New review queue…") { chooseReview(create: true) }.disabled(map.busy)
          Button("Open review queue…") { chooseReview(create: false) }.disabled(map.busy)
          if let directory = map.reviewDirectory {
            Button("Show review evidence") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
          }
        }
        TextField("Operator note", text: $reviewNote, axis: .vertical).lineLimit(2...4)
        Button("Add selected frame for review") { map.addSelectedForReview(note: reviewNote) }
          .disabled(map.selection?.issues.isEmpty != false || map.reviewDirectory == nil || map.busy)
        HStack {
          Text("\(map.reviewItemCount) review items · revision \(map.reviewRevision)").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Previous queue page") { map.loadReviewPage(map.reviewPageNumber - 1) }
            .disabled(map.busy || map.reviewPageNumber == 0)
          Button("Next queue page") { map.loadReviewPage(map.reviewPageNumber + 1) }
            .disabled(map.busy || (map.reviewPageNumber + 1) * 256 >= map.reviewItemCount)
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(map.reviewEvents, id: \.item.id) { event in
              VStack(alignment: .leading, spacing: 5) {
                fact("Frame \(event.item.firstFrameOrdinal)", event.state.rawValue.replacingOccurrences(of: "_", with: " "))
                if let note = event.operatorNote, !note.isEmpty { Text(note).font(.caption).textSelection(.enabled) }
                HStack {
                  Button("Inspect") { map.loadPage(event.item.firstFrameOrdinal / DVTapeEvidenceLedgerReader.recordsPerPage,
                    selecting: event.item.firstFrameOrdinal) }
                  Button("Defer") { map.updateReview(event.item, state: .deferred, note: reviewNote) }
                  Button("Reviewed") { map.updateReview(event.item, state: .reviewed, note: reviewNote) }
                  Button("Needs decision") { map.updateReview(event.item, state: .flaggedForOperatorDecision, note: reviewNote) }
                }.disabled(map.busy)
              }.padding(.vertical, 4)
            }
          }
        }.frame(maxHeight: 240)
        Text("Review only. No automatic reread, wear-budget consumption, deletion or merge is authorized by these controls.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
  }
  private func chooseReview(create: Bool) {
    let panel = NSOpenPanel()
    panel.title = create ? "Choose a parent folder for the separate review queue" : "Open a review queue for this exact evidence map"
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = create; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let selected = panel.url {
      let url = create ? selected.appendingPathComponent("RewindDV-Review-\(UUID().uuidString)") : selected
      map.connectReview(at: url, create: create, access: selected)
    }
  }
  private func chooseReportDestination() {
    let panel = NSOpenPanel(); panel.title = "Choose a folder for a new portable report bundle"
    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { map.exportReports(parent: url) }
  }
  private func chooseExternalReport() {
    let file = NSOpenPanel(); file.title = "Choose a DVRescue XML report (external claims only)"
    file.canChooseDirectories = false; file.allowsMultipleSelection = false
    guard file.runModal() == .OK, let input = file.url else { return }
    let folder = NSOpenPanel(); folder.title = "Preserve this external report in a new separate folder"
    folder.canChooseFiles = false; folder.canChooseDirectories = true; folder.canCreateDirectories = true
    folder.allowsMultipleSelection = false
    if folder.runModal() == .OK, let parent = folder.url { map.importExternalReport(input, parent: parent) }
  }
  private var overview: some View {
    VStack(alignment: .leading, spacing: 8) {
      ArchiveHeading("Tape map")
      ForEach([DVTapeEvidenceMapExporter.IssueCode.nonzeroVideoSTA, .audioErrorSentinels, .invalidMetadata, .conflictingMetadata,
        .timecodeTransition, .recordedDateTransition, .formatTransition], id: \.self) { code in
        HStack {
          Text(code.rawValue.replacingOccurrences(of: "_", with: " ")).font(.caption).frame(width: 215, alignment: .leading)
          GeometryReader { geometry in
            Canvas { context, size in
              let total = CGFloat(map.receipt?.frameLedgerRecordCount ?? 1)
              for bin in map.summaries {
                let count = bin.issueFrameCounts[code, default: 0]
                let rect = CGRect(x: CGFloat(bin.firstFrameOrdinal) / total * size.width, y: 0,
                  width: max(1, CGFloat(bin.endFrameOrdinalExclusive - bin.firstFrameOrdinal) / total * size.width), height: size.height)
                context.fill(Path(rect), with: .color(count > 0 ? .orange : (bin.qualityAssessedFrames == 0 ? .gray : .teal.opacity(0.3))))
              }
            }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
              let fraction = min(0.999999, max(0, tap.location.x / max(1, geometry.size.width)))
              map.jump(to: UInt64(fraction * Double(map.receipt?.frameLedgerRecordCount ?? 0)))
            })
          }.frame(height: 14).accessibilityLabel("\(code.rawValue) lane; use warning navigation below for keyboard access")
        }
      }
      HStack {
        Picker("Warning filter", selection: $issueFilter) {
          Text("All observations").tag(DVTapeEvidenceMapExporter.IssueCode?.none)
          ForEach(DVTapeEvidenceMapExporter.IssueCode.allCases, id: \.self) { code in
            Text(code.rawValue.replacingOccurrences(of: "_", with: " ")).tag(Optional(code))
          }
        }.frame(maxWidth: 370)
        Button("Previous warning") { map.findIssue(forward: false, code: issueFilter) }
        Button("Next warning") { map.findIssue(forward: true, code: issueFilter) }
      }.disabled(map.busy)
      HStack {
        TextField("Source frame (zero based)", text: $frameEntry).frame(width: 190)
          .onSubmit { if let n = UInt64(frameEntry) { map.jump(to: n) } }
        Button("Go to frame") { if let n = UInt64(frameEntry) { map.jump(to: n) } }
          .disabled(UInt64(frameEntry).map { $0 < (map.receipt?.frameLedgerRecordCount ?? 0) } != true)
        Button("Previous frame") { if let n = map.selection?.frameOrdinal, n > 0 { map.jump(to: n - 1) } }
          .disabled(map.selection?.frameOrdinal ?? 0 == 0)
        Button("Next frame") { if let n = map.selection?.frameOrdinal { map.jump(to: n + 1) } }
          .disabled(map.selection == nil || (map.selection?.frameOrdinal ?? 0) + 1 >= (map.receipt?.frameLedgerRecordCount ?? 0))
      }.disabled(map.busy)
      GeometryReader { geometry in
        Canvas { context, size in
          let total = CGFloat(map.receipt?.frameLedgerRecordCount ?? 1)
          for summary in map.summaries {
            let flagged = summary.issueFrameCount > 0
            let rect = CGRect(x: CGFloat(summary.firstFrameOrdinal) * size.width / total, y: 0,
              width: CGFloat(summary.endFrameOrdinalExclusive - summary.firstFrameOrdinal) * size.width / total,
              height: size.height)
            context.fill(Path(rect), with: .color(flagged ? .orange : .teal))
          }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
          let fraction = min(0.999999, max(0, value.location.x / max(1, geometry.size.width)))
          let frame = UInt64(fraction * Double(map.receipt?.frameLedgerRecordCount ?? 0))
          map.loadPage(frame / DVTapeEvidenceLedgerReader.recordsPerPage)
        })
        .accessibilityLabel("Tape evidence overview. Orange regions contain review observations; teal regions have none of the checked issue types.")
      }.frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
      Text("Click to inspect a region (up to 256 frames). Orange: at least one review observation in that region. Teal: no checked issue types observed—not proof of pristine tape.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func framePage(_ page: DVTapeEvidenceLedgerReader.Page) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button("Previous") { map.loadPage(page.pageNumber - 1) }.disabled(map.busy || page.pageNumber == 0)
        Text("Frames \(page.firstFrameOrdinal)–\(page.endFrameOrdinalExclusive - 1)").monospacedDigit()
        Button("Next") { map.loadPage(page.pageNumber + 1) }
          .disabled(map.busy || page.pageNumber + 1 >= UInt64(map.summaries.count))
        Spacer()
        Toggle("Only review observations on this page", isOn: $issuesOnly).toggleStyle(.checkbox)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(page.records.filter { record in
            (!issuesOnly || !record.issues.isEmpty) && (issueFilter.map { code in record.issues.contains { $0.code == code } } ?? true)
          }, id: \.boundaryEvidence.frameOrdinal) { record in
            Button { map.select(record) } label: {
              HStack {
                ArchiveHeading("Frame \(record.boundaryEvidence.frameOrdinal)")
                  .frame(width: 125, alignment: .leading)
                Text(record.issues.isEmpty ? "No checked issue types observed" : "\(record.issues.count) review observation types")
                  .foregroundStyle(record.issues.isEmpty ? .white : .orange)
                if let timeline = record.timeline {
                  Text("\(timeline.point.timecodeLabel ?? "TC unknown") · \(timeline.point.recordedDate.map { "YY " + $0 } ?? "Date unknown")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
              }.padding(6)
            }.buttonStyle(.plain)
          }
        }
      }.frame(maxHeight: 240)
    }
  }

  private func provenance(_ frame: DVTapeDefectInspector.Model) -> some View {
    ArchiveSection("Frame \(frame.frameOrdinal) · provenance and review") {
      VStack(alignment: .leading, spacing: 10) {
        fact("Source byte range", "\(frame.sourceByteOffset)..<\(frame.sourceByteEndExclusive)")
        fact("Frame SHA-256", frame.frameSHA256)
        ArchiveDisclosure("Source and evidence identity") {
          fact("Source SHA-256", frame.sourceSHA256)
          fact("Map receipt SHA-256", frame.mapReceiptSHA256)
          fact("Frame ledger SHA-256", frame.frameLedgerSHA256)
          Text(frame.provenanceScope).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(frame.issues, id: \.code) { issue in
          ArchiveDisclosure(issue.title) {
            fact("Observed evidence", issue.knownEvidence)
            fact("Limits", issue.unknownLimit)
            fact("Next review action", issue.reviewSuggestion)
          }
        }
        ArchiveDisclosure("Original metadata pack provenance") {
          ForEach(frame.rawPackProvenance, id: \.id) { pack in
            VStack(alignment: .leading, spacing: 4) {
              fact(pack.name, pack.rawHex)
              fact("Source byte offsets", pack.sourceByteOffsets.map(String.init).joined(separator: ", "))
              Text(pack.interpretationStatus).font(.caption).foregroundStyle(.red)
            }.padding(.vertical, 4)
          }
        }
        Text("Review never changes the original capture. A metadata observation alone is not permission to replace a frame or seek a tape.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
  }

  private func fact(_ kind: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(kind.uppercased()).font(.caption.bold()).foregroundStyle(.yellow)
      Text(value).font(.caption).foregroundStyle(.white).textSelection(.enabled)
    }
  }

  private func chooseMap() {
    let panel = NSOpenPanel()
    panel.title = "Open a completed rewindDV tape evidence map"
    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { map.open(url) }
  }
  private func chooseOriginal() {
    let panel = NSOpenPanel()
    panel.title = "Locate the original DV matching this map's SHA-256"
    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { map.connectSource(url) }
  }
  private func choose() {
    let source = NSOpenPanel()
    source.title = "Choose native DV for a tape evidence map"
    source.canChooseDirectories = false; source.allowsMultipleSelection = false
    guard source.runModal() == .OK, let sourceURL = source.url else { return }
    let parent = NSOpenPanel()
    parent.title = "Choose where to save the evidence map"
    parent.canChooseFiles = false; parent.canChooseDirectories = true
    parent.canCreateDirectories = true; parent.allowsMultipleSelection = false
    guard parent.runModal() == .OK, let parentURL = parent.url else { return }
    map.create(source: sourceURL, parent: parentURL)
  }
}
