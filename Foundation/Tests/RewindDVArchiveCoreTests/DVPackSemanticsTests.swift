import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

// Original synthetic fixtures, not extracted book tables or tape content.
// Oracle: SMPTE 314M-2005 tables 6, 13, 14, 16, 17, A.1;
// Video Demystified (2007) ch.11 tables 11.1, 11.2, 11.4, 11.5.
func semanticFrame(smpte: Bool = false, pal: Bool = false,
  audio: [UInt8] = [0x50, 0xd4, 0x00, 0x80, 0xd0],
  audioControl: [UInt8] = [0x51, 0x00, 0x07, 0x80, 0xff],
  video: [UInt8] = [0x60, 0xff, 0xff, 0xc0, 0xff],
  videoControl: [UInt8] = [0x61, 0x00, 0xc8, 0xf0, 0xff]) -> Data {
  var result = Data()
  for sequence in 0..<(pal ? 12 : 10) {
    func append(section: Int, number: Int) {
      var block = Data(repeating: 0xff, count: 80)
      block[0] = UInt8(section << 5)
      block[1] = UInt8(sequence << 4) | 4
      block[2] = UInt8(number)
      if section == 0 {
        block[3] = pal ? 0x80 : 0
        for i in 4...7 { block[i] = smpte ? 1 : 0 }
      }
      if section == 2 && number == 0 {
        block.replaceSubrange(3..<8, with: video)
        block.replaceSubrange(8..<13, with: videoControl)
      }
      if section == 3 && number < 2 {
        block.replaceSubrange(3..<8, with: number == 0 ? audio : audioControl)
      }
      if section == 4 { block[3] = 0 }
      result.append(block)
    }
    append(section: 0, number: 0)
    for n in 0..<2 { append(section: 1, number: n) }
    for n in 0..<3 { append(section: 2, number: n) }
    for group in 0..<9 {
      append(section: 3, number: group)
      for n in group * 15..<(group + 1) * 15 { append(section: 4, number: n) }
    }
  }
  return result
}

private func semantics(_ frame: Data, offset: UInt64 = 0) throws -> DVPackSemanticReport {
  DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 7, byteOffset: offset))
}

private func fields(_ report: DVPackSemanticReport, pack: String, id: String) -> [DVPackSemanticReport.Field] {
  report.packs.filter { $0.typeHex == pack }.flatMap(\.fields).filter { $0.id == id }
}

@Test func semanticIECAndSMPTEInterpretTheSameBitsDifferently() throws {
  let iec = try semantics(semanticFrame())
  let smpte = try semantics(semanticFrame(smpte: true))
  #expect(iec.format.contains("IEC"))
  #expect(smpte.format.contains("SMPTE"))
  for key in ["LF", "SMP"] {
    let a = fields(iec, pack: "0x50", id: key)
    let b = fields(smpte, pack: "0x50", id: key)
    #expect(!a.isEmpty && !b.isEmpty)
    #expect(a.allSatisfy { $0.status == "interpreted" })
    #expect(b.allSatisfy { $0.status == "reserved" })
  }
  #expect(fields(iec, pack: "0x50", id: "SMP").allSatisfy { $0.meaning.contains("32") })
}

@Test func semanticCopyCodesFollowSpecificFormatNotBookGeneralization() throws {
  for code in UInt8(0)...3 {
    let raw: [UInt8] = [0x51, code << 6 | 0x3c, 0xff, 0x80, 0xff]
    let iec = try semantics(semanticFrame(audioControl: raw))
    let smpte = try semantics(semanticFrame(smpte: true, audioControl: raw))
    let a = fields(iec, pack: "0x51", id: "CGMS")
    let b = fields(smpte, pack: "0x51", id: "CGMS")
    #expect(!a.isEmpty && !b.isEmpty)
    #expect(a.allSatisfy { $0.status == (code == 1 ? "reserved" : "interpreted") })
    #expect(b.allSatisfy { $0.status == (code == 0 ? "interpreted" : "reserved") })
  }
}

