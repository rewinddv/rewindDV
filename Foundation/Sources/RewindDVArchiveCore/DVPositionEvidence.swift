// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Recorded DV25 subcode observations, not a physical-position or seek oracle.
/// Behavioral reference: MediaInfoLib dd11d797, File_DvDif_Analysis.cpp:124-145.
/// SMPTE 314M table 7 calls these bits arbitrary: only IEC APT=0 is interpreted.
public struct DVPositionEvidence: Codable, Equatable, Sendable {
  public enum Classification: String, Codable, Sendable {
    case consistent, partial, conflicting, unavailable, unsupportedApplication
  }
  public struct Copy: Codable, Equatable, Sendable {
    public let sequence: UInt8
    public let block: UInt8
    public let firstSyncBlock: Int
    public let sourceByteOffsets: [UInt64]
    public let rawIDs: [[UInt8]]
    public let trackNumber: UInt32?
    public let blankFlag: Bool?
    public let issue: String?
  }
  public struct TimecodeCopy: Codable, Equatable, Sendable {
    public let sourceByteOffset: UInt64
    public let rawPack: [UInt8]
  }
  public let parser: String
  public let frameOrdinal: UInt64
  public let frameSHA256: String
  public let classification: Classification
  public let copies: [Copy]
  public let titleTimecodeCopies: [TimecodeCopy]
  public let normalizedFrameTrackCandidates: [UInt32]
  public let blankFlagValues: [Bool]
  public let expectedTracksPerFrame: UInt32
  public let etnStatus: String
  public let authority: String

  public static func inspect(_ inventory: DVMetadataInventory) -> Self {
    let tracks = UInt32(inventory.frameByteCount == 144_000 ? 12 : 10)
    let headers = inventory.extents.filter { $0.section == 0 }
    let applicationSupported = headers.count == Int(tracks)
      && headers.allSatisfy { $0.bytes.count == 80 && $0.bytes[4] & 7 == 0 }
    let validSequences = Set(headers.filter {
      $0.bytes.count == 80 && $0.bytes[7] & 0x80 == 0
    }.map(\.sequence))
    var copies: [Copy] = []
    var timecodes: [TimecodeCopy] = []
    for extent in inventory.extents where extent.section == 1 {
      guard extent.bytes.count == 80 else { continue }
      for slot in stride(from: 6, through: 46, by: 8) where extent.bytes[slot] == 0x13 {
        timecodes.append(.init(sourceByteOffset: extent.sourceByteOffset + UInt64(slot),
          rawPack: Array(extent.bytes[slot..<(slot + 5)])))
      }
      // DV25 single channel only. Retain other layouts, but do not decode them.
      let supported = applicationSupported && extent.bytes.count == 80
        && extent.bytes[1] & 0x0c == 0x04
      for group in 0..<2 {
        let slots = (0..<3).map { 3 + (group * 3 + $0) * 8 }
        let ids = slots.map { Array(extent.bytes[$0..<($0 + 3)]) }
        let offsets = slots.map { extent.sourceByteOffset + UInt64($0) }
        var issue: String?
        if !supported { issue = "unsupported_application_or_channel_layout" }
        else if !validSequences.contains(extent.sequence) { issue = "subcode_transmission_invalid" }
        else if ids.allSatisfy({ $0 == [0xff, 0xff, 0xff] }) { issue = "no_information" }
        else if ids.enumerated().contains(where: { index, id in
          id[2] != 0xff || Int(id[1] & 0x0f) != Int(extent.block) * 6 + group * 3 + index
            || ((id[0] & 0x80) != 0) != (Int(extent.sequence) < Int(tracks) / 2)
        }) { issue = "invalid_sync_identity" }
        let fragments = ids.map { UInt32($0[0] & 0x0f) * 16 + UInt32($0[1] >> 4) }
        let packed = fragments[0] | fragments[1] << 8 | fragments[2] << 16
        let track = packed >> 1
        if issue == nil && track == 0x7fffff { issue = "no_information" }
        copies.append(Copy(sequence: extent.sequence, block: extent.block,
          firstSyncBlock: Int(extent.block) * 6 + group * 3,
          sourceByteOffsets: offsets, rawIDs: ids,
          trackNumber: issue == nil ? track : nil,
          blankFlag: issue == nil ? packed & 1 != 0 : nil, issue: issue))
      }
    }
    // Normalize a *candidate* per frame; modulo arithmetic preserves possible wrap.
    // No vote, imputation, minimum selection, or erasure of conflicting copies.
    let candidates = Set(copies.compactMap { copy -> UInt32? in
      guard let n = copy.trackNumber else { return nil }
      return (n &+ 0x800000 &- UInt32(copy.sequence)) & 0x7fffff
    }).sorted()
    let flags = Set(copies.compactMap(\.blankFlag)).sorted { !$0 && $1 }
    let classification: Classification
    if !applicationSupported { classification = .unsupportedApplication }
    else if candidates.isEmpty { classification = .unavailable }
    else if candidates.count > 1 || flags.count > 1 { classification = .conflicting }
    else if copies.count != Int(tracks) * 4 || copies.contains(where: { $0.issue != nil }) { classification = .partial }
    else { classification = .consistent }
    return Self(parser: "rewinddv.recorded-dv25-atn.v1", frameOrdinal: inventory.frameOrdinal, frameSHA256: inventory.frameSHA256,
      classification: classification, copies: copies, titleTimecodeCopies: timecodes,
      normalizedFrameTrackCandidates: candidates, blankFlagValues: flags,
      expectedTracksPerFrame: tracks,
      etnStatus: "not_decoded; extended_track_number_is_not_an_alias_for_DV_ATN",
      authority: "recorded_metadata_only; not_physical_position_BOT_EOT_packet_loss_or_seek_merge_authority")
  }
}

/// Relates adjacent, fully consistent recorded observations within one file.
/// A reset/wrap candidate starts a new epoch rather than silently unwrapping.
public struct DVPositionContinuity: Sendable {
  public struct Observation: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let event: String
    public let previousFrameOrdinal: UInt64?
    public let deltaTracks: Int64?
  }
  private var previous: DVPositionEvidence?
  private var epoch: UInt64 = 0
  public init() {}

  public mutating func observe(_ value: DVPositionEvidence) -> Observation {
    let old = previous
    defer { previous = value.classification == .consistent ? value : nil }
    var event = "first_consistent_observation"
    var delta: Int64?
    if value.classification != .consistent {
      epoch += 1; event = "unusable_or_conflicting_position"
    } else if let old, let a = old.normalizedFrameTrackCandidates.first,
      let b = value.normalizedFrameTrackCandidates.first {
      delta = Int64(b) - Int64(a)
      if old.frameOrdinal == UInt64.max || value.frameOrdinal != old.frameOrdinal + 1
        || old.expectedTracksPerFrame != value.expectedTracksPerFrame {
        event = "frame_order_or_system_changed"; epoch += 1
      } else if b == a { event = "repeated_position"; epoch += 1 }
      else if b < a {
        event = (b &+ 0x800000 &- a) == value.expectedTracksPerFrame
          ? "possible_wrap_or_reset_not_resolved" : "reverse_or_reset_not_resolved"
        epoch += 1
      } else if b - a == value.expectedTracksPerFrame { event = "expected_forward_increment" }
      else { event = "position_jump_not_packet_loss_proof"; epoch += 1 }
    }
    return Observation(epoch: epoch, event: event,
      previousFrameOrdinal: old?.frameOrdinal, deltaTracks: delta)
  }
}
