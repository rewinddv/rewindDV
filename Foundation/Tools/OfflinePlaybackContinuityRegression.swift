// Offline-only continuous playback oracle. No driver or deck commands are linked.
import AVFoundation
import AppKit
import Combine
import Foundation

@main struct OfflinePlaybackContinuityRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count >= 2 else { fatalError("Provide local raw DV path") }
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let model = OfflineDVPlaybackModel(muteAudio: true)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 480))
    host.wantsLayer = true
    host.layer?.addSublayer(model.displayLayer)
    model.displayLayer.frame = host.bounds
    defer { model.close(); withExtendedLifetime(host) {} }
    model.open(url: url)
    let deadline = Date().addingTimeInterval(30)
    while (model.latestEnqueuedVideoTimeSeconds == nil || model.sourceAudioStatus == .verifying),
      Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard model.canPlay else { throw Failure(message: "File failed to become ready: \(model.state)") }
    // Independent archival analyzer provides expected source TC before timing the pump.
    let frameBytes = model.rasterHeight == 576 ? 144_000 : 120_000
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var expected: [String?] = []
    for _ in 0..<450 {
      guard let data = try handle.read(upToCount: frameBytes), data.count == frameBytes else { break }
      let manifest = DVCaptureMetadataEpochAnalyzer.analyze(data: data)
      let archivedTimecode = manifest.frames.first.flatMap {
        MonitorSourceTimecode.display(packs: $0.sourceTimecodePacks.map(\.rawBytes), isPAL: frameBytes == 144_000)
      }
      guard MonitorSourceTimecode.display(nativeDVFrame: data) == archivedTimecode else {
        throw Failure(message: "Playback TC parser disagrees with archival evidence")
      }
      expected.append(archivedTimecode)
    }
    // Whole-file audit and initial source specifications publish once when ready.
    // Finish those independent owners before measuring steady playback updates.
    let sourceDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    while (model.sourceFileAudit == nil || model.technicalSpecificationsStatus != "Source technical specifications"),
      ContinuousClock.now < sourceDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard model.sourceFileAudit != nil,
      model.technicalSpecificationsStatus == "Source technical specifications" else {
      throw Failure(message: "Initial source evidence did not settle: \(model.sourceFileAuditStatus); \(model.technicalSpecificationsStatus)")
    }
    model.play()
    // This native PCM fixture establishes its decoded format on first playback.
    // Await that initial publication and a moving clock; retain a full eight-second
    // steady-state observation window below, with a fresh heartbeat baseline.
    let playbackDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (model.currentTimeSeconds < 0.5 || model.decodedAudioFormat == nil),
      ContinuousClock.now < playbackDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard model.currentTimeSeconds >= 0.5, model.decodedAudioFormat != nil else {
      throw Failure(message: "Native PCM playback did not become ready: \(model.state)")
    }
    let initialMetadataSamples = model.metadata.sampledFrames
    let renderGeneration = model.renderGeneration
    let metadataStarted = Date()
    var workspaceInvalidations = 0
    let observation = model.objectWillChange.sink { workspaceInvalidations += 1 }
    defer { observation.cancel() }
    var samples = 0, missing = 0, mismatch = 0, starved = 0
    var minimumLead = Double.infinity, maximumHeartbeat = 0.0
    var previous = Date()
    for _ in 0..<400 {
      try await Task.sleep(for: .milliseconds(20))
      let now = Date()
      maximumHeartbeat = max(maximumHeartbeat, now.timeIntervalSince(previous))
      previous = now
      let frame = model.currentFrameOrdinal
      guard model.currentTimeSeconds > 0.5, frame < expected.count else { continue }
      samples += 1
      if expected[frame] != nil && model.sourceTimecodeText == nil { missing += 1 }
      if let text = model.sourceTimecodeText, text != expected[frame] { mismatch += 1 }
      let lead = (model.latestEnqueuedVideoTimeSeconds ?? -1) - model.currentTimeSeconds
      minimumLead = min(minimumLead, lead)
      if lead < -0.05 { starved += 1 }
    }
    print("OBSERVATIONS=\(samples) MISSING_TC=\(missing) MISMATCH_TC=\(mismatch) STARVED=\(starved) WORKSPACE_INVALIDATIONS=\(workspaceInvalidations) MIN_VIDEO_LEAD=\(minimumLead) MAX_MAIN_HEARTBEAT=\(maximumHeartbeat) POSITION=\(model.currentTimeSeconds)")
    guard samples > 100, missing == 0, mismatch == 0, starved == 0, workspaceInvalidations == 0 else {
      throw Failure(message: "Continuous playback/timecode regression")
    }
    let metadataSamples = model.metadata.sampledFrames - initialMetadataSamples
    guard metadataSamples > 0, metadataSamples <= Int(Date().timeIntervalSince(metadataStarted) * 2) + 2,
      model.metadata.maxPendingFrames <= 1, model.renderGeneration == renderGeneration else {
      throw Failure(message: "Inspector sampling exceeded bounds or restarted playback")
    }
    print("METADATA_SAMPLES=\(metadataSamples); pending<=1; render generation unchanged")
    print("OFFLINE_CONTINUITY_PASS; physical screen smoothness is not measured by this oracle")
  }
}
private struct Failure: Error { let message: String }
