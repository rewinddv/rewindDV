// OFFLINE, MUTED. Synthetic presentation faults, immutable saved DV fixture.
// No driver implementation or IOKit is linked by the slim compile recipe.
import AVFoundation
import AppKit
import Foundation

// Preserve every oracle; name the exact assertion even in optimized runs.
@MainActor private func precondition(_ value: @autoclosure () -> Bool, line: UInt = #line) {
  if !value() {
    try? FileHandle.standardError.write(contentsOf: Data("RECOVERY_ASSERTION_FAILED line=\(line)\n".utf8))
    fatalError("Recovery assertion failed at line \(line)")
  }
}

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

@MainActor private final class VideoAdmission { var allowed = false }

@main struct LivePreviewRecoveryRegression {
  @MainActor static func waitForPresentation(_ preview: LiveDVPreview, ordinal: UInt64) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while preview.latestSubmittedOrdinal != ordinal, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(preview.latestSubmittedOrdinal == ordinal)
  }
  @MainActor static func main() async throws {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
    let good = try file.read(upToCount: 120_000)!
    try file.close()
    precondition(good.count == 120_000)
    _ = NSApplication.shared
    let modeIndex = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 0
    let mode = DVViewingMode.allCases[modeIndex]
    print("VIEW_MODE=\(mode.rawValue)")
    let preview = LiveDVPreview(muteAudio: true)
    preview.viewingMode = mode
    await preview.begin()
    preview.observeReceivePackets(1)
    preview.offerPreservedFrame(good, ordinal: 0, sourceTimecode: "00:00:00:00")
    try await waitForPresentation(preview, ordinal: 0)
    precondition(preview.latestSubmittedOrdinal == 0)
    // Invalid in-memory input exercises decoder failure, not a real damaged tape.
    preview.offerPreservedFrame(Data(), ordinal: 1, sourceTimecode: nil)
    try await Task.sleep(for: .milliseconds(60))
    precondition(preview.isReceiving && preview.failedVideoFrames == 1)
    for ordinal in 2..<12 {
      preview.observeReceivePackets(UInt64(ordinal))
      preview.offerPreservedFrame(good, ordinal: UInt64(ordinal), sourceTimecode: "00:00:00:11")
      try await Task.sleep(for: .milliseconds(34))
    }
    try await waitForPresentation(preview, ordinal: 11)
    precondition(preview.latestSubmittedOrdinal == 11 && preview.isReceiving)
    precondition(preview.audio.frameAccounting.offeredFrames == 12)
    precondition(preview.failedVideoFrames == 1)
    try await Task.sleep(for: .milliseconds(1100))
    precondition(preview.isReceiving && preview.hasImage && preview.signalState == .noPackets)
    preview.observeReceivePackets(100)
    preview.offerPreservedFrame(good, ordinal: 12, sourceTimecode: "00:00:00:12")
    // Inspect meters while this single ~33ms audio frame is actually scheduled,
    // not 200ms after intake when the new independent audio path has finished it.
    let resumedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while preview.latestSubmittedOrdinal != 12, ContinuousClock.now < resumedDeadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(preview.latestSubmittedOrdinal == 12 && preview.signalState == .presenting)
    precondition(preview.audio.presentation.channel(at: 0).active)
    await preview.end(retainingImage: true)
    precondition(!preview.isReceiving && preview.signalState == .inactive && preview.hasImage)
    print("LIVE_PREVIEW_BAD_FRAME_AND_SIGNAL_GAP_RECOVERY_PASS; audio offered=13; video failures=1; no hardware or source edits")
    let admission = VideoAdmission()
    let congested = LiveDVPreview(muteAudio: true, permitsVideoSubmission: { admission.allowed })
    congested.viewingMode = mode
    await congested.begin()
    congested.observeReceivePackets(1)
    congested.offerPreservedFrame(good, ordinal: 0, sourceTimecode: "00:00:00:00")
    try await Task.sleep(for: .milliseconds(180))
    precondition(congested.signalState == .videoRecovering && !congested.hasImage)
    precondition(congested.audio.frameAccounting.offeredFrames == 1)
    admission.allowed = true
    congested.observeReceivePackets(2)
    congested.offerPreservedFrame(good, ordinal: 1, sourceTimecode: "00:00:00:01")
    try await waitForPresentation(congested, ordinal: 1)
    precondition(congested.hasImage && congested.latestSubmittedOrdinal == 1)
    admission.allowed = false
    congested.observeReceivePackets(3)
    congested.offerPreservedFrame(good, ordinal: 2, sourceTimecode: "00:00:00:02")
    try await Task.sleep(for: .milliseconds(180))
    precondition(congested.signalState == .videoRecovering && congested.latestSubmittedOrdinal == 1)
    precondition(congested.audio.frameAccounting.offeredFrames == 3 && congested.isReceiving)
    admission.allowed = true
    congested.observeReceivePackets(4)
    congested.offerPreservedFrame(good, ordinal: 3, sourceTimecode: "00:00:00:03")
    try await waitForPresentation(congested, ordinal: 3)
    precondition(congested.signalState == .presenting && congested.latestSubmittedOrdinal == 3)
    precondition(congested.rendererSkippedFrames == 2 && congested.failedVideoFrames == 0)
    await congested.end()
    print("LIVE_VIDEO_BACKPRESSURE_OVERLAY_AND_AUDIO_INDEPENDENCE_PASS; injected admission refusal, native renderer still used")
  }
}
