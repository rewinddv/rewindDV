// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

/// Camera recording modes, never inferred from the model of the playback deck.
/// Panasonic DVX100A/B manuals: NTSC 60i/30P/24P/24PA; PAL 50i/25P.
public enum DVFilmMode: String, Codable, CaseIterable, Sendable {
  case ntsc60i, ntsc30p, ntsc24p, ntsc24pa, pal50i, pal25p
  public var label: String {
    switch self {
    case .ntsc60i: "NTSC 60i · 59.94 fields/s"
    case .ntsc30p: "NTSC 30P · 29.97 progressive frames/s"
    case .ntsc24p: "NTSC 24P · 2:3 pulldown → 23.976p"
    case .ntsc24pa: "NTSC 24PA · 2:3:3:2 pulldown → 23.976p"
    case .pal50i: "PAL 50i · 50 fields/s"
    case .pal25p: "PAL 25P · 25 progressive frames/s"
    }
  }
  public var isPAL: Bool { self == .pal50i || self == .pal25p }
  public var isFilm: Bool { self == .ntsc24p || self == .ntsc24pa }
  public var isProgressive: Bool { self != .ntsc60i && self != .pal50i }
  public var sourceFrameTicks: Int64 { isPAL ? 4_800 : 4_004 }
  public var outputFrameTicks: Int64 { isFilm ? 5_005 : sourceFrameTicks }
  public static let timeScale: Int32 = 120_000
  public var sourceFrameBytes: Int { isPAL ? 144_000 : 120_000 }
}

public enum DVFilmDisplayAspect: String, Codable, CaseIterable, Sendable {
  case decoder, fullRaster4x3, fullRaster16x9
  public var label: String {
    switch self {
    case .decoder: "Preserve native decoder aspect"
    case .fullRaster4x3: "4:3 full raster (including recorded letterbox)"
    case .fullRaster16x9: "16:9 full raster (anamorphic squeeze)"
    }
  }
}

/// A versioned, exact frame/field map. Phase is an explicitly reviewed A-frame
/// origin, NOT timecode modulo 5. Scene breaks require a new plan.
public struct DVFilmPlan: Codable, Equatable, Sendable {
  public struct Picture: Codable, Equatable, Sendable {
    public let outputOrdinal: UInt64
    public let firstFieldSourceFrame: UInt64
    public let secondFieldSourceFrame: UInt64
    public let presentationTicks: Int64
    public let durationTicks: Int64
  }
  public let schemaVersion: Int
  public let mode: DVFilmMode
  public let firstSourceFrame: UInt64
  public let sourceFrameCount: UInt64
  public let outputFrameCount: UInt64
  public let sourceSHA256: String
  public let interpretation: String
  public let displayAspect: DVFilmDisplayAspect

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, mode, firstSourceFrame, sourceFrameCount, outputFrameCount, sourceSHA256, interpretation, displayAspect
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(mode: c.decode(DVFilmMode.self, forKey: .mode),
      firstSourceFrame: c.decode(UInt64.self, forKey: .firstSourceFrame),
      sourceFrameCount: c.decode(UInt64.self, forKey: .sourceFrameCount),
      sourceSHA256: c.decode(String.self, forKey: .sourceSHA256),
      displayAspect: c.decode(DVFilmDisplayAspect.self, forKey: .displayAspect))
    guard try c.decode(Int.self, forKey: .schemaVersion) == schemaVersion,
      try c.decode(UInt64.self, forKey: .outputFrameCount) == outputFrameCount,
      try c.decode(String.self, forKey: .interpretation) == interpretation else {
      throw DVIngestError.invalidEvidence("Unsupported or inconsistent cadence plan")
    }
  }

  public init(mode: DVFilmMode, firstSourceFrame: UInt64, sourceFrameCount: UInt64,
              sourceSHA256: String, displayAspect: DVFilmDisplayAspect = .decoder) throws {
    guard sourceFrameCount > 0,
      !mode.isFilm || sourceFrameCount % 5 == 0,
      firstSourceFrame <= UInt64.max - sourceFrameCount,
      firstSourceFrame + sourceFrameCount <= UInt64(Int64.max / mode.sourceFrameTicks),
      sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }) else {
      throw DVIngestError.invalidEvidence("Choose a valid range; 24P/24PA requires complete five-frame cycles beginning at a reviewed A frame.")
    }
    self.schemaVersion = 1; self.mode = mode; self.firstSourceFrame = firstSourceFrame
    self.displayAspect = displayAspect
    self.sourceFrameCount = sourceFrameCount
    self.outputFrameCount = mode.isFilm ? sourceFrameCount / 5 * 4 : sourceFrameCount
    self.sourceSHA256 = sourceSHA256.lowercased()
    self.interpretation = "Operator-selected recording mode and cycle origin; camera identity is not established by DV flags. Original DV remains authoritative."
  }

  public func picture(_ ordinal: UInt64) throws -> Picture {
    // Revalidate decoded plans too; synthesized Codable does not run init.
    let checked = try Self(mode: mode, firstSourceFrame: firstSourceFrame,
      sourceFrameCount: sourceFrameCount, sourceSHA256: sourceSHA256, displayAspect: displayAspect)
    guard schemaVersion == 1, checked.outputFrameCount == outputFrameCount,
      ordinal < outputFrameCount else { throw DVIngestError.invalidEvidence("Invalid cadence plan or picture ordinal") }
    let first: UInt64, second: UInt64
    if mode.isFilm {
      let cycle = firstSourceFrame + (ordinal / 4) * 5
      let phase = Int(ordinal % 4)
      // Panasonic manual progressive-mode diagrams (A,B,C,D source pictures):
      // 24P: AA BB BC CD DD; 24PA: AA BB BC CC DD.
      // Field order here is temporal, independent of pixel-buffer row parity.
      first = cycle + [0, 1, 3, 4][phase]
      second = cycle + (mode == .ntsc24p ? [0, 1, 2, 4] : [0, 1, 3, 4])[phase]
    } else { first = firstSourceFrame + ordinal; second = first }
    return Picture(outputOrdinal: ordinal, firstFieldSourceFrame: first,
      secondFieldSourceFrame: second, presentationTicks: Int64(ordinal) * mode.outputFrameTicks,
      durationTicks: mode.outputFrameTicks)
  }

  public var durationTicks: Int64 { Int64(outputFrameCount) * mode.outputFrameTicks }
}

