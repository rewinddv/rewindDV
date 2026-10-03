// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Qualified formulas and project cautions, separate from raw observations.
/// Numeric rules are public facts; references retain their evidence class.
enum DVCorpusSemantics {
  typealias Field = DVPackSemanticReport.Field
  static let reference = "OPEN_SOURCE_CONSENSUS: JohnstonJ/video-tools b6a12951ef8be7e2d13f0387583ce081e9124a88, DV pack numeric rules; final IEC applicability remains unqualified"
  private static let camera2Reference = "MANUFACTURER_REFERENCE: Sony US5845044A (1998-12-01), col. 7, Fig. 8C; https://patents.google.com/patent/US5845044A/en; implementation cross-check: JohnstonJ/video-tools b6a12951, camera_consumer.py; not final IEC qualification"
  private static let gainReference = "MANUFACTURER_REFERENCE: Sony US5845044A, col. 6; implementation counterevidence: GStreamer gst-plugins-bad 0fdd4e25, gst/hdvparse/gsthdvparse.c, lines 227–232. HDV camera observation is not MiniDV qualification."
  private static let shutterReference = "MANUFACTURER_REFERENCE: Sony US5845044A, col. 9; implementation counterevidence: GStreamer gst-plugins-bad 0fdd4e25, gst/hdvparse/gsthdvparse.c, lines 294–305."

  private static func numeric(_ id: String, raw: UInt32) -> DVPackSemanticReport.NumericDescriptor? {
    typealias N = DVPackSemanticReport.NumericDescriptor
    switch id {
    case "SPD": return N(bitWidth: 7, unit: "multiple of normal playback speed", relation: raw == 1 ? "lessThan" : raw == 127 ? "unknown" : "exact", rule: "aaux.playback_speed: 0=0; 1<1/16; 2...15=1/(18-code); 16...126=2^((code>>4)-2)+(code&15)*2^((code>>4)-6)")
    case "IRIS": return N(bitWidth: 6, unit: "f-number", relation: raw == 61 ? "lessThan" : raw >= 62 ? "special" : "exact", rule: "camera.iris: code<61 => 2^(code/8); 61<1; 62=closed; 63=unknown")
    case "FOCUS": return N(bitWidth: 7, unit: "cm", relation: raw == 127 ? "unknown" : "exact", rule: "camera.focus: (code>>2)*10^(code&3)")
    case "VP_SPEED": return N(bitWidth: 5, unit: "lines/field", relation: raw == 30 ? "greaterThan" : raw == 31 ? "unknown" : "exact", rule: "camera.vertical_pan: 0...29=code; 30>29; 31=unknown")
    case "HP_SPEED": return N(bitWidth: 6, unit: "pixels/field", relation: raw == 62 ? "greaterThan" : raw == 63 ? "unknown" : "exact", rule: "camera.horizontal_pan: 0...61=2*code; 62>122; 63=unknown")
    case "FOCAL_LENGTH": return N(bitWidth: 8, unit: "mm (35-mm equivalent)", relation: raw == 255 ? "unknown" : "exact", rule: "camera.focal_length: (code>>1)*10^(code&1)")
    case "ZOOM_MAGNITUDE": return N(bitWidth: 7, unit: "magnification", relation: raw == 126 ? "atLeast" : raw == 127 ? "unknown" : raw & 15 > 9 ? "raw" : "exact", rule: "camera.zoom decimal candidate only: 126>=8; ordinary=(code>>4)+(code&15)/10; nondecimal codes withheld; conflicts with Sony 2+5-bit layout and 126>4")
    case "CONSUMER_SHUTTER": return N(bitWidth: 15, unit: "unknown", relation: "raw", rule: "camera.shutter: PC3 | ((PC4&127)<<8); not seconds")
    case "TDP": return N(bitWidth: 9, unit: "following TEXT packs (tape candidate)", relation: "raw", rule: "text.count: PC1 | ((PC2&1)<<8); MIC byte-count context not acquired")
    case "ATN_OR_LENGTH": return N(bitWidth: 23, unit: "context-dependent raw code", relation: "raw", rule: "(PC1>>1) | PC2<<7 | PC3<<15; 0x01 MIC definition: tracks normalized to 10 µm SP reference pitch; 0x0B tag is a separate namespace")
    case "YEAR7": return N(bitWidth: 7, unit: "unknown year origin", relation: "raw", rule: "programme.year: (PC3>>5)<<4 | PC4>>4")
    default: return nil
    }
  }

