// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

actor SurgeryThumbnailDecoder {
  private let decoder = LiveDVFrameDecoder()
  private let context = CIContext(options: [.cacheIntermediates: false])
  func image(url: URL, clip: DVSurgeryClip, frame: Int) async throws -> CGImage {
    try Task.checkCancellation()
    try clip.timeline.verifyUnchanged(url: url)
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let bytes = try clip.timeline.readFrame(frame, from: input)
    let pixel = try await decoder.decode(bytes, ordinal: UInt64(frame), timecode: nil,
      forensicDVCPROPAL: bytes[3] & 128 != 0 && bytes[4] & 7 == 1)
    try Task.checkCancellation()
    let source = CIImage(cvPixelBuffer: pixel.pixelBuffer)
    // Navigation thumbnail only. Original interlaced picture and audio are
    // exported untouched. Use the current source's explicit display code.
    var wide = false
    if let report = try? DVMetadataInventory.inspect(frame: bytes, ordinal: UInt64(frame), byteOffset: clip.timeline.frame(frame).byteOffset) {
      let semantics = DVPackSemanticReport.inspect(report)
      wide = semantics.packs.contains { $0.typeHex == "0x61" && $0.fields.contains { $0.id == "DISP" && $0.rawValue == 2 && $0.status == "interpreted" } }
    }
    let height = wide ? 180.0 : 240.0
    let resized = source.transformed(by: CGAffineTransform(scaleX: 320 / source.extent.width, y: height / source.extent.height))
    guard let image = context.createCGImage(resized, from: resized.extent) else { throw LiveDVDecodeError.noDecodedImage }
    try clip.timeline.verifyUnchanged(url: url)
    return image
  }
}

@MainActor final class SurgeryModel: ObservableObject {
  @Published private(set) var clip: DVSurgeryClip?
  @Published private(set) var sourceURL: URL?
  @Published private(set) var busy = false
  @Published private(set) var choosing = false
  private var panel: NSOpenPanel?
  @Published private(set) var progress = 0.0
  @Published private(set) var status = "Open a DV clip to find its formats and recording breaks."
  @Published private(set) var error: String?
  @Published private(set) var epoch = UUID()
  @Published var first = 0
  @Published var end = 0
  @Published var startText = "00:00:00.000"
  @Published var endText = "00:00:00.000"
  @Published var splitScenes = false
  @Published private(set) var selectedSegments: Set<Int> = []
  @Published private(set) var exportedURL: URL?
  private var operation: Task<Void, Never>?
  private let decoder = SurgeryThumbnailDecoder()
  private var cache: [Int: CGImage] = [:]
  private var cacheOrder: [Int] = []
  private var sourceAccess = false