public struct DVFilmFrameEvidence: Codable, Equatable, Sendable {
  public let ordinal: UInt64
  public let byteOffset: UInt64
  public let isPAL: Bool
  public let format: String
  public let videoControlHex: [String]
  public let videoControlOffsets: [UInt64]
  public let frameField: UInt8?
  public let fieldOrder: UInt8?
  public let frameChange: UInt8?
  public let interlace: UInt8?
  public let fieldTimeDifference: UInt8?
  public let recordingStart: UInt8?
  public let timecodeFrame: Int?
  public let timecodeDropFrame: Bool?
  /// Additive provenance for the existing continuity calculation. This profile
  /// is not the IEC no-BINARY companion interpretation of S1/S2.
  public var timecodeInterpretation: String? = nil
  public let audioRateHz: Int?
  public let audioQuantizationCode: UInt8?
  public let videoStatusBlocks: Int

  public static func inspect(_ inventory: DVMetadataInventory) -> Self {
    inspect(inventory, semanticReport: DVPackSemanticReport.inspect(inventory))
  }
  static func inspect(_ inventory: DVMetadataInventory, semanticReport report: DVPackSemanticReport) -> Self {
    let packs = report.packs.filter { $0.typeHex == "0x61" && $0.id.hasPrefix("vaux-frame:") }
    func field(_ id: String) -> UInt8? {
      let values = packs.flatMap(\.fields).filter { $0.id == id }
      guard !values.isEmpty, values.allSatisfy({ $0.status == "interpreted" }),
        Set(values.map(\.rawValue)).count == 1 else { return nil }
      return values.first.flatMap { UInt8(exactly: $0.rawValue) }
    }
    let pal = inventory.frameByteCount == 144_000
    // Timecode is continuity evidence only. Ignore color/BGF bits; require
    // all available title-timecode values to agree and valid subcode TF.
    let headers = inventory.extents.filter { $0.section == 0 }
    let validTC = !headers.isEmpty && headers.allSatisfy { $0.bytes.count > 7 && $0.bytes[7] & 0x80 == 0 }
    let tc = validTC ? report.packs.filter { $0.typeHex == "0x13" && $0.id.hasPrefix("subcode-frame:") }
      .compactMap { timecode($0.rawHex, pal: pal) } : []
    let uniqueTC = Set(tc.map { "\($0.0):\($0.1)" })
    let tcCount = report.packs.filter { $0.typeHex == "0x13" && $0.id.hasPrefix("subcode-frame:") }.count
    let acceptedTC = uniqueTC.count == 1 && tc.count == tcCount ? tc.first : nil
    let quantizations = report.packs.filter { $0.typeHex == "0x50" }.flatMap(\.fields).filter { $0.id == "QU" }
    let quantization = !quantizations.isEmpty && quantizations.allSatisfy { $0.status == "interpreted" }
      && Set(quantizations.map(\.rawValue)).count == 1 ? quantizations.first?.rawValue : nil
    return Self(ordinal: inventory.frameOrdinal, byteOffset: inventory.frameByteOffset,
      isPAL: pal, format: report.format, videoControlHex: packs.map(\.rawHex),
      videoControlOffsets: packs.flatMap(\.sourceByteOffsets), frameField: field("FF"),
      fieldOrder: field("FS"), frameChange: field("FC"), interlace: field("IL"),
      fieldTimeDifference: field("SF"), recordingStart: field("REC_S"),
      timecodeFrame: acceptedTC?.0, timecodeDropFrame: acceptedTC?.1,
      timecodeInterpretation: "INFERENCE: retained implementation uses a SMPTE-style title-timecode continuity profile, PC1 bit6=drop; companion association not established. Not primary IEC flag semantics.",
      audioRateHz: inventory.audioSampleRate.sampleRateHz,
      audioQuantizationCode: quantization.flatMap(UInt8.init(exactly:)),
      videoStatusBlocks: inventory.nonzeroVideoStatusBlocks)
  }

