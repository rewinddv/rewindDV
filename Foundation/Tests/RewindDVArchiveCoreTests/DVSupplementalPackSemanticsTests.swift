import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

// Original synthetic vectors. Layout/mapping oracle is the pinned MediaInfo
// parser documented by each field, not recordings supplied by another project.
private func supplemental(_ bytes: [UInt8], pal: Bool = false, smpte: Bool = false,
  offset: Int = 253, invalid: Bool = false, duplicate: [UInt8]? = nil
) throws -> (DVPackSemanticReport, Data) {
  var frame = semanticFrame(smpte: smpte, pal: pal)
  frame.replaceSubrange(offset..<offset + 5, with: bytes)
  if invalid { frame[offset == 86 ? 7 : offset == 483 ? 5 : 6] |= 0x80 }
  if let duplicate { frame.replaceSubrange(offset + 12_000..<offset + 12_005, with: duplicate) }
  let inventory = try DVMetadataInventory.inspect(frame: frame, ordinal: 7, byteOffset: 120_000)
  return (DVPackSemanticReport.inspect(inventory), frame)
}
private func supplementalFields(_ report: DVPackSemanticReport, _ type: UInt8) -> [DVPackSemanticReport.Field] {
  report.packs.filter { $0.typeHex == String(format: "0x%02X", type) }.flatMap(\.fields)
}

@Test func cameraMappingsAndUnmappedCodesAreExhaustive() throws {
  for pal in [false, true] {
    for code in UInt8(0)...15 {
      let (report, _) = try supplemental([0x70, 0xc0, code << 4 | 7, 0x64, 0x85], pal: pal)
      let fields = supplementalFields(report, 0x70)
      let exposure = try #require(fields.first { $0.id == "AE_MODE" })
      #expect(exposure.status == (code < 5 ? "interpreted" : code == 15 ? "unavailable" : "reserved"))
      #expect(fields.first { $0.id == "WB_PRESET" }?.meaning == "Sunlight")
      #expect(fields.first { $0.id == "FOCUS_MODE" }?.meaning == "Manual")
      #expect(fields.first { $0.id == "AGC" }?.status == "interpreted")
    }
    for mode in UInt8(0)...7 {
      for preset in UInt8(0)...31 {
        let (report, _) = try supplemental([0x70, 0xc0, 0, mode << 5 | preset, 0], pal: pal)
        let fields = supplementalFields(report, 0x70)
        #expect(fields.first { $0.id == "WB_MODE" }?.status == (mode < 4 ? "interpreted" : mode == 7 ? "unavailable" : "reserved"))
        #expect(fields.first { $0.id == "WB_PRESET" }?.status == (preset < 7 ? "interpreted" : preset == 31 ? "unavailable" : "reserved"))
      }
    }
  }
}

@Test func cameraLensCandidatesKeepRawCodesAndQualifyUnits() throws {
  let (report, _) = try supplemental([0x71, 0xe5, 0xcb, 0x44, 0xa7])
  let fields = supplementalFields(report, 0x71)
  #expect(fields.count == 9)
  #expect(fields.filter { $0.status == "interpreted" && $0.id != "ZOOM_MAGNITUDE" }.allSatisfy { $0.confidence == .normativeConfirmed })
  #expect(fields.first { $0.id == "ZOOM_MAGNITUDE" }?.confidence == .normativeConfirmed)
  #expect(fields.first { $0.id == "ZOOM_MAGNITUDE" }?.meaning == "2.7×")
  let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.rawValue) })
  #expect(values == ["VPD": 1, "VP_SPEED": 5, "IS": 1, "HPD": 1, "HP_SPEED": 11,
    "FOCAL_LENGTH": 0x44, "ZEN": 1, "CAMERA_FIXED": 3, "ZOOM_MAGNITUDE": 0x27])
}

