// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Physical source coordinates. A format epoch is independent of timecode,
/// recording markers, audio configuration, picture cuts and acquisition loss.
public struct DVRecordingEpoch: Codable, Equatable, Sendable {
  public let id: String
  public let firstFrame: UInt64
  public var endFrameExclusive: UInt64
  public let byteOffset: UInt64
  public var byteEndExclusive: UInt64
  public let startTick: UInt64
  public let system: DVBoundaryEvidence.VideoSystem
  public let frameByteCount: Int
  public let cadenceNumerator: UInt64
  public let cadenceDenominator: UInt64
  public let width: Int
  public let height: Int
  public let validation: String
  public let boundaryProvenance: String
  public var frameTicks: UInt64 { system == .pal625_50 ? 1200 : 1001 }

  init(first: UInt64, offset: UInt64, tick: UInt64, pal: Bool) {
    id = "dif-epoch-\(first)-\(offset)"
    firstFrame = first; endFrameExclusive = first
    byteOffset = offset; byteEndExclusive = offset; startTick = tick
    system = pal ? .pal625_50 : .ntsc525_60
    frameByteCount = pal ? 144_000 : 120_000
    cadenceNumerator = pal ? 25 : 30_000; cadenceDenominator = pal ? 1 : 1001
    width = 720; height = pal ? 576 : 480
    validation = "ordered_dif_structure_verified"
    boundaryProvenance = first == 0 ? "source_start" : "frame_header_system_transition_not_recording_start"
  }

  /// Full ordered DIF identity validation, shared with native playback. No
  /// inference about picture quality, recording mode or metadata completeness.
  public static func validateFrame(_ bytes: Data, offset: UInt64) throws {
    let valid = bytes.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
      guard p.count == 120_000 || p.count == 144_000,
        (p[3] & 0x80 != 0) == (p.count == 144_000) else { return false }
      for i in 0..<(p.count / 80) {
        let local = i % 150, sequence = i / 150, at = i * 80
        let section: Int, number: Int
        if local == 0 { section = 0; number = 0 }
        else if local < 3 { section = 1; number = local - 1 }
        else if local < 6 { section = 2; number = local - 3 }
        else if (local - 6) % 16 == 0 { section = 3; number = (local - 6) / 16 }
        else { section = 4; number = local - 7 - (local - 6) / 16 }
        guard Int(p[at] >> 5) == section, Int(p[at + 1] >> 4) == sequence,
          Int(p[at + 2]) == number,
          section != 0 || (p[at + 3] & 0x80 != 0) == (p.count == 144_000) else { return false }
      }
      return true
    }
    guard valid else {
      throw DVIngestError.invalidEvidence("Incomplete or unordered DV frame at byte \(offset). Original bytes are unchanged; no frame boundary was guessed.")
    }
  }
}

public struct DVUnknownSourceRegion: Codable, Equatable, Sendable {
  public let byteOffset: UInt64
  public let byteEndExclusive: UInt64
  public let reason: String
  public let frameCount: UInt64? // Unknown; never estimate from neighbouring geometry.
}

public struct DVSourceFrameIdentity: Codable, Equatable, Sendable {
  public let sourceID: String
  public let ordinal: UInt64
  public let byteOffset: UInt64
  public let byteCount: Int
  public let epochID: String
  public let system: DVBoundaryEvidence.VideoSystem
  public let startTick: UInt64
  public let durationTicks: UInt64
  public var seconds: Double { Double(startTick) / 30_000 }
}

extension DVReviewedRangeExporter.Snapshot {
  public var sourceID: String { "urn:sha256:\(sourceSHA256)" }
  /// Legacy schema 1 is an explicit verified-uniform contract. Projecting its
  /// coordinates does not reinterpret any recorded metadata or rewrite a report.
  public var recordingEpochs: [DVRecordingEpoch] {
    if let epochs { return epochs }
    guard schemaVersion == 1, let frameByteCount, [120_000, 144_000].contains(frameByteCount) else { return [] }
    var epoch = DVRecordingEpoch(first: 0, offset: 0, tick: 0, pal: frameByteCount == 144_000)
    epoch.endFrameExclusive = frameCount; epoch.byteEndExclusive = sourceByteCount
    return [epoch]
  }
  public var verifiedByteCount: UInt64 { recordingEpochs.last?.byteEndExclusive ?? 0 }
  public var isComplete: Bool { verifiedByteCount == sourceByteCount && (unknownRegions ?? []).isEmpty }

