// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Non-pack observations. Fragment assembly is descriptive, never seek authority.
public struct DVStructuralMetadata: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let rawHex: String
  public let locations: [DVMetadataLocation]
  public let fields: [DVPackSemanticReport.Field]

  static func inspect(_ inventory: DVMetadataInventory, absoluteOffsetsKnown: Bool, consumerQualified: Bool) -> [Self] {
    guard inventory.extents.count <= 1800, [120000,144000].contains(inventory.frameByteCount) else { return [] }
    var result: [Self] = []
    let half = inventory.frameByteCount == 144_000 ? 6 : 5
    let headers = Dictionary(grouping: inventory.extents.filter { $0.section == 0 && inventory.hasBoundedExtent($0) }, by: \.sequence)

    for extent in inventory.extents where extent.section < 2 && extent.bytes.count == 80 {
      guard inventory.hasBoundedExtent(extent) else { continue }
      let b = [UInt8](extent.bytes)
      func location(_ local: Int, _ slot: Int, _ valid: Bool = true) -> DVMetadataLocation {
        inventory.location(extent, local: local, slot: slot,
          transmission: valid ? "valid" : "invalid", absolute: absoluteOffsetsKnown)
      }
      func field(_ id: String, _ raw: UInt32, _ meaning: String, valid: Bool = true,
        confidence: DVMetadataConfidence = .implementationCorroborated) -> DVPackSemanticReport.Field {
        .init(id: id, name: id, rawValue: raw, meaning: meaning,
          status: valid ? "interpreted" : "invalid",
          reference: "DV corpus v2 non-pack fields; DIF header/subcode geometry; structural evidence only",
          confidence: confidence, numeric: id == "ATN" ? .init(bitWidth: 23, unit: "unknown physical position", relation: "raw", rule: "subcode ATN fragments: low7 | middle8<<7 | high8<<15") : nil)
      }
      if extent.section == 0 {
        var fields: [DVPackSemanticReport.Field] = [
          field("DSF", UInt32(b[3] >> 7), b[3] & 0x80 == 0 ? "525/60 system" : "625/50 system"),
          field("DFTIA", UInt32(b[4] >> 4), "Raw track/pilot application code"),
          field("APT", UInt32(b[4] & 7), "Application ID; interpreted with AP1/AP2/AP3")]
        for i in 1...3 {
          fields.append(field("TF\(i)", UInt32(b[4+i] >> 7), b[4+i] & 0x80 == 0 ? "Section transmission valid" : "Section transmission invalid"))
          fields.append(field("AP\(i)", UInt32(b[4+i] & 7), "Section application ID"))
        }
        if b[4] >> 4 != 15 {
          fields.append(field("TRACK_PITCH", UInt32(b[4] >> 5), "Track pitch raw code; no physical units inferred", confidence: .provisional))
          fields.append(field("PILOT", UInt32((b[4] >> 4) & 1), "Pilot-frame raw indication", confidence: .provisional))
        }
        result.append(Self(id: "header-\(extent.sequence)", name: "DIF header · sequence \(extent.sequence)", rawHex: hex(Array(b[0...7])), locations: [location(0, 0)], fields: fields))
      } else {
        var fragments: [(UInt32, Bool, DVMetadataLocation)] = []
        for slot in 0..<6 {
          let local = 3 + slot * 8, number = Int(extent.block) * 6 + slot
          let x = b[local], y = b[local+1], parity = b[local+2]
          let firstHalf = Int(extent.sequence) < half
          let header = headers[extent.sequence]
          let transmitted = header?.count == 1 && ((header?.first?.bytes[7] ?? 128) & 128 == 0)
          let applicationMatches = ![0,6,11].contains(number) || (x >> 4) & 7 == (header?.first?.bytes[number == 11 ? 4 : 7] ?? 255) & 7
          let valid = consumerQualified && transmitted && applicationMatches && y & 15 == number && (x & 0x80 != 0) == firstHalf && parity == 0xff
          var fields = [field("FR", UInt32(x >> 7), firstHalf ? "First DIF-sequence half" : "Second DIF-sequence half", valid: valid),
            field("SYNC", UInt32(y & 15), "Sync block number \(number)", valid: valid),
            field("ID_PARITY", UInt32(parity), "Expected FF sync-ID parity placeholder", valid: valid)]
          if [0,6,11].contains(number) {
            fields.append(field(number == 11 ? "APT" : "AP3", UInt32((x >> 4) & 7), "Subcode application ID", valid: valid))
          } else {
            for (id, mask) in [("INDEX", UInt8(0x40)), ("SKIP", 0x20), ("PP", 0x10)] {
              fields.append(field(id, x & mask == 0 ? 0 : 1, x & mask == 0 ? "Tag asserted (active low)" : "Tag not asserted", valid: valid))
            }
          }
          let fragment = number % 3 == 0 ? UInt32(x & 15) << 3 | UInt32(y >> 5) : UInt32(x & 15) << 4 | UInt32(y >> 4)
          fields.append(field("ATN_HIGH_NIBBLE", UInt32(x & 15), "Raw high nibble of ATN fragment", valid: valid))
          fields.append(field(number % 3 == 0 ? "ATN_LOW3" : "ATN_LOW4", UInt32(number % 3 == 0 ? y >> 5 : y >> 4), "Raw low bits of ATN fragment", valid: valid))
          fields.append(field("ATN_FRAGMENT", fragment, "Fragment \(number % 3); no tape-position authority", valid: valid))
          if number % 3 == 0 { fields.append(field("BF", UInt32((y >> 4) & 1), "Blank flag raw code", valid: valid, confidence: .provisional)) }
          let loc = location(local, number, valid)
          fragments.append((fragment, valid, loc))
          result.append(Self(id: "sync-\(extent.sequence)-\(number)", name: "Subcode · sequence \(extent.sequence) · block \(extent.block) · sync \(number)", rawHex: hex(Array(b[local..<(local+3)])), locations: [loc], fields: fields))
        }
        for start in [0,3] {
          let triple = Array(fragments[start..<(start+3)])
          let value = triple[0].0 | triple[1].0 << 7 | triple[2].0 << 15
          result.append(Self(id: "atn-\(extent.sequence)-\(extent.block)-\(start)", name: "ATN observation · sequence \(extent.sequence) · sync \(Int(extent.block)*6+start)", rawHex: hex((start..<(start+3)).flatMap { Array(b[(3+$0*8)..<(6+$0*8)]) }), locations: triple.map(\.2), fields: [field("ATN", value, "Reconstructed fragment observation; repetitions are retained independently, never voted or used as transport authority", valid: triple.allSatisfy(\.1), confidence: .implementationCorroborated)]))
        }
      }
    }
    let tracks = Dictionary(grouping: result.filter { $0.id.hasPrefix("atn-") }, by: { $0.locations.first!.sequence })
    let conflicting = Set(tracks.compactMap { sequence, items in
      Set(items.flatMap(\.fields).filter { $0.status == "interpreted" }.map(\.rawValue)).count > 1 ? sequence : nil
    })
    return result.map { item in
      guard item.id.hasPrefix("atn-"), let location = item.locations.first,
        conflicting.contains(location.sequence) else { return item }
      return Self(id: item.id, name: item.name, rawHex: item.rawHex, locations: item.locations,
        fields: item.fields.map { field in
          guard field.status == "interpreted" else { return field }
          return DVPackSemanticReport.Field(id: field.id, name: field.name, rawValue: field.rawValue,
            meaning: "Conflicting ATN observations in this DIF sequence; no value selected",
            status: "conflicting", reference: field.reference, confidence: field.confidence, numeric: field.numeric)
        })
    }
  }
  private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension DVMetadataInventory {
  func hasBoundedExtent(_ extent: Extent) -> Bool {
    guard [120000,144000].contains(frameByteCount), extents.count <= 1800,
      extent.sourceByteOffset >= frameByteOffset, extent.section < 5,
      extent.bytes.count >= (extent.section == 3 ? 8 : 80),
      extent.sequence < (frameByteCount == 144000 ? 12 : 10),
      Int(extent.block) < [1,2,3,9,135][Int(extent.section)] else { return false }
    let relative = extent.sourceByteOffset - frameByteOffset
    return relative <= UInt64(frameByteCount - 80) && relative % 80 == 0
      && extent.sourceByteOffset <= UInt64.max - 80
      && extent.bytes[0] >> 5 == extent.section && extent.bytes[1] >> 4 == extent.sequence
      && extent.bytes[2] == extent.block
  }

  func location(_ extent: Extent, local: Int, slot: Int, transmission: String, absolute: Bool) -> DVMetadataLocation {
    DVMetadataLocation(frameOrdinal: frameOrdinal, frameByteOffset: absolute ? frameByteOffset : nil,
      sequence: extent.sequence, section: extent.section, block: extent.block, slot: slot,
      localByteOffset: Int(extent.sourceByteOffset - frameByteOffset) + local,
      absoluteByteOffset: absolute ? extent.sourceByteOffset + UInt64(local) : nil, transmission: transmission,
      difIDHex: extent.bytes.prefix(3).map { String(format: "%02X", $0) }.joined(separator: " "))
  }
}

