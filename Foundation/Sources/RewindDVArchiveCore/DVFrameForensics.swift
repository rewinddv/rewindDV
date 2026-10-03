// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Offline observations from the original complete DV25 frame, never a decoded
/// replacement. A nonzero STA or an audio error sentinel is not packet-loss proof.
public struct DVFrameForensics: Sendable {
  public struct Summary: Codable, Equatable, Sendable {
    public let version: Int
    public let videoStatusBySequence: [Int]
    public let audioErrorsBySequence: [Int]
    public let audioSamplesExamined: Int
    public let audioCoverage: String
    public let invalidMetadataValues: Int
    public let conflictingMetadataValues: Int
  }
  public struct AudioError: Codable, Equatable, Sendable {
    public let sequence: Int
    public let block: Int
    public let channel: Int // zero based
    public let sample: Int // in this frame, zero based
    public let code: Int
    /// Two source bytes for a linear sample; noncontiguous bytes for 12-bit.
    public let byteOffsets: [UInt64]
    public let bitMasks: [UInt8]
  }
  public struct Block: Codable, Identifiable, Equatable, Sendable {
    public let id: Int // physical DIF ordinal within frame
    public let sequence: Int
    public let section: Int
    public let number: Int
    public let sourceByteOffset: UInt64
    public let videoSTA: UInt8?
    public let audioErrorCount: Int
    public var name: String { ["Header", "Subcode", "VAUX", "Audio", "Video"][section] }
  }
  public let summary: Summary
  public let blocks: [Block]
  public let audioErrors: [AudioError]
  /// Declared active samples, independently qualified for each source channel.
  /// Unassessed channels are absent, never represented by a zero count.
  public struct AudioChannel: Equatable, Sendable {
    public let channel: Int
    public let sampleRate: Int
    public let sampleCount: Int
    public let nonlinear: Bool
  }
  public let audioChannels: [AudioChannel]
  public let semantics: DVPackSemanticReport
  public let position: DVPositionEvidence
  public let videoLayout: DVVideoBlockGeometry.Layout?

  public func block(containingSourceByte offset: UInt64) -> Block? {
    blocks.first { offset >= $0.sourceByteOffset && offset - $0.sourceByteOffset < 80 }
  }
  public func block(atRasterX x: Int, y: Int) -> Block? {
    guard let videoLayout, x >= 0, x < 720, y >= 0, y < (videoLayout.isPAL ? 576 : 480) else { return nil }
    return blocks.first { item in
      guard item.section == 4,
        let r = DVVideoBlockGeometry.region(sequence: item.sequence, block: item.number, layout: videoLayout) else { return false }
      return (r.x..<(r.x + r.width)).contains(x) && (r.y..<(r.y + r.height)).contains(y)
    }
  }

  public static func inspect(frame: Data, ordinal: UInt64, offset: UInt64) throws -> Self {
    let inventory = try DVMetadataInventory.inspect(frame: frame, ordinal: ordinal, byteOffset: offset)
    return inspectValidated(frame: frame, inventory: inventory)
  }

