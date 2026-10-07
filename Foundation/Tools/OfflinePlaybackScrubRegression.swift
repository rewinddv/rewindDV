// Native rapid-scrubbing and frame-local playback regression. No driver/deck access.
// Supply a finished raw DV capture at least 30 seconds long.
import AppKit
import Foundation

@main struct OfflinePlaybackScrubRegression {
  @MainActor static func main() async throws {
    setbuf(stdout, nil); _ = NSApplication.shared
    guard CommandLine.arguments.count == 2 else { fatalError("Provide a finished raw DV capture") }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let model = OfflineDVPlaybackModel(muteAudio: true)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 576))
    host.wantsLayer = true; host.layer?.addSublayer(model.displayLayer); model.displayLayer.frame = host.bounds
    defer { model.close(); withExtendedLifetime(host) {} }
    func require(_ ok: Bool, _ reason: String) throws {
      guard ok else { throw Failure(reason: reason) }; print("PASS", reason)
    }
    func wait(_ seconds: Int = 3, until condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
      while !condition() {
        if case .failed(let reason) = model.state { throw Failure(reason: reason) }
        guard ContinuousClock.now < deadline else { throw Failure(reason: "Timed out waiting for playback") }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    let opened = ContinuousClock.now
    model.open(url: url)
    try await wait { model.latestEnqueuedVideoTimeSeconds == 0 }
    print("FIRST_PICTURE", opened.duration(to: .now))
    try require(!model.isIndexing && model.sourceTimeline?.isPreviewEstimate == true,
      "opening uses frame-local preview with no automatic whole-file scan")
    try await wait(20) { model.durationSeconds >= 30 }
    let startingFrames = model.sourceTimeline!.frameCount
    model.setScrubbing(true)
    let parsed = model.metadata.sampledFrames
    var updates = 0, last = model.latestEnqueuedVideoTimeSeconds, latestTarget = 0.0
    let streamStart = ContinuousClock.now
    for i in 0..<120 {
      latestTarget = Double((i * 17) % 100) / 100 * model.durationSeconds
      model.seek(to: latestTarget)
      try await Task.sleep(for: .milliseconds(16))
      if let time = model.latestEnqueuedVideoTimeSeconds, time != last { updates += 1; last = time }
    }
    try require(!model.isIndexing && model.sourceTimeline!.frameCount == startingFrames,
      "full-range scrubbing does not start background indexing")
    try require(model.metadata.sampledFrames == parsed, "detailed metadata waits for gesture release")
    model.setScrubbing(false)
    let released = ContinuousClock.now
    let target = model.sourceTimeline!.frame(at: latestTarget)
    try await wait { model.latestEnqueuedVideoTimeSeconds == target.seconds }
    let finalLatency = released.duration(to: .now)
    print("SCRUB_UPDATES", updates, "STREAM_TIME", streamStart.duration(to: released), "FINAL_LATENCY", finalLatency)
    try require(updates >= 60 && finalLatency < .milliseconds(250), "rapid requests keep presenting pictures and promptly converge")
    try await wait { model.metadata.report?.frameOrdinal == UInt64(target.ordinal) }
    try require(model.currentFrameOrdinal == target.ordinal, "final inspector identifies the selected source frame")
    try require(model.metadata.ordinalIsEstimated, "frame-local metadata does not claim a globally indexed ordinal")
    let full = model.sourceTimeline!
    model.close()
    let reopened = ContinuousClock.now
    model.open(url: url)
    try await wait { model.latestEnqueuedVideoTimeSeconds == 0 }
    print("REOPEN", reopened.duration(to: .now))
    try require(!model.isIndexing, "reopening also avoids a whole-file scan")
    try require(model.sourceTimeline?.runs == full.runs, "reopening retains consistent preview coordinates")
    model.seek(to: full.durationSeconds)
    try await wait { model.latestEnqueuedVideoTimeSeconds == full.frame(full.frameCount - 1).seconds }
    try require(model.currentFrameOrdinal == full.frameCount - 1, "full-range seeking validates and decodes the final source frame")
    model.setScrubbing(true); model.close()
    try require(model.state == .idle, "close releases interactive indexing priority")
    print("OFFLINE_SCRUB_PASS")
  }
  struct Failure: Error { let reason: String }
}
