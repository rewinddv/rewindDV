// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Submission-side timing only. Queue coverage is predicted from accepted PCM,
/// not proof that the physical output device played every sample.
public struct LiveAudioTiming {
  public private(set) var submissions: UInt64 = 0
  public private(set) var lateSubmissions: UInt64 = 0
  public private(set) var lowLeadSubmissions: UInt64 = 0
  public private(set) var queueCoverageGaps: UInt64 = 0
  public private(set) var minimumLead: Double?
  public private(set) var minimumPriorCoverage: Double?
  public private(set) var maximumEnqueueInterval: Double = 0
  private var previousEnd: Double?
  private var previousEnqueue: Double?
  public init() {}
  public mutating func resetQueue() { previousEnd = nil; previousEnqueue = nil }
  public mutating func observe(now: Double, start: Double, duration: Double) {
    guard now.isFinite, start.isFinite, duration.isFinite, duration > 0 else { return }
    submissions &+= 1
    let lead = start - now
    minimumLead = min(minimumLead ?? lead, lead)
    if lead < 0 { lateSubmissions &+= 1 }
    if lead < 0.020 { lowLeadSubmissions &+= 1 }
    if let previousEnd {
      let coverage = previousEnd - now
      minimumPriorCoverage = min(minimumPriorCoverage ?? coverage, coverage)
      if coverage < 0 { queueCoverageGaps &+= 1 }
    }
    if let previousEnqueue { maximumEnqueueInterval = max(maximumEnqueueInterval, now - previousEnqueue) }
    previousEnd = start + duration; previousEnqueue = now
  }
  public var diagnostics: String {
    func ms(_ seconds: Double?) -> String { seconds.map { String($0 * 1000) } ?? "unknown" }
    return "audio_timing_scope=submission_not_physical_output; audio_submissions=\(submissions); audio_late_submissions=\(lateSubmissions); audio_low_lead_submissions=\(lowLeadSubmissions); audio_queue_coverage_gaps=\(queueCoverageGaps); audio_min_lead_ms=\(ms(minimumLead)); audio_min_prior_coverage_ms=\(ms(minimumPriorCoverage)); audio_max_enqueue_interval_ms=\(maximumEnqueueInterval * 1000)"
  }
}
