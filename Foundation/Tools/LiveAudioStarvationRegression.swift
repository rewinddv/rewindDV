// OFFLINE ONLY: muted saved-frame replay, no driver/client or hardware access.
import AppKit
import AVFoundation
import Foundation

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

@main struct LiveAudioStarvationRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(source.count >= 120_000 && source.count.isMultiple(of: 120_000))
    let expectBaseline = CommandLine.arguments.contains("--expect-baseline")
    let preview = LiveDVPreview(muteAudio: true, beforeDecode: { ordinal in
      // A video-only stall must not starve otherwise punctual audio delivery.
      if ordinal > 10 && ordinal % 30 == 15 { try? await Task.sleep(for: .milliseconds(180)) }
    })
    await preview.begin()
    let start = ContinuousClock.now
    for ordinal in 0..<180 {
      try await ContinuousClock().sleep(until: start.advanced(by: .nanoseconds(Int64(ordinal) * 33_366_667)))
      let i = ordinal % (source.count / 120_000)
      preview.offerPreservedFrame(source.subdata(in: i*120_000..<(i+1)*120_000),
        ordinal: UInt64(ordinal), sourceTimecode: nil)
    }
    try await Task.sleep(for: .seconds(1))
    print(preview.timingDiagnostics)
    print("audio_resyncs=\(preview.audio.resynchronizations); audio_frames=\(preview.audio.frameAccounting.offeredFrames); audio_skips=\(preview.audio.skippedAudioFrames)")
    if expectBaseline {
      precondition(preview.audio.resynchronizations > 0 || preview.audio.timing.queueCoverageGaps > 0,
        "Red oracle did not expose video-dependent audio starvation")
      print("BASELINE_STARVATION_REPRODUCED_NOT_A_PASS")
    } else {
      precondition(preview.audio.resynchronizations == 0, "Video-only work must not reset audio")
      precondition(preview.audio.timing.queueCoverageGaps == 0)
      precondition(preview.audio.timing.lateSubmissions == 0)
      precondition(preview.audio.frameAccounting.offeredFrames == 180)
      precondition(preview.audio.frameAccounting.omittedBeforeAudio == 0)
      precondition(preview.audio.skippedAudioFrames == 0)
      print("AUDIO_STARVATION_REGRESSION_PASSED")
    }
    await preview.end()
  }
}
