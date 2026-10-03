// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Field layouts and selected mappings adapted from MediaInfoLib, Copyright
// (c) 2002-2025 MediaArea.net SARL. BSD-2-Clause notice: see
// Foundation/App/Resources/ThirdPartyNotices.txt. No library is linked.
import Foundation

/// Bounded, descriptive IEC consumer-DV metadata. Not transport, repair,
/// chronology, camera-identification or caption-rendering authority.
/// Application format, section, TF and repetition conflicts are gated by the
/// caller. Do not reuse these layouts for SMPTE merely because IDs match.
enum DVSupplementalPackSemantics {
  typealias Field = DVPackSemanticReport.Field
  static let reference = "MediaInfoLib 6ce87668473b0591c323a66842c937aa1cf76bdf, Source/MediaInfo/Multiple/File_DvDif.cpp (timecode, binary_group, recdate/rectime, closed_captions, consumer_camera_1/2) and File_DvDif_Analysis.cpp (subcode recording clock, caption parity); implementation corroboration, not full IEC standards qualification"

  static func decode(_ p: [UInt8], isPAL: Bool) -> [Field] {
    guard p.count == 5 else { return [] }
    let result: [Field]
    switch p[0] {
    case 0x13:
      // Only corroborated digits and CF/NTSC DF. Do not borrow the SMPTE
      // PC/BGF names for IEC: retain those physical bits without a meaning.
      result = [
        component("TC_HOURS", "Timecode hours", p[4] & 0x3f, mask: 0x3f, range: 0...23),
        component("TC_MINUTES", "Timecode minutes", p[3] & 0x7f, mask: 0x7f, range: 0...59),
        component("TC_SECONDS", "Timecode seconds", p[2] & 0x7f, mask: 0x7f, range: 0...59),
        component("TC_FRAMES", "Timecode frames", p[1] & 0x3f, mask: 0x3f, range: 0...(isPAL ? 24 : 29)),
        field("CF", "Color-frame synchronization", p[1] >> 7, p[1] & 0x80 == 0 ? "Unsynchronized mode" : "Synchronized mode"),
        isPAL ? raw("ARB", "Arbitrary bit", (p[1] >> 6) & 1)
          : field("DF", "Drop-frame flag", (p[1] >> 6) & 1, p[1] & 0x40 == 0 ? "Nondrop-frame timecode" : "Drop-frame timecode"),
        raw("PC2_BIT7", "Timecode PC2 bit 7", p[2] >> 7),
        raw("PC3_BIT7", "Timecode PC3 bit 7", p[3] >> 7),
        raw("PC4_BITS76", "Timecode PC4 bits 7–6", p[4] >> 6)]
    case 0x14:
      result = (0..<8).map { index in
        let nibble = (p[1 + index / 2] >> (index % 2 * 4)) & 0x0f
        return field("BG\(index + 1)", "User bits group \(index + 1)", nibble,
          String(format: "0x%X — raw user nibble; encoding unspecified", nibble))
      }
    case 0x52, 0x62: result = date(p)
    case 0x53, 0x63:
      result = [
        component("REC_HOURS", "Recorded hours", p[4] & 0x3f, mask: 0x3f, range: 0...23),
        component("REC_MINUTES", "Recorded minutes", p[3] & 0x7f, mask: 0x7f, range: 0...59),
        component("REC_SECONDS", "Recorded seconds", p[2] & 0x7f, mask: 0x7f, range: 0...59),
        component("REC_FRAMES", "Recorded frame component", p[1] & 0x3f, mask: 0x3f, range: 0...(isPAL ? 24 : 29))]
    case 0x65:
      result = (1...4).map { index in
        let byte = p[index]
        let id = "CC_F\((index + 1) / 2)_BYTE\((index - 1) % 2 + 1)"
        let name = "Caption field \((index + 1) / 2), byte \((index - 1) % 2 + 1)"
        if byte == 0xff { return field(id, name, byte, "All-one byte; no caption content established", status: "unavailable") }
        guard !isPAL else {
          return field(id, name, byte, "Raw payload retained; 625/50 caption interpretation is not qualified", status: "uninterpreted")
        }
        let odd = byte.nonzeroBitCount % 2 == 1
        return field(id, name, byte,
          String(format: "0x%02X — %@; not decoded caption text", byte, odd ? "odd parity valid" : "odd parity failed"),
          status: odd ? "interpreted" : "invalid")
      }
    case 0x70:
      result = [
        raw("IRIS", "Iris code", p[1] & 0x3f),
        choice("AE_MODE", "Exposure mode", p[2] >> 4,
          [0: "Full automatic", 1: "Gain priority", 2: "Shutter priority", 3: "Iris priority", 4: "Manual"], unavailable: 15),
        raw("AGC", "Automatic gain control code", p[2] & 0x0f),
        choice("WB_MODE", "White-balance mode", p[3] >> 5,
          [0: "Automatic", 1: "Hold", 2: "One push", 3: "Preset"], unavailable: 7),
        choice("WB_PRESET", "White-balance preset", p[3] & 0x1f,
          [0: "Candle", 1: "Incandescent lamp", 2: "Low-color-temperature fluorescent lamp", 3: "High-color-temperature fluorescent lamp", 4: "Sunlight", 5: "Cloudy weather"], unavailable: 31),
        field("FOCUS_MODE", "Focus mode", p[4] >> 7, p[4] & 0x80 == 0 ? "Automatic" : "Manual"),
        raw("FOCUS", "Focus position code", p[4] & 0x7f)]
    case 0x71:
      // Upstream supplies bit layout but not qualified units/polarity. Its
      // trace zoom formula repeats the units variable for the tenths digit;
      // retain both codes rather than importing that calculation.
      result = [raw("VPD", "Vertical pan direction code", (p[1] >> 5) & 1),
        raw("VP_SPEED", "Vertical pan speed code", p[1] & 0x1f),
        raw("IS", "Image stabilizer code", p[2] >> 7),
        raw("HPD", "Horizontal pan direction code", (p[2] >> 6) & 1),
        raw("HP_SPEED", "Horizontal pan speed code", p[2] & 0x3f),
        raw("FOCAL_LENGTH", "Focal length code", p[3]),
        raw("ZEN", "Electronic zoom enable code", p[4] >> 7),
        raw("ZOOM_UNITS", "Electronic zoom units code", (p[4] >> 4) & 7),
        raw("ZOOM_TENTHS", "Electronic zoom tenths code", p[4] & 0x0f)]
    default: return []
    }
    return result
  }