  private static func timecode(_ hex: String, pal: Bool) -> (Int, Bool)? {
    let p = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    guard p.count == 5 else { return nil }
    func bcd(_ byte: UInt8, mask: UInt8, limit: Int) -> Int? {
      let b = byte & mask, n = Int(b >> 4) * 10 + Int(b & 15)
      return b & 15 <= 9 && b >> 4 <= 9 && n < limit ? n : nil
    }
    guard let f = bcd(p[1], mask: 0x3f, limit: pal ? 25 : 30),
      let s = bcd(p[2], mask: 0x7f, limit: 60), let m = bcd(p[3], mask: 0x7f, limit: 60),
      let h = bcd(p[4], mask: 0x3f, limit: 24) else { return nil }
    let drop = p[1] & 0x40 != 0
    guard !(pal && drop), !(drop && m % 10 != 0 && s == 0 && f < 2) else { return nil }
    let nominal = ((h * 60 + m) * 60 + s) * (pal ? 25 : 30) + f
    return (nominal - (drop ? 2 * (h * 60 + m - (h * 60 + m) / 10) : 0), drop)
  }
}

/// Bounded look-back. Metadata patterns are suggestions, never authorization
/// to remove pictures: SF describes field timing, not a Panasonic model ID.
public struct DVFilmCadenceObserver: Sendable {
  public struct Observation: Codable, Equatable, Sendable {
    public let frame: DVFilmFrameEvidence
    public let boundaryReasons: [String]
    public let candidate: DVFilmMode?
    public let candidateAFrame: UInt64?
    public let evidence: String
  }
  private var previous: DVFilmFrameEvidence?
  private var window: [DVFilmFrameEvidence] = []
  public init() {}
  public mutating func observe(_ frame: DVFilmFrameEvidence) -> Observation {
    var boundaries: [String] = []
    if let p = previous {
      let nextOrdinal = p.ordinal.addingReportingOverflow(1)
      let nextOffset = p.byteOffset.addingReportingOverflow(p.isPAL ? 144_000 : 120_000)
      if nextOrdinal.overflow || nextOffset.overflow || frame.ordinal != nextOrdinal.partialValue || frame.byteOffset != nextOffset.partialValue {
        boundaries.append("Source frame/byte sequence changed")
      }
      if frame.isPAL != p.isPAL || frame.format != p.format { boundaries.append("Recorded system/application format changed") }
      if frame.audioRateHz != p.audioRateHz || frame.audioQuantizationCode != p.audioQuantizationCode {
        boundaries.append("Audio-rate or quantization evidence changed")
      }
      if frame.recordingStart == 0 && p.recordingStart != 0 { boundaries.append("Recording-start flag") }
      if let a = p.timecodeFrame, let b = frame.timecodeFrame {
        let day = p.isPAL ? 2_160_000 : (p.timecodeDropFrame == true ? 2_589_408 : 2_592_000)
        if a < 0 || a >= day || b < 0 || b >= day || frame.timecodeDropFrame != p.timecodeDropFrame || b != (a + 1) % day {
          boundaries.append("Timecode discontinuity or numbering-mode change")
        }
      } else if (p.timecodeFrame == nil) != (frame.timecodeFrame == nil) { boundaries.append("Timecode evidence became available/unavailable") }
    }
    if frame.frameField == nil || frame.fieldOrder == nil || frame.interlace == nil {
      boundaries.append("Missing, conflicting, invalid or unsupported video-control metadata")
    }
    if frame.videoStatusBlocks != 0 { boundaries.append("Source video status reports damage/concealment") }
    if !boundaries.isEmpty { window.removeAll(keepingCapacity: true) }
    previous = frame
    window.append(frame)
    if window.count > 15 { window.removeFirst() }
    var candidate: DVFilmMode?, origin: UInt64?
    if window.count == 15, window.allSatisfy({ $0.frameField == 1 && $0.fieldOrder == frame.fieldOrder && $0.interlace != nil && $0.videoStatusBlocks == 0 }) {
      if window.allSatisfy({ $0.interlace == 0 && ($0.fieldTimeDifference == nil || $0.fieldTimeDifference == 0) }) {
        candidate = frame.isPAL ? .pal25p : .ntsc30p
      } else if !frame.isPAL {
        // Verify three consecutive cycles and all five possible phases.
        for mode in [DVFilmMode.ntsc24p, .ntsc24pa] {
          let pattern: [UInt8] = mode == .ntsc24p ? [0, 0, 1, 1, 0] : [0, 0, 1, 0, 0]
          for phase in 0..<5 where window.enumerated().allSatisfy({ i, f in f.fieldTimeDifference == pattern[(i + phase) % 5] }) {
            candidate = mode
            origin = window[0].ordinal + UInt64((5 - phase) % 5)
          }
        }
      }
    }
    return Observation(frame: frame, boundaryReasons: boundaries, candidate: candidate,
      candidateAFrame: origin, evidence: candidate == nil
        ? "No qualified cadence suggestion. Stored DV timing remains authoritative."
        : "15-frame metadata pattern only; verify mode/phase against moving pictures. Camera identity and inverse-telecine correctness remain unverified.")
  }
}

