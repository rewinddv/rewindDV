// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreImage
import SwiftUI
import CryptoKit

@MainActor final class DVArchiveVisualReviewModel: ObservableObject {
  struct Sample: Identifiable {
    var id: UInt64 { evidence.identity.ordinal }
    let evidence: SampleEvidence
    let image: NSImage?
    let png: Data?
  }
  struct SampleEvidence: Codable, Sendable {
    let identity: DVSourceFrameIdentity
    let frameSHA256: String
    let recordedTimecode: String?
    let imageFile: String?
    let imageSHA256: String?
    let pictureStatus: String
  }
  struct ContactReceipt: Codable, Sendable {
    let schemaVersion: Int
    let completion: String
    let plan: DVArchiveSamplePlan
    let mapReceiptSHA256: String
    let samples: [SampleEvidence]
    let htmlSHA256: String
    let qualification: String
  }
  @Published private(set) var samples: [Sample] = []
  @Published private(set) var busy = false
  @Published private(set) var message = "Build a source-bound filmstrip after verifying the original DV."
  @Published private(set) var output: URL?
  private var plan: DVArchiveSamplePlan?
  private var map: DVTapeEvidenceLedgerReader?
  private var source: DVVerifiedFrameSource?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private let decoder = LiveDVFrameDecoder()