  private static func date(_ p: [UInt8]) -> [Field] {
    var day = component("REC_DAY", "Recorded day", p[2] & 0x3f, mask: 0x3f, range: 1...31)
    let month = component("REC_MONTH", "Recorded month", p[3] & 0x1f, mask: 0x1f, range: 1...12)
    let year = component("REC_YEAR", "Recorded year (two digits)", p[4], mask: 0xff, range: 0...99)
    if day.status == "interpreted", month.status == "interpreted" {
      let m = bcd(month.rawValue), d = bcd(day.rawValue)
      let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
      // A century is not encoded. Year 00 is not declared leap/non-leap.
      let impossibleLeap = m == 2 && d == 29 && year.status == "interpreted" && bcd(year.rawValue) % 4 != 0
      if d > days || impossibleLeap {
        day = field(day.id, day.name, day.rawValue, "Impossible calendar day for the recorded month/year", status: "invalid")
      }
    }
    return [year, month, day, p[1] == 0xff
      ? field("REC_TIMEZONE", "Recording time-zone code", p[1], "No information", status: "unavailable")
      : raw("REC_TIMEZONE", "Recording time-zone code", p[1])]
  }

  private static func bcd<T: BinaryInteger>(_ byte: T) -> Int { Int(byte >> 4) * 10 + Int(byte & 0x0f) }
  private static func component(_ id: String, _ name: String, _ byte: UInt8,
    mask: UInt8, range: ClosedRange<Int>) -> Field {
    if byte == mask { return field(id, name, byte, "No information", status: "unavailable") }
    guard byte & 0x0f <= 9, byte >> 4 <= 9, range.contains(bcd(byte)) else {
      return field(id, name, byte, "Invalid BCD or out-of-range value; original bits retained", status: "invalid")
    }
    return field(id, name, byte, String(format: "%02d", bcd(byte)))
  }
  private static func choice(_ id: String, _ name: String, _ byte: UInt8,
    _ values: [UInt8: String], unavailable: UInt8) -> Field {
    if byte == unavailable { return field(id, name, byte, "No information", status: "unavailable") }
    guard let meaning = values[byte] else { return raw(id, name, byte) }
    return field(id, name, byte, meaning)
  }
  private static func raw(_ id: String, _ name: String, _ byte: UInt8) -> Field {
    field(id, name, byte, "Raw numeric code retained; no incomplete mapping is guessed", status: "uninterpreted")
  }
  private static func field<T: BinaryInteger>(_ id: String, _ name: String, _ byte: T,
    _ meaning: String, status: String = "interpreted") -> Field {
    Field(id: id, name: name, rawValue: byte, meaning: meaning, status: status, reference: reference)
  }
}
