// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Receive lifetime has no dependency on DV content, timecode, ATN, cadence,
/// frame count, or elapsed capture time. STATUS evidence is supplied only after
/// the adapter validates the transaction and full route. A natural stop is an
/// inferred tape boundary, never proof of the physical tape's absolute position.
public struct TapeMotionEvidence: Sendable {
  public enum Direction: Sendable { case rewind, forwardPlayback }
  public enum Decision: Equatable, Sendable {
    case keepReceiving, stoppedWithoutObservedMotion, naturalStop, transportFault
  }
  public let routeIdentity: String
  public let direction: Direction
  public private(set) var sawExpectedMotion = false
  private var lastReceipt: String?
  private var lastUptime: UInt64?
  private var consecutiveStops = 0

  public init(routeIdentity: String, direction: Direction) {
    self.routeIdentity = routeIdentity; self.direction = direction
  }

  /// Missing/invalid/transitioning STATUS breaks the stop sequence, not capture.
  /// Unique, increasing observations prevent a cached result being counted twice.
  public mutating func observe(response: [UInt8]?, route: String, receipt: String,
                               uptimeNanoseconds: UInt64) -> Decision {
    guard route == routeIdentity, !receipt.isEmpty, receipt != lastReceipt,
      lastUptime.map({ uptimeNanoseconds > $0 }) ?? true else {
      consecutiveStops = 0; return .keepReceiving
    }
    lastReceipt = receipt; lastUptime = uptimeNanoseconds
    guard let response, response.count == 4, response[0] == 0x0c, response[1] == 0x20 else {
      consecutiveStops = 0; return .keepReceiving
    }
    let opcode = response[2], operand = response[3]
    // Existing TA 2004005 table 46/47 mappings in AVCTapeStatusDecoder.
    if opcode == 0xc4 && [UInt8(0x30), 0x31].contains(operand) || opcode == 0xc1 && operand == 0x60 {
      consecutiveStops = 0; return .transportFault
    }
    let expected = direction == .rewind
      ? opcode == 0xc4 && [UInt8(0x45), 0x65].contains(operand)
      : opcode == 0xc3 && operand == 0x75
    if expected { sawExpectedMotion = true }
    guard opcode == 0xc4 && operand == 0x60 else {
      consecutiveStops = 0; return .keepReceiving
    }
    consecutiveStops += 1
    guard consecutiveStops >= 2 else { return .keepReceiving }
    return sawExpectedMotion ? .naturalStop : .stoppedWithoutObservedMotion
  }

  /// No data and missing metadata are observations, never terminal events.
  public func signalGap() -> Decision { .keepReceiving }
}
