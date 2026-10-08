// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

// Engineering oracles only: the published implementation geometry is a contract
// under test, not independent proof of IEC meaning. Values are reconstructed bit
// by bit from input, never obtained from a decoded expected-value fixture.
private func engineeringBits(_ bytes: [UInt8], _ slices: [DVIEC61834.Slice]) -> UInt32 {
  var result: UInt32 = 0
  var significance: UInt32 = 1
  for slice in slices {
    for bit in slice.shift..<(slice.shift + slice.width) {
      if (Int(bytes[slice.byte]) / (1 << bit)) % 2 == 1 { result += significance }
      significance = significance &* 2
    }
  }
  return result
}

private func engineeringContexts() -> [DVIEC61834.Context] {
  (0..<15).map { profile in
    var c = DVIEC61834.Context(); c.mpeg = true
    c.mic = profile == 1; c.professionalCamera = profile == 2
    c.binaryCompanion = profile == 3 ? false : profile == 4 ? true : nil
    c.menuTopic = profile == 5 ? true : profile == 6 ? false : nil
    c.teletextSystem = [7:0, 8:1, 9:3][profile]
    c.isPAL = profile == 10; c.genreBasicCategory = profile == 11 ? 2 : nil
    c.mpegSourceType = [12:4, 13:5, 14:6][profile]
    return c
  }
}

