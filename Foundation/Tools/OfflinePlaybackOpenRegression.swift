// Offline file-open and presentation regression. No driver or deck access.
import AppKit
import Foundation

@main struct OfflinePlaybackOpenRegression {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    guard CommandLine.arguments.count == 2 else { fatalError("Provide a raw DV file") }
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let model = OfflineDVPlaybackModel(muteAudio: true)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 720, height: 576))
    host.wantsLayer = true; host.layer?.addSublayer(model.displayLayer)
    model.displayLayer.frame = host.bounds
    defer { model.close(); withExtendedLifetime(host) {} }
    func require(_ condition: Bool, _ reason: String) throws {
      guard condition else { throw Failure(reason: reason) }; print("PASS", reason)
    }
    func waitFrame(_ ordinal: Int? = nil) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while ContinuousClock.now < deadline {
        if case .failed(let reason) = model.state { throw Failure(reason: reason) }
        if model.latestEnqueuedVideoTimeSeconds != nil,
          ordinal == nil || model.metadata.report?.frameOrdinal == UInt64(ordinal!) { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      throw Failure(reason: "No selected source frame within three seconds")
    }
    let start = ContinuousClock.now
    model.open(url: url); try await waitFrame(0)
    print("FIRST_PICTURE", start.duration(to: .now))
    try require(model.canPlay, "first picture is paused and immediately ready to play")
    try require(!model.isIndexing, "opening does not start a whole-file coordinate scan")
    try require(model.sourceFileAudit == nil && !model.sourceFileAuditStatus.hasPrefix("Assessing"),
      "file open does not start whole-file forensic assessment")
    for _ in 0..<3 {
      model.play(); try await Task.sleep(for: .milliseconds(800))
      try require(model.state == .playing && model.currentTimeSeconds > 0.3,
        "play advances without a whole-file index")
      model.pause(); try await waitFrame()
      let held = model.currentTimeSeconds
      try await Task.sleep(for: .milliseconds(80))
      try require(abs(model.currentTimeSeconds - held) < 0.05, "pause holds the selected source picture")
      for time in [0.4, 0.1, 0.3, 0.2] { model.seek(to: time) }
      try await waitFrame()
      let target = model.sourceTimeline!.frame(at: 0.2).ordinal
      try await waitFrame(target)
      try require(model.currentFrameOrdinal == target, "rapid scrubbing converges using frame-local reads")
      model.stop(); try await waitFrame(0)
    }
    model.open(url: url); model.close()
    try await Task.sleep(for: .milliseconds(300))
    try require(model.state == .idle && !model.hasLoadedFile && !model.isIndexing,
      "close cancels both initial load and indexing without stale publication")
    model.open(url: url); try await waitFrame(0)
    try require(model.canPlay, "reopening immediately presents source frame zero")
    print("OFFLINE_FILE_OPEN_PASS")
  }
  struct Failure: Error { let reason: String }
}
