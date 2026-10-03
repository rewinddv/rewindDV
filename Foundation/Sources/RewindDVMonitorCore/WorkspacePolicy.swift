// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// One monitor workspace; source identity determines the available operations.
/// Presentation cannot grant hardware or capture authority.
public enum MonitorSource: String, CaseIterable, Identifiable, Sendable {
  case deck = "Capture"
  case file = "Playback"
  public var id: Self { self }
}

public enum MonitorAction: CaseIterable, Sendable {
  case play, pause, stop, rewind, fastForward, shuttleForward, shuttleReverse, stepBackward, stepForward, beginning, end, capture
}

public struct WorkspaceCapabilities: Equatable, Sendable {
  public let source: MonitorSource
  public let fileReady: Bool
  public let filePlaying: Bool
  public let deckSelected: Bool
  public let busy: Bool
  public let lockedOut: Bool
  public let requiresSupervisedStop: Bool
  public let fastForwardSupported: Bool
  public let liveMonitoring: Bool
  public let ingestActive: Bool
  public let shuttleForwardSupported: Bool
  public let shuttleReverseSupported: Bool

  public init(
    source: MonitorSource, fileReady: Bool = false, filePlaying: Bool = false,
    deckSelected: Bool = false,
    busy: Bool = false, lockedOut: Bool = false,
    requiresSupervisedStop: Bool = false, fastForwardSupported: Bool = false,
    liveMonitoring: Bool = false, ingestActive: Bool = false,
    shuttleForwardSupported: Bool = false, shuttleReverseSupported: Bool = false
  ) {
    self.source = source
    self.fileReady = fileReady
    self.filePlaying = filePlaying
    self.deckSelected = deckSelected
    self.busy = busy
    self.lockedOut = lockedOut
    self.requiresSupervisedStop = requiresSupervisedStop
    self.fastForwardSupported = fastForwardSupported
    self.liveMonitoring = liveMonitoring
    self.ingestActive = ingestActive
    self.shuttleForwardSupported = shuttleForwardSupported
    self.shuttleReverseSupported = shuttleReverseSupported
  }

  public func allows(_ action: MonitorAction) -> Bool {
    // Capture stays unrepresentable until raw-preserving receive is integrated.
    guard action != .capture, !busy else { return false }
    switch source {
    case .deck:
      // A direct transport-button click is the one-command intent. There is
      // no persistent arm toggle; route freshness remains a bridge/driver gate.
      guard deckSelected, !lockedOut else { return false }
      if action == .stop { return true }
      if ingestActive { return false }
      if liveMonitoring {
        return action == .play || (action == .shuttleForward && shuttleForwardSupported)
          || (action == .shuttleReverse && shuttleReverseSupported)
      }
      if requiresSupervisedStop { return false }
      return action == .play || action == .stop || action == .rewind || (action == .fastForward && fastForwardSupported)
    case .file:
      guard fileReady else { return false }
      switch action {
      case .play: return !filePlaying
      case .pause: return filePlaying
      case .stepBackward, .stepForward, .beginning, .end: return true
      case .stop, .rewind, .fastForward, .shuttleForward, .shuttleReverse, .capture: return false
      }
    }
  }
}

/// Counter is elapsed media time, never a substitute for source tape timecode.
public enum MonitorCounter {
  public static func elapsed(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1_000) else {
      return "--:--:--.---"
    }
    let milliseconds = Int((seconds * 1_000).rounded(.down))
    return String(
      format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000,
      (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60,
      milliseconds % 1_000)
  }
}
