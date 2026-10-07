// Offline-only view-control continuity oracle. Never links the driver.
import AVFoundation
import AppKit
import Foundation

@main struct OfflinePlaybackSettingsRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide local raw DV path") }
    _ = NSApplication.shared
    let model = OfflineDVPlaybackModel(muteAudio: true)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 576))
    host.wantsLayer = true
    host.layer?.addSublayer(model.displayLayer)
    model.displayLayer.frame = host.bounds
    defer { model.close(); withExtendedLifetime(host) {} }
    func require(_ value: Bool, _ reason: String) throws {
      guard value else { throw Failure(message: reason) }
    }
    model.open(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let ready = Date().addingTimeInterval(30)
    while (model.latestEnqueuedVideoTimeSeconds == nil || model.isIndexing || model.sourceAudioStatus == .verifying),
      Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
    try require(model.canPlay && model.durationSeconds > 12, "Need a ready clip longer than 12 seconds")
    let initialGeneration = model.renderGeneration
    let initialPicture = model.latestEnqueuedVideoTimeSeconds
    for zoom: CGFloat in [2, 4, 8, 1] { model.setZoom(zoom) }
    for aspect in DVDisplayAspect.allCases { model.setDisplayAspect(aspect) }
    try require(model.renderGeneration == initialGeneration &&
      model.latestEnqueuedVideoTimeSeconds == initialPicture, "Paused geometry controls restarted decoding")
    model.play()
    let started = Date().addingTimeInterval(5)
    while model.currentTimeSeconds < 0.5, Date() < started {
      try await Task.sleep(for: .milliseconds(10))
    }
    try require(model.currentTimeSeconds >= 0.5, "Playback did not start")
    let generation = model.renderGeneration
    let startPosition = model.currentTimeSeconds
    let began = Date()
    var previousPosition = startPosition
    var previousAudio = model.latestIngestedPCMEndTimeSeconds ?? -1
    var previousTick = Date()
    var lastAdvance = Date()
    var maxStall = 0.0, maxHeartbeat = 0.0, minVideoLead = Double.infinity
    var changes = 0
    for step in 0..<400 {
      if step % 5 == 0 {
        let index = step / 5
        model.setZoom([1, 2, 4, 8][index % 4])
        model.setDisplayAspect(DVDisplayAspect.allCases[index % 2])
        try require(model.displayAspectRatio == CGFloat(DVDisplayAspect.allCases[index % 2].ratio),
          "Aspect override did not apply immediately")
        model.setViewingMode(DVViewingMode.allCases[index % DVViewingMode.allCases.count])
        model.setExtremeZebras(index % 2 == 0)
        model.setZoomCenter(CGPoint(x: index % 2 == 0 ? 0.2 : 0.8, y: 0.5))
        changes += 1
      }
      try await Task.sleep(for: .milliseconds(20))
      let now = Date()
      maxHeartbeat = max(maxHeartbeat, now.timeIntervalSince(previousTick))
      previousTick = now
      try require(model.state == .playing, "Setting change interrupted playback: \(model.state)")
      try require(model.renderGeneration == generation, "Setting change restarted render session")
      let position = model.currentTimeSeconds
      try require(position >= previousPosition, "Playback clock moved backward")
      if position > previousPosition { lastAdvance = now }
      maxStall = max(maxStall, now.timeIntervalSince(lastAdvance))
      previousPosition = position
      try require(model.sourceTimecodeText != nil, "Timecode disappeared while changing settings")
      let lead = (model.latestEnqueuedVideoTimeSeconds ?? -1) - position
      minVideoLead = min(minVideoLead, lead)
      try require(lead >= -0.05 && lead < 0.3, "Picture queue starved or exceeded interactive bound: \(lead)")
      let audio = model.latestIngestedPCMEndTimeSeconds ?? -1
      try require(audio >= previousAudio && audio >= position - 0.05, "PCM progression reset or starved")
      previousAudio = audio
    }
    // Bursts must converge on the latest choice, not replay a queue of settings.
    for index in 0..<100 {
      model.setViewingMode(DVViewingMode.allCases[index % 5])
      model.setExtremeZebras(index % 2 == 0)
    }
    model.setViewingMode(.bottom)
    model.setExtremeZebras(true)
    let settled = Date().addingTimeInterval(0.3)
    while (model.lastQueuedViewingMode != .bottom || !model.lastQueuedExtremeZebras), Date() < settled {
      try await Task.sleep(for: .milliseconds(5))
    }
    try require(model.lastQueuedViewingMode == .bottom && model.lastQueuedExtremeZebras,
      "Latest picture policy was not queued promptly")
    try require(model.renderGeneration == generation, "Burst restarted session")
    let elapsed = Date().timeIntervalSince(began)
    let advanced = model.currentTimeSeconds - startPosition
    try require(abs(advanced - elapsed) < 0.12 && maxStall < 0.12,
      "Playback clock stalled during controls: \(advanced) / \(elapsed)")
    model.pause()
    let pausedTime = model.currentTimeSeconds
    model.setViewingMode(.blend)
    model.setExtremeZebras(false)
    let pausedReady = Date().addingTimeInterval(5)
    while model.latestEnqueuedVideoTimeSeconds == nil, Date() < pausedReady {
      try await Task.sleep(for: .milliseconds(5))
    }
    try require(model.state == .paused && abs(model.currentTimeSeconds - pausedTime) < 0.041,
      "Paused picture adjustment moved off the selected frame")
    try require(model.lastQueuedViewingMode == .blend && !model.lastQueuedExtremeZebras,
      "Paused picture adjustment did not render")
    print("SETTINGS_CONTINUITY_PASS changes=\(changes) burst=100 generation=\(generation) elapsed=\(elapsed) advanced=\(advanced) max_clock_stall=\(maxStall) max_main_heartbeat=\(maxHeartbeat) min_video_lead=\(minVideoLead)")
    print("Clock, PCM progression, bounded queue, latest-policy and paused-frame checks only; audible/visible continuity needs GUI qualification.")
  }
}
private struct Failure: Error { let message: String }
