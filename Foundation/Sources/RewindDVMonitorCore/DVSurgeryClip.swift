// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Offline DV25 editing coordinates. Suggestions are metadata observations,
/// never inferred camera takes. All public positions are original-file frames.
public struct DVSurgeryClip: Sendable {
  public struct Segment: Identifiable, Sendable {
    public var id: Int { first }
    public let first: Int
    public let end: Int
    public let format: String
    public let reason: String
    public let formatBoundary: Bool
  }
  public let timeline: DVPlaybackTimeline
  public let sha256: String
  public let segments: [Segment]

  public static func read(_ url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> Self {
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 1
    var hash = SHA256(), detector = SurgeryMetadataDetector()
    var starts: [(Int, String, String, Bool)] = []
    var previousFormat: String?
    let timeline = try DVPlaybackTimeline.read(url: url) { data, ordinal, offset in
      let metadata = try SurgeryMetadataDetector.observe(data)
      let changed = previousFormat != metadata.format
      let reasons = detector.consume(metadata, reset: changed)
      if ordinal == 0 || changed || !reasons.isEmpty {
        guard starts.count < 100_000 else { throw DVPlaybackTimeline.Failure(reason: "Too many segment boundaries to review safely.") }
        starts.append((ordinal, metadata.format, ordinal == 0 ? "Start of clip" : changed ? "Format change" : reasons.joined(separator: " · "), changed))
      }
      previousFormat = metadata.format
      hash.update(data: data)
      if ordinal % 128 == 0 { progress(Double(offset) / max(1, size)) }
    }
    progress(1)
    return Self(timeline: timeline, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      segments: starts.enumerated().map { i, item in
        Segment(first: item.0, end: i + 1 < starts.count ? starts[i + 1].0 : timeline.frameCount,
          format: item.1, reason: item.2, formatBoundary: item.3)
      })
  }

  public func seconds(_ boundary: Int) -> Double {
    boundary >= timeline.frameCount ? timeline.durationSeconds : timeline.frame(boundary).seconds
  }

  /// Nearest complete-frame boundary, ties towards the later boundary. The UI
  /// presents the snapped values. End is exclusive; no partial DIF blocks.
  public func boundary(at seconds: Double) -> Int {
    guard seconds.isFinite else { return 0 }
    if seconds >= timeline.durationSeconds { return timeline.frameCount }
    let frame = timeline.frame(at: max(0, seconds))
    let midpoint = frame.seconds + Double(frame.durationTicks) / 60_000
    return seconds + 0.000_000_01 >= midpoint ? frame.ordinal + 1 : frame.ordinal
  }

  public func ranges(first: Int, end: Int, splitScenes: Bool) throws -> [DVSurgeryByteExporter.Range] {
    guard first >= 0, first < end, end <= timeline.frameCount else {
      throw DVPlaybackTimeline.Failure(reason: "Choose an end time after the start time, within the clip.")
    }
    let cuts = [first] + segments.filter { $0.first > first && $0.first < end && (splitScenes || $0.formatBoundary) }.map(\.first) + [end]
    return zip(cuts, cuts.dropFirst()).map { a, b in
      let offset = timeline.frame(a).byteOffset
      let byteEnd = b == timeline.frameCount ? timeline.byteCount : timeline.frame(b).byteOffset
      return .init(firstFrame: a, endFrameExclusive: b, byteOffset: offset, byteCount: byteEnd - offset,
        startSeconds: seconds(a), endSeconds: seconds(b), format: segments.last { $0.first <= a }!.format)
    }
  }

  /// Selection order cannot reorder or duplicate source segments.
  public func selectedRanges(_ ids: Set<Int>) throws -> [DVSurgeryByteExporter.Range] {
    guard ids.isSubset(of: Set(segments.map(\.id))) else {
      throw DVPlaybackTimeline.Failure(reason: "Segment selection no longer belongs to this clip.")
    }
    return try segments.filter { ids.contains($0.id) }.flatMap {
      try ranges(first: $0.first, end: $0.end, splitScenes: false)
    }
  }

  public static func parseTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    var total = 0.0
    for (i, part) in parts.enumerated() {
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
        let value = Double(part), value.isFinite, value >= 0,
        (i == 0 || value < 60), (i == parts.count - 1 || value.rounded(.down) == value) else { return nil }
      total = total * 60 + value
    }
    return total.isFinite ? total : nil
  }
}

