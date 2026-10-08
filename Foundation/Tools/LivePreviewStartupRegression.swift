// OFFLINE ONLY. Muted, read-only saved DV; no driver or hardware linked.
import AppKit
import AVFoundation
import Foundation

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

@main struct LivePreviewStartupRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
    let frame = try file.read(upToCount: 120_000)!
    try file.close()
    precondition(frame.count == 120_000)
    let injectDelay = CommandLine.arguments.contains("--delay-startup")
    let preview = LiveDVPreview(muteAudio: true, beforeDecode: { ordinal in
      // Deterministic reproduction of cold decode exceeding the old 120ms
      // pre-decode presentation budget. Only this offline harness injects work.
      if injectDelay, ordinal < 2 {
        try? await Task.sleep(for: .milliseconds(ordinal == 0 ? 150 : 80))
      }
    })
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 480),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "rewindDV offline preview timing test — no deck access"
    let view = NSView(frame: window.contentView!.bounds)
    view.wantsLayer = true
    preview.displayLayer.frame = view.bounds
    view.layer!.addSublayer(preview.displayLayer)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    for cycle in 0..<2 {
      await preview.begin()
      // Idle before arrival models app-before-deck: no presentation anchor may
      // be based on launch time. The first actual frame establishes it.
      try await Task.sleep(for: .seconds(2))
      let start = ContinuousClock.now
      for ordinal in 0..<120 {
        let deadline = start.advanced(by: .nanoseconds(Int64(ordinal) * 33_366_667))
        try await ContinuousClock().sleep(until: deadline)
        preview.offerPreservedFrame(frame, ordinal: UInt64(ordinal), sourceTimecode: "00:00:00:00")
      }
      // Decode-first startup shifts the shared A/V anchor by the injected cold
      // work. Wait for actual presentation, not a fixed 200ms wall-clock guess;
      // missing frames, stalls and all drop/resync counters still fail below.
      let drainDeadline = ContinuousClock.now.advanced(by: .seconds(2))
      while preview.latestSubmittedOrdinal != 119, ContinuousClock.now < drainDeadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      preview.requestNativeVideoMetrics()
      try await Task.sleep(for: .milliseconds(100))
      print("CYCLE=\(cycle); \(preview.timingDiagnostics); queue_skips=\(preview.queueSkippedFrames); renderer_skips=\(preview.rendererSkippedFrames)")
      precondition(preview.failedVideoFrames == 0)
      precondition(preview.audio.frameAccounting.offeredFrames == 120)
      precondition(preview.latestSubmittedOrdinal == 119)
      precondition(preview.lateVideoSubmissions == 0, "Video must be ready before its shared A/V deadline")
      precondition(preview.queueSkippedFrames == 0 && preview.rendererSkippedFrames == 0)
      precondition(preview.audio.resynchronizations == 0, "Cold decode must not reset an already running presentation clock")
      precondition(preview.nativeVideoMetrics.contains("dropped:0,"), "Native renderer must report zero drops in this paced test")
      await preview.end()
    }
    window.orderOut(nil)
  }
}
