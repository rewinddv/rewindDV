// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Consumer enum vocabulary adapted from JohnstonJ/video-tools (MIT),
// b6a12951ef8be7e2d13f0387583ce081e9124a88, source_control.py,
// aaux_source_control.py and vaux_source_control.py.
// Copyright (c) 2024 James Johnston. See ThirdPartyNotices.txt for the MIT notice.
// Professional-DV mappings remain separate factual tables.
import Foundation

/// A source-bound, descriptive reading of metadata packs in one DV25 frame.
///
/// This report never establishes tape position, recording history, physical
/// transport state, content-deletion policy, or merge authority. Every decoded
/// value remains attached to the exact five source bytes and their offsets.
public struct DVPackSemanticReport: Codable, Equatable, Sendable {
  /// Machine-readable source width and conversion contract. Raw codes remain
  /// authoritative; formulas are qualified by the Field's evidence/status.
  public struct NumericDescriptor: Codable, Equatable, Sendable {
    public let bitWidth: Int
    public let unit: String
    public let relation: String
    public let rule: String
  }
  public struct Field: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let rawValue: UInt32
    public let meaning: String
    /// One of: interpreted, reserved, unavailable, uninterpreted, invalid, conflicting.
    public let status: String
    public let reference: String
    public let confidence: DVMetadataConfidence
    public let qualifier: String?
    public let numeric: NumericDescriptor?

    public init<T: BinaryInteger>(id: String, name: String, rawValue: T,
      meaning: String, status: String, reference: String,
      confidence: DVMetadataConfidence? = nil, qualifier: String? = nil, numeric: NumericDescriptor? = nil) {
      self.id = id; self.name = name; self.rawValue = UInt32(rawValue)
      self.meaning = meaning; self.status = status; self.reference = reference
      self.confidence = confidence ?? (status == "interpreted"
        ? (reference.hasPrefix("SMPTE ST 314M") ? .normativeConfirmed : .implementationCorroborated) : .unknown)
      self.qualifier = qualifier; self.numeric = numeric
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      name = try c.decode(String.self, forKey: .name)
      rawValue = try c.decode(UInt32.self, forKey: .rawValue)
      meaning = try c.decode(String.self, forKey: .meaning)
      status = try c.decode(String.self, forKey: .status)
      reference = try c.decode(String.self, forKey: .reference)
      // Historical v1 text remains intact; it is never silently upgraded.
      confidence = try c.decodeIfPresent(DVMetadataConfidence.self, forKey: .confidence) ?? .unknown
      qualifier = try c.decodeIfPresent(String.self, forKey: .qualifier)
      numeric = try c.decodeIfPresent(NumericDescriptor.self, forKey: .numeric)
    }

    private enum CodingKeys: String, CodingKey {
      case id, name, meaning, status, reference, confidence, qualifier, numeric
      case rawValue = "raw_value"
    }
  }

  public struct Pack: Codable, Equatable, Sendable {
    public let id: String
    public let typeHex: String
    public let name: String
    public let rawHex: String
    public var sourceByteOffsets: [UInt64]
    public var observationCount: Int { locations?.count ?? sourceByteOffsets.count }
    public let status: String
    public let fields: [Field]
    public var rawComponents: [Field]? = nil
    public var locations: [DVMetadataLocation]? = nil
    public var catalogEvidence: String? = nil

    private enum CodingKeys: String, CodingKey {
      case id, name, status, fields, rawComponents, locations, catalogEvidence
      case typeHex = "type_hex"
      case rawHex = "raw_hex"
      case sourceByteOffsets = "source_byte_offsets"
    }
  }

  public let schemaVersion: Int
  public let frameOrdinal: UInt64
  public let frameByteOffset: UInt64?
  public let frameSHA256: String
  public let format: String
  public let formatEvidence: String
  public let packs: [Pack]
  /// Descriptive pack coverage only; absence is not evidence of tape loss.
  public let missingPrincipalPacks: [String]
  public var structuralMetadata: [DVStructuralMetadata]? = nil
  public var absoluteOffsetsKnown: Bool? = nil

  private enum CodingKeys: String, CodingKey {
    case packs, format, structuralMetadata, absoluteOffsetsKnown
    case schemaVersion = "schema_version"
    case frameOrdinal = "frame_ordinal"
    case frameByteOffset = "frame_byte_offset"
    case frameSHA256 = "frame_sha256"
    case formatEvidence = "format_evidence"
    case missingPrincipalPacks = "missing_principal_packs"
  }

  public static func inspect(_ inventory: DVMetadataInventory, absoluteOffsetsKnown: Bool = true) -> Self {
    let assessment = assessHeaders(inventory)
    let observations = collectPacks(inventory, headers: assessment.headers)
    let isPAL = inventory.frameByteCount == 144_000
    var decoded = observations.map { decode($0, format: assessment.format, isPAL: isPAL) }
    decoded = flagConflicts(decoded)
    var report = Self(
      schemaVersion: 2,
      frameOrdinal: inventory.frameOrdinal,
      frameByteOffset: absoluteOffsetsKnown ? inventory.frameByteOffset : nil,
      frameSHA256: inventory.frameSHA256,
      format: assessment.format.label,
      formatEvidence: assessment.evidence,
      packs: decoded,
      missingPrincipalPacks: missingPrincipalPacks(observations))
    report.absoluteOffsetsKnown = absoluteOffsetsKnown
    report.structuralMetadata = DVStructuralMetadata.inspect(inventory, absoluteOffsetsKnown: absoluteOffsetsKnown, consumerQualified: assessment.format == .iec61834)
    report = report.attachingLocations(inventory, absoluteOffsetsKnown: absoluteOffsetsKnown)
    return report
  }
}