  func reset() {
    task?.cancel(); task = nil; generation = UUID(); busy = false
    samples = []; plan = nil; map = nil; source = nil; output = nil
    message = "Build a source-bound filmstrip after verifying the original DV."
  }
  func cancel() { task?.cancel() }
  func build(map: DVTapeEvidenceLedgerReader, source: DVVerifiedFrameSource, first: UInt64, end: UInt64) {
    reset(); self.map = map; self.source = source; busy = true
    let id = generation
    task = Task {
      defer { if generation == id { busy = false; task = nil } }
      do {
        let plan = try DVArchiveSamplePlan.make(source: map.binding.mapReceipt.sourceSnapshot, first: first, endExclusive: end)
        try await source.requireSnapshot(plan.source)
        let context = CIContext()
        var result: [Sample] = []
        for identity in plan.frames {
          try Task.checkCancellation()
          let page = try await map.page(identity.ordinal / DVTapeEvidenceLedgerReader.recordsPerPage)
          guard let record = page.records.first(where: { $0.boundaryEvidence.frameOrdinal == identity.ordinal }) else {
            throw DVIngestError.invalidEvidence("sample ordinal missing from verified map")
          }
          let original = try await source.frame(record)
          var png: Data?, image: NSImage?, status = "Decoded navigation image; original interlaced frame remains authoritative"
          do {
            guard original.evidence.videoLayout != nil else { throw LiveDVDecodeError.malformedFrame }
            let decoded = try await decoder.decode(original.bytes, ordinal: identity.ordinal, timecode: nil,
              viewingMode: .weave, forensicDVCPROPAL: original.evidence.videoLayout == .pal411)
            let picture = CIImage(cvPixelBuffer: decoded.pixelBuffer)
            let reduced = picture.transformed(by: CGAffineTransform(scaleX: 320 / picture.extent.width, y: 320 / picture.extent.width))
            guard let cg = context.createCGImage(reduced, from: reduced.extent),
              let bytes = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
              throw LiveDVDecodeError.noDecodedImage
            }
            png = bytes; image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
          } catch { status = "Picture unavailable: " + error.localizedDescription }
          try Task.checkCancellation()
          guard generation == id else { return }
          let evidence = SampleEvidence(identity: identity, frameSHA256: record.boundaryEvidence.frameSHA256,
            recordedTimecode: record.timeline?.point.timecodeLabel,
            imageFile: png == nil ? nil : "frame-\(identity.ordinal).png",
            imageSHA256: png.map { DVAnalysisReportExporter.hex(SHA256.hash(data: $0)) }, pictureStatus: status)
          result.append(Sample(evidence: evidence, image: image, png: png))
          message = "Verified sample \(result.count) of \(plan.frames.count)…"
        }
        try await source.verifyUnchanged()
        guard generation == id else { return }
        self.plan = plan; samples = result
        message = "\(result.count) source-bound samples. \(plan.omittedTransitionEndpoints) transition endpoints omitted by the sample budget. Pictures are navigation aids, not proof of media quality."
      } catch {
        guard generation == id else { return }
        samples = []; self.plan = nil; message = "Visual review incomplete: \(error.localizedDescription)"
      }
    }
  }

  func exportContactSheet(parent: URL) {
    guard !busy, let plan, let map, let source, !samples.isEmpty else { return }
    let id = generation, rows = samples.map(\.evidence), images = samples.map(\.png)
    let destination = parent.appendingPathComponent("RewindDV-Contact-\(UUID())")
    let access = parent.startAccessingSecurityScopedResource()
    busy = true; output = nil
    task = Task {
      defer { if access { parent.stopAccessingSecurityScopedResource() }; if generation == id { busy = false; task = nil } }
      let operation = Task.detached(priority: .utility) {
        try await source.requireSnapshot(plan.source)
        let directory = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
        defer { directory.close() }
        try directory.writeExclusive(named: "intent.json", data: Data("{\"state\":\"incomplete_until_contact_json\"}".utf8), synchronize: true)
        var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>rewindDV contact sheet</title><style>body{font:14px system-ui;background:#111;color:#eee;padding:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:24px}img{max-width:100%;height:auto}p{overflow-wrap:anywhere}small{color:#bbb}</style></head><body><h1>Source-bound contact sheet</h1><p>Source SHA-256: \(plan.source.sourceSHA256)</p><p>Sampled source ordinals; navigation images do not establish media quality. No frame is substituted when decoding is unavailable.</p><main>"
        for (i, row) in rows.enumerated() {
          try Task.checkCancellation()
          // Bind every sample again before publication, including its exact hash.
          let page = try await map.page(row.identity.ordinal / DVTapeEvidenceLedgerReader.recordsPerPage)
          guard let record = page.records.first(where: { $0.boundaryEvidence.frameOrdinal == row.identity.ordinal }),
            record.boundaryEvidence.frameSHA256 == row.frameSHA256 else { throw DVIngestError.invalidEvidence("contact sample map changed") }
          _ = try await source.frame(record)
          if let png = images[i], let name = row.imageFile, let sha = row.imageSHA256 {
            try directory.writeExclusive(named: name + ".partial", data: png, synchronize: true)
            try directory.promoteExclusive(from: name + ".partial", to: name, expectedBytes: UInt64(png.count), expectedSHA256: sha)
          }
          let f = row.identity
          html += "<article><h2>Frame \(f.ordinal) · \(f.system.rawValue)</h2>"
          if let name = row.imageFile { html += "<img src=\"\(name)\" alt=\"Source frame \(f.ordinal)\">" }
          html += "<p>Byte \(f.byteOffset) · \(f.byteCount) bytes<br>Epoch \(f.epochID)<br>Presentation \(f.startTick)/30000 s<br>Recorded timecode: \(DVAnalysisReportExporter.xmlEscape(row.recordedTimecode ?? "unavailable"))</p><small>\(DVAnalysisReportExporter.xmlEscape(row.pictureStatus))<br>Frame SHA-256: \(row.frameSHA256)</small></article>"
        }
        html += "</main></body></html>"
        let data = Data(html.utf8), htmlSHA = DVAnalysisReportExporter.hex(SHA256.hash(data: Data(html.utf8)))
        try directory.writeExclusive(named: "contact.html.partial", data: data, synchronize: true)
        try directory.promoteExclusive(from: "contact.html.partial", to: "contact.html", expectedBytes: UInt64(data.count), expectedSHA256: htmlSHA)
        let receipt = ContactReceipt(schemaVersion: 1, completion: "complete", plan: plan,
          mapReceiptSHA256: map.binding.mapReceiptSHA256, samples: rows, htmlSHA256: htmlSHA,
          qualification: "Offline verified byte identities and derived navigation images; not physical acquisition or picture-quality qualification")
        let marker = try DVAnalysisReportExporter.encode(receipt)
        try directory.writeExclusive(named: "contact.json.partial", data: marker, synchronize: true)
        try await source.verifyUnchanged()
        if map.binding.pageCount > 0 { _ = try await map.page(map.binding.pageCount - 1) }
        try Task.checkCancellation(); try directory.requireCurrentDestinationPath(); try directory.synchronize()
        try directory.promoteExclusive(from: "contact.json.partial", to: "contact.json", expectedBytes: UInt64(marker.count), expectedSHA256: DVAnalysisReportExporter.hex(SHA256.hash(data: marker)))
        do { try directory.synchronize() }
        catch { directory.withdrawCompletionMarkerBestEffort(from: "contact.json", to: "contact.json.partial"); throw error }
      }
      do {
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        guard generation == id else { return }
        output = destination; message = "Contact sheet and source-mapping manifest verified."
      } catch {
        guard generation == id else { return }
        message = "Contact sheet incomplete: \(error.localizedDescription). Partial evidence retained at \(destination.path)."
      }
    }
  }
}