@Test(arguments: [false, true]) func semanticOriginalBytesOffsetsAndCodableRoundTrip(pal: Bool) throws {
  let frame = semanticFrame(pal: pal)
  let original = frame
  let report = try semantics(frame, offset: 123)
  #expect(frame == original)
  #expect(report.frameByteOffset == 123 && report.frameOrdinal == 7)
  #expect(report.frameSHA256 == SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined())
  #expect(Set(report.packs.map(\.id)).count == report.packs.count)
  // All subcode (12), VAUX (45), and AAUX (9) pack slots per sequence.
  #expect(report.packs.reduce(0) { $0 + $1.sourceByteOffsets.count } == (pal ? 12 : 10) * 66)
  for pack in report.packs {
    for offset in pack.sourceByteOffsets {
      let index = Int(offset - 123)
      let raw = frame.subdata(in: index..<(index + 5)).map { String(format: "%02X", $0) }.joined()
      #expect(pack.rawHex.replacingOccurrences(of: " ", with: "").uppercased() == raw)
    }
    #expect(Set(pack.fields.map(\.id)).count == pack.fields.count)
  }
  #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
}

@Test func semanticSMPTEAudioSizeRespectsItsFieldSystem() throws {
  for system in UInt8(0)...1 {
    for code in [UInt8(20), 22, 24] {
      let report = try semantics(semanticFrame(smpte: true, pal: system == 1,
        audio: [0x50, 0x40 | code, 0x10, 0xc0 | (system << 5), 0xc0]))
      let values = fields(report, pack: "0x50", id: "AF_SIZE")
      #expect(!values.isEmpty)
      let valid = system == 0 ? code != 24 : code == 24
      #expect(values.allSatisfy { ($0.status == "interpreted") == valid })
    }
  }
}

@Test func semanticTunerCodeUsesVerifiedFinalTable() throws {
  let report = try semantics(semanticFrame(video: [0x60, 0x12, 0x81, 0, 0x12]))
  let tuner = fields(report, pack: "0x60", id: "TUN")
  #expect(!tuner.isEmpty)
  #expect(tuner.allSatisfy { $0.status == "reserved" && $0.confidence == .normativeConfirmed })
  let control = fields(report, pack: "0x61", id: "SS")
  #expect(!control.isEmpty)
  #expect(control.allSatisfy { $0.status == "interpreted" })
}

@Test func semanticAllAudioRateAndQuantizationCodesAreFormatSpecific() throws {
  for smpte in [false, true] {
    for code in UInt8(0)...7 {
      let report = try semantics(semanticFrame(smpte: smpte,
        audio: [0x50,0x54,0x10,0xc0,0xc0 | (code << 3) | code]))
      for id in ["SMP", "QU"] {
        let values = fields(report, pack: "0x50", id: id)
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0.rawValue == code })
        let interpreted = smpte ? code == 0 : code < 3
        #expect(values.allSatisfy { ($0.status == "interpreted") == interpreted })
      }
    }
  }
}

@Test func semanticDoesNotInterpretPacksInUnqualifiedSections() throws {
  var frame = semanticFrame()
  frame.replaceSubrange(86..<91, with: [0x50,0x54,0x10,0xc0,0xc0])
  let report = try semantics(frame)
  let subcode = report.packs.filter { $0.sourceByteOffsets.contains(86) }
  #expect(subcode.count == 1)
  #expect(subcode.allSatisfy { $0.fields.isEmpty || $0.fields.allSatisfy { $0.status != "interpreted" } })
}

@Test func semanticUnknownAndConflictingIdentityDoesNotGuess() throws {
  var unknown = semanticFrame()
  for seq in 0..<10 { for byte in 4...7 { unknown[seq * 12000 + byte] = 7 } }
  let report = try semantics(unknown)
  #expect(report.packs.flatMap(\.fields).allSatisfy { $0.status != "interpreted" })
  var mixed = semanticFrame()
  for byte in 4...7 { mixed[12000 + byte] = 1 }
  #expect(try semantics(mixed).packs.flatMap(\.fields).allSatisfy { $0.status != "interpreted" })
}