  public func validate() throws {
    guard [1, 2].contains(schemaVersion), sourceByteCount > 0, sourceByteCount <= UInt64(Int64.max),
      sourceSHA256.count == 64, sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw DVIngestError.invalidEvidence("unsupported or malformed source snapshot")
    }
    if schemaVersion == 1 {
      guard epochs == nil, unknownRegions == nil, frameCount > 0,
        let frameByteCount, [120_000, 144_000].contains(frameByteCount),
        videoSystem == (frameByteCount == 144_000 ? .pal625_50 : .ntsc525_60) else {
        throw DVIngestError.invalidEvidence("invalid legacy uniform source snapshot")
      }
    } else if epochs == nil || frameByteCount != nil || videoSystem != nil
      || (interpretationVersion ?? 0) <= 0 || (epochs?.count ?? 0) > 100_000 {
      throw DVIngestError.invalidEvidence("epoch source requires bounded explicit epochs and interpretation provenance, without global uniform fields")
    }
    var ordinal: UInt64 = 0, offset: UInt64 = 0, ticks: UInt64 = 0
    var previousSystem: DVBoundaryEvidence.VideoSystem?
    for epoch in recordingEpochs {
      let expected = DVRecordingEpoch(first: ordinal, offset: offset, tick: ticks, pal: epoch.system == .pal625_50)
      guard epoch.firstFrame == ordinal, epoch.endFrameExclusive > ordinal,
        epoch.endFrameExclusive <= frameCount, epoch.byteOffset == offset,
        epoch.id == expected.id, epoch.startTick == ticks,
        epoch.frameByteCount == expected.frameByteCount,
        epoch.cadenceNumerator == expected.cadenceNumerator, epoch.cadenceDenominator == expected.cadenceDenominator,
        epoch.width == expected.width, epoch.height == expected.height,
        epoch.validation == expected.validation, epoch.boundaryProvenance == expected.boundaryProvenance,
        previousSystem != epoch.system else { throw DVIngestError.invalidEvidence("invalid epoch identity, order, geometry or cadence") }
      let count = epoch.endFrameExclusive - ordinal
      offset = try Self.checkedAdd(offset, Self.checkedMultiply(count, UInt64(epoch.frameByteCount)))
      ticks = try Self.checkedAdd(ticks, Self.checkedMultiply(count, epoch.frameTicks))
      guard epoch.byteEndExclusive == offset, offset <= sourceByteCount else {
        throw DVIngestError.invalidEvidence("epoch byte extent does not match frame inventory")
      }
      ordinal = epoch.endFrameExclusive; previousSystem = epoch.system
    }
    guard ordinal == frameCount else { throw DVIngestError.invalidEvidence("epoch inventory does not cover declared frames") }
    // Stop at the first unprovable boundary. The remaining bytes are retained,
    // explicitly unindexed; no speculative resynchronization or ordinal claim.
    for region in unknownRegions ?? [] {
      guard region.byteOffset == offset, region.byteEndExclusive > offset,
        region.byteEndExclusive <= sourceByteCount, region.frameCount == nil,
        !region.reason.isEmpty else { throw DVIngestError.invalidEvidence("invalid unknown source interval") }
      offset = region.byteEndExclusive
    }
    guard offset == sourceByteCount else { throw DVIngestError.invalidEvidence("unaccounted source bytes") }
  }

  public func frame(_ ordinal: UInt64) throws -> DVSourceFrameIdentity {
    guard ordinal < frameCount else { throw DVIngestError.invalidEvidence("source frame ordinal is outside verified inventory") }
    let runs = recordingEpochs
    var low = 0, high = runs.count
    while low < high {
      let mid = low + (high - low) / 2
      if runs[mid].firstFrame <= ordinal { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { throw DVIngestError.invalidEvidence("source frame has no verified epoch") }
    let epoch = runs[low - 1]
    guard ordinal < epoch.endFrameExclusive, [120_000, 144_000].contains(epoch.frameByteCount) else {
      throw DVIngestError.invalidEvidence("source frame lies in an unknown interval")
    }
    let relative = ordinal - epoch.firstFrame
    return DVSourceFrameIdentity(sourceID: sourceID, ordinal: ordinal,
      byteOffset: try Self.checkedAdd(epoch.byteOffset, Self.checkedMultiply(relative, UInt64(epoch.frameByteCount))),
      byteCount: epoch.frameByteCount, epochID: epoch.id, system: epoch.system,
      startTick: try Self.checkedAdd(epoch.startTick, Self.checkedMultiply(relative, epoch.frameTicks)),
      durationTicks: epoch.frameTicks)
  }
  public func byteOffset(atBoundary ordinal: UInt64) throws -> UInt64 {
    if ordinal == frameCount { return verifiedByteCount }
    return try frame(ordinal).byteOffset
  }
  public func presentationTick(atBoundary ordinal: UInt64) throws -> UInt64 {
    if ordinal == frameCount {
      guard ordinal > 0 else { return 0 }
      let last = try frame(ordinal - 1)
      return try Self.checkedAdd(last.startTick, last.durationTicks)
    }
    return try frame(ordinal).startTick
  }
  static func checkedAdd(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (n, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw DVIngestError.invalidEvidence("source coordinate overflow") }; return n
  }
  static func checkedMultiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (n, overflow) = a.multipliedReportingOverflow(by: b)
    guard !overflow else { throw DVIngestError.invalidEvidence("source coordinate overflow") }; return n
  }
}
