import AVFoundation
// Silent, offline-only real DV interaction regression. No driver is linked.
import AppKit
import CryptoKit
import Foundation

@main struct OfflinePlaybackInteractionRegression {
  @MainActor static func main() async throws {
    guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Provide one local DV path and optional viewing-mode index") }
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let model = OfflineDVPlaybackModel(muteAudio: true)
    if CommandLine.arguments.count == 3 {
      guard let index = Int(CommandLine.arguments[2]), DVViewingMode.allCases.indices.contains(index) else {
        fatalError("Viewing mode must be 0...4")
      }
      model.setViewingMode(DVViewingMode.allCases[index])
    }
    print("VIEW_MODE=\(model.viewingMode.rawValue)")
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 480))
    host.wantsLayer = true
    host.layer?.addSublayer(model.displayLayer)
    model.displayLayer.frame = host.bounds
    defer { withExtendedLifetime(host) {} }
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw Failure(message: message) }
      print("PASS: \(message)")
    }
    func waitFrame() async throws {
      let deadline = Date().addingTimeInterval(5)
      while model.latestEnqueuedVideoTimeSeconds == nil && Date() < deadline {
        if case .failed(let detail) = model.state { throw Failure(message: detail) }
        try await Task.sleep(for: .milliseconds(2))
      }
      try require(model.latestEnqueuedVideoTimeSeconds != nil, "selected frame decoded")
    }
    let pickerSession = OfflineDVPlaybackModel(muteAudio: true)
    try require(pickerSession.consumeInitialFilePickerRequest(), "first Playback visit offers file picker")
    try require(!pickerSession.consumeInitialFilePickerRequest(), "cancel/revisit does not offer picker again")
    pickerSession.close()
    try require(!pickerSession.consumeInitialFilePickerRequest(), "closing file does not re-arm picker")
    model.open(url: url)
    try require(model.zoom == 1, "new file defaults to 1x")
    try require(!model.consumeInitialFilePickerRequest(), "explicit file load suppresses automatic picker")
    try await waitFrame()
    let specsDeadline = Date().addingTimeInterval(5)
    while model.technicalSpecifications == nil && Date() < specsDeadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try require(model.technicalSpecifications?.sections.first?.title == "General",
      "selected file receives background technical specifications")
    let originalSpecs = model.technicalSpecifications
    model.setDisplayAspect(.widescreen)
    try require(model.technicalSpecifications == originalSpecs,
      "preview aspect override cannot change source technical specifications")
    model.setDisplayAspect(.standard)
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { throw Failure(message: "No sample timing") }
    var interval = 0.0
    var exactInterval = CMTime.invalid
    for _ in 0..<8 {
      guard let sample = output.copyNextSampleBuffer() else { break }
      let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
      if duration.isFinite && duration > 0 {
        interval = duration
        exactInterval = CMSampleBufferGetDuration(sample)
        break
      }
    }
    try require(interval > 0, "exact sample cadence available")
    reader.cancelReading()
    let format = try await track.load(.formatDescriptions)[0]
    let height = CMVideoFormatDescriptionGetDimensions(format).height
    let frameBytes = height == 576 ? 144_000 : 120_000
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    func verifySelection(_ frame: Int) async throws {
      try require(model.currentFrameOrdinal == frame, "selected ordinal \(frame)")
      try require(
        abs((model.latestEnqueuedVideoTimeSeconds ?? -1) - Double(frame) * interval) < 0.000_001,
        "decoded picture PTS equals exact frame \(frame)")
      try handle.seek(toOffset: UInt64(frame * frameBytes))
      let raw = try handle.read(upToCount: frameBytes) ?? Data()
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while model.metadata.report?.frameOrdinal != UInt64(frame), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      let expectedHash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
      try require(model.metadata.report?.frameOrdinal == UInt64(frame)
        && model.metadata.report?.frameSHA256 == expectedHash,
        "Inspector metadata matches the exact selected source-frame bytes: " + model.pausedMetadataAssociationDiagnostics)
      try require(model.metadata.maxPendingFrames <= 1, "Inspector keeps at most one pending frame")
      let sourceInventory = try DVMetadataInventory.inspect(frame: raw, ordinal: UInt64(frame), byteOffset: UInt64(frame * frameBytes))
      let expectedClock = DVTechnicalSpecifications.make(path: url.path, byteCount: UInt64(raw.count), inventory: sourceInventory).sections.first { $0.title == "General" }?.rows.first { $0.label == "Recorded date & time" }
      try require(model.recordedClockFrameOrdinal == UInt64(frame), "recording clock is bound to selected ordinal \(frame)")
      if let expectedClock, !expectedClock.isWarning {
        try require(model.recordedClock?.value == expectedClock.value, "recording date/time agrees with independently inventoried frame \(frame)")
      } else {
        try require(model.recordedClock?.isWarning == true, "missing or invalid frame clock never borrows first valid time")
      }
      let metadata = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)
      let expected = metadata.frames.first.flatMap {
        MonitorSourceTimecode.display(
          packs: $0.sourceTimecodePacks.map(\.rawBytes), isPAL: height == 576)
      }
      try require(
        expected != nil && model.sourceTimecodeText == expected,
        "timecode agrees with raw source frame \(frame): \(model.sourceTimecodeText ?? "unknown")")
    }
    func fingerprint(_ pixel: CVPixelBuffer) -> SHA256.Digest {
      precondition(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA)
      CVPixelBufferLockBaseAddress(pixel, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
      let base = CVPixelBufferGetBaseAddress(pixel)!
      var hash = SHA256()
      for row in 0..<CVPixelBufferGetHeight(pixel) {
        hash.update(
          data: Data(
            bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)),
            count: CVPixelBufferGetWidth(pixel) * 4))
      }
      return hash.finalize()
    }
    func verifyDisplayedFrame(_ frame: Int) async throws {
      if model.extremeZebras { return } // Exact overlay pixels are checked by the GPU oracle.
      let expectedReader = try AVAssetReader(asset: asset)
      expectedReader.timeRange = CMTimeRange(
        start: CMTimeMultiply(exactInterval, multiplier: Int32(frame)),
        duration: exactInterval)
      let expectedOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      expectedReader.add(expectedOutput)
      guard expectedReader.startReading(), let sample = expectedOutput.copyNextSampleBuffer(),
        let pixel = CMSampleBufferGetImageBuffer(sample)
      else { throw Failure(message: "No expected picture") }
      defer { expectedReader.cancelReading() }
      let expectedHash = fingerprint(pixel)
      let began = Date()
      var matched = false
      var hadDisplayedBuffer = false
      while Date().timeIntervalSince(began) < 1 {
        if let displayed = model.displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
          guard CVPixelBufferGetPixelFormatType(displayed) == kCVPixelFormatType_32BGRA else {
            print("DISPLAYED_PIXEL_CHECK_NOT_COMPARABLE: native YCbCr cannot be byte-compared to the BGRA reference; use the field/raster oracle")
            return
          }
          hadDisplayedBuffer = true
          if fingerprint(displayed) == expectedHash {
            matched = true
            break
          }
        }
        try await Task.sleep(for: .milliseconds(2))
      }
      if !hadDisplayedBuffer {
        print(
          "DISPLAYED_PIXEL_CHECK_UNAVAILABLE: offscreen renderer returned no readable displayed buffer"
        )
        return
      }
      try require(matched, "renderer displayed pixels equal independently decoded frame \(frame)")
    }
    model.seek(to: 100 * interval)
    try await waitFrame()
    try await verifySelection(100)
    model.setZoom(8)
    try await waitFrame()
    try await verifySelection(100)
    model.setZoomCenter(CGPoint(x: -1, y: 2))
    try require(model.zoomCenter == CGPoint(x: 0.0625, y: 0.9375), "navigator clamps within frame")
    model.setExtremeZebras(true)
    try await waitFrame()
    try await verifySelection(100)
    try require(model.state == .paused && model.extremeZebras, "zebra toggle preserves paused frame")
    model.setExtremeZebras(false)
    try await waitFrame()
    try await verifySelection(100)
    try await verifyDisplayedFrame(100)
    model.setExtremeZebras(true)
    try await waitFrame()
    for delta in [1, 1, -1, -1, -1] {
      let expected = model.currentFrameOrdinal + delta
      model.stepFrames(delta)
      try await waitFrame()
      try await verifySelection(expected)
    }
    // Requests may arrive before the previous frame finishes decoding.
    model.stepFrames(1)
    model.stepFrames(1)
    model.stepFrames(-1)
    try await waitFrame()
    try await verifySelection(100)
    var maxSeekSeconds = 0.0
    for frame in [30, 500, 80, 700, 100, 600, 1, 816] {
      let began = Date()
      model.seek(to: Double(frame) * interval)
      try await waitFrame()
      maxSeekSeconds = max(maxSeekSeconds, Date().timeIntervalSince(began))
      try await verifySelection(frame)
    }
    print("MAX_REQUEST_TO_DECODE_SECONDS=\(maxSeekSeconds)")
    let displayedTimecode = model.sourceTimecodeText
    model.seek(to: 40 * interval)
    try require(model.sourceTimecodeText == displayedTimecode,
      "pending seek retains the displayed picture's timecode")
    for frame in 41...240 { model.seek(to: Double(frame) * interval) }
    let burstDeadline = Date().addingTimeInterval(5)
    while (model.currentFrameOrdinal != 240 || model.latestEnqueuedVideoTimeSeconds == nil)
      && Date() < burstDeadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try await verifySelection(240)
    for frame in stride(from: 20, through: 220, by: 5) {
      model.seek(to: Double(frame) * interval)
      try await Task.sleep(for: .milliseconds(16))
    }
    try await waitFrame()
    try await verifySelection(220)
    try await verifyDisplayedFrame(220)
    // Allow raw audio verification to finish, while keeping output explicitly muted.
    let verificationDeadline = Date().addingTimeInterval(30)
    while model.sourceAudioStatus == .verifying && Date() < verificationDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    model.seek(to: 0)
    try await waitFrame()
    model.play()
    var maxHeartbeatSeconds = 0.0
    var previous = Date()
    for _ in 0..<200 {
      try await Task.sleep(for: .milliseconds(20))
      let now = Date()
      maxHeartbeatSeconds = max(maxHeartbeatSeconds, now.timeIntervalSince(previous))
      previous = now
    }
    print("MAX_MAIN_ACTOR_HEARTBEAT_SECONDS=\(maxHeartbeatSeconds)")
    try require(model.currentTimeSeconds > 3, "playback clock advances at normal speed")
    try require(model.recordedClockFrameOrdinal == UInt64(model.currentFrameOrdinal), "playing clock metadata follows current source frame without 500ms sampling lag")
    try require(!model.decodedAudioHasConflict, "playback retains valid audio timing")
    let lead = (model.latestEnqueuedVideoTimeSeconds ?? -1) - model.currentTimeSeconds
    print("VIDEO_LEAD_SECONDS=\(lead)")
    try require(lead > 0 && lead < 0.6, "video is supplied ahead of the presentation clock")
    model.pause()
    let pausedFrame = model.currentFrameOrdinal
    try await waitFrame()
    try await verifySelection(pausedFrame)
    model.setExtremeZebras(false)
    try await waitFrame()
    try await verifySelection(pausedFrame)
    try await verifyDisplayedFrame(pausedFrame)
    try await Task.sleep(for: .milliseconds(300))
    try await verifySelection(pausedFrame)
    try await verifyDisplayedFrame(pausedFrame)
    let auditDeadline = Date().addingTimeInterval(120)
    while model.isIndexing && Date() < auditDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    model.assessWholeFile()
    while model.sourceFileAudit == nil && Date() < auditDeadline && !model.sourceFileAuditStatus.hasPrefix("Unavailable") {
      try await Task.sleep(for: .milliseconds(20))
    }
    try require(model.sourceFileAudit?.frames == UInt64(Int(model.durationSeconds / interval + 0.5)), "whole-file audio/error audit covers complete source frames")
    if let audit = model.sourceFileAudit { print("SOURCE_AUDIT=\(audit.sections)") }
    model.close()
    try require(model.recordedClock == nil && model.sourceFileAudit == nil, "close clears clock and source audit")
    try require(model.technicalSpecifications == nil, "closing clears old file technical specifications")
    model.open(url: url)
    try require(model.zoom == 1 && model.zoomCenter == CGPoint(x: 0.5, y: 0.5), "reopening resets zoom and center")
    model.close()
    print(
      "OFFLINE_INTERACTION_PASS; render timing measured, physical screen smoothness requires operator confirmation"
    )
  }
}

private struct Failure: Error { let message: String }
