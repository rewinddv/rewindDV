import Testing
@testable import RewindDVMonitorCore

struct LiveSignalPresentationTests {
  @Test func gapsNeverEndMonitoringAndFreshFramesRecover() {
    var signal = LiveSignalPresentation()
    signal.begin(at: 0)
    #expect(signal.state(at: 0) == .waitingForSignal)
    #expect(signal.state(at: 1) == .noPackets)
    for seconds in 1...10_000 {
      signal.observePackets(UInt64(seconds), at: Double(seconds))
      #expect(signal.state(at: Double(seconds)) == .noCompleteFrames)
    }
    signal.observeFrame(at: 10_000)
    signal.videoSubmitted()
    #expect(signal.state(at: 10_000) == .presenting)
    #expect(signal.state(at: 10_002) == .noPackets)
    signal.observePackets(10_001, at: 10_003)
    signal.observeFrame(at: 10_003)
    #expect(signal.state(at: 10_003) == .presenting)
    signal.end()
    #expect(signal.state(at: 20_000) == .inactive)
  }

  @Test func failedVideoDoesNotClaimMissingPacketsOrStoppedDeck() {
    var signal = LiveSignalPresentation()
    signal.begin(at: 0)
    signal.observePackets(1, at: 0.1)
    signal.observeFrame(at: 0.1)
    signal.videoFailedToPresent()
    #expect(signal.state(at: 0.2) == .videoRecovering)
    signal.observePackets(1, at: 2) // stale count must not refresh liveness
    #expect(signal.state(at: 2) == .noPackets)
    signal.observePackets(2, at: 2.1)
    #expect(signal.state(at: 2.1) == .noCompleteFrames)
    signal.observeFrame(at: 2.1)
    signal.videoSubmitted()
    #expect(signal.state(at: 2.1) == .presenting)
  }
}
