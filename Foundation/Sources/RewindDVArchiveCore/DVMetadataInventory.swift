// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

/// Lossless inventory of DV25 metadata-bearing byte extents. Interpretation is
/// deliberately separate from retention; no position/quality/merge authority.
public struct DVMetadataInventory: Codable, Equatable, Sendable {
  public struct Extent: Codable, Equatable, Sendable {
    public let sourceByteOffset: UInt64
    public let sequence: UInt8
    public let section: UInt8
    public let block: UInt8
    public let kind: String
    public let bytes: Data
  }
  public struct PackSummary: Codable, Equatable, Sendable {
    public let typeHex: String
    public let label: String
    public let observations: Int
  }
  public let schemaVersion: Int
  public let frameOrdinal: UInt64
  public let frameByteOffset: UInt64
  public let frameByteCount: Int
  public let frameSHA256: String
  public let extents: [Extent]
  public let packs: [PackSummary]
  public let audioSampleRate: DVAudioSampleRateClassification
  public let nonzeroVideoStatusBlocks: Int
  public let positionInterpretation: String

  public static func inspect(frame: Data, ordinal: UInt64, byteOffset: UInt64) throws -> Self {
    guard frame.count == 120_000 || frame.count == 144_000,
      byteOffset <= UInt64.max - UInt64(frame.count),
      frame[0] >> 5 == 0, frame[1] >> 4 == 0, frame[2] == 0,
      (frame[3] & 0x80 != 0) == (frame.count == 144_000) else {
      throw DVIngestError.invalidEvidence("metadata inventory requires one complete ordered DV25 frame")
    }
    let analysis = DVCaptureMetadataEpochAnalyzer.analyze(data: frame)
    guard analysis.completeFrameCount == 1, analysis.unclassifiedExtents.isEmpty,
      let observed = analysis.frames.first else {
      throw DVIngestError.invalidEvidence("metadata inventory DIF structure rejected")
    }
    var extents: [Extent] = [], counts: [UInt8: Int] = [:]
    var blockIdentities = Set<Int>()
    var videoStatus = 0
    for offset in stride(from: 0, to: frame.count, by: 80) {
      let section = frame[offset] >> 5
      let sequence = frame[offset + 1] >> 4
      let block = frame[offset + 2]
      guard section < 5, sequence < (frame.count == 144_000 ? 12 : 10),
        Int(block) < [1, 2, 3, 9, 135][Int(section)],
        blockIdentities.insert(Int(sequence) * 2048 + Int(section) * 256 + Int(block)).inserted,
        section != 0 || ((frame[offset + 3] & 0x80 != 0) == (frame.count == 144_000)) else {
        throw DVIngestError.invalidEvidence("metadata inventory duplicate/out-of-range DIF identity or conflicting system")
      }
      let size: Int
      let kind: String
      switch section {
      case 0: size = 80; kind = "DIF header and reserved bytes"
      case 1: size = 80; kind = "Subcode: raw sync IDs, position fragments, packs and reserved bytes"
      case 2: size = 80; kind = "VAUX: raw packs and reserved bytes"
      case 3: size = 8; kind = "Audio DIF ID and AAUX pack (audio samples remain in original DV)"
      case 4:
        size = 4; kind = "Video DIF ID and raw STA/QNO (compressed picture remains in original DV)"
        if frame[offset + 3] >> 4 != 0 { videoStatus += 1 }
      default: throw DVIngestError.invalidEvidence("unknown DIF section")
      }
      extents.append(Extent(sourceByteOffset: byteOffset + UInt64(offset),
        sequence: sequence, section: section, block: block, kind: kind,
        bytes: frame.subdata(in: offset..<(offset + size))))
      switch section {
      case 1:
        for slot in stride(from: 6, through: 46, by: 8) { counts[frame[offset + slot], default: 0] += 1 }
      case 2:
        for slot in stride(from: 3, through: 73, by: 5) { counts[frame[offset + slot], default: 0] += 1 }
      case 3: counts[frame[offset + 3], default: 0] += 1
      default: break
      }
    }
    return Self(schemaVersion: 1, frameOrdinal: ordinal, frameByteOffset: byteOffset,
      frameByteCount: frame.count,
      frameSHA256: SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined(),
      extents: extents, packs: counts.keys.sorted().map {
        PackSummary(typeHex: String(format: "0x%02X", $0), label: packLabel($0), observations: counts[$0]!)
      }, audioSampleRate: observed.audioSampleRate, nonzeroVideoStatusBlocks: videoStatus,
      positionInterpretation: "Raw subcode preserved; ATN/ETN not interpreted or qualified as seek/merge authority")
  }

  private static func packLabel(_ type: UInt8) -> String {
    DVPackCatalog.entry(type).name
  }
}
