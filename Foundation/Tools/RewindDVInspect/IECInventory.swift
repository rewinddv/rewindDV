// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import RewindDVArchiveCore

/// Executable field inventory, not a claim of physical or external-standard
/// qualification. Probe bytes exercise selectors; they are not tape evidence.
struct IECInventory: Encodable {
  struct Variant: Encodable {
    let context: String
    let probe: [UInt8]
    let layout: [DVIEC61834.LayoutField]
    let evidence: [Evidence]
  }
  struct Evidence: Encodable {
    let id: String
    let reference: String
    let confidence: DVMetadataConfidence
    let numeric: DVPackSemanticReport.NumericDescriptor?
    let qualifier: String?
  }
  struct Pack: Encodable {
    let header: Int
    let name: String
    let allocation: String
    let reference: String
    let variants: [Variant]
  }
  let interpretationVersion = DVIEC61834.interpretationVersion
  let scope = "All 256 allocations and executable field-layout variants. Reserved/unassigned IDs have no invented fields. Opaque fields, external dependencies and disputes are not counted as fully decoded semantics. Selector probes are synthetic."
  let packs: [Pack]

  static func make() throws -> Self {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var packs: [Pack] = []
    for entry in DVPackCatalog.entries {
      var variants: [Variant] = [], seen = Set<Data>()
      // All single-byte selector values, plus every externally supplied layout
      // context. Each schema is stored once; its first probe is reproducible.
      for profile in 0..<15 {
        var c = DVIEC61834.Context(); c.mpeg = true
        c.mic = profile == 1; c.professionalCamera = profile == 2
        c.binaryCompanion = profile == 3 ? false:profile == 4 ? true:nil
        c.menuTopic = profile == 5 ? true:profile == 6 ? false:nil
        c.teletextSystem = [7:0,8:1,9:3][profile]
        c.isPAL = profile == 10
        c.genreBasicCategory = profile == 11 ? 2:nil
        c.mpegSourceType = [12:4,13:5,14:6][profile]
        let name = ["tape-default","MIC","professional-camera","without-binary","with-binary","menu","non-menu","Japan-teletext","NABTS","UK-teletext","PAL","sports-genre","MPEG25","MPEG12.5","MPEG6.25"][profile]
        for value in UInt8.min...UInt8.max {
          let bytes = [entry.header,value,value,value,value]
          guard let decoded = DVIEC61834.decode(bytes,context:c), !decoded.layout.isEmpty else { continue }
          let encoded = try encoder.encode(decoded.layout)
          guard seen.insert(encoded).inserted else { continue }
          let evidence = decoded.fields.map { Evidence(id:$0.id,reference:$0.reference,confidence:$0.confidence,numeric:$0.numeric,qualifier:$0.qualifier) }
          variants.append(.init(context:name,probe:bytes,layout:decoded.layout,evidence:evidence))
        }
      }
      packs.append(.init(header:Int(entry.header),name:entry.name,allocation:entry.allocation,reference:entry.evidence,variants:variants))
    }
    return .init(packs:packs)
  }
}
