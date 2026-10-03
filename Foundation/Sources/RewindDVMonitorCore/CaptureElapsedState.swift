// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Monotonic wall-clock duration of the current or most recent PLAY interval.
///
/// This is deliberately independent of source timecode, packet counts and frame
/// ordinals. Its caller restarts the clock for every newly accepted/observed PLAY and
/// stops it on qualified mechanical STOP or explicit operator confirmation of
/// physical STOP. Receive termination and verification never fabricate STOP.
public struct CaptureElapsedState: Equatable, Sendable {
  public enum DVSystem: String, Codable, Equatable, Sendable {
    case ntsc525_60
    case pal625_50

    public var nominalFrameCount: UInt64 { self == .pal625_50 ? 25 : 30 }
  }

  public private(set) var startedAtUptimeNanoseconds: UInt64?
  public private(set) var stoppedAtUptimeNanoseconds: UInt64?
  public private(set) var system: DVSystem?
  public private(set) var conflictingSystems = false

  public init() {}

  public var hasStarted: Bool { startedAtUptimeNanoseconds != nil }
  public var isRunning: Bool { hasStarted && stoppedAtUptimeNanoseconds == nil }

  public mutating func resetInterval() {
    startedAtUptimeNanoseconds = nil
    stoppedAtUptimeNanoseconds = nil
  }

  public mutating func begin(atUptimeNanoseconds instant: UInt64) {
    // Every deliberate PLAY is a new operator-visible interval, including PLAY
    // used to return from picture search. Preserve the established DV system so
    // its nominal frame subdivision does not disappear between commands.
    startedAtUptimeNanoseconds = instant
    stoppedAtUptimeNanoseconds = nil
  }

  public mutating func stop(atUptimeNanoseconds instant: UInt64) {
    guard let start = startedAtUptimeNanoseconds, stoppedAtUptimeNanoseconds == nil else { return }
    stoppedAtUptimeNanoseconds = max(start, instant)
  }

  public mutating func observeCompleteDVFrame(byteCount: Int) {
    guard !conflictingSystems else { return }
    let observed: DVSystem
    switch byteCount {
    case 120_000: observed = .ntsc525_60
    case 144_000: observed = .pal625_50
    default: return
    }
    if let system, system != observed {
      self.system = nil
      conflictingSystems = true
    } else {
      system = observed
    }
  }

  public func elapsedNanoseconds(atUptimeNanoseconds now: UInt64) -> UInt64? {
    guard let start = startedAtUptimeNanoseconds else { return nil }
    let end = stoppedAtUptimeNanoseconds ?? now
    return end >= start ? end - start : 0
  }

  /// HH:MM:SS:FF display. FF is a nominal frame subdivision of monotonic wall
  /// time (30 for NTSC, 25 for PAL), never source timecode or a drop-frame label.
  /// Until native DV establishes the system, useful wall time remains visible
  /// and only the unproven frame field is withheld.
  public func display(atUptimeNanoseconds now: UInt64) -> String? {
    guard let elapsed = elapsedNanoseconds(atUptimeNanoseconds: now) else { return nil }
    let totalSeconds = elapsed / 1_000_000_000
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds / 60) % 60
    let seconds = totalSeconds % 60
    let frames = system.map {
      (elapsed % 1_000_000_000) * $0.nominalFrameCount / 1_000_000_000
    }
    return "\(Self.two(hours)):\(Self.two(minutes)):\(Self.two(seconds)):\(frames.map(Self.two) ?? "--")"
  }

  private static func two(_ value: UInt64) -> String {
    value < 10 ? "0\(value)" : String(value)
  }
}
