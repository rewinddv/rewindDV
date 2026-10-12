// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Grouping only. No field extraction, application inference or value selection.
public enum DVMetadataPresentation {
  /// Existing interpreted checks remain intact. Group the known disputed checks
  /// per raw/context pack, never across missing frames or distinct observations.
  public static func unresolvedVAUX61(_ report: DVPackSemanticReport) -> [DVPackSemanticReport.Pack] {
    report.packs.filter { pack in
      pack.typeHex == "0x61" && pack.fields.contains {
        ["PC2_FIXED6", "PC2_FIXED3"].contains($0.id) && $0.status == "invalid"
      }
    }
  }
  /// Presentation-only provenance. Labels/IDs used by consumers stay unchanged.
  /// A format constant or calculated value must never acquire a fictitious pack ID.
  public static func inspectorLabel(_ label: String, section: String) -> String {
    if label.hasPrefix("[") { return label }
    let source: String
    if section.hasPrefix("Recorded camera · ") {
      source = String(section.split(separator: "·").last ?? "CAMERA").trimmingCharacters(in: .whitespaces)
    } else if section.hasPrefix("Recorded Camera - ") {
      source = String(section.dropFirst("Recorded Camera - ".count))
    } else if section == "Recorded camera settings" {
      source = "0x70–0x7F"
    } else if section == "Apple presentation geometry" {
      source = label == "Aspect comparison" ? "0x61 + APPLE" : label == "Preview aspect — display only" ? "PREVIEW" : "APPLE"
    } else if section == "Recorded motion / lens" {
      source = label == "Recorded speed" ? "0x51" : "0x71"
    } else if section.hasPrefix("Exact source audio") {
      source = label == "Assessed frames" ? "FILE AUDIT" : "0x50 + CALCULATED"
    } else if section == "Source error summary" {
      source = label == "Nonzero video STA blocks" ? "DIF VIDEO STA" : label == "Active audio error sentinels" ? "DIF AUDIO" : "FILE AUDIT"
    } else if section == "HDV transport" {
      source = ["Capture", "Preview"].contains(label) ? "APP" : "CIP / MPEG-TS"
    } else if section == "General" {
      switch label {
      case "Recorded date & time": source = "0x62 / 0x63"
      case "Complete name", "File size", "Destination", "Final DV file size", "Raw evidence size so far", "Last observed raw evidence size": source = "FILE"
      case "Format", "Commercial name": source = "DIF STRUCTURE"
      case "Duration", "Overall bit rate mode", "Overall bit rate", "Final DV duration": source = "CALCULATED"
      case "PLAY elapsed": source = "TRANSPORT CLOCK"
      case "Capture status", "Final complete frames", "Complete frames received": source = "CAPTURE STATE"
      default: source = "SOURCE UNSPECIFIED"
      }
    } else if section == "Video" {
      switch label {
      case "Tape-reported display aspect ratio", "Scan type", "Scan order": source = "0x61"
      case "Time code of first frame", "Time code source", "Observed timecode": source = "0x13"
      case "Standard", "Height", "Frame rate", "Frame rate mode": source = "DIF SYSTEM"
      case "Chroma subsampling": source = "DIF + 0x60"
      case "Width", "Color space", "Bit depth", "Compression mode": source = "DV CODING"
      case "Bit rate", "Bits/(Pixel*Frame)", "Stream size": source = "CALCULATED"
      default: source = "DIF FRAME"
      }
    } else if section == "Audio" || section == "Audio 1" || section == "Audio 2" {
      switch label {
      case "ID": source = "PAIR INDEX"
      case "Duration": source = "CALCULATED"
      case "Bit rate", "Bit rate mode", "Stream size": source = "0x50 + CALCULATED"
      default: source = "0x50"
      }
    } else {
      source = "SOURCE UNSPECIFIED"
    }
    return "[\(source)] — \(label)"
  }
  public static func packFieldLabel(_ label: String, packID: String) -> String {
    "[\(packID)] — \(label)"
  }
  /// Retain format-specific transport rows as well as compact DV summaries.
  public static func summarySections(_ sections: [DVTechnicalSpecifications.Section]) -> [DVTechnicalSpecifications.Section] {
    sections.filter { ["General", "Video", "Audio", "Audio 1", "Audio 2", "Apple presentation geometry", "HDV transport", "Source error summary", "Recorded motion / lens"].contains($0.title) || $0.title.hasPrefix("Exact source audio · channel ") }
  }
  /// Ordered overview plus every available report field. Presentation never
  /// chooses between conflicting observations or invents absent pack contents.
  public static func overviewSections(_ sections: [DVTechnicalSpecifications.Section],
    metadata: DVPackSemanticReport?) -> [DVTechnicalSpecifications.Section] {
    let cameras = cameraSections(metadata)
    var result: [DVTechnicalSpecifications.Section] = []
    var used = Set<String>()
    func append(_ title: String) {
      let matches = sections.filter { $0.title == title }
      result += matches
      if !matches.isEmpty { used.insert(title) }
    }
    append("General")
    append("Video")
    append("Apple presentation geometry")
    append("Audio"); append("Audio 1"); append("Audio 2")
    for type in ["0x70", "0x71", "0x7F"] {
      let title = "Recorded Camera - " + type.lowercased()
      result.append(cameras.first { $0.title == "Recorded camera · " + type } .map {
        .init(title: title, rows: $0.rows)
      } ?? .init(title: title, rows: [.init(label: "Camera metadata",
        value: metadata == nil ? "Waiting for a sampled DV frame" : "No pack recorded in this sampled frame",
        evidence: "Optional recorded metadata; settings are never inferred from the deck or another frame.")]))
    }
    append("Recorded motion / lens")
    if sections.contains(where: { $0.title == "Source error summary" }) {
      append("Source error summary")
    } else {
      result.append(.init(title: "Source error summary", rows: [.init(label: "Source audit",
        value: "Unavailable — whole-source error assessment not performed",
        evidence: "Sampled metadata does not establish whole-source integrity or capture loss.")]))
    }
    // Retain every other technical section, including exact source-audio audits
    // and qualified format observations that the compact summary used to hide.
    result += sections.filter { !used.contains($0.title) && $0.title != "Recorded camera settings" }
    result += cameras.filter { !["Recorded camera · 0x70", "Recorded camera · 0x71", "Recorded camera · 0x7F", "Recorded camera settings"].contains($0.title) }
    guard let metadata else { return result }
    for (index, pack) in metadata.packs.enumerated() {
      // Camera summaries above aggregate meanings. Retain every original
      // field here too so equal wording cannot hide distinct codes or contexts.
      let fields = pack.fields
      var rows = fields.map { overviewField($0, source: pack.typeHex, observation: pack.rawHex + "; " + pack.status) }
      if rows.isEmpty {
        rows.append(.init(label: "Interpretation", value: pack.status,
          evidence: (pack.catalogEvidence ?? pack.name) + "; " + pack.rawHex))
        rows += rawPayloadFields(pack).map { overviewField($0, source: pack.typeHex, observation: pack.rawHex) }
      }
      result.append(.init(title: "Recorded metadata - \(pack.typeHex.lowercased()) - \(pack.name) - observation \(index + 1)", rows: rows))
    }
    for item in metadata.structuralMetadata ?? [] {
      result.append(.init(title: "Source structure - " + item.name, rows: item.fields.map {
        overviewField($0, source: "DIF STRUCTURE", observation: item.rawHex, structural: true)
      }))
    }
    for (index, sequence) in (metadata.sequences ?? []).enumerated() {
      var rows: [DVTechnicalSpecifications.Row] = [
        .init(label: "Sequence status", value: sequence.status, evidence: sequence.reference),
        .init(label: "Expected length", value: "\(sequence.expectedCount) \(sequence.countUnit)", evidence: sequence.reference),
        .init(label: "Observed payload", value: "\(sequence.payload.count) bytes in \(sequence.observations.count) observed packs", evidence: sequence.reference)]
      for key in (sequence.characterSets ?? [:]).keys.sorted() {
        rows.append(.init(label: "Character set - " + key,
          value: String(format: "Recorded identifier 0x%02X; glyph interpretation unresolved", sequence.characterSets![key]!), evidence: sequence.reference))
      }
      for (componentIndex, component) in (sequence.components ?? []).enumerated() {
        rows.append(.init(label: "Line component \(componentIndex + 1)", value: String(format: "0x%02X", component.header) + " — \(component.status); \(component.samples.count) observed samples; \(component.padding.count) padding samples; expected \(component.expectedSamples.map(String.init) ?? "unknown")", evidence: sequence.reference))
      }
      result.append(.init(title: "Recorded sequences - \(sequence.kind.capitalized) \(index + 1)", rows: rows))
    }
    result.append(.init(title: "Metadata coverage & interpretation", rows: [
      .init(label: "Decoded field coverage", value: "Every available decoded field in this sampled frame is available in this Overview. Expand additional sections to read their fields. Original bytes and locations are available in Metadata & packs.", evidence: metadata.formatEvidence),
      .init(label: "Interpretation limits", value: "Unrecorded settings, vendor payloads and external profiles are not inferred. Unresolved or disputed meanings remain qualified; this is not 100% universal semantic decoding.", evidence: "IEC 61834-4:1998 + AMD1:2010; applicable external profiles and manufacturer evidence are required."),
      .init(label: "Principal packs not observed", value: metadata.missingPrincipalPacks.isEmpty ? "None" : metadata.missingPrincipalPacks.joined(separator: ", "), evidence: "Frame-local coverage; absence does not establish tape loss."),
      .init(label: "Frame fingerprint", value: metadata.frameSHA256, evidence: "SHA-256 of the sampled original DV frame.")]))
    return result
  }
  private static func overviewField(_ field: DVPackSemanticReport.Field, source: String,
    observation: String, structural: Bool = false) -> DVTechnicalSpecifications.Row {
    let structuralNames = ["DSF": "DV system flag", "DFTIA": "Track and pilot application code", "APT": "Track application identifier",
      "FR": "DIF sequence half", "SYNC": "Sync block number", "ID_PARITY": "Sync identifier parity", "ATN_HIGH_NIBBLE": "Absolute track number high fragment",
      "ATN_FRAGMENT": "Absolute track number fragment", "ATN": "Absolute track number observation", "BF": "Blank flag", "TRACK_PITCH": "Track pitch code", "PILOT": "Pilot frame indication",
      "INDEX": "Index identifier", "SKIP": "Skip identifier", "PP": "Picture identifier",
      "ATN_LOW3": "Absolute track number low three fragment bits", "ATN_LOW4": "Absolute track number low four fragment bits"]
    var name = structural ? structuralNames[field.id] ?? field.name : field.name
    if structural && field.id.hasPrefix("TF") { name = "Section \(field.id.dropFirst(2)) transmission flag" }
    if structural && field.id.hasPrefix("AP") && field.id != "APT" { name = "Section \(field.id.dropFirst(2)) application identifier" }
    var value = fieldValue(field)
    value += " (recorded code \(field.rawValue))"
    if let qualifier = field.qualifier, !qualifier.isEmpty { value += "; " + qualifier }
    return .init(label: packFieldLabel(name, packID: source), value: value,
      evidence: fieldCaption(field) + "; " + field.reference + "; " + observation)
  }
  /// All recorded camera fields, not a hand-maintained subset of consumer settings.
  /// Distinct observations remain visible; no value is voted or carried across frames.
  public static func cameraSections(_ report: DVPackSemanticReport?) -> [DVTechnicalSpecifications.Section] {
    let packs = report?.packs.filter { pack in
      guard let id = UInt8(pack.typeHex.dropFirst(2), radix:16) else { return false }
      return (0x70...0x7f).contains(id)
    } ?? []
    guard !packs.isEmpty else {
      return [.init(title: "Recorded camera settings", rows: [.init(label: "Camera metadata", value: report == nil ? "Waiting for a sampled DV frame" : "No camera packs recorded in this sampled frame", evidence: "Camera settings are optional source metadata; the playback deck cannot supply settings that were not recorded.")])]
    }
    return Dictionary(grouping:packs, by: \.typeHex).keys.sorted().map { type in
      let observed = packs.filter { $0.typeHex == type }
      var ids = Set<String>()
      let fields = observed.flatMap(\.fields).filter { !isFormatDetail($0) && ids.insert($0.id).inserted }
      var rows = fields.map { field -> DVTechnicalSpecifications.Row in
        let alternatives = observed.flatMap(\.fields).filter { $0.id == field.id }
        let values = Set(alternatives.map(fieldValue)).sorted()
        return .init(label:field.name, value:values.count == 1 ? values[0] : "Multiple recorded values: " + values.joined(separator:" / "),
          evidence: alternatives.map { $0.reference + "; " + ($0.qualifier ?? "") }.joined(separator:"; ") + "; original packs: " + observed.map(\.rawHex).joined(separator:"; "))
      }
      for (index, pack) in observed.enumerated() where pack.fields.isEmpty {
        rows.append(.init(label:"Unqualified observation \(index + 1)",value:pack.status,evidence:pack.rawHex + "; " + pack.name))
      }
      return .init(title:"Recorded camera · " + type, rows:rows.isEmpty ? [.init(label:"Camera pack",value:"Observed; interpretation unavailable for this format or context",evidence:observed.map(\.status).joined(separator:"; "))] : rows)
    }
  }
  public static func isFormatDetail(_ field: DVPackSemanticReport.Field) -> Bool {
    field.id.contains("FIXED") || field.id.contains("RESERVED") || field.id.contains("EXTENSION_UNUSED")
  }
  public static func fieldValue(_ field: DVPackSemanticReport.Field) -> String {
    if field.status == "unavailable" { return "Unavailable — " + field.meaning }
    if field.status == "reserved" { return "Reserved — " + field.meaning }
    if field.status == "invalid" { return "Invalid — " + field.meaning }
    if field.confidence == .conflictingEvidence { return "Unresolved — " + field.meaning }
    if field.status == "uninterpreted" { return "Unresolved — " + field.meaning }
    return field.meaning
  }
  public struct Group: Identifiable {
    public let title: String
    public let packs: [DVPackSemanticReport.Pack]
    public var id: String { title }
  }
  public static func groups(_ report: DVPackSemanticReport) -> [Group] {
    let order = ["Timecode & Recording", "Camera", "Source / Recording History", "Text / Captions", "Auxiliary / Other"]
    func title(_ pack: DVPackSemanticReport.Pack) -> String {
      guard let header = UInt8(pack.typeHex.dropFirst(2), radix: 16) else { return order[4] }
      if [0x13,0x14,0x52,0x53,0x54,0x62,0x63,0x64].contains(header) { return order[0] }
      if (0x70...0x7f).contains(header) { return order[1] }
      if [0x50,0x51,0x60,0x61].contains(header) { return order[2] }
      if header & 15 == 8 || header & 15 == 9 || header == 0x65 || header == 0x55 { return order[3] }
      return order[4]
    }
    // Unknown, reserved and placement-unqualified packs are still observations.
    // Keep them visible beside interpreted packs instead of hiding their names.
    let observed = Dictionary(grouping: report.packs, by: title)
    return order.compactMap { name in observed[name].map { Group(title: name, packs: $0) } }
  }
  public static func rawPayloadFields(_ pack: DVPackSemanticReport.Pack) -> [DVPackSemanticReport.Field] {
    if let components = pack.rawComponents, !components.isEmpty { return components }
    let bytes = pack.rawHex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 5 else { return [] }
    return (1...4).map { index in
      .init(id: "payload-PC\(index)", name: "Payload byte PC\(index) (raw)", rawValue: bytes[index],
        meaning: String(format: "0x%02X — original payload byte", bytes[index]), status: "uninterpreted",
        reference: "Five-byte DV pack: PC0 identifies the pack; PC1–PC4 retain its payload.",
        confidence: .unknown, qualifier: "No field boundaries or meanings are selected for this observation.")
    }
  }
  public static func fieldCaption(_ field: DVPackSemanticReport.Field) -> String {
    var text = "\(field.confidence.label) · \(field.status) · raw \(field.rawValue) (\(String(format: "0x%X", field.rawValue)))"
    if let numeric = field.numeric {
      text += " · \(numeric.bitWidth) bits · \(numeric.unit) · \(numeric.relation) · \(numeric.rule)"
    }
    return text
  }
  public static func matches(_ pack: DVPackSemanticReport.Pack, query: String) -> Bool {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return term.isEmpty || ([pack.typeHex, pack.name, pack.status] + pack.fields.flatMap { [$0.id, $0.name, $0.meaning] })
      .contains { $0.localizedCaseInsensitiveContains(term) }
  }
  public static func layoutCaption(_ field: DVIEC61834.LayoutField) -> String {
    var parts = field.slices.map { "PC\($0.byte)[\($0.shift + $0.width - 1):\($0.shift)]" }
    parts.append("encoding: " + field.encoding)
    if let lower = field.rangeLower { parts.append("minimum: \(lower)") }
    if let upper = field.rangeUpper { parts.append("maximum: \(upper)") }
    if let sentinel = field.sentinel { parts.append("sentinel: \(sentinel)") }
    if let fixed = field.fixed { parts.append("fixed: \(fixed)") }
    if let labels = field.labels { parts += labels.keys.sorted().map { "\($0): \(labels[$0]!)" } }
    return parts.joined(separator: " · ")
  }
  public static func location(_ value: DVMetadataLocation) -> String {
    "frame \(value.frameOrdinal) · sequence \(value.sequence) · section \(value.section) · DIF block \(value.block) · slot \(value.slot) · frame byte \(value.localByteOffset) · "
      + (value.absoluteByteOffset.map { "source byte \($0)" } ?? "durable source offset unknown") + " · transmission \(value.transmission) · original DIF ID \(value.difIDHex ?? "unavailable")"
  }
}
