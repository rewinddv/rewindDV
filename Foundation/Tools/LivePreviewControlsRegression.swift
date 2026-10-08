// OFFLINE ONLY: saved DV, muted audio; no driver, user client or tape access.
import AppKit
import AVFoundation
import CryptoKit
import Foundation

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}
struct LiveReceiveRecord: Sendable {
  let header: Data
  let payload: Data
  let sequence: UInt64
  let transferStatus: UInt16
}
enum DriverBridgeError: Error { case receiptUnavailable(String) }

@main struct LivePreviewControlsRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let sourceBytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
    precondition(sourceBytes.intValue >= 817 * 120_000, "Scrub oracle requires at least 817 NTSC frames")
    let file = try FileHandle(forReadingFrom: url)
    let frame = try file.read(upToCount: 120_000)!
    try file.close()
    precondition(frame.count == 120_000)
    let digest = SHA256.hash(data: frame)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("rewinddv-preview-controls-\(UUID())")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let flight = try LiveReceiveFlight(route: Data(), destinationParent: destination,
      faults: DurableWriterFaults(rawDelayNanoseconds: 50_000_000))
    var expected = Data("RDRXLOG1".utf8)
    let preview = LiveDVPreview(muteAudio: true)
    preview.setZoom(8)
    preview.setZoomCenter(CGPoint(x: -5, y: 5))
    precondition(preview.zoomCenter == CGPoint(x: 0.0625, y: 0.9375))
    preview.setZoom(3)
    precondition(preview.zoom == 8)
    preview.setZoom(1)
    precondition(preview.zoomCenter == CGPoint(x: 0.5, y: 0.5))
    await preview.begin()
    preview.metadata.setRawURL(flight.directory.appendingPathComponent("receive.records.raw"))
    var audioEpoch: UInt64?
    var resets: UInt64?
    let start = ContinuousClock.now
    for ordinal in 0..<180 {
      try await ContinuousClock().sleep(until: start.advanced(by: .nanoseconds(Int64(ordinal) * 33_366_667)))
      if ordinal >= 20 {
        if audioEpoch == nil { audioEpoch = preview.audio.presentationEpoch; resets = preview.videoTimelineResets }
        preview.viewingMode = DVViewingMode.allCases[(ordinal / 8) % DVViewingMode.allCases.count]
        preview.setExtremeZebras(ordinal % 4 < 2)
        preview.setZoom(CGFloat([1, 2, 4, 8][ordinal % 4]))
        preview.setZoomCenter(CGPoint(x: Double(ordinal % 9) / 8, y: 0.25))
        preview.setDisplayAspect(ordinal % 2 == 0 ? .standard : .widescreen)
        precondition(preview.isReceiving)
        precondition(preview.audio.presentationEpoch == audioEpoch, "UI settings restarted the audio clock")
        precondition(preview.videoTimelineResets == resets, "UI settings reset the video timeline")
      }
      // Raw preservation is admitted first and runs on its own serial writer.
      // Display changes never enter that writer or alter its payload.
      let header = Data(repeating: UInt8(ordinal), count: 24)
      precondition(flight.enqueue([LiveReceiveRecord(header: header, payload: frame,
        sequence: UInt64(ordinal + 1), transferStatus: 0)]))
      expected.append(header); expected.append(frame)
      preview.observeReceivePackets(UInt64(ordinal + 1))
      preview.offerPreservedFrame(frame, ordinal: UInt64(ordinal), sourceTimecode: "00:00:00:00")
    }
    let presentationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while preview.latestSubmittedOrdinal != 179, ContinuousClock.now < presentationDeadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(preview.latestSubmittedOrdinal == 179)
    precondition(preview.audio.frameAccounting.offeredFrames == 180)
    precondition(preview.failedVideoFrames == 0)
    precondition(preview.queueSkippedFrames == 0 && preview.rendererSkippedFrames == 0)
    precondition(SHA256.hash(data: frame) == digest)
    precondition(preview.metadata.report != nil && !preview.metadata.isStale)
    precondition((preview.metadata.rawFileBytes ?? 0) > 0)
    print("LIVE_PREVIEW_CONTROLS_PASS; 180 frames, 160 setting changes; \(preview.timingDiagnostics)")
    await preview.end(retainingImage: true)
    precondition(preview.metadata.isStale && preview.metadata.status.hasPrefix("Stopped"))
    preview.setZoom(4)
    preview.setDisplayAspect(.widescreen)
    preview.setExtremeZebras(true)
    await preview.refreshHeldGeometry()
    precondition(preview.hasImage && !preview.isReceiving && preview.latestSubmittedOrdinal == 179)
    precondition(preview.displayAspect == .widescreen && preview.zoom == 4)
    // Reproduce the reported ordering: retain the ended live renderer, then
    // open an offline file and drag back/forth while both renderers exist.
    let playback = OfflineDVPlaybackModel(muteAudio: true)
    playback.open(url: url)
    for _ in 0..<2500 {
      if playback.latestEnqueuedVideoTimeSeconds != nil { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(playback.latestEnqueuedVideoTimeSeconds != nil)
    let cadence = 1001.0 / 30_000.0
    var maxSeek = 0.0
    for frame in [30, 500, 80, 700, 100, 600, 1, 816] {
      let began = ContinuousClock.now
      playback.seek(to: Double(frame) * cadence)
      for _ in 0..<2500 {
        if playback.latestEnqueuedVideoTimeSeconds != nil { break }
        try await Task.sleep(for: .milliseconds(2))
      }
      let elapsed = began.duration(to: .now).components
      maxSeek = max(maxSeek, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
      precondition(playback.currentFrameOrdinal == frame)
      precondition(abs((playback.latestEnqueuedVideoTimeSeconds ?? -1) - Double(frame) * cadence) < 0.000001)
      precondition(playback.sourceTimecodeText != nil)
    }
    var completedDuringDrag = 0
    for step in 0..<120 {
      let frame = step.isMultiple(of: 2) ? 50 + step : 800 - step
      playback.seek(to: Double(frame) * cadence)
      try await Task.sleep(for: .milliseconds(16))
      if playback.latestEnqueuedVideoTimeSeconds != nil { completedDuringDrag += 1 }
    }
    playback.seek(to: 316 * cadence)
    for _ in 0..<2500 {
      if playback.currentFrameOrdinal == 316 && playback.latestEnqueuedVideoTimeSeconds != nil { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(playback.currentFrameOrdinal == 316)
    precondition(playback.latestEnqueuedVideoTimeSeconds != nil)
    precondition(completedDuringDrag >= 90, "Fewer than 75% of paced scrub requests completed within 16ms")
    print("AFTER_LIVE_SCRUB_PASS; maxSeekSeconds=\(maxSeek); completedWithin16ms=\(completedDuringDrag)/120")
    playback.close()
    await preview.end()
    precondition(!preview.hasImage && !preview.isReceiving)
    let joined = await flight.joinRaw()
    precondition(joined.failure == nil && joined.durableThrough == 180 && joined.idle)
    try await flight.finish("offline live-preview controls regression")
    let raw = try Data(contentsOf: flight.directory.appendingPathComponent("receive.records.raw"))
    precondition(raw == expected && SHA256.hash(data: raw) == SHA256.hash(data: expected))
    print("LIVE_PREVIEW_CONCURRENT_RAW_WRITER_BIT_EXACT_PASS; bytes=\(raw.count)")
    print("LIVE_PREVIEW_HELD_SETTINGS_AND_END_PASS")
  }
}
