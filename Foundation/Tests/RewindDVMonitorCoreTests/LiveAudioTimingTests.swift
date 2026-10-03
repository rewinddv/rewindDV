import Testing
@testable import RewindDVMonitorCore

@Test func audioTimingMeasuresDeadlinesCoverageAndResetBoundaries() {
  var timing = LiveAudioTiming()
  timing.observe(now: 0, start: 0.12, duration: 0.04)
  timing.observe(now: 0.04, start: 0.16, duration: 0.04)
  #expect(timing.queueCoverageGaps == 0 && timing.lateSubmissions == 0)
  timing.observe(now: 0.21, start: 0.20, duration: 0.04)
  #expect(timing.queueCoverageGaps == 1 && timing.lateSubmissions == 1)
  #expect(timing.lowLeadSubmissions == 1)
  #expect(abs(timing.minimumLead! + 0.01) < 1e-9)
  #expect(abs(timing.maximumEnqueueInterval - 0.17) < 1e-9)
  timing.resetQueue()
  timing.observe(now: 10, start: 10.12, duration: 0.04)
  #expect(timing.queueCoverageGaps == 1) // intentional gap/reset is distinct
  #expect(timing.submissions == 4)
  timing.observe(now: .nan, start: 0, duration: 1)
  timing.observe(now: 0, start: .infinity, duration: 1)
  timing.observe(now: 0, start: 0, duration: 0)
  #expect(timing.submissions == 4)
  #expect(timing.diagnostics.contains("submission_not_physical_output"))
}