@Test func supplementalFormatScopeTransmissionAndUnknownRemainGated() throws {
  for type: UInt8 in [0x14, 0x52, 0x53, 0x62, 0x63, 0x65, 0x70, 0x71] {
    let expected = type == 0x14 ? 86 : [0x52, 0x53].contains(type) ? 483 : 253
    let payload: [UInt8] = [type, 0xc0, 0x12, 0x01, 0x24]
    let (unsupported, _) = try supplemental(payload, smpte: true, offset: expected)
    #expect(supplementalFields(unsupported, type).isEmpty)
    let (wrong, _) = try supplemental(payload, offset: expected == 483 ? 253 : 483)
    if type != 0x14 { #expect(supplementalFields(wrong, type).isEmpty) }
    else { #expect(supplementalFields(wrong,type).count == 8) }
    let (invalid, _) = try supplemental(payload, offset: expected, invalid: true)
    let fields = supplementalFields(invalid, type)
    #expect(!fields.isEmpty && fields.allSatisfy { $0.status == "invalid" })
    let (empty, _) = try supplemental([type, 255, 255, 255, 255], offset: expected)
    let emptyFields = supplementalFields(empty, type)
    #expect(!emptyFields.isEmpty)
    if [0x52,0x53,0x62,0x63,0x65].contains(type) {
      #expect(emptyFields.filter { $0.id.hasPrefix("REC_") || $0.id.hasPrefix("CC_") }.allSatisfy { $0.status == "unavailable" })
    } else if type == 0x14 {
      #expect(emptyFields.allSatisfy { $0.rawValue == 15 && $0.status == "uninterpreted" })
    } else {
      #expect(emptyFields.contains { $0.status != "unavailable" })
    }
  }
  let (unknown, _) = try supplemental([0x72, 1, 2, 3, 4])
  #expect(supplementalFields(unknown, 0x72).isEmpty)
}

@Test func supplementalCameraConflictsAndLayoutWarningsRetainRawProof() throws {
  let (report, frame) = try supplemental([0x70, 0, 0x40, 0x64, 0], duplicate: [0x70, 0xc0, 0, 0x64, 0])
  let packs = report.packs.filter { $0.typeHex == "0x70" }
  #expect(packs.count == 2 && packs.allSatisfy { $0.status.contains("Conflicting") })
  #expect(packs.flatMap(\.fields).filter { $0.id == "AE_MODE" }.allSatisfy { $0.status == "conflicting" })
  #expect(packs.flatMap(\.sourceByteOffsets).sorted() == [120_253, 132_253])
  #expect(report.frameSHA256 == SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined())
  #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
  let (warning, _) = try supplemental([0x70, 0, 0, 0, 0])
  #expect(warning.packs.first { $0.typeHex == "0x70" }?.status.contains("fixed/reserved") == true)
}

@Test func binaryUserBitsStayOrderedAndDoNotGuessTextEncoding() throws {
  let (report, _) = try supplemental([0x14, 0x21, 0x43, 0x65, 0x87], offset: 86)
  let fields = supplementalFields(report, 0x14)
  #expect(fields.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 7, 8])
  #expect(fields.allSatisfy { $0.status == "uninterpreted" && $0.qualifier?.contains("SMPTE/EBU") == true })
}

@Test func recordingClockComponentsRespectBCDCalendarAndSystem() throws {
  for (type, offset): (UInt8, Int) in [(0x52, 483), (0x62, 253)] {
    for (day, month, year, valid): (UInt8, UInt8, UInt8, Bool) in [
      (0x29, 0x02, 0x04, true), (0x29, 0x02, 0x03, false), (0x31, 0x04, 0x24, false),
      (0x31, 0x12, 0x99, true), (0x2a, 0x02, 0x04, false), (0, 1, 1, false)] {
      let (report, _) = try supplemental([type, 0xff, day | 0xc0, month | 0xe0, year], offset: offset)
      let fields = supplementalFields(report, type)
      #expect(fields.first { $0.id == "REC_DAY" }?.status == (valid ? "interpreted" : "invalid"))
      #expect(fields.first { $0.id == "ZONE_CODE" }?.status == "unavailable")
    }
  }
  for type: UInt8 in [0x53, 0x63] {
    let offset = type == 0x53 ? 483 : 253
    for pal in [false, true] {
      let (report, _) = try supplemental([type, 0xe9, 0xd9, 0xd9, 0xe3], pal: pal, offset: offset)
      let fields = supplementalFields(report, type)
      #expect(fields.first { $0.id == "REC_FRAMES" }?.status == (pal ? "invalid" : "interpreted"))
      #expect(fields.first { $0.id == "REC_HOURS" }?.meaning == "23")
      #expect(fields.first { $0.id == "REC_SECONDS" }?.meaning == "59")
    }
    let (unknownFrames, _) = try supplemental([type, 0xff, 0x80, 0x80, 0x80], offset: offset)
    #expect(supplementalFields(unknownFrames, type).first { $0.id == "REC_FRAMES" }?.status == "unavailable")
    #expect(supplementalFields(unknownFrames, type).first { $0.id == "REC_SECONDS" }?.meaning == "00")
  }
}

@Test func subcodeRecordingClocksRetainSeparateContextFromVAUX() throws {
  var frame = semanticFrame()
  frame.replaceSubrange(86..<91, with: [0x62, 0xff, 0xe2, 0xe9, 0x26])
  frame.replaceSubrange(253..<258, with: [0x62, 0xff, 0xe3, 0xe9, 0x26])
  let report = DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 0, byteOffset: 0))
  let packs = report.packs.filter { $0.typeHex == "0x62" }
  #expect(packs.count == 2)
  #expect(packs.allSatisfy { !$0.status.contains("Conflicting") })
  #expect(packs.flatMap(\.fields).filter { $0.id == "REC_DAY" }.map(\.meaning).sorted() == ["22", "23"])
}