private extension DVPackSemanticReport {
  enum FormatIdentity {
    case iec61834, smpte314M, unknown

    var label: String {
      switch self {
      case .iec61834: "IEC 61834 consumer DV"
      case .smpte314M: "SMPTE ST 314M-2005 DV"
      case .unknown: "Unknown or mixed DV application format"
      }
    }
  }

  enum Transmission: String {
    case valid, invalid, unavailable
  }

  struct HeaderAssessment {
    let format: FormatIdentity
    let evidence: String
    let headers: [UInt8: [UInt8]]
  }

  struct Observation {
    let context: String
    let contextName: String
    let type: UInt8
    let raw: [UInt8]
    let offsets: [UInt64]
    let transmission: Transmission
  }

  static let iecAS = "IEC 61834 AAUX source pack; Video Demystified (2007), ch. 11, Table 11.1"
  static let iecASC = "IEC 61834 AAUX source-control pack; Video Demystified (2007), ch. 11, Table 11.2"
  static let iecVS = "IEC 61834 VAUX source pack; Video Demystified (2007), ch. 11, Table 11.4"
  static let iecVSC = "IEC 61834 VAUX source-control pack; Video Demystified (2007), ch. 11, Table 11.5"
  static let smpteAS = "SMPTE ST 314M-2005, Table 16"
  static let smpteASC = "SMPTE ST 314M-2005, Table 17"
  static let smpteVS = "SMPTE ST 314M-2005, Table 13"
  static let smpteVSC = "SMPTE ST 314M-2005, Table 14"
  static let smpteTC = "SMPTE ST 314M-2005, Table 10"

  static func assessHeaders(_ inventory: DVMetadataInventory) -> HeaderAssessment {
    guard inventory.extents.count <= 1_800,
      inventory.frameByteCount == 120_000 || inventory.frameByteCount == 144_000
    else {
      return HeaderAssessment(format: .unknown,
        evidence: "Inventory bounds or DV25 frame size are invalid; no format interpretation was attempted.",
        headers: [:])
    }
    let expected = inventory.frameByteCount == 144_000 ? 12 : 10
    var headers: [UInt8: [UInt8]] = [:]
    var malformed = 0
    for extent in inventory.extents where extent.section == 0 {
      let bytes = [UInt8](extent.bytes)
      guard bytes.count == 80, extent.block == 0, bytes[0] >> 5 == 0,
        bytes[1] >> 4 == extent.sequence, bytes[2] == 0,
        Int(extent.sequence) < expected,
        (bytes[3] & 0x80 != 0) == (inventory.frameByteCount == 144_000),
        extentRangeIsValid(extent, inventory: inventory, requiredCount: 80),
        headers[extent.sequence] == nil
      else { malformed += 1; continue }
      headers[extent.sequence] = bytes
    }
    guard malformed == 0, headers.count == expected,
      (0..<expected).allSatisfy({ headers[UInt8($0)] != nil })
    else {
      return HeaderAssessment(format: .unknown,
        evidence: "The complete set of one valid DIF header per sequence was not present; application identity is unavailable.",
        headers: headers)
    }
    let tuples = headers.keys.sorted().map { sequence in
      (4...7).map { headers[sequence]![$0] & 0x07 }
    }
    if tuples.allSatisfy({ $0 == [0, 0, 0, 0] }) {
      return HeaderAssessment(format: .iec61834,
        evidence: "Every valid DIF header reports APT/AP1/AP2/AP3 [0000], identifying IEC 61834 syntax.",
        headers: headers)
    }
    if tuples.allSatisfy({ $0 == [1, 1, 1, 1] }) {
      return HeaderAssessment(format: .smpte314M,
        evidence: "Every valid DIF header reports APT/AP1/AP2/AP3 [1111], identifying SMPTE ST 314M syntax; SMPTE 370M is not inferred.",
        headers: headers)
    }
    return HeaderAssessment(format: .unknown,
      evidence: "APT/AP1/AP2/AP3 values are unsupported or conflict across valid DIF headers; no format was guessed.",
      headers: headers)
  }