@Test func semanticInvalidTransmissionRetainsButDoesNotInterpretAudio() throws {
  var frame = semanticFrame()
  for seq in 0..<10 { frame[seq * 12000 + 5] |= 0x80 }
  let report = try semantics(frame)
  let audio = report.packs.filter { ["0x50", "0x51"].contains($0.typeHex) }
  #expect(!audio.isEmpty)
  #expect(audio.flatMap(\.fields).allSatisfy { $0.status != "interpreted" })
  #expect(!fields(report, pack: "0x61", id: "FF").isEmpty)
}

@Test func semanticUnknownPackRemainsOriginalNotDecodedByPayload() throws {
  let report = try semantics(semanticFrame(video: [0xe1, 0x50, 0x51, 0x60, 0x61]))
  let unknown = report.packs.filter { $0.typeHex == "0xE1" }
  #expect(!unknown.isEmpty)
  #expect(unknown.allSatisfy { $0.fields.isEmpty || $0.fields.allSatisfy { $0.status != "interpreted" } })
}

@Test func semanticConflictingCopiesAreNotVotedAway() throws {
  var frame = semanticFrame()
  // One contradictory video-source-control copy among nine matching copies.
  let sourceOffset = 12000 + 3 * 80 + 8
  frame[sourceOffset + 3] ^= 0x20 // FC, frame-change indicator
  let report = try semantics(frame)
  let controls = report.packs.filter { $0.typeHex == "0x61" }
  #expect(controls.count >= 2)
  #expect(Set(controls.flatMap(\.sourceByteOffsets)).contains(UInt64(sourceOffset)))
  #expect(Set(controls.flatMap(\.fields).filter { $0.id == "FC" }.map(\.rawValue)) == [0, 1])
  #expect(controls.contains { $0.status.lowercased().contains("conflict")
    || $0.fields.contains { $0.status.lowercased().contains("conflict") } })
}

@Test func semanticRetainsAllNoInformationPacks() throws {
  let frame = semanticFrame(smpte: true)
  let report = try semantics(frame)
  let noInfo = report.packs.filter { $0.typeHex == "0xFF" }
  #expect(!noInfo.isEmpty)
  #expect(noInfo.allSatisfy { $0.fields.isEmpty || $0.fields.allSatisfy { $0.status != "interpreted" } })
  #expect(noInfo.allSatisfy { !$0.sourceByteOffsets.isEmpty })
  #expect(noInfo.allSatisfy { $0.status.contains("Valid no-information sentinel") })
}

@Test func semanticRejectsMalformedNoInformationSentinelWithoutDiscardingIt() throws {
  var frame = semanticFrame(smpte: true)
  frame.replaceSubrange(94..<99, with: [0xff, 0xff, 0xfe, 0xff, 0xff])
  let malformed = try #require(try semantics(frame).packs.first {
    $0.rawHex == "FF FF FE FF FF"
  })
  #expect(malformed.typeHex == "0xFF")
  #expect(malformed.status.contains("Invalid no-information pack"))
  #expect(malformed.sourceByteOffsets == [94])
  #expect(malformed.fields.isEmpty)
}

@Test func semanticDoesNotTransferSMPTE314SentinelRuleToIEC() throws {
  let noInfo = try semantics(semanticFrame()).packs.filter { $0.typeHex == "0xFF" }
  #expect(!noInfo.isEmpty)
  #expect(noInfo.allSatisfy { $0.fields.isEmpty })
  #expect(noInfo.allSatisfy { $0.status.contains("No-information candidate") && $0.status.contains("discrepancy") })
}

