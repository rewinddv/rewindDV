import XCTest
@testable import RewindDVMonitorCore

final class LivePresentationTimelineTests: XCTestCase {
  func testNormalNTSCPALAndBatchesDoNotReset() {
    for pal in [false, true] {
      var clock = LivePresentationTimeline()
      let duration = pal ? 0.04 : 1001.0 / 30000.0
      for ordinal in 0..<600 {
        let now = Double(ordinal / 2 * 2) * duration
        let schedule = clock.schedule(ordinal: UInt64(ordinal), pal: pal, now: now)
        XCTAssertNil(schedule.resetReason)
        XCTAssertEqual(schedule.seconds, 0.25 + Double(ordinal) * duration, accuracy: 1e-8)
      }
      XCTAssertEqual(clock.interruptions, 0)
    }
  }

  func testM15TwoSecondInterruptionWaitsThenReanchorsExactlyOnce() {
    var clock = LivePresentationTimeline()
    for i in 0..<4 { _ = clock.schedule(ordinal: UInt64(i), pal: false, now: Double(i) / 30) }
    XCTAssertFalse(clock.observeIdle(now: 0.2))
    XCTAssertTrue(clock.observeIdle(now: 0.4))
    XCTAssertFalse(clock.observeIdle(now: 2.0))
    XCTAssertTrue(clock.waitingForInput)
    let resumed = clock.schedule(ordinal: 4, pal: false, now: 2.135526)
    XCTAssertEqual(resumed.resetReason, "preview_input_resumed")
    XCTAssertEqual(resumed.seconds, 2.385526, accuracy: 1e-8)
    XCTAssertFalse(clock.waitingForInput)
    XCTAssertEqual(clock.interruptions, 1)
    XCTAssertNil(clock.schedule(ordinal: 5, pal: false, now: 2.168893).resetReason)
  }

  func testWaitDoesNotRetireStillQueuedMedia() {
    var clock = LivePresentationTimeline()
    _ = clock.schedule(ordinal: 0, pal: false, now: 0)
    // Six frames fit inside the unchanged 500ms maximum future horizon.
    XCTAssertNil(clock.schedule(ordinal: 6, pal: false, now: 0.01).resetReason)
    XCTAssertFalse(clock.observeIdle(now: 0.30))
    XCTAssertFalse(clock.observeIdle(now: 0.45))
    XCTAssertTrue(clock.observeIdle(now: 0.60))
  }

  func testBoundedDeliveryJitterKeepsClockAndRealStarvationStillResets() {
    for pal in [false, true] {
      var clock = LivePresentationTimeline()
      let duration = pal ? 0.04 : 1001.0 / 30000.0
      for i in 0..<180 {
        let now = Double(i) * duration + (i >= 100 ? 0.140 : 0)
        let schedule = clock.schedule(ordinal: UInt64(i), pal: pal, now: now)
        XCTAssertNil(schedule.resetReason)
        XCTAssertGreaterThanOrEqual(schedule.seconds - now, 0.109999)
      }
      let resumed = clock.schedule(ordinal: 180, pal: pal, now: 180 * duration + 2)
      XCTAssertEqual(resumed.resetReason, "preview_input_resumed")
      XCTAssertEqual(clock.interruptions, 1)
      XCTAssertEqual(resumed.seconds, 180 * duration + 2.25, accuracy: 1e-8)
    }
  }

  func testOrdinalGapResetFormatChangeAndTimerStarvation() {
    var clock = LivePresentationTimeline()
    _ = clock.schedule(ordinal: 0, pal: false, now: 0)
    XCTAssertNil(clock.schedule(ordinal: 4, pal: false, now: 0.02).resetReason)
    XCTAssertEqual(clock.schedule(ordinal: 2, pal: false, now: 0.04).resetReason, "source_timeline_reset")
    XCTAssertEqual(clock.schedule(ordinal: 3, pal: true, now: 0.08).resetReason, "source_timeline_reset")
    XCTAssertEqual(clock.schedule(ordinal: 4, pal: true, now: 1).resetReason, "preview_input_resumed")
    XCTAssertNotNil(clock.schedule(ordinal: 1000, pal: true, now: 1.01).resetReason)
  }

  func testUnusableLeadingInteriorTrailingAudioIsNotDeliveryLoss() {
    var audio = LiveAudioFrameAccounting()
    for i in 0..<18 {
      audio.observe(ordinal: UInt64(i), source: [0, 1, 4, 5, 17].contains(i) ? .unavailablePCM : .usable)
    }
    XCTAssertEqual(audio.offeredFrames, 18)
    XCTAssertEqual(audio.unavailablePCMFrames, 5)
    XCTAssertEqual(audio.omittedBeforeAudio, 0)
    XCTAssertEqual(audio.unknownFormatFrames, 0)
    XCTAssertTrue(audio.observe(ordinal: 21, source: .unknownFormat))
    XCTAssertEqual(audio.omittedBeforeAudio, 3)
    XCTAssertEqual(audio.unknownFormatFrames, 1)
    XCTAssertTrue(audio.observe(ordinal: 2, source: .usable))
    XCTAssertEqual(audio.omittedBeforeAudio, 3)
  }

  func testInitialOmissionAndReorderedOrdinalsDoNotUnderflow() {
    var audio = LiveAudioFrameAccounting()
    XCTAssertTrue(audio.observe(ordinal: 3, source: .unknownFormat))
    XCTAssertEqual(audio.omittedBeforeAudio, 3)
    XCTAssertTrue(audio.observe(ordinal: 3, source: .usable))
    XCTAssertTrue(audio.observe(ordinal: 0, source: .unavailablePCM))
    XCTAssertEqual(audio.omittedBeforeAudio, 3)
  }
}