private func engineeringGeometry(_ bytes: [UInt8], _ context: DVIEC61834.Context) throws {
  let original = bytes
  guard let decoded = DVIEC61834.decode(bytes, context: context) else { return }
  #expect(bytes == original)
  #expect(Set(decoded.fields.map(\.id)).count == decoded.fields.count)
  var covered = Set<Int>()
  for layout in decoded.layout {
    let field = try #require(decoded.fields.first { $0.id == layout.id })
    for slice in layout.slices {
      #expect((1...4).contains(slice.byte))
      #expect(slice.width > 0 && slice.shift >= 0 && slice.shift + slice.width <= 8)
      for bit in slice.shift..<(slice.shift + slice.width) {
        let coordinate = slice.byte * 8 + bit
        let alias = (bytes[0] == 0x70 && layout.id == "AGC_DB_CANDIDATE") ||
          (bytes[0] == 0x0f && ["FMODE", "RMODE"].contains(layout.id))
        #expect(covered.insert(coordinate).inserted || alias)
      }
    }
    #expect(field.rawValue == engineeringBits(bytes, layout.slices))
  }
  if !decoded.layout.isEmpty { #expect(covered == Set(8..<40)) }
}

@Test func engineeringEveryPackAndIndependentByteDomains() throws {
  var context = DVIEC61834.Context(); context.mpeg = true
  // Vary each PC byte independently, avoiding the equal-byte probes used by the
  // inventory. Exercise every eight-bit domain against asymmetric neighbours.
  for header in UInt8.min...UInt8.max {
    for byte in 1...4 {
      for value in UInt8.min...UInt8.max {
        var pack: [UInt8] = [header, 0x96, 0x39, 0xa5, 0x6c]
        pack[byte] = value
        try engineeringGeometry(pack, context)
      }
    }
  }
}

@Test func engineeringAlternateContextsWalkingBitsAndDeterminism() throws {
  for context in engineeringContexts() {
    for header in UInt8.min...UInt8.max {
      for bit in 0..<32 {
        var pack: [UInt8] = [header, 0, 0, 0, 0]
        pack[1 + bit / 8] = 1 << (bit % 8)
        try engineeringGeometry(pack, context)
        let first = DVIEC61834.decode(pack, context: context)
        let second = DVIEC61834.decode(pack, context: context)
        #expect(first?.fields == second?.fields)
        #expect(first?.layout == second?.layout)
      }
    }
  }
}

@Test func engineeringMalformedLengthsAndMPEGContextIsolation() {
  for length in [0, 1, 2, 3, 4, 6, 7, 64, 4096] {
    for byte: UInt8 in [0, 0x42, 0x70, 0x90, 0xff] {
      let result = DVIEC61834.decode(Array(repeating: byte, count: length))
      #expect(result?.fields.isEmpty == true)
      #expect(result?.layout.isEmpty == true)
    }
  }
  for header: UInt8 in 0x90...0x9f {
    for value in UInt8.min...UInt8.max {
      let result = DVIEC61834.decode([header, value, value ^ 0xff, 0x55, 0xaa])
      #expect(result?.fields.isEmpty == true)
      #expect(result?.layout.isEmpty == true)
    }
  }
}

@Test func engineeringEveryPackRetainsBytesPositionsAndReportRoundTrip() throws {
  // Reuse only the existing synthetic DIF framing helper, not semantic outputs.
  var frame = semanticFrame()
  var expected: [Int:[UInt8]] = [:]
  var ordinal = 0
  for offset in stride(from: 0, to: frame.count, by: 80) where frame[offset] >> 5 == 2 {
    for slot in stride(from: 3, through: 73, by: 5) {
      // Two observations of each byte pattern where space allows; all 256 IDs
      // appear, including MPEG bytes in a qualified SD-DV frame.
      let header = UInt8((ordinal / 2) % 256)
      let raw: [UInt8] = [header, header ^ 0xa5, 0x19, 0xe7, 0x40]
      frame.replaceSubrange((offset + slot)..<(offset + slot + 5), with: raw)
      expected[offset + slot] = raw; ordinal += 1
    }
  }
  // VAUX has 450 slots, so use AAUX for the remaining 31 distinct IDs.
  for offset in stride(from: 0, to: frame.count, by: 80) where frame[offset] >> 5 == 3 {
    let header = UInt8((ordinal / 2) % 256)
    let raw: [UInt8] = [header, header ^ 0xa5, 0x19, 0xe7, 0x40]
    frame.replaceSubrange((offset + 3)..<(offset + 8), with: raw)
    expected[offset + 3] = raw; ordinal += 1
  }
  #expect(Set(expected.values.map { $0[0] }).count == 256)
  let before = SHA256.hash(data: frame)
  let inventory = try DVMetadataInventory.inspect(frame: frame, ordinal: 9, byteOffset: 120_000)
  let report = DVPackSemanticReport.inspect(inventory)
  #expect(report.schemaVersion == 3)
  #expect(report.interpretationVersion == DVIEC61834.interpretationVersion)
  var recovered: [Int:[UInt8]] = [:]
  for pack in report.packs {
    let bytes = pack.rawHex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    for location in pack.locations ?? [] {
      if let absolute = location.absoluteByteOffset {
        let offset = Int(absolute - 120_000)
        if expected[offset] != nil { recovered[offset] = bytes }
      }
    }
    if let header = bytes.first, (0x90...0x9f).contains(header) { #expect(pack.fields.isEmpty) }
    if let header = bytes.first, (0xa0...0xef).contains(header) { #expect(pack.fields.isEmpty) }
  }
  #expect(recovered == expected)
  #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
  #expect(SHA256.hash(data: frame) == before)
}

@Test func engineeringHistoricalSchemasKeepRawConflictsAndUnknownConfidence() throws {
  // Literal report independent of the encoder/decoder under test. Missing
  // confidence and interpretation revision must remain unknown in all eras.
  for version in [1, 2, 3] {
    let json = """
    {"schema_version":\(version),"frame_ordinal":5,"frame_byte_offset":120000,
     "frame_sha256":"synthetic","format":"historic","format_evidence":"historic",
     "missing_principal_packs":[],"packs":[
       {"id":"maker-a","type_hex":"0xF1","name":"unknown maker","raw_hex":"F1 01 23 45 67",
        "source_byte_offsets":[120243,120323],"status":"raw retained",
        "fields":[{"id":"unresolved","name":"old interpretation","raw_value":103,
                   "meaning":"retained historically","status":"uninterpreted","reference":"historic"}]},
       {"id":"maker-b","type_hex":"0xF1","name":"unknown maker","raw_hex":"F1 89 AB CD EF",
        "source_byte_offsets":[120403],"status":"conflicting repetition",
        "fields":[{"id":"unresolved","name":"disputed interpretation","raw_value":239,
                   "meaning":"conflicting historical value","status":"conflicting","reference":"historic",
                   "confidence":"conflictingEvidence"}]}
     ]}
    """
    let report = try JSONDecoder().decode(DVPackSemanticReport.self, from: Data(json.utf8))
    #expect(report.schemaVersion == version)
    #expect(report.interpretationVersion == nil)
    #expect(report.packs[0].fields[0].confidence == .unknown)
    #expect(report.packs[1].fields[0].confidence == .conflictingEvidence)
    #expect(report.packs.map(\.rawHex) == ["F1 01 23 45 67", "F1 89 AB CD EF"])
    #expect(report.packs.map(\.observationCount) == [2, 1])
    #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
  }
}