  // The caller must have built inventory from these exact bytes. Not public API.
  static func inspectValidated(frame: Data, inventory: DVMetadataInventory) -> Self {
    let sequences = frame.count == 144_000 ? 12 : 10
    let half = sequences / 2
    let semantics = DVPackSemanticReport.inspect(inventory)
    var videoCounts = [Int](repeating: 0, count: sequences)
    var audioCounts = videoCounts
    var errors: [AudioError] = []
    var examined = 0
    var coveredHalves = 0
    var channels: [AudioChannel] = []
    // Reuse the native DV audio sample-placement contract, but do not decode,
    // silence, replace, or test unused capacity. Each half is assessed separately.
    // IEEE/IEC consumer DV only here: SMPTE meanings are not silently assumed.
    if semantics.format == "IEC 61834 consumer DV" {
      for part in 0..<2 {
        let extents = inventory.extents.filter { Int($0.sequence) / half == part }
        let validHeaders = extents.filter { $0.section == 0 }.allSatisfy {
          $0.bytes[5] & 0x80 == 0 // AP1/audio transmission flag
        } && extents.allSatisfy { $0.bytes[1] & 0x0c == 0x04 }
        let packs = extents.filter { $0.section == 3 && $0.bytes[3] == 0x50 }
        let configs = packs.map { e -> [Int] in
          let p = e.bytes
          return [Int((p[7] >> 3) & 7), Int(p[7] & 7), Int(p[4] & 63), Int(p[6] & 31), Int((p[6] >> 5) & 1), Int((p[5] >> 5) & 3)]
        }
        guard validHeaders, let config = configs.first,
          configs.allSatisfy({ $0 == config }), config[0] < 3, config[1] <= 1,
          config[3] == 0, config[4] == (sequences == 12 ? 1 : 0),
          config[5] == (config[1] == 1 ? 1 : 0),
          config[1] == 0 || config[0] == 2 else { continue }
        let nonlinear = config[1] == 1
        let minimum = (sequences == 12 ? [1896,1742,1264] : [1580,1452,1053])[config[0]]
        let samples = minimum + config[2]
        let capacity = half * 9 * (nonlinear ? 24 : 36)
        guard samples <= capacity else { continue }
        coveredHalves += 1
        for side in 0..<(nonlinear ? 2 : 1) {
          channels.append(AudioChannel(channel: nonlinear ? part * 2 + side : part,
            sampleRate: [48_000, 44_100, 32_000][config[0]], sampleCount: samples, nonlinear: nonlinear))
        }
        for extent in extents where extent.section == 3 {
          let seq = Int(extent.sequence), block = Int(extent.block)
          let start = Int(extent.sourceByteOffset - inventory.frameByteOffset) + 8
          let phase = ((seq % half) * 6 + (block / 3) * (half * 6 - 10)) % (half * 6)
          let base = phase + (block % 3) * half * 6
          for word in 0..<(nonlinear ? 24 : 36) {
            let sample = (base + word * sequences * 9) / 2
            guard sample < samples else { continue }
            for side in 0..<(nonlinear ? 2 : 1) {
              examined += 1
              let at = start + word * (nonlinear ? 3 : 2)
              let code = nonlinear
                ? Int(frame[at + side]) * 16 + Int(side == 0 ? frame[at + 2] >> 4 : frame[at + 2] & 15)
                : Int(frame[at]) * 256 + Int(frame[at + 1])
              guard code == (nonlinear ? 0x800 : 0x8000) else { continue }
              errors.append(AudioError(sequence: seq, block: block,
                channel: nonlinear ? part * 2 + side : part, sample: sample, code: code,
                byteOffsets: nonlinear
                  ? [inventory.frameByteOffset + UInt64(at + side), inventory.frameByteOffset + UInt64(at + 2)]
                  : [inventory.frameByteOffset + UInt64(at), inventory.frameByteOffset + UInt64(at + 1)],
                bitMasks: nonlinear ? [0xff, side == 0 ? 0xf0 : 0x0f] : [0xff, 0xff]))
              audioCounts[seq] += 1
            }
          }
        }
      }
    }
    let byBlock = Dictionary(grouping: errors, by: { $0.sequence * 9 + $0.block })
    let blocks = inventory.extents.enumerated().map { index, e -> Block in
      let sta = e.section == 4 ? e.bytes[3] >> 4 : nil
      if let sta, sta != 0 { videoCounts[Int(e.sequence)] += 1 }
      return Block(id: index, sequence: Int(e.sequence), section: Int(e.section), number: Int(e.block),
        sourceByteOffset: e.sourceByteOffset, videoSTA: sta,
        audioErrorCount: e.section == 3 ? byBlock[Int(e.sequence) * 9 + Int(e.block)]?.count ?? 0 : 0)
    }
    let sourcePacks: [[UInt8]] = inventory.extents.filter { $0.section == 2 }.flatMap { extent -> [[UInt8]] in
      stride(from: 3, through: 73, by: 5).filter { extent.bytes[$0] == 0x60 }.map {
        Array(extent.bytes[$0..<($0 + 5)])
      }
    }
    let iec = semantics.format == "IEC 61834 consumer DV"
    let smpte = semantics.format == "SMPTE ST 314M-2005 DV"
    let geometryQualified = (iec || smpte) && !sourcePacks.isEmpty
      && inventory.extents.allSatisfy { $0.bytes[1] & 0x0c == 0x04 }
      && inventory.extents.filter { $0.section == 0 }.allSatisfy { $0.bytes[6] & 0x80 == 0 }
      && sourcePacks.allSatisfy { $0[3] & 31 == 0 && Int(($0[3] >> 5) & 1) == (sequences == 12 ? 1 : 0) }
    return Self(summary: Summary(version: 1, videoStatusBySequence: videoCounts,
      audioErrorsBySequence: audioCounts, audioSamplesExamined: examined,
      audioCoverage: coveredHalves == 2 ? "Both IEC audio halves examined; active sample positions only"
        : "\(coveredHalves)/2 audio halves examined; absent, conflicting or unsupported layout remains unassessed",
      invalidMetadataValues: semantics.packs.filter { !$0.status.hasPrefix("Conflicting field values") && $0.fields.contains { $0.status == "invalid" } }.count,
      conflictingMetadataValues: semantics.packs.filter { $0.status.hasPrefix("Conflicting field values") }.count),
      blocks: blocks, audioErrors: errors, audioChannels: channels, semantics: semantics, position: DVPositionEvidence.inspect(inventory),
      videoLayout: geometryQualified ? (sequences == 10 ? .ntsc411 : (iec ? .pal420 : .pal411)) : nil)
  }

  /// Byte offsets are hexadecimal, absolute within the source file. Display-only.
  public static func hexDump(_ bytes: Data, sourceOffset: UInt64) -> String {
    stride(from: 0, to: bytes.count, by: 16).map { index in
      String(format: "%012llX", sourceOffset + UInt64(index)) + "  "
        + bytes[index..<min(index + 16, bytes.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
    }.joined(separator: "\n")
  }
}