@Test func semanticSMPTE525TitleTimecodeDecodesOnlyNormativeFields() throws {
  var frame = semanticFrame(smpte: true)
  frame.replaceSubrange(86..<91, with: [0x13, 0x52, 0xb4, 0xa3, 0xc1])
  let report = try semantics(frame)
  let timecode = try #require(report.packs.first { $0.typeHex == "0x13" })
  #expect(timecode.sourceByteOffsets == [86])
  #expect(timecode.rawHex == "13 52 B4 A3 C1")
  #expect(timecode.fields.first { $0.id == "TC_HOURS" }?.meaning == "01")
  #expect(timecode.fields.first { $0.id == "TC_MINUTES" }?.meaning == "23")
  #expect(timecode.fields.first { $0.id == "TC_SECONDS" }?.meaning == "34")
  #expect(timecode.fields.first { $0.id == "TC_FRAMES" }?.meaning == "12")
  #expect(timecode.fields.first { $0.id == "DF" }?.meaning == "Drop-frame timecode")
  #expect(timecode.fields.first { $0.id == "PC" }?.meaning == "Odd")
  #expect(timecode.fields.filter { $0.id.hasPrefix("BGF") }.allSatisfy {
    $0.status == "uninterpreted"
  })
  #expect(!timecode.fields.contains { $0.id == "ARB" })
}

@Test func semanticSMPTE625TitleTimecodeUsesItsDistinctFlagLayout() throws {
  var frame = semanticFrame(smpte: true, pal: true)
  frame.replaceSubrange(86..<91, with: [0x13, 0xe4, 0xd9, 0xd8, 0xe3])
  let timecode = try #require(try semantics(frame).packs.first { $0.typeHex == "0x13" })
  #expect(timecode.fields.first { $0.id == "TC_HOURS" }?.meaning == "23")
  #expect(timecode.fields.first { $0.id == "TC_MINUTES" }?.meaning == "58")
  #expect(timecode.fields.first { $0.id == "TC_SECONDS" }?.meaning == "59")
  #expect(timecode.fields.first { $0.id == "TC_FRAMES" }?.meaning == "24")
  #expect(timecode.fields.first { $0.id == "PC" }?.meaning == "Odd")
  #expect(timecode.fields.first { $0.id == "ARB" }?.status == "uninterpreted")
  #expect(!timecode.fields.contains { $0.id == "DF" })
}

@Test func semanticTitleTimecodeRejectsMalformedBCDAndWrongScope() throws {
  var smpte = semanticFrame(smpte: true)
  smpte.replaceSubrange(86..<91, with: [0x13, 0x1a, 0x60, 0x00, 0x24])
  let fields = try #require(try semantics(smpte).packs.first { $0.typeHex == "0x13" }).fields
  #expect(fields.first { $0.id == "TC_FRAMES" }?.status == "invalid")
  #expect(fields.first { $0.id == "TC_SECONDS" }?.status == "invalid")
  #expect(fields.first { $0.id == "TC_HOURS" }?.status == "invalid")

  var iec = semanticFrame()
  iec.replaceSubrange(253..<258, with: [0x13, 0x12, 0x34, 0x23, 0x01])
  let retained = try #require(try semantics(iec).packs.first { $0.typeHex == "0x13" })
  #expect(retained.fields.isEmpty)
  #expect(retained.status.contains("outside subcode"))
}

@Test func semanticInvalidTransmissionNeverAuthorizesTimecodeFields() throws {
  var frame = semanticFrame(smpte: true)
  frame.replaceSubrange(86..<91, with: [0x13, 0x12, 0x34, 0x23, 0x01])
  frame[7] |= 0x80
  let timecode = try #require(try semantics(frame).packs.first { $0.typeHex == "0x13" })
  #expect(!timecode.fields.isEmpty)
  #expect(timecode.fields.allSatisfy { $0.status == "invalid" })
  #expect(timecode.status.contains("marks this section invalid"))
}