  static func collectPacks(
    _ inventory: DVMetadataInventory,
    headers: [UInt8: [UInt8]]
  ) -> [Observation] {
    guard inventory.extents.count <= 1_800,
      inventory.frameByteCount == 120_000 || inventory.frameByteCount == 144_000
    else { return [] }
    let half = UInt8(inventory.frameByteCount == 144_000 ? 6 : 5)
    struct Key: Hashable {
      let context: String
      let contextName: String
      let type: UInt8
      let raw: [UInt8]
      let transmission: Transmission
    }
    var grouped: [Key: [UInt64]] = [:]
    var seenExtents = Set<String>()
    for extent in inventory.extents where extent.section == 1 || extent.section == 2 || extent.section == 3 {
      let bytes = [UInt8](extent.bytes)
      let required = extent.section == 3 ? 8 : 80
      let extentKey = "\(extent.sourceByteOffset):\(extent.section):\(extent.sequence):\(extent.block)"
      guard bytes.count == required,
        bytes.count >= 3, bytes[0] >> 5 == extent.section,
        bytes[1] >> 4 == extent.sequence, bytes[2] == extent.block,
        extentRangeIsValid(extent, inventory: inventory, requiredCount: required),
        seenExtents.insert(extentKey).inserted
      else { continue }
      let slots: [Int]
      let context: String
      let contextName: String
      let tfByte: Int
      if extent.section == 1 {
        context = "subcode-frame"
        contextName = "Subcode frame scope"
        tfByte = 7
        slots = Array(stride(from: 6, through: 46, by: 8))
      } else if extent.section == 2 {
        context = "vaux-frame"
        contextName = "VAUX frame scope"
        tfByte = 6
        slots = Array(stride(from: 3, through: 73, by: 5))
      } else if extent.sequence < half {
        context = "aaux-sequence-half-1"
        contextName = "AAUX sequence half 1 (audio-block/channel context)"
        tfByte = 5
        slots = [3]
      } else {
        context = "aaux-sequence-half-2"
        contextName = "AAUX sequence half 2 (audio-block/channel context)"
        tfByte = 5
        slots = [3]
      }
      let transmission: Transmission
      if let header = headers[extent.sequence], header.count > tfByte {
        transmission = header[tfByte] & 0x80 == 0 ? .valid : .invalid
      } else {
        transmission = .unavailable
      }
      for slot in slots where slot <= bytes.count - 5 {
        guard let offset = adding(extent.sourceByteOffset, UInt64(slot)),
          offsetRangeIsValid(offset, count: 5, inventory: inventory)
        else { continue }
        let raw = Array(bytes[slot..<(slot + 5)])
        let key = Key(context: context, contextName: contextName,
          type: raw[0], raw: raw, transmission: transmission)
        grouped[key, default: []].append(offset)
      }
    }
    return grouped.map { key, offsets in
      Observation(context: key.context, contextName: key.contextName,
        type: key.type, raw: key.raw, offsets: offsets.sorted(),
        transmission: key.transmission)
    }.sorted {
      if $0.context != $1.context { return $0.context < $1.context }
      if $0.type != $1.type { return $0.type < $1.type }
      if $0.raw != $1.raw { return $0.raw.lexicographicallyPrecedes($1.raw) }
      return $0.transmission.rawValue < $1.transmission.rawValue
    }
  }

