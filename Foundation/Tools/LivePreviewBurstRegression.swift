// OFFLINE ONLY: muted saved DV; no driver or hardware access.
import AppKit
import AVFoundation
import Foundation

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

@main struct LivePreviewBurstRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(source.count >= 120_000 && source.count.isMultiple(of: 120_000))
    let baseline = CommandLine.arguments.contains("--expect-baseline")
    let preview = LiveDVPreview(muteAudio: true, beforeDecode: { ordinal in
      if ordinal == 100 { try? await Task.sleep(for: .milliseconds(60)) }
    })
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    let view = NSView(frame: window.contentView!.bounds)
    view.wantsLayer = true
    preview.displayLayer.frame = view.bounds
    view.layer!.addSublayer(preview.displayLayer)
    window.contentView = view
    window.title = "Offline burst timing regression — no deck access"
    window.makeKeyAndOrderFront(nil)
    await preview.begin()
    let start = ContinuousClock.now
    for ordinal in 0..<180 {
      // Real input gap, then bounded delivery jitter. No invented source data
      // fills the gap. Sustained 140ms late delivery exposes the old 120ms lead.
      let gap = ordinal >= 7 ? 1_000_000_000 : 0
      let jitter = ordinal >= 100 ? 140_000_000 : 0
      let deadline = start.advanced(by: .nanoseconds(Int64(ordinal) * 33_366_667 + Int64(gap + jitter)))
      try await ContinuousClock().sleep(until: deadline)
      let i = ordinal % (source.count / 120_000)
      preview.offerPreservedFrame(source.subdata(in: i*120_000..<(i+1)*120_000),
        ordinal: UInt64(ordinal), sourceTimecode: nil)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while preview.latestSubmittedOrdinal != 179, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    preview.requestNativeVideoMetrics()
    try await Task.sleep(for: .milliseconds(100))
    print(preview.timingDiagnostics)
    print("resyncs=\(preview.audio.resynchronizations); renderer_skips=\(preview.rendererSkippedFrames); queue_skips=\(preview.queueSkippedFrames)")
    if baseline {
      precondition(preview.audio.resynchronizations > 1 || preview.lateVideoSubmissions > 0)
      print("BASELINE_BURST_DEFECT_REPRODUCED_NOT_A_PASS")
    } else {
      precondition(preview.audio.resynchronizations == 1, "Only the real input gap should reset the clock")
      precondition(preview.audio.timing.lateSubmissions == 0 && preview.audio.timing.queueCoverageGaps == 0)
      precondition(preview.audio.frameAccounting.offeredFrames == 180 && preview.audio.skippedAudioFrames == 0)
      precondition(preview.latestSubmittedOrdinal == 179 && preview.failedVideoFrames == 0)
      precondition(preview.rendererSkippedFrames == 0 && preview.queueSkippedFrames == 0)
      precondition(preview.lateVideoSubmissions == 0)
      precondition(preview.nativeVideoMetrics.contains("dropped:0,"))
      print("BURST_AND_INPUT_GAP_REGRESSION_PASSED")
    }
    await preview.end()
    window.orderOut(nil)
  }
}