struct DVArchiveVisualReviewView: View {
  @ObservedObject var visual: DVArchiveVisualReviewModel
  let canBuild: Bool
  let build: (UInt64, UInt64) -> Void
  let select: (UInt64) -> Void
  let frameCount: UInt64
  @State private var first = "0"
  @State private var end = ""
  @State private var grid = false
  private var range: (UInt64, UInt64)? {
    guard let start = UInt64(first), let stop = UInt64(end), start < stop, stop <= frameCount else { return nil }
    return (start, stop)
  }
  var body: some View {
    ArchiveDisclosure("Filmstrip and contact sheet") {
      HStack {
        TextField("First ordinal", text: $first).frame(width: 110).accessibilityIdentifier("filmstrip-first")
        TextField("Exclusive end", text: $end).frame(width: 110).accessibilityIdentifier("filmstrip-end")
        Button("Build filmstrip") { if let range { build(range.0, range.1) } }
          .disabled(!canBuild || range == nil || visual.busy).accessibilityIdentifier("filmstrip-build")
        Toggle("Contact-sheet layout", isOn: $grid).toggleStyle(.checkbox)
        if visual.busy { ProgressView().controlSize(.small); Button("Cancel") { visual.cancel() } }
      }
      Text("Zero-based source ordinals; exclusive end. Every image retains its original byte offset and recording system.").font(.caption)
      Text(visual.message).font(.caption).textSelection(.enabled)
      if grid {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))]) { ForEach(visual.samples) { sample in tile(sample) } }
      } else {
        ScrollView(.horizontal) { HStack(alignment: .top) { ForEach(visual.samples) { sample in tile(sample).frame(width: 220) } } }
      }
      Button("Export contact sheet…") {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Creates a separate HTML contact sheet, PNG samples and contact.json source-mapping manifest."
        if panel.runModal() == .OK, let parent = panel.url { visual.exportContactSheet(parent: parent) }
      }.disabled(visual.samples.isEmpty || visual.busy).accessibilityIdentifier("contact-sheet-export")
      if let output = visual.output { Button("Show contact sheet") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
    }.onAppear { if end.isEmpty { end = String(frameCount) } }
      .onChange(of: frameCount) { _, count in first = "0"; end = String(count) }
  }
  private func tile(_ sample: DVArchiveVisualReviewModel.Sample) -> some View {
    Button { select(sample.id) } label: {
      VStack(alignment: .leading, spacing: 5) {
        if let image = sample.image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 160) }
        else { Text("Picture unavailable").frame(height: 160) }
        Text("Frame \(sample.id) · \(sample.evidence.identity.system.rawValue)")
        Text("Byte \(sample.evidence.identity.byteOffset)")
        Text(sample.evidence.recordedTimecode ?? "Recorded timecode unavailable")
      }.font(.caption).padding(5)
    }.buttonStyle(.plain).accessibilityLabel("Inspect source frame \(sample.id), byte \(sample.evidence.identity.byteOffset), \(sample.evidence.identity.system.rawValue)")
  }
}
