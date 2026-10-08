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
    let source: String
    if section == "Apple presentation geometry" {
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
      text += " · \(numeric.bitWidth) bits · \(numeric.unit) · \(numeric.relation)"
    }
    return text
  }
  public static func location(_ value: DVMetadataLocation) -> String {
    "frame \(value.frameOrdinal) · sequence \(value.sequence) · section \(value.section) · DIF block \(value.block) · slot \(value.slot) · frame byte \(value.localByteOffset) · "
      + (value.absoluteByteOffset.map { "source byte \($0)" } ?? "durable source offset unknown") + " · transmission \(value.transmission) · original DIF ID \(value.difIDHex ?? "unavailable")"
  }
}