@Test func iecTitleTimecodeDigitsAndFlagsDoNotBorrowSMPTEBGF() throws {
  for pal in [false, true] {
    let (report, _) = try supplemental([0x13, 0xe4, 0xd9, 0xd8, 0xe3], pal: pal, offset: 86)
    let fields = supplementalFields(report, 0x13)
    #expect(fields.first { $0.id == "TC_HOURS" }?.meaning == "23")
    #expect(fields.first { $0.id == "TC_MINUTES" }?.meaning == "58")
    #expect(fields.first { $0.id == "TC_SECONDS" }?.meaning == "59")
    #expect(fields.first { $0.id == "TC_FRAMES" }?.meaning == "24")
    #expect(fields.first { $0.id == "S2" }?.confidence == .normativeConfirmed)
    #expect(fields.first { $0.id == "S2" }?.rawValue == 1)
    #expect(fields.first { $0.id == "S1" }?.status == "uninterpreted")
    #expect(!fields.contains { $0.id == "DF" || $0.id == "CF" })
    #expect(!fields.contains { $0.id == "PC" || $0.id.hasPrefix("BGF") })
    #expect(fields.filter { $0.id.hasPrefix("PC") }.allSatisfy { $0.status == "uninterpreted" })
    let (invalid, _) = try supplemental([0x13, 0xe4, 0xd9, 0xd8, 0xe3], pal: pal, offset: 86, invalid: true)
    #expect(supplementalFields(invalid, 0x13).allSatisfy { $0.status == "invalid" })
  }
}

@Test func captionFieldsRetainBothPairsAndCheckAllByteParitiesWithoutTextClaims() throws {
  for byte in UInt8.min...UInt8.max {
    let (report, _) = try supplemental([0x65, byte, 0x80, 0x94, 0x2c])
    let fields = supplementalFields(report, 0x65)
    let first = try #require(fields.first)
    #expect(first.rawValue == byte)
    #expect(first.status == (byte == 255 ? "unavailable" : byte.nonzeroBitCount % 2 == 1 ? "interpreted" : "invalid"))
    #expect(fields.map(\.id) == ["CC_F1_BYTE1", "CC_F1_BYTE2", "CC_F2_BYTE1", "CC_F2_BYTE2"])
  }
  let (pal, _) = try supplemental([0x65, 0x94, 0x2c, 0x80, 0x80], pal: true)
  #expect(supplementalFields(pal, 0x65).allSatisfy { $0.status == "uninterpreted" })
}