public struct DVFilmScan: Codable, Sendable {
  public struct Segment: Codable, Identifiable, Sendable {
    public var id: UInt64 { firstFrame }
    public let firstFrame: UInt64
    public var endFrameExclusive: UInt64
    public let candidate: DVFilmMode?
    public let candidateAFrame: UInt64?
    public let reasons: [String]
  }
  public let schemaVersion: Int
  public let sourceSHA256: String
  public let sourceBytes: UInt64
  public let frameCount: UInt64
  public let systems: [String]
  public let segments: [Segment]
  public let segmentCount: UInt64
  public let segmentsTruncated: Bool
  public let sourceDamageFrames: UInt64
  public let unqualifiedMetadataFrames: UInt64
  public let cameraIdentity: String

  public static func scan(url: URL,
    onFrame: ((DVFilmCadenceObserver.Observation) throws -> Void)? = nil) throws -> Self {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let initial = try input.seekToEnd(); try input.seek(toOffset: 0)
    var hash = SHA256(), observer = DVFilmCadenceObserver()
    var ordinal: UInt64 = 0, offset: UInt64 = 0, damage: UInt64 = 0, unqualified: UInt64 = 0
    var segments: [Segment] = [], segmentCount: UInt64 = 0
    var lastCandidate: DVFilmMode?, lastPhase: UInt64?, systems = Set<String>()
    while offset < initial {
      try Task.checkCancellation()
      guard let header = try input.read(upToCount: 80), header.count == 80 else {
        throw DVIngestError.invalidEvidence("Incomplete DV header at \(offset)")
      }
      let size = header[3] & 0x80 == 0 ? 120_000 : 144_000
      guard let tail = try input.read(upToCount: size - 80), tail.count == size - 80 else {
        throw DVIngestError.invalidEvidence("Incomplete DV frame at \(offset)")
      }
      let frame = header + tail
      let inventory = try DVMetadataInventory.inspect(frame: frame, ordinal: ordinal, byteOffset: offset)
      let observation = observer.observe(DVFilmFrameEvidence.inspect(inventory))
      try onFrame?(observation)
      hash.update(data: frame)
      systems.insert(inventory.frameByteCount == 144_000 ? "625/50 PAL" : "525/60 NTSC")
      if inventory.nonzeroVideoStatusBlocks > 0 { damage += 1 }
      if observation.frame.interlace == nil { unqualified += 1 }
      let phase = observation.candidateAFrame.map { $0 % 5 }
      let newSegment = ordinal == 0 || observation.candidate != lastCandidate || phase != lastPhase || !observation.boundaryReasons.isEmpty
      if newSegment {
        segmentCount += 1
        if segments.count < 4096 {
          segments.append(Segment(firstFrame: ordinal, endFrameExclusive: ordinal + 1,
            candidate: observation.candidate, candidateAFrame: observation.candidateAFrame,
            reasons: observation.boundaryReasons))
        }
      } else if segmentCount <= 4096 { segments[segments.count - 1].endFrameExclusive = ordinal + 1 }
      lastCandidate = observation.candidate; lastPhase = phase
      ordinal += 1; offset += UInt64(size)
    }
    guard ordinal > 0, offset == initial, try input.seekToEnd() == initial else {
      throw DVIngestError.invalidEvidence("Empty or changing source file")
    }
    return Self(schemaVersion: 1, sourceSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      sourceBytes: offset, frameCount: ordinal, systems: systems.sorted(), segments: segments,
      segmentCount: segmentCount, segmentsTruncated: segmentCount > 4096,
      sourceDamageFrames: damage, unqualifiedMetadataFrames: unqualified,
      cameraIdentity: "Not inferred. DVX100A and DVX100B share these recording modes; playback-deck identity does not identify the recording camera.")
  }
}
