// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Confidence describes the interpretation's evidence, independently of whether
/// an observed value is valid, reserved, unavailable or structurally unusable.
public enum DVMetadataConfidence: String, Codable, CaseIterable, Sendable {
  case normativeConfirmed, independentlyCorroborated, implementationCorroborated
  case mostLikely, provisional, conflictingEvidence, unknown

  public var label: String {
    switch self {
    case .normativeConfirmed: "Confirmed"
    case .independentlyCorroborated: "Corroborated"
    case .implementationCorroborated: "Implementation corroborated"
    case .mostLikely: "Most likely — not 100% confirmed"
    case .provisional: "Provisional interpretation"
    case .conflictingEvidence: "Conflicting evidence — raw value retained"
    case .unknown: "Meaning not established"
    }
  }
}

public struct DVMetadataLocation: Codable, Equatable, Sendable {
  public let frameOrdinal: UInt64
  public let frameByteOffset: UInt64?
  public let sequence: UInt8
  public let section: UInt8
  public let block: UInt8
  public let slot: Int
  public let localByteOffset: Int
  public let absoluteByteOffset: UInt64?
  public let transmission: String
  public var difIDHex: String? = nil
}
