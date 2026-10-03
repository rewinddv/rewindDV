// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded, rebuildable observations for one complete native DV25 frame.
///
/// This type describes retained bytes. It does not classify visible content,
/// establish tape-recording history, select frames for deletion, or authorize
/// a merge. The caller remains responsible for any reviewed derivative policy.
public struct DVBoundaryEvidence: Codable, Equatable, Sendable {
  public enum VideoSystem: String, Codable, Equatable, Sendable {
    case ntsc525_60 = "ntsc_525_60"
    case pal625_50 = "pal_625_50"
  }

  /// Cardinality of distinct raw values, not an interpretation of their bits.
  public enum RawValueSetClassification: String, Codable, Equatable, Sendable {
    case notObserved = "not_observed"
    case singleUniqueRawValueObserved = "single_unique_raw_value_observed"
    case multipleUniqueRawValuesObserved = "multiple_unique_raw_values_observed"
  }

  public struct RawPackValue: Codable, Equatable, Sendable {
    /// Exact five-byte pack, including the 0x60 or 0x61 type byte.
    public let rawBytes: [UInt8]
    /// Absolute offsets of every occurrence's type byte in the source DV.
    public let observationSourceByteOffsets: [UInt64]

    private enum CodingKeys: String, CodingKey {
      case rawBytes = "raw_bytes"
      case observationSourceByteOffsets = "observation_source_byte_offsets"
    }
  }

  public struct PackSet: Codable, Equatable, Sendable {
    public let packType: UInt8
    public let classification: RawValueSetClassification
    /// One entry per unique raw five-byte value, sorted bytewise.
    public let uniqueRawValues: [RawPackValue]

    private enum CodingKeys: String, CodingKey {
      case packType = "pack_type"
      case classification
      case uniqueRawValues = "unique_raw_values"
    }
  }

  public let schemaVersion: UInt16
  public let frameOrdinal: UInt64
  public let frameSourceByteOffset: UInt64
  public let frameByteCount: Int
  public let frameSHA256: String
  public let videoSystem: VideoSystem
  public let audioSampleRate: DVAudioSampleRateClassification
  public let nonzeroVideoSTABlockCount: Int
  public let vauxSource: PackSet
  public let vauxSourceControl: PackSet
  public let interpretationPolicy: String

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case frameOrdinal = "frame_ordinal"
    case frameSourceByteOffset = "frame_source_byte_offset"
    case frameByteCount = "frame_byte_count"
    case frameSHA256 = "frame_sha256"
    case videoSystem = "video_system"
    case audioSampleRate = "audio_sample_rate"
    case nonzeroVideoSTABlockCount = "nonzero_video_sta_block_count"
    case vauxSource = "vaux_source"
    case vauxSourceControl = "vaux_source_control"
    case interpretationPolicy = "interpretation_policy"
  }

  public static func inspect(
    frame: Data,
    ordinal: UInt64,
    sourceByteOffset: UInt64
  ) throws -> Self {
    // Data.SubSequence is Data and may carry nonzero indices. Materialize a
    // fresh zero-based value before calling parsers that use integer offsets.
    var normalizedFrame = Data()
    normalizedFrame.reserveCapacity(frame.count)
    normalizedFrame.append(contentsOf: frame)

    let inventory = try DVMetadataInventory.inspect(
      frame: normalizedFrame, ordinal: ordinal, byteOffset: sourceByteOffset)
    var sourceValues: [[UInt8]: [UInt64]] = [:]
    var sourceControlValues: [[UInt8]: [UInt64]] = [:]

    for extent in inventory.extents where extent.section == 2 {
      // Inventory validation guarantees a complete 80-byte VAUX DIF block.
      guard extent.bytes.count == 80 else {
        throw DVIngestError.invalidEvidence("boundary evidence requires complete VAUX blocks")
      }
      for slot in stride(from: 3, through: 73, by: 5) {
        let raw = Array(extent.bytes[slot..<(slot + 5)])
        let observationOffset = extent.sourceByteOffset + UInt64(slot)
        switch raw[0] {
        case 0x60: sourceValues[raw, default: []].append(observationOffset)
        case 0x61: sourceControlValues[raw, default: []].append(observationOffset)
        default: break
        }
      }
    }

    return Self(
      schemaVersion: 1,
      frameOrdinal: inventory.frameOrdinal,
      frameSourceByteOffset: inventory.frameByteOffset,
      frameByteCount: inventory.frameByteCount,
      frameSHA256: inventory.frameSHA256,
      videoSystem: inventory.frameByteCount == 144_000 ? .pal625_50 : .ntsc525_60,
      audioSampleRate: inventory.audioSampleRate,
      nonzeroVideoSTABlockCount: inventory.nonzeroVideoStatusBlocks,
      vauxSource: makePackSet(type: 0x60, values: sourceValues),
      vauxSourceControl: makePackSet(type: 0x61, values: sourceControlValues),
      interpretationPolicy:
        "raw_frame_observation_only; no_gray_or_content_deletion; no_tape_recording_truth; no_merge_authority")
  }

  private static func makePackSet(
    type: UInt8,
    values: [[UInt8]: [UInt64]]
  ) -> PackSet {
    let rawValues = values.keys.sorted {
      $0.lexicographicallyPrecedes($1)
    }.map {
      RawPackValue(
        rawBytes: $0,
        observationSourceByteOffsets: values[$0]!.sorted())
    }
    let classification: RawValueSetClassification
    switch rawValues.count {
    case 0: classification = .notObserved
    case 1: classification = .singleUniqueRawValueObserved
    default: classification = .multipleUniqueRawValuesObserved
    }
    return PackSet(
      packType: type,
      classification: classification,
      uniqueRawValues: rawValues)
  }
}
