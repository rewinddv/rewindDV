// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Deterministic ordinal samples for both filmstrip and contact-sheet consumers.
/// Presentation time and recorded timecode are labels, never frame identity.
public struct DVArchiveSamplePlan: Codable, Equatable, Sendable {
  public let source: DVReviewedRangeExporter.Snapshot
  public let firstFrame: UInt64
  public let endFrameExclusive: UInt64
  public let frames: [DVSourceFrameIdentity]
  public let policy: String
  public let omittedTransitionEndpoints: Int

  public static func make(source: DVReviewedRangeExporter.Snapshot, first: UInt64,
    endExclusive: UInt64, maximumSamples: Int = 24) throws -> Self {
    try source.validate()
    guard first < endExclusive, endExclusive <= source.frameCount, (2...256).contains(maximumSamples) else {
      throw DVIngestError.invalidEvidence("visual review range or sample budget is invalid")
    }
    var transitions = Set([first, endExclusive - 1])
    for epoch in source.recordingEpochs where epoch.firstFrame > first && epoch.firstFrame < endExclusive {
      transitions.insert(epoch.firstFrame - 1); transitions.insert(epoch.firstFrame)
    }
    var chosen = transitions
    let slots = min(UInt64(maximumSamples), endExclusive - first)
    if slots > 1 {
      for i in 0..<slots { chosen.insert(first + (endExclusive - first - 1) * i / (slots - 1)) }
    }
    if chosen.count > maximumSamples {
      if transitions.count <= maximumSamples {
        chosen = transitions
        for value in (0..<slots).map({ first + (endExclusive - first - 1) * $0 / max(1, slots - 1) }) {
          if chosen.count < maximumSamples { chosen.insert(value) }
        }
      } else {
        let ordered = transitions.sorted()
        chosen = Set((0..<maximumSamples).map { ordered[(ordered.count - 1) * $0 / (maximumSamples - 1)] })
      }
    }
    return Self(source: source, firstFrame: first, endFrameExclusive: endExclusive,
      frames: try chosen.sorted().map { try source.frame($0) },
      policy: "Source ordinals sampled deterministically; includes range endpoints and prioritizes both sides of recording-system transitions. Not an exhaustive visual review. Unknown byte regions are not sampled.",
      omittedTransitionEndpoints: transitions.subtracting(chosen).count)
  }
}