  static func enrich(_ existing: [Field], pack p: [UInt8], isPAL: Bool) -> [Field] {
    guard p.count == 5 else { return existing }
    var fields = existing
    func put<T: BinaryInteger>(_ id: String, _ name: String, _ raw: T, _ value: String,
      status: String = "interpreted", confidence: DVMetadataConfidence = .mostLikely,
      note: String = "Physical meaning supported by implementation research; applicable final IEC clause not independently qualified.",
      source: String = reference) {
      let f = Field(id: id, name: name, rawValue: raw, meaning: value, status: status,
        reference: source, confidence: confidence, qualifier: note, numeric: numeric(id, raw: UInt32(raw)))
      if let i = fields.firstIndex(where: { $0.id == id }) { fields[i] = f } else { fields.append(f) }
    }
    func unavailable<T: BinaryInteger>(_ id: String, _ name: String, _ raw: T) {
      put(id, name, raw, "No information", status: "unavailable", confidence: .implementationCorroborated)
    }
    func candidate<T: BinaryInteger>(_ id: String, _ name: String, _ raw: T, note: String) {
      put(id, name, raw, "Raw code \(raw)", status: "uninterpreted", confidence: .provisional, note: note)
    }
    switch p[0] {
    case 0x13:
      put("CF", "PC1 bit 7 — CF/BF variant", p[1] >> 7, "CF/BF meaning requires a qualified layout variant and companion context",
        status: "uninterpreted", confidence: .conflictingEvidence, note: "Interpretation depends on the IEC layout variant; no common CF/BF meaning is assigned.")
    case 0x51:
      let c = Int(p[3] & 127)
      let speed: String
      switch c {
      case 0: speed = "0×"
      case 1: speed = "Below 1/16× (range, not exact speed)"
      case 2...15: speed = "1/\(18-c)×"
      case 127: speed = "No information"
      default: speed = String(format: "%.6g×", pow(2, Double((c >> 4)-2)) + Double(c & 15) * pow(2, Double((c >> 4)-6)))
      }
      put("SPD", "Recorded playback-speed code", c, speed, status: c == 127 ? "unavailable" : "interpreted",
        note: "Nonlinear recorded-speed code. This is source metadata, not a measurement of current deck speed.")
      if let i = fields.firstIndex(where: { $0.id == "ICH" }) {
        let f = fields[i]
        fields[i] = Field(id: f.id, name: f.name, rawValue: f.rawValue, meaning: f.meaning,
          status: f.status, reference: f.reference, confidence: .provisional,
          qualifier: "The reference describes insert-channel semantics as MIC-only; this DV-stream observation does not establish MIC applicability.")
      }
    case 0x61:
      let c = p[2] & 7
      if c == 1 {
        // This enrichment is dispatched only for qualified consumer DV. Sony's
        // explicit VAUX table outweighs MediaInfo's conflicting generic mapping;
        // do not promote it to a professional-DV or normative IEC rule.
        let field = Field(id: "DISP", name: "Display/aspect code", rawValue: c,
          meaning: "4:3 — letterboxed", status: "interpreted",
          reference: "MANUFACTURER_REFERENCE: Sony EP0719057A2 (1996-06-26), Fig. 22B description, VAUX 0x61 PC2 DISP: 001 = 4:3 letter box; https://patents.google.com/patent/EP0719057A2/en",
          confidence: .independentlyCorroborated,
          qualifier: "Consumer DV only. Corroborated by DVswitch DV_format VAUX source control and FFmpeg libavformat/dv.c; MediaInfo maps code 1 differently. Applicable IEC table not independently verified. Full frame is 4:3; preserve recorded letterbox pixels and raw code. No crop or pixel-content inference.")
        if let i = fields.firstIndex(where: { $0.id == "DISP" }) { fields[i] = field }
        else { fields.append(field) }
      }
    case 0x52, 0x62:
      let zone = p[1] & 63, weekday = p[3] >> 5
      put("WEEKDAY", "Recorded weekday", weekday,
        weekday == 7 ? "No information" : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][Int(weekday)],
        status: weekday == 7 ? "unavailable" : "interpreted", note: "Sunday-based enumeration. No host-calendar comparison or century pivot.")
      if zone == 63 {
        unavailable("ZONE_CODE", "Time-zone code", zone)
        unavailable("DS", "Daylight-saving flag (raw)", p[1] >> 7)
        unavailable("TM", "Half-hour flag (raw)", (p[1] >> 6) & 1)
      } else {
        let number = Int(zone >> 4) * 10 + Int(zone & 15)
        let valid = zone & 15 < 10 && zone >> 4 < 10 && number <= 23
        put("ZONE_CODE", "Time-zone code", zone, valid ? "BCD code \(number); signed UTC offset not established" : "Invalid BCD zone code",
          status: valid ? "uninterpreted" : "invalid", confidence: .provisional)
        put("DS", "Recorded daylight-saving flag", p[1] >> 7, p[1] & 128 == 0 ? "DST indicated" : "Normal time indicated",
          note: "Raw recorded flag; no UTC conversion or host-zone application.")
        put("TM", "Recorded half-hour flag", (p[1] >> 6) & 1, p[1] & 64 == 0 ? "Add half-hour indicated" : "No added half-hour indicated",
          note: "Interpretation candidate only; no signed timezone is synthesized.")
      }
    case 0x70:
      let iris = p[1] & 63, focus = p[4] & 127, gain = p[2] & 15
      switch iris {
      case 63: unavailable("IRIS", "Iris", iris)
      case 62: put("IRIS", "Iris", iris, "Closed iris")
      case 61: put("IRIS", "Iris", iris, "Below F1.0")
      default: put("IRIS", "Iris", iris, String(format: "F%.3g", pow(2, Double(iris) / 8)))
      }
      if focus == 127 { unavailable("FOCUS", "Focus position", focus) }
      else { put("FOCUS", "Focus position", focus, String(format: "%.0f cm", Double(focus >> 2) * pow(10, Double(focus & 3)))) }
      if gain == 15 { unavailable("AGC", "Gain code", gain) }
      else if gain == 14 { put("AGC", "Gain code", gain, "Code 14: implementation/patent range disagreement", status: "uninterpreted", confidence: .conflictingEvidence) }
      else { put("AGC", "Gain code", gain, "Raw code \(gain); dB conversion not established", status: "uninterpreted", confidence: .implementationCorroborated,
        note: "Candidate formula: −3 + 3 × code dB. Historical GStreamer reports a camera disagreement and a different upper range. No universal conversion or known-camera calibration is established; original code retained.", source: gainReference) }
      for (id, name, code, range) in [
        ("AE_MODE", "Exposure mode", p[2] >> 4, UInt8(5)...14),
        ("WB_MODE", "White-balance mode", p[3] >> 5, UInt8(4)...6),
        ("WB_PRESET", "White-balance preset", p[3] & 31, UInt8(7)...30)
      ] where range.contains(code) {
        put(id, name, code, "Reserved code", status: "reserved", confidence: .implementationCorroborated)
      }
      if p[3] & 31 == 6 { put("WB_PRESET", "White-balance preset", 6, "Other", confidence: .implementationCorroborated) }
    case 0x71:
      let v = p[1] & 31, h = p[2] & 63, focal = p[3], z = p[4] & 127
      let panNote = "Consumer DV candidate supported by Sony's scan-relative description and implementation layout; final IEC clause not independently qualified. Not physical left/right/up/down, camera velocity, or current deck motion."
      put("VPD", "Vertical pan direction", (p[1] >> 5) & 1, p[1] & 32 == 0 ? "Along raster scanning" : "Against raster scanning",
        note: panNote, source: camera2Reference)
      if v == 31 { unavailable("VP_SPEED", "Vertical pan speed", v) }
      else { put("VP_SPEED", "Vertical pan speed", v, v == 30 ? "> 29 lines/field" : "\(v) lines/field",
        note: panNote, source: camera2Reference) }
      put("HPD", "Horizontal pan direction", (p[2] >> 6) & 1, p[2] & 64 == 0 ? "Along raster scanning" : "Against raster scanning",
        note: panNote, source: camera2Reference)
      if h == 63 { unavailable("HP_SPEED", "Horizontal pan speed", h) }
      else { put("HP_SPEED", "Horizontal pan speed", h, h == 62 ? "> 122 pixels/field" : "\(Int(h) * 2) pixels/field",
        note: panNote, source: camera2Reference) }
      put("IS", "Image stabilizer", p[2] >> 7, p[2] & 128 == 0 ? "Enabled (active-low)" : "Disabled (active-low)")
      if focal == 255 { unavailable("FOCAL_LENGTH", "35-mm-equivalent focal length", focal) }
      else { put("FOCAL_LENGTH", "35-mm-equivalent focal length", focal, String(format: "%.0f mm equivalent", Double(focal >> 1) * pow(10, Double(focal & 1))),
        note: "The scale is corroborated; Sony's later modified-DV/AVC patent explicitly calls the existing Consumer Camera 2 field 35 mm equivalent. That later context does not qualify every MiniDV camera. Not physical lens length or sensor-size evidence.",
        source: camera2Reference + "; MANUFACTURER_REFERENCE: Sony WO2012165218A1, description of Figs. 6–7; https://patents.google.com/patent/WO2012165218A1/en") }
      put("ZEN", "Electronic zoom", p[4] >> 7, p[4] & 128 == 0 ? "Enabled (active-low)" : "Disabled (active-low)")
      let zoomNote = "Decimal-layout candidate only (3 unit bits + 4 decimal bits; code 126 means ≥8× in JohnstonJ). Sony US5845044A col. 7 instead describes 2 integral + 5 fractional bits and code 126 >4×. Applicable final IEC layout unresolved; no preview zoom or source-byte change."
      if z == 127 { unavailable("ZOOM_MAGNITUDE", "Electronic zoom magnitude", z) }
      else if z == 126 { put("ZOOM_MAGNITUDE", "Electronic zoom magnitude", z, "≥ 8×", confidence: .conflictingEvidence, note: zoomNote, source: camera2Reference) }
      else if z & 15 > 9 { put("ZOOM_MAGNITUDE", "Electronic zoom magnitude", z, "Outside the decimal zoom model; legacy layout unresolved", status: "uninterpreted", confidence: .conflictingEvidence, note: zoomNote, source: camera2Reference) }
      else { put("ZOOM_MAGNITUDE", "Electronic zoom magnitude", z, String(format: "%.1f×", Double(z >> 4) + Double(z & 15) / 10), confidence: .conflictingEvidence, note: zoomNote, source: camera2Reference) }
    case 0x54, 0x64:
      fields = DVSupplementalPackSemantics.decode([0x14] + p.dropFirst(), isPAL: isPAL)
    case 0x7f:
      for byte in 1...2 {
        put("PRO_SHUTTER_\(byte)", "Professional shutter component \(byte) (raw)", p[byte],
          p[byte] == 255 ? "No information" : "Raw code \(p[byte]); professional applicability not established",
          status: p[byte] == 255 ? "unavailable" : "uninterpreted", confidence: .implementationCorroborated)
      }
      let c = UInt32(p[3]) | (UInt32(p[4] & 127) << 8)
      put("CONSUMER_SHUTTER", "Consumer shutter raw value", c,
        c == 32767 ? "No information" : c == 0 ? "Zero-code validity conflicts between implementation and patent" : "Raw value \(c); time conversion not established",
        status: c == 32767 ? "unavailable" : "uninterpreted", confidence: c == 0 ? .conflictingEvidence : .implementationCorroborated,
        note: "Candidate duration: raw CSS × horizontal scan period. Applicable SD timebase and camera behaviour remain unqualified. GStreamer's HDV reciprocal constant 34000 was observation-derived and must not be applied universally to MiniDV. Zero and absent codes are not converted.", source: shutterReference)
      put("SHUTTER_FIXED", "PC4 fixed high bit", p[4] >> 7, p[4] & 128 != 0 ? "Expected high bit present" : "Expected high bit missing; original bytes retained",
        status: p[4] & 128 != 0 ? "interpreted" : "invalid", confidence: .implementationCorroborated)
    case 0x08, 0x18:
      candidate("TDP", "Text count candidate", UInt32(p[1]) | (UInt32(p[2] & 1) << 8),
        note: "Patent candidate for this header only. Tape: following TEXT packs; MIC: following text bytes. MIC was not acquired. Character encoding is not assumed UTF-8.")
    case 0x01:
      put("ATN_OR_LENGTH", "Tape-length code (MIC definition)",
        UInt32(p[1] >> 1) | (UInt32(p[2]) << 7) | (UInt32(p[3]) << 15),
        "MIC length code: 23 bits; unit is track count at 10 µm SP pitch",
        status: "uninterpreted", confidence: .provisional,
        note: "Bit geometry and reference unit are primary-verified. MIC was not acquired; a DIF occurrence does not establish cassette capacity, remaining time, actual SP/LP mode or seek position.",
        source: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12 (public preview PDF p.14); MIC main area.")
    case 0x0b:
      candidate("ATN_OR_LENGTH", "Tag ATN raw candidate",
        UInt32(p[1] >> 1) | (UInt32(p[2]) << 7) | (UInt32(p[3]) << 15),
        note: "Patent layout candidate; not remaining time, seek authority or verified physical position.")
      if p[0] == 0x0b { put("BF", "Blank flag candidate", p[1] & 1, "Patent polarity conflict; raw flag retained", status: "uninterpreted", confidence: .conflictingEvidence) }
    case 0x53, 0x63:
      fields = fields.map { f in
        guard f.id == "REC_SECONDS" else { return f }
        return Field(id: f.id, name: f.name, rawValue: f.rawValue, meaning: f.meaning,
          status: f.status, reference: f.reference, confidence: f.confidence,
          qualifier: DVPackSemanticReport.recordingClockCaution, numeric: f.numeric)
      }
    case 0x42:
      candidate("YEAR7", "Compact programme year code", UInt32(p[3] >> 5) << 4 | UInt32(p[4] >> 4),
        note: "Patent compact binary layout; no BCD decoder, year origin or century inferred.")
    case 0x56, 0x66:
      for i in 1...4 { put("PC\(i)", "Transparent data PC\(i)", p[i], "Raw byte; selector/data widths unresolved",
        status: "uninterpreted", confidence: .conflictingEvidence,
        note: "Competing layouts: selector/data = 8/24 bits or 4/28 bits. Interpretation withheld; all four payload bytes remain available.") }
    default: break
    }
    return fields
  }
}