/// Field layout follows the original DV Cut parser and native pack inspector
/// (OPEN_SOURCE_CONSENSUS; github.com/rewinddv/dv-cut/blob/main/REFERENCES.md).
/// Invalid/conflicting repeats never win a vote; AAUX halves stay separate.
struct SurgeryMetadataDetector {
  struct Observation { let format: String; let fields: [String: Int] }
  var previous: Observation?
  var asserted = Set<String>()
  mutating func consume(_ current: Observation, reset: Bool) -> [String] {
    if reset { previous = nil; asserted.removeAll() }
    var reasons = Set<String>()
    for (key, value) in current.fields {
      if key.hasSuffix("/start") {
        if value == 0 { if !asserted.contains(key), previous != nil { reasons.insert("Recording start") }; asserted.insert(key) }
        else { asserted.remove(key) }
      }
      guard let old = previous?.fields[key] else { continue }
      if key.hasSuffix("/end"), old == 0, value == 1 { reasons.insert("Recording end") }
      if key.hasSuffix("/date"), old != value { reasons.insert("Recorded date changed") }
      if key.hasSuffix("/clock"), value != old, value != (old + 1) % 86400 { reasons.insert("Recorded clock jump") }
      if key.hasSuffix("/tc"), let day = current.fields["tcDay"],
        previous?.fields["tcDay"] != day || value != (old + 1) % day { reasons.insert("Timecode discontinuity") }
    }
    previous = current
    return reasons.sorted()
  }
  static func observe(_ data: Data) throws -> Observation {
    try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      let pal = p[3] & 128 != 0, apt = p[4] & 7, sequences = pal ? 12 : 10
      guard apt <= 1 else { throw DVPlaybackTimeline.Failure(reason: "Surgery currently supports DV25 files. This DV application profile is unsupported.") }
      var values: [String: Set<Int>] = [:], invalid = Set<String>()
      func field(_ key: String, _ value: Int?) {
        if let value { values[key, default: []].insert(value) } else { invalid.insert(key) }
      }
      func bcd(_ x: UInt8, _ max: Int, _ min: Int = 0) -> Int? {
        let n = Int(x >> 4) * 10 + Int(x & 15)
        return x & 15 < 10 && x >> 4 < 10 && n >= min && n <= max ? n : nil
      }
      for at in stride(from: 0, to: p.count, by: 80) {
        let section = p[at] >> 5, seq = Int(p[at + 1] >> 4), head = seq * 12000
        guard p[at + 1] & 12 == 4 else { throw DVPlaybackTimeline.Failure(reason: "Multichannel DVCPRO is not supported by Surgery yet.") }
        if section == 0 {
          guard (4...7).allSatisfy({ p[at + $0] & 7 == apt }) else { throw DVPlaybackTimeline.Failure(reason: "Conflicting DV application IDs; no boundary guessed.") }
        }
        guard section >= 1, section <= 3 else { continue }
        let scope = section == 1 ? "Subcode" : section == 2 ? "VAUX" : "AAUX\(seq < sequences / 2 ? 1 : 2)"
        let valid = p[head + (section == 1 ? 7 : section == 2 ? 6 : 5)] & 128 == 0
        let slots = section == 1 ? [6,14,22,30,38,46] : section == 2 ? Array(stride(from: 3, through: 73, by: 5)) : [3]
        for slot in slots {
          let i = at + slot, type = p[i], key = scope + "/\(type)"
          if section == 2 && type == 0x60 {
            guard p[i + 3] & 31 == 0, (p[i + 3] & 32 != 0) == pal else {
              throw DVPlaybackTimeline.Failure(reason: "Unsupported or conflicting video profile. Surgery currently requires DV25.")
            }
          }
          if section == 2 && type == 0x61 && apt == 0 {
            field(key + "/start", valid && p[i + 2] & 0x48 == 0x48 ? Int(p[i + 2] >> 7) : nil)
          }
          if section == 3 && type == 0x51 {
            let qualified = apt == 0 ? p[i + 4] & 128 != 0 : p[i + 1] & 60 == 60 && p[i + 2] & 15 == 15 && p[i + 4] == 255
            field(key + "/start", valid && qualified ? Int(p[i + 2] >> 7) : nil)
            field(key + "/end", valid && qualified ? Int((p[i + 2] >> 6) & 1) : nil)
          }
          guard apt == 0 else { continue }
          if type == 0x13 && section == 1 {
            let drop = !pal && p[i + 1] & 64 != 0
            let day = drop ? 2589408 : (pal ? 25 : 30) * 86400
            field("tcDay", valid ? day : nil)
            if valid, let f = bcd(p[i + 1] & 63, pal ? 24 : 29), let s = bcd(p[i + 2] & 127, 59),
              let m = bcd(p[i + 3] & 127, 59), let h = bcd(p[i + 4] & 63, 23), !(drop && m % 10 != 0 && s == 0 && f < 2) {
              let minutes = h * 60 + m
              field(key + "/tc", ((h * 3600 + m * 60 + s) * (pal ? 25 : 30) + f) - (drop ? 2 * (minutes - minutes / 10) : 0))
            } else { field(key + "/tc", nil) }
          }
          if ((section == 1 || section == 2) && type == 0x62) || (section == 3 && type == 0x52) {
            if valid, let y = bcd(p[i + 4], 99), let m = bcd(p[i + 3] & 31, 12, 1), let d = bcd(p[i + 2] & 63, 31, 1),
              d <= [31,y % 4 == 0 ? 29 : 28,31,30,31,30,31,31,30,31,30,31][m - 1] { field(key + "/date", y * 10000 + m * 100 + d) }
            else { field(key + "/date", nil) }
          }
          if ((section == 1 || section == 2) && type == 0x63) || (section == 3 && type == 0x53) {
            if valid, let h = bcd(p[i + 4] & 63, 23), let m = bcd(p[i + 3] & 127, 59), let s = bcd(p[i + 2] & 127, 59) { field(key + "/clock", h * 3600 + m * 60 + s) }
            else { field(key + "/clock", nil) }
          }
        }
      }
      let fields = values.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { !invalid.contains($0.key) }
      return Observation(format: (apt == 0 ? "DV / DVCAM" : "DVCPRO-compatible DV25") + (pal ? " · PAL" : " · NTSC"), fields: fields)
    }
  }
}