@Test func semanticUnapprovedCandidatePacksRemainRaw() throws {
  var binaryGroup = semanticFrame(smpte: true)
  binaryGroup.replaceSubrange(86..<91, with: [0x14, 1, 2, 3, 4])
  #expect(try semantics(binaryGroup).packs.first { $0.typeHex == "0x14" }?.fields.isEmpty == true)

  for type in [UInt8(0x52), 0x53] {
    var frame = semanticFrame(smpte: true)
    frame.replaceSubrange(483..<488, with: [type, 1, 2, 3, 4])
    #expect(try semantics(frame).packs.first { $0.typeHex == String(format: "0x%02X", type) }?.fields.isEmpty == true)
  }
  for type in [UInt8(0x62), 0x63, 0x65, 0x70, 0x71] {
    var frame = semanticFrame(smpte: true)
    frame.replaceSubrange(243..<248, with: [type, 1, 2, 3, 4])
    #expect(try semantics(frame).packs.first { $0.typeHex == String(format: "0x%02X", type) }?.fields.isEmpty == true)
  }
}

@Test func semanticMissingCoverageDoesNotFabricatePacks() throws {
  let report = try semantics(semanticFrame(audio: [255,255,255,255,255],
    videoControl: [255,255,255,255,255]))
  #expect(report.missingPrincipalPacks.count == 3)
  #expect(!report.packs.contains { ["0x50", "0x61"].contains($0.typeHex) })
}

@Test func semanticSeparateAudioChannelsAreNotFalseConflicts() throws {
  var frame = semanticFrame(smpte: true, audio: [0x50, 0x54, 0x10, 0xc0, 0xc0])
  for seq in 5..<10 { frame[seq * 12000 + 6 * 80 + 5] = 0x11 }
  let report = try semantics(frame)
  let audioModes = fields(report, pack: "0x50", id: "AM")
  #expect(Set(audioModes.map(\.rawValue)) == [0,1])
  #expect(audioModes.allSatisfy { $0.status == "interpreted" })
}

@Test func semanticHandlesUntrustedDecodedInventoryWithoutCrashing() throws {
  let original = try DVMetadataInventory.inspect(frame: semanticFrame(), ordinal: 0, byteOffset: 0)
  var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
  var extents = try #require(json["extents"] as? [[String: Any]])
  for i in extents.indices {
    extents[i]["bytes"] = Data([0x50]).base64EncodedString()
    extents[i]["sourceByteOffset"] = NSNumber(value: UInt64.max)
  }
  json["extents"] = extents
  let malformed = try JSONDecoder().decode(DVMetadataInventory.self,
    from: JSONSerialization.data(withJSONObject: json))
  let report = DVPackSemanticReport.inspect(malformed)
  #expect(report.packs.flatMap(\.fields).allSatisfy { $0.status != "interpreted" })
}

@Test func semanticOfflineReaderBoundsAndMixedFrameSizes() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-semantic-test-\(UUID().uuidString).dv")
  defer { try? FileManager.default.removeItem(at: url) }
  let original = semanticFrame() + semanticFrame(pal: true)
  try original.write(to: url, options: .withoutOverwriting)
  let second = try DVMetadataFrameReader.read(url: url, ordinal: 1)
  #expect(second.frameByteOffset == 120000 && second.frameByteCount == 144000)
  #expect(throws: (any Error).self) { try DVMetadataFrameReader.read(url: url, ordinal: .max) }
  #expect(try Data(contentsOf: url) == original)
  // Malformed earlier frames may not be skipped when assigning a later ordinal.
  var malformed = original
  malformed[80] = 0
  try malformed.write(to: url)
  #expect(throws: (any Error).self) { try DVMetadataFrameReader.read(url: url, ordinal: 1) }
  try Data(original.prefix(119999)).write(to: url)
  #expect(throws: (any Error).self) { try DVMetadataFrameReader.read(url: url, ordinal: 0) }
}
