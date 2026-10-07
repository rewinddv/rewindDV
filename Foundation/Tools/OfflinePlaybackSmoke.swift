// Offline-only native renderer regression. No DriverBridge or hardware is linked.
import AppKit
import Foundation

@main
struct OfflinePlaybackSmoke {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
      fatalError("Usage: OfflinePlaybackSmoke /absolute/path/to/source.dv [--through-end]")
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    _ = NSApplication.shared
    let model = OfflineDVPlaybackModel(muteAudio: true)
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
      if !value() { throw SmokeFailure(message: message) }
      print("PASS: \(message)")
    }
    func settle(_ milliseconds: Int = 300) async throws {
      try await Task.sleep(for: .milliseconds(milliseconds))
    }
    model.open(url: url)
    for _ in 0..<600 {
      if !model.isLoading { break }
      try await settle(50)
    }
    try require(
      model.hasLoadedFile && model.state == .paused,
      "native file opens paused: \(model.state)")
    try require(!model.isIndexing, "ordinary playback does not scan the whole file")
    print("VIDEO: \(model.videoDescription)")
    print("AUDIO: \(model.audioDescription)")
    print("DURATION: \(model.durationSeconds)")
    try require(model.durationSeconds > 1, "fixture has sufficient duration")
    model.play()
    try await settle(2_000)
    try require(model.currentTimeSeconds > 0.5, "native playback clock advances")
    let videoLead = (model.latestEnqueuedVideoTimeSeconds ?? -.infinity) - model.currentTimeSeconds
    let audioLead = (model.latestIngestedPCMEndTimeSeconds ?? -.infinity) - model.currentTimeSeconds
    print("VIDEO_LEAD_SECONDS: \(videoLead)")
    print("AUDIO_LEAD_SECONDS: \(audioLead)")
    try require(videoLead >= -0.1 && videoLead <= 0.55, "video stays paced to presentation clock")
    try require(audioLead >= -0.1 && audioLead <= 0.55, "PCM stays paced even when audio is muted")
    try require(
      model.meterPresentation.channels.contains(where: \.active), "current PCM reaches meters")
    try require(
      !model.decodedAudioHasConflict, "native meter admission has no timing/format conflict")
    print("SOURCE_AUDIO: \(model.sourceAudioDescription)")
    print("SOURCE_TIMECODE: \(model.sourceTimecodeText ?? "unknown")")
    print("METER: \(model.meterPresentation)")
    if CommandLine.arguments.last == "--through-end" {
      let deadline = Date().addingTimeInterval(model.durationSeconds + 5)
      while model.state == .playing && Date() < deadline { try await settle(100) }
      try require(model.state == .ended, "complete offline playback reaches EOF without a stall")
      try require(
        !model.decodedAudioHasConflict, "complete playback retains valid audio/meter timing")
      model.seek(to: model.durationSeconds / 2)
      try await settle(500)
      model.play()
      try await settle(500)
    }
    model.pause()
    let paused = model.currentTimeSeconds
    try await settle()
    try require(abs(model.currentTimeSeconds - paused) < 0.05, "pause freezes presentation clock")
    model.seek(to: model.durationSeconds)
    try await settle(800)
    try require(
      model.state == .paused && model.currentTimeSeconds > model.durationSeconds - 0.2,
      "end seek retains the final renderable frame")
    model.seek(to: model.durationSeconds * 0.7)
    model.seek(to: model.durationSeconds * 0.2)
    model.seek(to: model.durationSeconds * 0.4)
    try await settle(800)
    try require(
      model.state == .paused && abs(model.currentTimeSeconds - model.durationSeconds * 0.4) < 0.1,
      "rapid seeks retain only the newest render generation")
    model.stop()
    try await settle(500)
    try require(
      model.state == .paused && model.currentTimeSeconds < 0.05, "offline STOP returns to beginning"
    )
    model.open(url: url)
    model.close()
    try await settle(1_000)
    try require(
      model.state == .idle && model.sourceURL == nil && !model.hasLoadedFile,
      "close cancels in-flight file load without stale publication")
    print("OFFLINE_PLAYBACK_SMOKE_PASS — no hardware control was linked or invoked")
  }
}

private struct SmokeFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}
