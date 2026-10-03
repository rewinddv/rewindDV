// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Presentation-only policy. An input interruption says nothing about packet
/// loss or tape damage. The archival byte path never consults this clock.
public struct LivePresentationTimeline {
  // Bounded shared A/V headroom, not raw-capture buffering. The observed live
  // path can deliver 100–145ms bursts plus video processing. 120ms allowed a
  // small scheduling delay to flush audio and retire pending video epochs.
  public static let presentationLead = 0.250
  public struct Schedule {
    public let seconds: Double
    public let resetReason: String?
  }
  public private(set) var waitingForInput = false
  public private(set) var interruptions: UInt64 = 0
  private var anchorOrdinal: UInt64?
  private var anchorTime = 0.0
  private var lastOrdinal: UInt64?
  private var lastOfferTime: Double?
  private var scheduledThrough = 0.0
  private var sourcePAL: Bool?
  public init() {}

  /// Enter wait only after queued media has had time to play. No renderer flush
  /// occurs on entering wait; the held image/timecode remain available.
  @discardableResult public mutating func observeIdle(now: Double) -> Bool {
    guard now.isFinite, !waitingForInput, let lastOfferTime,
      now - lastOfferTime > 0.250, now > scheduledThrough else { return false }
    waitingForInput = true
    interruptions &+= 1
    return true
  }

  public mutating func schedule(ordinal: UInt64, pal: Bool, now: Double) -> Schedule {
    let duration = pal ? 1.0 / 25.0 : 1001.0 / 30000.0
    // Also detects a starved UI clock task; no dependence on timer precision.
    observeIdle(now: now)
    var reason: String?
    if anchorOrdinal != nil {
      if sourcePAL != pal || (lastOrdinal.map { ordinal <= $0 } ?? false) {
        reason = "source_timeline_reset"
      } else if waitingForInput {
        reason = "preview_input_resumed"
      }
    }
    if anchorOrdinal == nil || reason != nil {
      anchorOrdinal = ordinal; anchorTime = now + Self.presentationLead
    }
    var time = anchorTime + Double(ordinal - anchorOrdinal!) * duration
    if time < now || time > now + 0.500 {
      reason = "presentation_lead_seconds=\(time - now)"
      anchorOrdinal = ordinal; anchorTime = now + Self.presentationLead; time = anchorTime
    }
    waitingForInput = false
    lastOfferTime = now; lastOrdinal = ordinal; sourcePAL = pal
    scheduledThrough = time + duration
    return Schedule(seconds: time, resetReason: reason)
  }
}

/// Counts every frame offered to the audio stage, including unusable leading
/// and trailing frames. No counter here measures raw receive loss.
public struct LiveAudioFrameAccounting {
  public enum SourceAudio { case usable, unknownFormat, unavailablePCM }
  public private(set) var offeredFrames: UInt64 = 0
  public private(set) var omittedBeforeAudio: UInt64 = 0
  public private(set) var unknownFormatFrames: UInt64 = 0
  public private(set) var unavailablePCMFrames: UInt64 = 0
  private var lastOrdinal: UInt64?
  public init() {}

  @discardableResult public mutating func observe(ordinal: UInt64, source: SourceAudio) -> Bool {
    let gap: UInt64
    if let lastOrdinal {
      gap = ordinal > lastOrdinal ? ordinal - lastOrdinal - 1 : 0
    } else { gap = ordinal }
    let discontinuous = lastOrdinal.map { ordinal <= $0 || gap > 0 } ?? (gap > 0)
    omittedBeforeAudio &+= gap
    offeredFrames &+= 1
    switch source {
    case .usable: break
    case .unknownFormat: unknownFormatFrames &+= 1
    case .unavailablePCM: unavailablePCMFrames &+= 1
    }
    lastOrdinal = ordinal
    return discontinuous
  }
}