  var ranges: [DVSurgeryByteExporter.Range] { (try? clip?.ranges(first: first, end: end, splitScenes: splitScenes)) ?? [] }
  var mergeRanges: [DVSurgeryByteExporter.Range] { (try? clip?.selectedRanges(selectedSegments)) ?? [] }
  var mergeIssue: String? {
    if mergeRanges.isEmpty { return "Check the segments you want to join." }
    if Set(mergeRanges.map(\.format)).count > 1 { return "Choose segments with the same format. Export PAL, NTSC and DV profiles separately." }
    return nil
  }
  func toggleSegment(_ id: Int) {
    guard !busy, !choosing, clip?.segments.contains(where: { $0.id == id }) == true else { return }
    if !selectedSegments.insert(id).inserted { selectedSegments.remove(id) }
    error = nil; exportedURL = nil
  }
  func selectAllSegments(_ all: Bool) {
    guard !busy, !choosing else { return }
    selectedSegments = all ? Set(clip?.segments.map(\.id) ?? []) : []
    error = nil; exportedURL = nil
  }
  var hasUnappliedTimes: Bool { guard let clip else { return false }; return startText != time(clip.seconds(first)) || endText != time(clip.seconds(end)) }
  func time(_ seconds: Double) -> String { MonitorCounter.elapsed(seconds: (seconds * 1000).rounded() / 1000) }
  func choose() {
    guard !busy, !choosing else { return }
    let panel = NSOpenPanel(); panel.title = "Open a clip for Surgery"
    panel.allowedContentTypes = [UTType(filenameExtension: "dv") ?? .data, UTType(filenameExtension: "dif") ?? .data]
    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    self.panel = panel; choosing = true
    panel.begin { [weak self] response in
      self?.panel = nil; self?.choosing = false
      if response == .OK, let url = panel.url { self?.open(url) }
    }
  }
  func open(_ url: URL) {
    guard !busy else { return }
    if sourceAccess { sourceURL?.stopAccessingSecurityScopedResource() }
    sourceAccess = url.startAccessingSecurityScopedResource()
    sourceURL = url; clip = nil; selectedSegments = []; cache.removeAll(); cacheOrder.removeAll(); epoch = UUID()
    exportedURL = nil; error = nil; busy = true; progress = 0; status = "Reading frame boundaries and recording metadata…"
    let job = Task.detached(priority: .userInitiated) { [weak self] in
      try DVSurgeryClip.read(url) { value in Task { @MainActor [weak self] in self?.progress = value } }
    }
    operation = Task {
      defer { busy = false; operation = nil }
      do {
        let loaded = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        try Task.checkCancellation()
        clip = loaded; select(first: 0, end: loaded.timeline.frameCount)
        status = "\(loaded.timeline.frameCount.formatted()) frames inspected · \(loaded.segments.count) segments"
      } catch is CancellationError { status = "Analysis cancelled." }
      catch { self.error = error.localizedDescription; status = "Unable to analyze this clip." }
    }
  }
  func cancel() { operation?.cancel() }
  func select(first: Int, end: Int) {
    guard let clip else { return }
    self.first = min(max(0, first), clip.timeline.frameCount - 1)
    self.end = min(max(self.first + 1, end), clip.timeline.frameCount)
    startText = time(clip.seconds(self.first)); endText = time(clip.seconds(self.end)); error = nil; exportedURL = nil
  }
  @discardableResult func applyTimes() -> Bool {
    guard let clip, let start = DVSurgeryClip.parseTime(startText), let finish = DVSurgeryClip.parseTime(endText),
      start < finish, start >= 0, finish <= clip.timeline.durationSeconds + 0.00051 else {
      error = "Enter a valid start and end within the clip (HH:MM:SS.mmm or seconds)."; return false
    }
    let a = clip.boundary(at: start), b = clip.boundary(at: finish)
    guard a < b else { error = "The range must contain at least one complete frame."; return false }
    select(first: a, end: b); return true
  }
  func thumbnail(_ frame: Int) async -> CGImage? {
    guard let clip, let url = sourceURL else { return nil }
    if let image = cache[frame] { return image }
    let current = epoch
    do {
      let image = try await decoder.image(url: url, clip: clip, frame: frame)
      try Task.checkCancellation()
      guard current == epoch else { return nil }
      if cache[frame] == nil { cacheOrder.append(frame) }
      cache[frame] = image
      while cacheOrder.count > 96 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
      return image
    } catch { return nil }
  }
  func chooseExport(merged: Bool = false) {
    guard !busy, !choosing else { return }
    if merged { guard mergeIssue == nil else { return } }
    else { guard applyTimes(), !ranges.isEmpty else { return } }
    let panel = NSOpenPanel(); panel.title = merged ? "Choose a folder for the merged clip" : "Choose a folder for the lossless exports"
    panel.prompt = "Export here"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    self.panel = panel; choosing = true
    panel.begin { [weak self] response in
      self?.panel = nil; self?.choosing = false
      guard response == .OK, let parent = panel.url else { return }
      self?.export(to: parent, merged: merged)
    }
  }
  func export(to parent: URL, merged: Bool = false) {
    let selected = merged ? mergeRanges : ranges
    guard let clip, let url = sourceURL, !busy, !selected.isEmpty else { return }
    if merged, let issue = mergeIssue { error = issue; return }
    let access = parent.startAccessingSecurityScopedResource()
    let output = parent.appendingPathComponent("Surgery — " + UUID().uuidString.prefix(8))
    busy = true; progress = 0; error = nil; exportedURL = nil; status = "Copying original frames and verifying saved files…"
    let job = Task.detached(priority: .userInitiated) { [weak self] in
      try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: selected, destination: output, layout: merged ? .merged : .separate) { value in
        Task { @MainActor [weak self] in self?.progress = value }
      }
    }
    operation = Task {
      defer { busy = false; operation = nil; if access { parent.stopAccessingSecurityScopedResource() } }
      do {
        let receipt = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        exportedURL = output; status = merged ? "\(selected.count) segments merged into one lossless clip, saved and verified." : "\(receipt.outputs.count) lossless \(receipt.outputs.count == 1 ? "clip" : "clips") saved and verified."
      } catch is CancellationError { status = "Export cancelled. Any partial folder is marked incomplete." }
      catch { self.error = error.localizedDescription; status = "Export did not complete. Any partial folder is marked incomplete." }
    }
  }
}