extension DVPackSemanticReport {
  public static let recordingClockCaution = "EMPIRICAL_EVIDENCE: Lacey and Koenig, AAFS 2007 C49, pp.183–184, reports uneven recording-clock ticks on a Samsung PAL camcorder. Recorded seconds need not align uniformly with frame count; clock irregularity alone does not prove dropped frames, edits or camera identity. No interpolation or universal jitter tolerance is inferred."
  /// Compact summaries reuse the same BCD/range/calendar checks as field rows.
  /// Callers must establish consumer format and section transmission validity.
  public static func recordedDate(from pack: [UInt8]) -> String? {
    guard pack.count == 5, [0x52,0x62].contains(pack[0]) else { return nil }
    let fields = DVSupplementalPackSemantics.decode(pack, isPAL: false)
    let ids = ["REC_YEAR", "REC_MONTH", "REC_DAY"]
    let values = ids.compactMap { id in fields.first { $0.id == id && $0.status == "interpreted" }?.meaning }
    guard values.count == 3 else { return nil }
    return "YY \(values[0])-\(values[1])-\(values[2]) (century unknown)"
  }
  public static func recordedTime(from pack: [UInt8]) -> String? {
    guard pack.count == 5, [0x53,0x63].contains(pack[0]) else { return nil }
    let fields = DVSupplementalPackSemantics.decode(pack, isPAL: false)
    let ids = ["REC_HOURS", "REC_MINUTES", "REC_SECONDS"]
    let values = ids.compactMap { id in fields.first { $0.id == id && $0.status == "interpreted" }?.meaning }
    return values.count == 3 ? values.joined(separator: ":") : nil
  }
  /// Only established display codes are usable by the lightweight preview.
  /// Consumer DISP=1 is a 4:3 letterboxed frame, not anamorphic 16:9.
  public static func displayWidescreen(code: UInt8, consumer: Bool) -> Bool? {
    switch code {
    case 0: false
    case 1 where consumer: false
    case 2: true
    case 4 where consumer: false
    default: nil
    }
  }
}