  static func decode(_ observation: Observation, format: FormatIdentity, isPAL: Bool) -> Pack {
    let rawHex = observation.raw.map { String(format: "%02X", $0) }.joined(separator: " ")
    let typeHex = String(format: "0x%02X", observation.type)
    let id = "\(observation.context):\(typeHex):\(rawHex.replacingOccurrences(of: " ", with: "").lowercased()):\(observation.transmission.rawValue)"
    let baseName = packName(observation.type)
    if observation.type == 0xff {
      guard format == .smpte314M else {
        return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
          rawHex: rawHex, sourceByteOffsets: observation.offsets,
          status: observation.raw.allSatisfy { $0 == 0xff }
            ? (format == .iec61834 && observation.transmission == .valid
              ? "No-information candidate; all five bytes FF. Base No Info / amendment OPTION discrepancy retained."
              : "No-information bytes retained; surrounding format/transmission is not qualified.")
            : "0xFF header with non-FF payload — damaged/ambiguous observation; all five original bytes retained.",
          fields: [])
      }
      let sentinelConforms = observation.raw.count == 5 && observation.raw.allSatisfy { $0 == 0xff }
      let status: String
      if !sentinelConforms {
        status = "Invalid no-information pack: SMPTE ST 314M-2005 Table 8 requires all five bytes to be 0xFF; original bytes retained."
      } else if observation.transmission == .invalid {
        status = "No-information sentinel bytes conform, but the matching DIF header marks this section invalid (TF=1)."
      } else if observation.transmission == .unavailable {
        status = "No-information sentinel bytes conform, but matching DIF-header transmission validity is unavailable."
      } else {
        status = "Valid no-information sentinel; all five bytes are 0xFF. This is structural padding, not recorded metadata."
      }
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets, status: status, fields: [])
    }
    if observation.type == 0x13 && observation.context != "subcode-frame" {
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets,
        status: "Title-timecode pack retained without field interpretation outside subcode frame scope.",
        fields: [])
    }
    let typeIsInExpectedSection = DVPackCatalog.permitsSDObservation(observation.type, context: observation.context)
    guard typeIsInExpectedSection else {
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets,
        status: "Unknown or out-of-scope pack retained without interpretation (\(observation.contextName)).",
        fields: [])
    }
    guard format != .unknown else {
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets,
        status: "Format identity is unsupported or conflicting; raw pack retained without field interpretation.",
        fields: [])
    }
    var fields = decodeFields(observation.raw, format: format, isPAL: isPAL)
    if format == .iec61834 {
      fields = DVCorpusSemantics.enrich(fields, pack: observation.raw, isPAL: isPAL)
    }
    guard !fields.isEmpty else {
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets,
        status: "Pack layout is not qualified for this application format; raw bytes retained without interpretation.", fields: [])
    }
    if observation.transmission != .valid {
      let state = observation.transmission == .invalid
        ? "The matching DIF header marks this section invalid (TF=1)."
        : "The matching DIF header is unavailable."
      fields = fields.map { field in
        Field(id: field.id, name: field.name, rawValue: field.rawValue,
          meaning: "\(state) Raw field bits retained without interpretation.",
          status: observation.transmission == .invalid ? "invalid" : "unavailable",
          reference: field.reference, confidence: field.confidence, qualifier: state, numeric: field.numeric)
      }
      return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
        rawHex: rawHex, sourceByteOffsets: observation.offsets, status: state, fields: fields)
    }
    let fixedMismatch = fixedLayoutMismatch(observation.raw, format: format)
    return Pack(id: id, typeHex: typeHex, name: "\(baseName) — \(observation.contextName)",
      rawHex: rawHex, sourceByteOffsets: observation.offsets,
      status: fixedMismatch
        ? "Fields interpreted independently; fixed/reserved layout bits differ from the cited table defaults."
        : fields.allSatisfy({ $0.status == "uninterpreted" })
          ? "Field layout identified; numeric codes retained without semantic interpretation."
          : "Fields assessed independently within \(observation.contextName); descriptive evidence only.",
      fields: fields)
  }

  static func flagConflicts(_ packs: [Pack]) -> [Pack] {
    func scope(_ id: String) -> String { id.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":") }
    var values: [String: [String: Set<UInt32>]] = [:]
    for pack in packs {
      for field in pack.fields where field.status == "interpreted" {
        values[scope(pack.id), default: [:]][field.id, default: []].insert(field.rawValue)
      }
    }
    return packs.map { pack in
      let conflicts = Set(values[scope(pack.id), default: [:]].compactMap { $0.value.count > 1 ? $0.key : nil })
      guard !conflicts.isEmpty else { return pack }
      var changed = false
      let fields = pack.fields.map { field -> Field in
        guard conflicts.contains(field.id), field.status == "interpreted" else { return field }
        changed = true
        return Field(id: field.id, name: field.name, rawValue: field.rawValue,
          meaning: "Conflicting recognized values occur in the same context; this raw observation is not selected as authority. \(field.meaning)",
          status: "conflicting", reference: field.reference, confidence: field.confidence, qualifier: field.qualifier, numeric: field.numeric)
      }
      guard changed else { return pack }
      return Pack(id: pack.id, typeHex: pack.typeHex, name: pack.name,
        rawHex: pack.rawHex, sourceByteOffsets: pack.sourceByteOffsets,
        status: "Conflicting field values in the same scope (\(conflicts.sorted().joined(separator: ", "))); no majority or selection applied.",
        fields: fields)
    }
  }

  static func decodeFields(_ p: [UInt8], format: FormatIdentity, isPAL: Bool) -> [Field] {
    guard p.count == 5 else { return [] }
    switch (format, p[0]) {
    case (.smpte314M, 0x13): return smpte13(p, isPAL: isPAL)
    case (.iec61834, 0x50): return iec50(p)
    case (.iec61834, 0x51): return iec51(p)
    case (.iec61834, 0x60): return iec60(p)
    case (.iec61834, 0x61): return iec61(p)
    case (.iec61834, 0x13), (.iec61834, 0x14), (.iec61834, 0x52), (.iec61834, 0x53),
         (.iec61834, 0x62), (.iec61834, 0x63), (.iec61834, 0x65),
         (.iec61834, 0x70), (.iec61834, 0x71):
      return DVSupplementalPackSemantics.decode(p, isPAL: isPAL)
    case (.smpte314M, 0x50): return smpte50(p)
    case (.smpte314M, 0x51): return smpte51(p)
    case (.smpte314M, 0x60): return smpte60(p)
    case (.smpte314M, 0x61): return smpte61(p)
    default: return []
    }
  }

  /// Table 10 defines different flag placement for 525/60 and 625/50. The
  /// component digits and explicitly defined CF/DF/PC meanings are decoded;
  /// binary-group/arbitrary bits remain raw until their referenced standards
  /// are available. No timecode is extrapolated or normalized.
  static func smpte13(_ p: [UInt8], isPAL: Bool) -> [Field] {
    var result = [
      bcdField("TC_HOURS", "Timecode hours", p[4] & 0x3f, upperBound: 24, smpteTC),
      bcdField("TC_MINUTES", "Timecode minutes", p[3] & 0x7f, upperBound: 60, smpteTC),
      bcdField("TC_SECONDS", "Timecode seconds", p[2] & 0x7f, upperBound: 60, smpteTC),
      bcdField("TC_FRAMES", "Timecode frames", p[1] & 0x3f,
        upperBound: isPAL ? 25 : 30, smpteTC),
      booleanFlag("CF", "Color-frame synchronization", p[1] >> 7,
        zero: "Color-frame synchronization: off", one: "Color-frame synchronization: on", smpteTC),
    ]
    if isPAL {
      result.append(raw("ARB", "Arbitrary bit", (p[1] >> 6) & 1, smpteTC))
      result.append(raw("BGF0", "Binary-group flag 0", p[2] >> 7, smpteTC))
      result.append(raw("BGF2", "Binary-group flag 2", p[3] >> 7, smpteTC))
      result.append(booleanFlag("PC", "Biphase-mark polarity correction", p[4] >> 7,
        zero: "Even", one: "Odd", smpteTC))
    } else {
      result.append(booleanFlag("DF", "Drop-frame flag", (p[1] >> 6) & 1,
        zero: "Nondrop-frame timecode", one: "Drop-frame timecode", smpteTC))
      result.append(booleanFlag("PC", "Biphase-mark polarity correction", p[2] >> 7,
        zero: "Even", one: "Odd", smpteTC))
      result.append(raw("BGF0", "Binary-group flag 0", p[3] >> 7, smpteTC))
      result.append(raw("BGF2", "Binary-group flag 2", p[4] >> 7, smpteTC))
    }
    result.append(raw("BGF1", "Binary-group flag 1", (p[4] >> 6) & 1, smpteTC))
    return result
  }

  static func bcdField(_ id: String, _ name: String, _ rawValue: UInt8,
    upperBound: Int, _ reference: String) -> Field {
    let tens = Int(rawValue >> 4)
    let units = Int(rawValue & 0x0f)
    let value = tens * 10 + units
    guard tens < 10, units < 10, value < upperBound else {
      return Field(id: id, name: name, rawValue: rawValue,
        meaning: "Invalid BCD or out-of-range value; original bits retained.",
        status: "invalid", reference: reference)
    }
    return Field(id: id, name: name, rawValue: rawValue,
      meaning: String(format: "%02d", value), status: "interpreted", reference: reference)
  }

  static func iec50(_ p: [UInt8]) -> [Field] {
    [mapped("LF", "Locked audio sample-rate flag", p[1] >> 7, [0: "Audio/video lock: locked", 1: "Audio/video lock: unlocked"], iecAS),
     raw("AF_SIZE", "Audio frame size", p[1] & 0x3f, iecAS),
     mapped("SM", "Stereo mode", p[2] >> 7, [0: "Audio arrangement: multiple stereo pairs", 1: "Audio arrangement: lumped"], iecAS),
     mapped("CHN", "Audio channels per audio block", (p[2] >> 5) & 3, [0: "1 channel/block", 1: "2 channels/block"], iecAS),
     mapped("PA", "Paired-audio relationship", (p[2] >> 4) & 1, [0: "Audio channel pairing: paired", 1: "Audio channel pairing: independent"], iecAS),
     raw("AM", "Audio mode", p[2] & 0x0f, iecAS),
     mapped("ML", "Multi-language flag", (p[3] >> 6) & 1, [0: "Multi-language: yes", 1: "Multi-language: no"], iecAS),
     fieldSystem((p[3] >> 5) & 1, reference: iecAS),
     mapped("STYPE", "Audio/video system type", p[3] & 0x1f, [0: "System class: SD", 2: "System class: HD"], iecAS),
     mapped("EF", "Audio emphasis flag", p[4] >> 7, [0: "Emphasis on", 1: "Emphasis off"], iecAS),
     mapped("TC", "Emphasis time constant", (p[4] >> 6) & 1, [1: "50/15 microseconds"], iecAS),
     mapped("SMP", "Audio sampling frequency", (p[4] >> 3) & 7, [0: "48 kHz", 1: "44.1 kHz", 2: "32 kHz"], iecAS),
     mapped("QU", "Audio quantization", p[4] & 7, [0: "16-bit linear", 1: "12-bit nonlinear", 2: "20-bit linear"], iecAS)]
  }

  static func iec51(_ p: [UInt8]) -> [Field] {
    [iecCGMS(p[1] >> 6, iecASC),
     mappedUnavailable("ISR", "Previous input source", (p[1] >> 4) & 3, [0: "Analog input", 1: "Digital input"], unavailable: [3: "No information"], iecASC),
     mappedUnavailable("CMP", "Compression count", (p[1] >> 2) & 3, [0: "Once", 1: "Twice", 2: "Three or more times"], unavailable: [3: "No information"], iecASC),
     mappedUnavailable("SS", "Source and recording situation", p[1] & 3,
       [0: "Scrambled; audience restricted; no descrambling", 1: "Scrambled; audience unrestricted; no descrambling", 2: "Audience restricted; source may be descrambled"], unavailable: [3: "No information"], iecASC),
     booleanFlag("REC_S", "Recording-start flag", p[2] >> 7, zero: "Recording-start marker: set", one: "Recording-start marker: clear", iecASC),
     booleanFlag("REC_E", "Recording-end flag", (p[2] >> 6) & 1, zero: "Recording-end marker: set", one: "Recording-end marker: clear", iecASC),
     mapped("REC_M", "Recording mode", (p[2] >> 3) & 7, [1: "Original", 3: "Inserted audio channels: 1", 4: "Inserted audio channels: 4", 5: "Inserted audio channels: 2", 7: "Recording-mode code is invalid"], iecASC, invalid: [7]),
     mappedUnavailable("ICH", "Insert audio channel", p[2] & 7, [0: "CH1", 1: "CH2", 2: "CH3", 3: "CH4", 4: "CH1 + CH2", 5: "CH3 + CH4", 6: "CH1 + CH2 + CH3 + CH4"], unavailable: [7: "No information"], iecASC),
     booleanFlag("DRF", "Direction flag", p[3] >> 7, zero: "Recorded direction: reverse", one: "Recorded direction: forward", iecASC),
     raw("SPD", "Playback-speed code", p[3] & 0x7f, iecASC),
     raw("GEN", "Audio-source category", p[4] & 0x7f, iecASC)]
  }

  static func iec60(_ p: [UInt8]) -> [Field] {
    let system = (p[3] >> 5) & 1
    return [raw("TVCH_TENS_UNITS", "Television-channel tens and units digits", p[1], iecVS),
      raw("TVCH_HUNDREDS", "Television-channel hundreds digit", p[2] & 0x0f, iecVS),
      booleanFlag("BW", "Black-and-white flag", p[2] >> 7, zero: "Black and white", one: "Color", iecVS),
      booleanFlag("EN", "Color-frame validity flag", (p[2] >> 6) & 1, zero: "Color-frame code validity: valid", one: "Color-frame code validity: invalid", iecVS),
      colorFrame((p[2] >> 4) & 3, enabled: (p[2] >> 6) & 1 == 0, system: system, reference: iecVS),
      raw("SRC", "Video input-source code", p[3] >> 6, iecVS),
      fieldSystem(system, reference: iecVS),
      mapped("STYPE", "Video system type", p[3] & 0x1f, [0: "System class: SD", 2: "System class: HD"], iecVS),
      tunerField(p[4])]
  }

  static func iec61(_ p: [UInt8]) -> [Field] {
    [iecCGMS(p[1] >> 6, iecVSC),
     mappedUnavailable("ISR", "Previous input source", (p[1] >> 4) & 3, [0: "Analog input", 1: "Digital input"], unavailable: [3: "No information"], iecVSC),
     mappedUnavailable("CMP", "Compression count", (p[1] >> 2) & 3, [0: "Once", 1: "Twice", 2: "Three or more times"], unavailable: [3: "No information"], iecVSC),
     mappedUnavailable("SS", "Source and recording situation", p[1] & 3,
       [0: "Scrambled; audience restricted; no descrambling", 1: "Scrambled; audience unrestricted; no descrambling", 2: "Audience restricted; source may be descrambled"], unavailable: [3: "No information"], iecVSC),
     booleanFlag("REC_S", "Recording-start flag", p[2] >> 7, zero: "Recording-start marker: set", one: "Recording-start marker: clear", iecVSC),
     mapped("REC_M", "Recording mode", (p[2] >> 4) & 3, [0: "Original", 2: "Insert", 3: "Recording-mode code is invalid"], iecVSC, invalid: [3]),
     raw("DISP", "Aspect-ratio information code", p[2] & 7, iecVSC),
     booleanFlag("FF", "Frame/field flag", p[3] >> 7, zero: "Output sequence: (selected, selected)", one: "Output sequence: (first, second)", iecVSC),
     booleanFlag("FS", "First/second field flag", (p[3] >> 6) & 1, zero: "First output: field/frame 2", one: "First output: field/frame 1", iecVSC),
     booleanFlag("FC", "Frame-change flag", (p[3] >> 5) & 1, zero: "Previous-picture comparison: same", one: "Previous-picture comparison: different", iecVSC),
     booleanFlag("IL", "Interlace flag", (p[3] >> 4) & 1, zero: "Noninterlaced", one: "Interlace indicated or undetermined", iecVSC),
     booleanFlag("SF", "Still-field picture flag", (p[3] >> 3) & 1, zero: "Time between fields: 0 s", one: "Time between fields: 1001/60 s or 1/50 s", iecVSC),
     booleanFlag("SC", "Still-camera picture flag", (p[3] >> 2) & 1, zero: "Still-camera marker: set", one: "Still-camera marker: clear", iecVSC),
     mapped("BCS", "Broadcast system", p[3] & 3, [0: "Type 0 (IEC 61880 / CEA-608)", 1: "Type 1 (ETS 300 294)"], iecVSC),
     raw("GEN", "Video-source category", p[4] & 0x7f, iecVSC)]
  }

  static func smpte50(_ p: [UInt8]) -> [Field] {
    let system = (p[3] >> 5) & 1
    return [mapped("LF", "Locked audio sample-rate flag", p[1] >> 7, [0: "Audio/video lock: locked"], smpteAS),
     smpteAFSize(p[1] & 0x3f, system: system),
     mapped("CHN", "Audio channels per audio block", (p[2] >> 5) & 3, [0: "1 channel/block"], smpteAS),
     mapped("AM", "Audio mode", p[2] & 0x0f, [0: "CH1 (CH3)", 1: "CH2 (CH4)", 15: "Invalid audio data"], smpteAS, invalid: [15]),
     fieldSystem(system, reference: smpteAS),
     mapped("STYPE", "Audio blocks per video frame", p[3] & 0x1f, [0: "Audio blocks/frame: 2", 2: "Audio blocks/frame: 4"], smpteAS),
     mapped("SMP", "Audio sampling frequency", (p[4] >> 3) & 7, [0: "48 kHz"], smpteAS),
     mapped("QU", "Audio quantization", p[4] & 7, [0: "16-bit linear"], smpteAS)]
  }

  static func smpteAFSize(_ value: UInt8, system: UInt8) -> Field {
    let meanings: [UInt8: String] = system == 0
      ? [20: "1600 samples/frame (525/60)", 22: "1602 samples/frame (525/60)"]
      : [24: "1920 samples/frame (625/50)"]
    return mapped("AF_SIZE", "Audio samples per frame", value, meanings, smpteAS)
  }

  static func smpte51(_ p: [UInt8]) -> [Field] {
    let recS = p[2] >> 7
    let recE = (p[2] >> 6) & 1
    return [mapped("CGMS", "Copy-generation management", p[1] >> 6, [0: "Copy free"], smpteASC),
      mapped("EFC", "Audio emphasis channel flag", p[1] & 3, [0: "Emphasis off", 1: "Emphasis on"], smpteASC),
      booleanFlag("REC_S", "Recording-start flag", recS, zero: "Recording-start marker: set", one: "Recording-start marker: clear", smpteASC),
      booleanFlag("REC_E", "Recording-end flag", recE, zero: "Recording-end marker: set", one: "Recording-end marker: clear", smpteASC),
      conditionalFlag("FADE_S", "Recording-start fade flag", (p[2] >> 5) & 1, applicable: recS == 0, smpteASC),
      conditionalFlag("FADE_E", "Recording-end fade flag", (p[2] >> 4) & 1, applicable: recE == 0, smpteASC),
      booleanFlag("DRF", "Direction flag", p[3] >> 7, zero: "Recorded direction: reverse", one: "Recorded direction: forward", smpteASC),
      speedField(p[3] & 0x7f)]
  }

  static func smpte60(_ p: [UInt8]) -> [Field] {
    let system = (p[3] >> 5) & 1
    return [booleanFlag("BW", "Black-and-white flag", p[2] >> 7, zero: "Black and white", one: "Color", smpteVS),
      booleanFlag("EN", "Color-frame validity flag", (p[2] >> 6) & 1, zero: "Color-frame code validity: valid", one: "Color-frame code validity: invalid", smpteVS),
      colorFrame((p[2] >> 4) & 3, enabled: (p[2] >> 6) & 1 == 0, system: system, reference: smpteVS),
      fieldSystem(system, reference: smpteVS),
      mapped("STYPE", "Video compression type", p[3] & 0x1f, [0: "4:1:1 compression", 4: "4:2:2 compression"], smpteVS),
      viscField(p[4])]
  }

  static func smpte61(_ p: [UInt8]) -> [Field] {
    [mapped("CGMS", "Copy-generation management", p[1] >> 6, [0: "Copy free"], smpteVSC),
     mapped("DISP", "Display select mode", p[2] & 7, [0: "Full-frame aspect: 4:3", 2: "Full-frame aspect: 16:9, anamorphic"], smpteVSC),
     booleanFlag("FF", "Frame/field flag", p[3] >> 7, zero: "Field sequence: (selected, selected)", one: "Field sequence: (first, second)", smpteVSC),
     booleanFlag("FS", "First/second field flag", (p[3] >> 6) & 1, zero: "Field-one period carries field 2", one: "Field-one period carries field 1", smpteVSC),
     booleanFlag("FC", "Frame-change flag", (p[3] >> 5) & 1, zero: "Previous-picture comparison: same", one: "Previous-picture comparison: different", smpteVSC),
     booleanFlag("IL", "Interlace flag", (p[3] >> 4) & 1, zero: "Noninterlaced", one: "Interlaced", smpteVSC)]
  }

  static func mapped(_ id: String, _ name: String, _ value: UInt8,
    _ meanings: [UInt8: String], _ reference: String, invalid: Set<UInt8> = []) -> Field {
    if invalid.contains(value) {
      return Field(id: id, name: name, rawValue: value, meaning: meanings[value] ?? "Invalid code", status: "invalid", reference: reference)
    }
    if let meaning = meanings[value] {
      return Field(id: id, name: name, rawValue: value, meaning: meaning, status: "interpreted", reference: reference)
    }
    return Field(id: id, name: name, rawValue: value, meaning: "Reserved code", status: "reserved", reference: reference)
  }

  static func mappedUnavailable(_ id: String, _ name: String, _ value: UInt8,
    _ meanings: [UInt8: String], unavailable: [UInt8: String], _ reference: String) -> Field {
    if let meaning = meanings[value] { return Field(id: id, name: name, rawValue: value, meaning: meaning, status: "interpreted", reference: reference) }
    if let meaning = unavailable[value] { return Field(id: id, name: name, rawValue: value, meaning: meaning, status: "unavailable", reference: reference) }
    return Field(id: id, name: name, rawValue: value, meaning: "Reserved or unassigned code", status: "reserved", reference: reference)
  }

  static func raw(_ id: String, _ name: String, _ value: UInt8, _ reference: String) -> Field {
    Field(id: id, name: name, rawValue: value,
      meaning: "Raw numeric code retained; no incomplete mapping is guessed.",
      status: "uninterpreted", reference: reference)
  }

  static func booleanFlag(_ id: String, _ name: String, _ value: UInt8,
    zero: String, one: String, _ reference: String) -> Field {
    mapped(id, name, value, [0: zero, 1: one], reference)
  }

  static func conditionalFlag(_ id: String, _ name: String, _ value: UInt8,
    applicable: Bool, _ reference: String) -> Field {
    guard applicable else {
      return Field(id: id, name: name, rawValue: value,
        meaning: "Unavailable because the corresponding recording-point flag is not asserted; no physical event is inferred.",
        status: "unavailable", reference: reference)
    }
    return booleanFlag(id, name, value, zero: "Fading off", one: "Fading on", reference)
  }

  static func fieldSystem(_ value: UInt8, reference: String) -> Field {
    mapped("FIELD_SYSTEM", "Field system", value, [0: "Field-system class: 60", 1: "Field-system class: 50"], reference)
  }

  static func iecCGMS(_ value: UInt8, _ reference: String) -> Field {
    mapped("CGMS", "Copy-generation management", value,
      [0: "Copy code: unrestricted", 2: "Copy code: one generation", 3: "Copy code: prohibited"], reference)
  }

  static func colorFrame(_ value: UInt8, enabled: Bool, system: UInt8, reference: String) -> Field {
    guard enabled else {
      return Field(id: "CLF", name: "Color-frame identification", rawValue: value,
        meaning: "Unavailable because EN marks CLF invalid", status: "unavailable", reference: reference)
    }
    let meanings: [UInt8: String] = system == 0
      ? [0: "Color frame A", 1: "Color frame B"]
      : [0: "Fields 1 and 2", 1: "Fields 3 and 4", 2: "Fields 5 and 6", 3: "Fields 7 and 8"]
    return mapped("CLF", "Color-frame identification", value, meanings, reference)
  }

  static func viscField(_ value: UInt8) -> Field {
    if value == 0x7f { return Field(id: "VISC", name: "VISC code", rawValue: value, meaning: "No information", status: "unavailable", reference: smpteVS) }
    if (0x79...0x7e).contains(value) || (0x80...0x87).contains(value) {
      return Field(id: "VISC", name: "VISC code", rawValue: value, meaning: "Reserved code", status: "reserved", reference: smpteVS)
    }
    return raw("VISC", "VISC code", value, smpteVS)
  }

  static func tunerField(_ value: UInt8) -> Field {
    if value == 0xff {
      return Field(id: "TUN", name: "Tuner-category code", rawValue: value,
        meaning: "No information", status: "unavailable", reference: iecVS)
    }
    return raw("TUN", "Tuner-category code", value, iecVS)
  }

  static func speedField(_ value: UInt8) -> Field {
    if value == 0x7f { return Field(id: "SPD", name: "Shuttle-speed code", rawValue: value, meaning: "Data invalid", status: "invalid", reference: smpteASC) }
    return raw("SPD", "Shuttle-speed code", value, smpteASC)
  }

  static func fixedLayoutMismatch(_ p: [UInt8], format: FormatIdentity) -> Bool {
    guard p.count == 5 else { return true }
    switch (format, p[0]) {
    case (.iec61834, 0x50): return p[1] & 0x40 != 0x40 || p[3] & 0x80 != 0x80
    case (.iec61834, 0x51): return p[4] & 0x80 != 0x80
    case (.iec61834, 0x60): return false
    case (.iec61834, 0x61): return p[2] & 0x48 != 0x48 || p[4] & 0x80 != 0x80
    case (.iec61834, 0x70), (.iec61834, 0x71): return p[1] & 0xc0 != 0xc0
    case (.smpte314M, 0x50): return p[1] & 0x40 != 0x40 || p[2] & 0x90 != 0x10 || p[3] & 0xc0 != 0xc0 || p[4] & 0xc0 != 0xc0
    case (.smpte314M, 0x51): return p[1] & 0x3c != 0x3c || p[2] & 0x0f != 0x0f || p[4] != 0xff
    case (.smpte314M, 0x60): return p[1] != 0xff || p[2] & 0x0f != 0x0f || p[3] & 0xc0 != 0xc0
    case (.smpte314M, 0x61): return p[1] & 0x3f != 0x3f || p[2] & 0xf8 != 0xc8 || p[3] & 0x0f != 0x0c || p[4] != 0xff
    default: return false
    }
  }

  static func packName(_ type: UInt8) -> String { DVPackCatalog.entry(type).name }

  static func missingPrincipalPacks(_ observations: [Observation]) -> [String] {
    let required: [(String, UInt8, String)] = [
      ("aaux-sequence-half-1", 0x50, "AAUX source (0x50) missing from sequence half 1"),
      ("aaux-sequence-half-1", 0x51, "AAUX source control (0x51) missing from sequence half 1"),
      ("aaux-sequence-half-2", 0x50, "AAUX source (0x50) missing from sequence half 2"),
      ("aaux-sequence-half-2", 0x51, "AAUX source control (0x51) missing from sequence half 2"),
      ("vaux-frame", 0x60, "VAUX source (0x60) missing from frame"),
      ("vaux-frame", 0x61, "VAUX source control (0x61) missing from frame"),
    ]
    return required.compactMap { context, type, description in
      observations.contains { $0.context == context && $0.type == type } ? nil : description
    }
  }

  static func adding(_ a: UInt64, _ b: UInt64) -> UInt64? {
    let (value, overflow) = a.addingReportingOverflow(b)
    return overflow ? nil : value
  }

  static func extentRangeIsValid(_ extent: DVMetadataInventory.Extent,
    inventory: DVMetadataInventory, requiredCount: Int) -> Bool {
    offsetRangeIsValid(extent.sourceByteOffset, count: requiredCount, inventory: inventory)
  }

  static func offsetRangeIsValid(_ offset: UInt64, count: Int,
    inventory: DVMetadataInventory) -> Bool {
    guard count >= 0, offset >= inventory.frameByteOffset,
      let frameEnd = adding(inventory.frameByteOffset, UInt64(inventory.frameByteCount)),
      let end = adding(offset, UInt64(count))
    else { return false }
    return end <= frameEnd
  }
}