extension DVPackSemanticReport {
  func attachingLocations(_ inventory: DVMetadataInventory, absoluteOffsetsKnown: Bool) -> Self {
    var coordinates: [UInt64: (DVMetadataInventory.Extent, Int, Int)] = [:]
    for extent in inventory.extents where inventory.hasBoundedExtent(extent) {
      let slots: [Int]
      switch extent.section {
      case 1: slots = Array(stride(from: 6, through: 46, by: 8))
      case 2: slots = Array(stride(from: 3, through: 73, by: 5))
      case 3: slots = [3]
      default: continue
      }
      for (slot, local) in slots.enumerated() { coordinates[extent.sourceByteOffset + UInt64(local)] = (extent, local, slot) }
    }
    let attached = packs.map { original -> Pack in
      var pack = original
      let bytes = pack.rawHex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
      guard bytes.count == 5 else { return pack }
      let entry = DVPackCatalog.entry(bytes[0])
      let context = String(pack.id.split(separator: ":")[0])
      let transmission = String(pack.id.split(separator: ":").last ?? "unavailable")
      pack.locations = pack.sourceByteOffsets.compactMap { offset in
        guard let (extent, local, slot) = coordinates[offset] else { return nil }
        return inventory.location(extent, local: local, slot: slot, transmission: transmission, absolute: absoluteOffsetsKnown)
      }
      if !absoluteOffsetsKnown { pack.sourceByteOffsets = [] }
      pack.catalogEvidence = "Allocation: " + entry.allocation + ". " + entry.evidence
      if format == "IEC 61834 consumer DV", DVPackCatalog.permitsSDObservation(bytes[0], context: context), entry.hasQualifiedSDLayout {
        pack.rawComponents = entry.components.map { component in
          Field(id: component.id, name: component.name, rawValue: component.extract(bytes)!,
            meaning: "Raw component; PC\(component.byte), mask \(String(format: "0x%02X", component.mask)), shift \(component.shift)",
            status: transmission == "valid" ? "uninterpreted" : transmission == "invalid" ? "invalid" : "unavailable",
            reference: component.reference, confidence: component.confidence,
            qualifier: component.qualifier, numeric: .init(bitWidth: component.width, unit: "raw code", relation: "raw", rule: component.id))
        }
      }
      return pack
    }
    var result = Self(schemaVersion: schemaVersion, frameOrdinal: frameOrdinal, frameByteOffset: frameByteOffset,
      frameSHA256: frameSHA256, format: format, formatEvidence: formatEvidence, packs: attached, missingPrincipalPacks: missingPrincipalPacks)
    result.structuralMetadata = structuralMetadata
    result.absoluteOffsetsKnown = absoluteOffsetsKnown
    return result
  }
}
