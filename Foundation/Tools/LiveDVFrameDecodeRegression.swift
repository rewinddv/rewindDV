// Native, silent, offline stream-decode prerequisite. Does not open a driver.
import AVFoundation
import AppKit
import Foundation

// Standalone preview harness: no driver or live-monitor linkage.
struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

@main struct LiveDVFrameDecodeRegression {
  @MainActor static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    guard condition() else {
      try? FileHandle.standardError.write(contentsOf: Data("PRESENTATION_DEADLINE_FAILED \(description)\n".utf8))
      fatalError(description)
    }
  }
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide one local DV fixture") }
    let decoder = LiveDVFrameDecoder()
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
    defer { try? handle.close() }
    let began = Date()
    var count = 0
    var maxDecode = 0.0
    var firstFrame = Data()
    while let frame = try handle.read(upToCount: 120_000), !frame.isEmpty {
      guard frame.count == 120_000 else { fatalError("NTSC fixture expected") }
      let before = Date()
      let result = try await decoder.decode(frame, ordinal: UInt64(count), timecode: nil)
      maxDecode = max(maxDecode, Date().timeIntervalSince(before))
      precondition(CVPixelBufferGetWidth(result.pixelBuffer) == 720)
      precondition(CVPixelBufferGetHeight(result.pixelBuffer) == 480)
      if count == 0 {
        firstFrame = frame
        print(
          "FIELD_COUNT=\(String(describing: CVBufferCopyAttachment(result.pixelBuffer, kCVImageBufferFieldCountKey, nil)))"
        )
        print(
          "FIELD_DETAIL=\(String(describing: CVBufferCopyAttachment(result.pixelBuffer, kCVImageBufferFieldDetailKey, nil)))"
        )
        print(
          "PRIMARIES=\(String(describing: CVBufferCopyAttachment(result.pixelBuffer, kCVImageBufferColorPrimariesKey, nil)))"
        )
      }
      count += 1
    }
    await decoder.reset()
    print(
      "LIVE_DECODE_OFFLINE_PASS frames=\(count) seconds=\(Date().timeIntervalSince(began)) maxFrameSeconds=\(maxDecode)"
    )
    _ = NSApplication.shared
    let preview = LiveDVPreview(muteAudio: true)
    await preview.begin()
    let metadata = DVCaptureMetadataEpochAnalyzer.analyze(data: firstFrame)
    let timecode = metadata.frames.first.flatMap {
      MonitorSourceTimecode.display(packs: $0.sourceTimecodePacks.map(\.rawBytes), isPAL: false)
    }
    precondition(timecode != nil)
    // Offline backpressure simulation: repeat one already-preserved fixture
    // frame with synthetic preview sequence numbers, not source tape ordinals.
    for sequence in 0..<100 {
      preview.offerPreservedFrame(firstFrame, ordinal: UInt64(sequence), sourceTimecode: timecode)
    }
    for _ in 0..<500 {
      if preview.latestSubmittedOrdinal == 99 || preview.error != nil { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    print("FIFO_RESULT ordinal=\(String(describing: preview.latestSubmittedOrdinal)) skipped=\(preview.skippedPreviewFrames) error=\(String(describing: preview.error))")
    precondition(preview.error == nil, preview.error ?? "unknown")
    precondition(preview.latestSubmittedOrdinal == 99)
    precondition(preview.sourceTimecode == timecode)
    // The independent bound is 16 waiting frames; all 100 offers occur without
    // suspension on MainActor, so no worker can dequeue during submission.
    let offered: UInt64 = 100, expectedRetained: UInt64 = 16
    precondition(preview.queueSkippedFrames == offered - expectedRetained)
    precondition(preview.decodedFrames == expectedRetained)
    precondition(preview.decodedFrames + preview.queueSkippedFrames == offered)
    precondition(preview.failedVideoFrames == 0)
    precondition(preview.skippedPreviewFrames == preview.queueSkippedFrames + preview.rendererSkippedFrames)
    precondition(preview.rendererSkippedFrames < preview.decodedFrames)
    print("LIVE_PREVIEW_BOUNDED_FIFO_PASS submitted=99 queue_skipped=\(preview.queueSkippedFrames) decoded=\(preview.decodedFrames) renderer_skipped=\(preview.rendererSkippedFrames) timecode=\(timecode!)")
    preview.offerPreservedFrame(firstFrame, ordinal: 100, sourceTimecode: timecode)
    await preview.end()
    try await Task.sleep(for: .milliseconds(50))
    precondition(
      !preview.isReceiving && preview.latestSubmittedOrdinal == nil && preview.sourceTimecode == nil
    )
    print("LIVE_PREVIEW_END_CANCELS_STALE_PUBLICATION_PASS")
    await preview.begin()
    preview.offerPreservedFrame(firstFrame, ordinal: 0, sourceTimecode: timecode)
    preview.offerPreservedFrame(firstFrame, ordinal: 1, sourceTimecode: timecode)
    try await waitUntil("two-frame native presentation") { preview.latestSubmittedOrdinal == 1 && preview.audio.presentation.channel(at: 0).active }
    precondition(preview.skippedPreviewFrames == 0)
    precondition(preview.latestSubmittedOrdinal == 1)
    precondition(preview.audio.detail.contains("48,000") || preview.audio.detail.contains("48000"))
    precondition(preview.audio.presentation.channel(at: 0).active)
    // Decoded preview samples stay full-raster square pixel. The viewport,
    // independently tested by LiveAspectGeometryRegression, owns display PAR.
    precondition(abs((preview.presentedAspectRatio ?? 0) - 1.5) < 0.0001)
    precondition(abs(preview.displayAspectRatio - 4.0 / 3.0) < 0.0001)
    await preview.end(retainingImage: true)
    precondition(preview.hasImage && preview.sourceTimecode == timecode)
    precondition(!preview.audio.presentation.channel(at: 0).active)
    preview.aspect = .anamorphic
    await preview.refreshHeldGeometry()
    precondition(abs((preview.presentedAspectRatio ?? 0) - 1.5) < 0.0001)
    precondition(abs(preview.displayAspectRatio - 16.0 / 9.0) < 0.0001)
    print("LIVE_PCM_METERS_FINAL_IMAGE_AND_4_3_16_9_GEOMETRY_PASS; speaker output muted during test")
    await preview.begin()
    // Real-time two-frame batches exercise native renderer fullness, not just
    // queue bookkeeping. All bytes are from an already saved offline fixture.
    try handle.seek(toOffset: 0)
    let pacingStart = ContinuousClock.now
    for pair in 0..<((count + 1) / 2) {
      for offset in 0..<2 {
        guard pair * 2 + offset < count else { continue }
        let fixtureFrame = try handle.read(upToCount: 120_000)!
        precondition(fixtureFrame.count == 120_000)
        preview.offerPreservedFrame(fixtureFrame, ordinal: UInt64(pair * 2 + offset), sourceTimecode: timecode)
      }
      let offered = min((pair + 1) * 2, count)
      try await ContinuousClock().sleep(until: pacingStart.advanced(by: .nanoseconds(Int64(offered) * 33_366_667)))
    }
    try await waitUntil("paced tail native presentation") { preview.latestSubmittedOrdinal == UInt64(count - 1) }
    print("PACED_RESULT ordinal=\(String(describing: preview.latestSubmittedOrdinal)) video_skips=\(preview.skippedPreviewFrames) audio_skips=\(preview.audio.skippedAudioFrames) resyncs=\(preview.audio.resynchronizations) last_resync=\(preview.audio.lastResynchronization)")
    precondition(preview.error == nil)
    precondition(preview.latestSubmittedOrdinal == UInt64(count - 1))
    precondition(preview.skippedPreviewFrames == 0)
    precondition(preview.audio.skippedAudioFrames == 0)
    precondition(preview.audio.resynchronizations == 0)
    await preview.end(retainingImage: true)
    print("LIVE_PREVIEW_REALTIME_TWO_FRAME_BATCHES_PASS frames=\(count)")
    await preview.begin()
    preview.offerPreservedFrame(firstFrame, ordinal: 0, sourceTimecode: "00:00:00:00")
    try await Task.sleep(for: .milliseconds(20))
    preview.offerPreservedFrame(firstFrame, ordinal: 100, sourceTimecode: "00:00:03:10")
    try await Task.sleep(for: .milliseconds(400))
    precondition(preview.error == nil)
    precondition(preview.audio.resynchronizations == 1)
    precondition(preview.videoTimelineResets == 1)
    precondition(preview.latestSubmittedOrdinal == 100)
    precondition(preview.sourceTimecode == "00:00:03:10")
    await preview.end(retainingImage: true)
    print("LIVE_PREVIEW_CLOCK_RESET_RETIRES_VIDEO_AND_TIMECODE_PASS")
    await preview.begin()
    preview.offerPreservedFrame(firstFrame, ordinal: 0, sourceTimecode: "00:00:00:00")
    try await Task.sleep(for: .milliseconds(20))
    preview.offerPreservedFrame(firstFrame, ordinal: 4, sourceTimecode: "00:00:00:04")
    try await Task.sleep(for: .milliseconds(20))
    precondition(preview.audio.deliveryGapFrames == 3)
    precondition(preview.audio.resynchronizations == 0 && preview.videoTimelineResets == 0)
    // Regression above the original anchor must still retire BOTH timelines.
    preview.offerPreservedFrame(firstFrame, ordinal: 2, sourceTimecode: "00:00:00:02")
    try await Task.sleep(for: .milliseconds(350))
    precondition(preview.error == nil && preview.latestSubmittedOrdinal == 2)
    precondition(preview.sourceTimecode == "00:00:00:02")
    precondition(preview.audio.resynchronizations == 1 && preview.videoTimelineResets == 1)
    precondition(preview.audio.lastResynchronization == "source_timeline_reset")
    await preview.end(retainingImage: true)
    print("LIVE_FORWARD_GAP_PRESERVES_AUDIO_AND_REGRESSION_RETIRES_BOTH_TIMELINES_PASS")
    await preview.begin()
    preview.offerPreservedFrame(firstFrame, ordinal: 0, sourceTimecode: "00:00:00:00")
    try await Task.sleep(for: .milliseconds(2100))
    precondition(preview.audio.inputInterruptions == 1)
    precondition(preview.hasImage && preview.sourceTimecode == "00:00:00:00")
    preview.offerPreservedFrame(firstFrame, ordinal: 1, sourceTimecode: "00:00:00:01")
    try await waitUntil("input resume native presentation") { preview.latestSubmittedOrdinal == 1 }
    precondition(preview.audio.resynchronizations == 1 && preview.videoTimelineResets == 1)
    precondition(preview.audio.lastResynchronization == "preview_input_resumed")
    precondition(preview.sourceTimecode == "00:00:00:01" && preview.latestSubmittedOrdinal == 1)
    precondition(preview.audio.deliveryGapFrames == 0 && preview.error == nil)
    await preview.end(retainingImage: true)
    print("LIVE_TWO_SECOND_INPUT_INTERRUPTION_HOLDS_IMAGE_AND_RECOVERS_CLOCK_PASS")

    // Synthetic damaged PCM marker in an IN-MEMORY copy, never a saved source.
    var unavailable = firstFrame
    unavailable[6 * 80 + 8] = 0x80; unavailable[6 * 80 + 9] = 0
    precondition(LiveDVMedia(frame: unavailable)?.audio != nil)
    precondition(LiveDVMedia(frame: unavailable)?.pcm16(frame: unavailable) == nil)
    await preview.begin()
    _ = preview.audio.offer(firstFrame, ordinal: 0)
    _ = preview.audio.offer(unavailable, ordinal: 1)
    _ = preview.audio.offer(Data(), ordinal: 2)
    // Both unavailable branches used to erase this queued good meter/audio.
    try await waitUntil("queued good PCM reaches meters") { preview.audio.presentation.channel(at: 0).active }
    precondition(preview.audio.presentation.channel(at: 0).active)
    precondition(preview.audio.frameAccounting.offeredFrames == 3)
    precondition(preview.audio.frameAccounting.unavailablePCMFrames == 1)
    precondition(preview.audio.frameAccounting.unknownFormatFrames == 1)
    precondition(preview.audio.deliveryGapFrames == 0)
    precondition(preview.audio.resynchronizations == 0)
    await preview.end()
    print("LIVE_UNUSABLE_AND_UNKNOWN_AUDIO_KEEP_QUEUED_GOOD_PCM_METERS_AND_EXACT_COUNTERS_PASS")
  }
}
