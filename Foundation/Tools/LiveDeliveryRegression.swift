// Native, muted, OFFLINE ONLY. Replays saved DV through the actual receive pump
// and preview, including empty polls and a slow UI consumer. No DriverBridge is
// constructed and no driver connection or deck command is possible here.
import AVFoundation
import AppKit
import Combine
import Foundation

private actor FixtureReceiver {
  let bytes: Data
  let statusWire: Data
  let start = ContinuousClock.now
  var next = 0
  var polls = 0
  var emptyPolls = 0
  init(bytes: Data, status: Data) { self.bytes = bytes; statusWire = status }
  func read() throws -> LiveReceiveBatch {
    polls += 1
    let elapsed = start.duration(to: .now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    let count = bytes.count / 120_000
    let through = min(count, Int(seconds * 30000.0 / 1001.0))
    var frames: [LivePreservedFrame] = []
    while next < through {
      let frame = bytes.subdata(in: (next * 120_000)..<((next + 1) * 120_000))
      frames.append(LivePreservedFrame(bytes: frame, ordinal: UInt64(next),
        timecode: LiveDVMedia(frame: frame)?.timecode))
      next += 1
    }
    if frames.isEmpty { emptyPolls += 1 }
    var wire = statusWire
    var state = UInt32(next == count ? 2 : 1).littleEndian
    withUnsafeBytes(of: &state) { wire.replaceSubrange(80..<84, with: $0) }
    return LiveReceiveBatch(status: try LiveReceiveStatus(wire), frames: frames,
      drained: true, rejectedPackets: 0, assembledFrames: UInt64(next),
      discontinuities: 0, incompleteFrames: 0)
  }
}

@main struct LiveDeliveryRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 3 else { fatalError("Provide saved .dv and verification.json") }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(bytes.count > 0 && bytes.count.isMultiple(of: 120_000))
    let verification = try JSONDecoder().decode(DVIngestVerification.self,
      from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let wire = Data(base64Encoded: verification.finalStatusWireBase64)!
    _ = NSApplication.shared
    let model = LiveMonitorModel(muteAudio: true)
    let preview = model.preview
    var forwardedWorkspaceInvalidations = 0
    let observation = model.objectWillChange.sink { forwardedWorkspaceInvalidations += 1 }
    defer { observation.cancel() }
    await preview.begin()
    let source = FixtureReceiver(bytes: bytes, status: wire)
    let pump = LiveReceivePump(readBatch: { try await source.read() })
    var received: [UInt64] = []
    for await _ in pump.notifications {
      // UI lag is intentional: status polling continues much faster than this.
      try await Task.sleep(for: .milliseconds(50))
      Self.simulateMainThreadLayoutStall()
      guard let event = pump.take() else { continue }
      switch event {
      case .failure(let reason): fatalError(reason)
      case .batch(let batch):
        for frame in batch.frames {
          received.append(frame.ordinal)
          preview.offerPreservedFrame(frame.bytes, ordinal: frame.ordinal, sourceTimecode: frame.timecode)
        }
        if batch.status.state >= 2 { break }
      }
    }
    await pump.cancelAndJoin()
    try await Task.sleep(for: .milliseconds(300))
    let count = bytes.count / 120_000
    print("PUMP_REPLAY frames=\(count) received=\(received.count) polls=\(await source.polls) empty_polls=\(await source.emptyPolls) delivery_skips=\(pump.skippedDeliveryFrames) preview_skips=\(preview.skippedPreviewFrames) audio_skips=\(preview.audio.skippedAudioFrames) audio_delivery_gaps=\(preview.audio.deliveryGapFrames) resyncs=\(preview.audio.resynchronizations)")
    precondition(received == (0..<count).map(UInt64.init))
    precondition(pump.skippedDeliveryFrames == 0 && preview.skippedPreviewFrames == 0)
    precondition(preview.audio.skippedAudioFrames == 0 && preview.audio.deliveryGapFrames == 0)
    precondition(preview.audio.resynchronizations == 0)
    precondition(preview.latestSubmittedOrdinal == UInt64(count - 1))
    precondition(preview.error == nil)
    precondition(forwardedWorkspaceInvalidations == 0)
    print("PER_FRAME_PREVIEW_FORWARDED_WORKSPACE_INVALIDATIONS=\(forwardedWorkspaceInvalidations)")
    await preview.end(retainingImage: true)
    print("LIVE_PUMP_EMPTY_POLLS_SLOW_UI_NATIVE_AV_PASS; muted offline replay, not hardware proof")
    let cancelledSource = FixtureReceiver(bytes: bytes, status: wire)
    let cancelledPump = LiveReceivePump(readBatch: { try await cancelledSource.read() })
    try await Task.sleep(for: .milliseconds(30))
    await cancelledPump.cancelAndJoin()
    let finalPolls = await cancelledSource.polls
    try await Task.sleep(for: .milliseconds(40))
    let laterPolls = await cancelledSource.polls
    precondition(laterPolls == finalPolls)
    let failedPump = LiveReceivePump(readBatch: { throw LiveDVDecodeError.malformedFrame })
    var sawFailure = false
    for await _ in failedPump.notifications {
      if case .failure = failedPump.take() { sawFailure = true; break }
    }
    await failedPump.cancelAndJoin()
    precondition(sawFailure)
    print("LIVE_PUMP_JOIN_FENCES_READER_AND_FAILURE_BEFORE_FIRST_STATUS_PASS")
  }

  @MainActor private static func simulateMainThreadLayoutStall() {
    // Deliberately block the main thread as a costly SwiftUI layout would.
    // The detached producer and native render clocks must continue safely.
    Thread.sleep(forTimeInterval: 0.025)
  }
}
