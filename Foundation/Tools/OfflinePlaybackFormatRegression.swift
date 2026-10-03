// Read-only native playback oracle. No driver or deck commands are linked.
import AVFoundation
import AppKit
import CryptoKit
import Foundation

@main struct OfflinePlaybackFormatRegression {
  struct Expected { let ordinal: Int; let offset: UInt64; let bytes: Int; let tick: Int64 }
  struct Failure: Error { let reason: String }
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide a raw DV source") }
    setbuf(stdout, nil)
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    // Independent boundary oracle: count source bytes and sum exact cadence,
    // without using the product timeline or Apple's uniform raw importer.
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let length = try handle.seekToEnd()
    var selected: [Expected] = [], previous: Expected?, offset: UInt64 = 0, tick: Int64 = 0, ordinal = 0
    while offset < length {
      try autoreleasepool {
        try handle.seek(toOffset: offset)
        guard let h = try handle.read(upToCount: 80), h.count == 80 else { throw Failure(reason: "Oracle short header") }
        let size = h[3] & 0x80 == 0 ? 120000 : 144000
        let current = Expected(ordinal: ordinal, offset: offset, bytes: size, tick: tick)
        if let previous, previous.bytes != size { selected.append(previous); selected.append(current) }
        if ordinal < 10 || ordinal % 10000 == 0 { selected.append(current) }
        previous = current; offset += UInt64(size); tick += size == 144000 ? 1200 : 1001; ordinal += 1
      }
    }
    if let previous { selected.append(previous) }
    guard offset == length else { throw Failure(reason: "Oracle incomplete tail") }
    _ = NSApplication.shared
    let model = OfflineDVPlaybackModel(muteAudio: true)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 576)); host.wantsLayer = true
    host.layer?.addSublayer(model.displayLayer); model.displayLayer.frame = host.bounds
    defer { model.close(); withExtendedLifetime(host) {} }
    func require(_ yes: Bool, _ reason: String) throws {
      guard yes else { throw Failure(reason: reason) }; print("PASS", reason)
    }
    func waitFrame(_ expected: Int? = nil) async throws {
      let deadline = Date().addingTimeInterval(60)
      while Date() < deadline {
        if case .failed(let reason) = model.state { throw Failure(reason: reason) }
        if model.latestEnqueuedVideoTimeSeconds != nil,
          expected == nil || model.metadata.report?.frameOrdinal == UInt64(expected!) { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      throw Failure(reason: "Timed out awaiting selected frame \(String(describing: expected)): \(model.state)")
    }
    let began = Date(); model.open(url: url); try await waitFrame(0)
    print("LOAD_SECONDS", Date().timeIntervalSince(began), "FRAMES", ordinal)
    try require(abs(model.durationSeconds - Double(tick) / 30000) < 1e-9, "duration equals independent variable-cadence source oracle")
    try require(!model.frameCounterIsEstimated, "source ordinals are exact")
    for expected in selected + selected.reversed() {
      model.seek(to: Double(expected.tick) / 30000); try await waitFrame(expected.ordinal)
      try require(model.currentFrameOrdinal == expected.ordinal, "seek ordinal \(expected.ordinal)")
      try require(abs(model.currentTimeSeconds - Double(expected.tick) / 30000) < 1e-9, "exact selected frame PTS")
      try handle.seek(toOffset: expected.offset)
      let bytes = try handle.read(upToCount: expected.bytes)!
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      try require(model.metadata.report?.frameSHA256 == hash, "inspector source hash at byte \(expected.offset)")
      try require(model.rasterHeight == (expected.bytes == 144000 ? 576 : 480), "selected raster follows system")
      guard let fileFacts = model.technicalSpecifications, let sampled = model.metadata.specifications else {
        throw Failure(reason: "Selected inspector specification snapshot is missing")
      }
      let inspector = fileFacts.playbackReport(sampledFrame: sampled, timeline: model.sourceTimeline)
      func value(_ section: String, _ label: String) -> String? {
        inspector.sections.first { $0.title == section }?.rows.first { $0.label == label }?.value
      }
      let pal = bytes[3] & 0x80 != 0
      try require(value("Video", "Standard") == (pal ? "PAL" : "NTSC"), "visible inspector standard follows selected source bytes")
      try require(value("Video", "Height") == (pal ? "576 pixels" : "480 pixels"), "visible inspector height follows selected source bytes")
      try require(value("Video", "Width") == "720 pixels", "visible inspector source width")
      try require(value("Video", "Frame rate") == (pal ? "25.000 (25/1) FPS" : "29.970 (30000/1001) FPS"), "visible inspector exact source cadence")
      if sampled.semanticReport?.format == "IEC 61834 consumer DV" {
        // Independent raw VAUX check: system identity alone does not establish
        // chroma when the source pack is absent (as on a real boundary frame).
        var sourceTypes: Set<UInt8> = []
        for block in stride(from: 0, to: bytes.count, by: 80) where bytes[block] >> 5 == 2 {
          for slot in stride(from: 3, through: 73, by: 5) where bytes[block + slot] == 0x60 {
            sourceTypes.insert(bytes[block + slot + 3] & 0x1f)
          }
        }
        let chroma = sourceTypes == [0] ? (pal ? "4:2:0" : "4:1:1") : "Unknown / conflicting"
        try require(value("Video", "Chroma subsampling") == chroma, "visible inspector consumer DV chroma: \(chroma)")
      }
      try require(sampled.semanticReport?.frameSHA256 == hash, "all inspector format fields share the exact selected source hash")
      try require(model.metadata.geometry == nil || model.metadata.geometry?.rows.first { $0.label == "Stored dimensions" }?.value == (pal ? "720 × 576" : "720 × 480"), "Apple geometry belongs to the same sampled frame")

      try require(model.sourceTimecodeText == MonitorSourceTimecode.display(nativeDVFrame: bytes), "timecode is bound to selected source")
      for mode in [DVViewingMode.standard, .allCases[1]] {
        model.setViewingMode(mode); try await waitFrame(expected.ordinal)
        try require(model.currentFrameOrdinal == expected.ordinal, "view mode retains source selection")
      }
    }
    // Rapid coalesced seeks must converge after repeated system changes.
    for _ in 0..<5 { for e in selected { model.seek(to: Double(e.tick) / 30000) } }
    let last = selected.last!; try await waitFrame(last.ordinal)
    try require(model.currentFrameOrdinal == last.ordinal && model.metadata.maxPendingFrames <= 1, "rapid mixed-system scrubbing remains bounded and converges")
    let transitions = selected.filter { item in selected.contains { $0.ordinal == item.ordinal - 1 && $0.bytes != item.bytes } }
    for e in transitions {
      model.seek(to: max(0, Double(e.tick) / 30000 - 0.12)); try await waitFrame()
      model.play()
      let end = min(model.durationSeconds, Double(e.tick) / 30000 + 0.5)
      let deadline = Date().addingTimeInterval(5)
      while model.currentTimeSeconds < end - 0.03, Date() < deadline {
        if case .failed(let reason) = model.state { throw Failure(reason: reason) }
        try await Task.sleep(for: .milliseconds(10))
      }
      try require(model.currentTimeSeconds >= end - 0.03, "continuous playback crosses transition at \(e.ordinal)")
      try require(!model.decodedAudioHasConflict, "audio remains valid after system transition: \(model.audioDescription)")
      model.pause(); try await waitFrame()
      let frame = model.currentFrameOrdinal
      model.stepFrames(-1); try await waitFrame(frame - 1)
      model.stepFrames(1); try await waitFrame(frame)
    }
    model.seek(to: model.durationSeconds); try await waitFrame(ordinal - 1)
    model.play()
    for _ in 0..<200 where model.state == .playing { try await Task.sleep(for: .milliseconds(10)) }
    try require(model.state == .ended, "final frame reaches EOF")
    print("OFFLINE_FORMAT_REGRESSION_PASS")
  }
}
