import Foundation
import Testing
@testable import RewindDVArchiveCore

private func reconciled(_ raw: [UInt8], offset: Int = 86, smpte: Bool = false,
  invalid: Bool = false, repeated: Bool = false) throws -> DVPackSemanticReport {
  var frame = semanticFrame(smpte: smpte,
    audioControl: raw[0] == 0x51 ? raw : [0x51,0,7,0x80,0xff],
    videoControl: raw[0] == 0x61 ? raw : [0x61,0,0xc8,0xf0,0xff])
  frame.replaceSubrange(offset..<offset + 5, with: raw)
  if repeated { frame.replaceSubrange(offset + 12_000..<offset + 12_005, with: raw) }
  if invalid { frame[offset == 86 ? 7 : offset == 483 ? 5 : 6] |= 128 }
  return DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 2, byteOffset: 900))
}
private func reconciledPack(_ report: DVPackSemanticReport, _ type: UInt8) throws -> DVPackSemanticReport.Pack {
  try #require(report.packs.first { $0.typeHex == String(format: "0x%02X", type) })
}
private func field(_ fields: [DVPackSemanticReport.Field], _ id: String) throws -> DVPackSemanticReport.Field {
  try #require(fields.first { $0.id == id })
}

@Test func reconciledTextFieldsKeepPackSpecificEnumerationAndAllNineBits() throws {
  for type: UInt8 in [0x08, 0x18, 0x68] {
    for low in 0...255 {
      for high: UInt8 in [0, 1] {
        let p: [UInt8] = [type, UInt8(low), 0xae | high, 0, 0xbd]
        let f = DVCorpusSemantics.enrich([], pack: p, isPAL: false)
        #expect(try field(f, "TDP").rawValue == UInt32(low + Int(high) * 256))
        #expect(try field(f, "OPN").rawValue == 7)
        #expect(try field(f, "TEXT_TYPE").rawValue == 10)
        #expect(f.allSatisfy { $0.confidence == .provisional && $0.status == "uninterpreted" })
        if type == 0x08 {
          #expect(try field(f, "AREA_NO").rawValue == 5)
          #expect(try field(f, "TOPIC_TAG").rawValue == 29)
        } else { #expect(!f.contains { $0.id == "AREA_NO" }) }
      }
    }
    for pc2: UInt8 in 0...255 {
      let f = DVCorpusSemantics.enrich([], pack: [type, 0, pc2, 0, 0], isPAL: false)
      #expect(try field(f, "OPN").rawValue == UInt32(Int(pc2) / 2 % 8))
      #expect(try field(f, "TEXT_TYPE").rawValue == UInt32(Int(pc2) / 16))
    }
    let offset = type == 0x68 ? 253 : 86
    let p = try reconciledPack(reconciled([type, 0x55, 0xff, 0, 0], offset: offset), type)
    #expect(try field(p.fields, "TDP").rawValue == 341)
    #expect(p.rawComponents?.contains { $0.id.hasSuffix("option_raw") && $0.numeric?.bitWidth == 3 } == true)
  }
}

@Test func reconciledATNFormTAGPreserves23BitsAndIndependentBlankFlag() throws {
  // Walking bits detect significance/order errors; endpoints cover all-one ATN.
  for number: UInt32 in [0, 1, 127, 128, 32767, 32768, 0x7fffff] + (0..<23).map({ UInt32(1) << $0 }) {
    for blank: UInt8 in [0, 1] {
      let raw: [UInt8] = [0x0b, UInt8(number % 128) * 2 + blank,
        UInt8(number / 128 % 256), UInt8(number / 32768), 0xf0]
      let f = DVCorpusSemantics.enrich([], pack: raw, isPAL: false)
      #expect(try field(f, "ATN_OR_LENGTH").rawValue == number)
      #expect(try field(f, "BF").rawValue == UInt32(blank))
      #expect(try field(f, "TEXT").rawValue == 1)
      #expect(try field(f, "TT").rawValue == 1)
      #expect(try field(f, "HL").rawValue == 1)
    }
  }
  for pc4: UInt8 in 0...255 {
    let f = DVCorpusSemantics.enrich([], pack: [0x0b, 0, 0, 0, pc4], isPAL: false)
    for (id, divisor): (String, Int) in [("TEXT",128), ("TT",64), ("HL",32)] {
      #expect(try field(f,id).rawValue == UInt32(Int(pc4) / divisor % 2))
    }
    let tag = try field(f, "TAG_ID")
    #expect(tag.rawValue == UInt32(Int(pc4) % 16))
    #expect(tag.status == ((12...14).contains(Int(pc4) % 16) ? "reserved" : "uninterpreted"))
    #expect(try field(f, "TAG_FIXED").status == (Int(pc4) / 16 % 2 == 0 ? "invalid" : "uninterpreted"))
  }
  let title = DVCorpusSemantics.enrich([], pack: [0x13, 1, 0, 0, 0], isPAL: false)
  #expect(!title.contains { $0.id == "BF" })
}

@Test func reconciledProgrammeDateIsBinaryAndHasNoCenturyPolicy() throws {
  // 59, 23, 29 and year code 109 are deliberately not BCD encodings.
  let p: [UInt8] = [0x42, 0xbb, 0xb7, 0xdd, 0xd2]
  let report = try reconciled(p)
  #expect(try reconciledPack(report,0x42).fields.isEmpty) // MIC-only, not tape
  var context = DVIEC61834.Context(); context.mic = true
  let f = try #require(DVIEC61834.decode(p,context:context)).fields
  for (id, raw): (String, UInt32) in [("PROGRAMME_MINUTES", 59), ("REC_MODE", 2),
    ("PROGRAMME_HOURS", 23), ("WEEKDAY", 5), ("PROGRAMME_DAY", 29),
    ("PROGRAMME_MONTH", 2), ("YEAR7", 109)] {
    #expect(try field(f, id).rawValue == raw)
  }
  #expect(try field(f, "YEAR7").numeric?.bitWidth == 7)
  #expect(f.allSatisfy { $0.confidence == .normativeConfirmed })
  #expect(try field(f,"YEAR7").status == "invalid")
  #expect(!f.contains { $0.meaning.contains("20") || $0.meaning.contains("19") })
  for year in 0...127 {
    let f = DVCorpusSemantics.enrich([], pack: [0x42, 0, 0, UInt8(year / 16) * 32 | 1,
      UInt8(year % 16) * 16 | 1], isPAL: false)
    #expect(try field(f, "YEAR7").rawValue == UInt32(year))
  }
  for (byte, id, divisor, modulus, valid): (Int, String, Int, Int, ClosedRange<Int>) in [
    (1,"PROGRAMME_MINUTES",1,64,0...59), (2,"PROGRAMME_HOURS",1,32,0...23),
    (3,"PROGRAMME_DAY",1,32,1...31), (4,"PROGRAMME_MONTH",1,16,1...12)] {
    for value in 0...255 {
      var raw: [UInt8] = [0x42, 1, 1, 1, 1]; raw[byte] = UInt8(value)
      let f = try field(DVCorpusSemantics.enrich([], pack: raw, isPAL: false), id)
      #expect(f.rawValue == UInt32(value / divisor % modulus))
      #expect(f.status == (valid.contains(value % modulus) ? "uninterpreted" : "invalid"))
      let all = DVCorpusSemantics.enrich([], pack: raw, isPAL: false)
      #expect(try field(all,"PROGRAMME_REC_MODE").rawValue == UInt32(Int(raw[1]) / 64))
      #expect(try field(all,"PROGRAMME_WEEKDAY").rawValue == UInt32(Int(raw[2]) / 32))
    }
  }
}

@Test func reconciledAAUXAndVAUXHaveIndependentWidthsAndTapeApplicability() throws {
  for value: UInt8 in 0...255 {
    let report = try reconciled([0x51, 0, value, 0x80, 0xff], offset: 483)
    let f = try reconciledPack(report, 0x51).fields
    #expect(try field(f, "REC_M").rawValue == UInt32(Int(value) / 8 % 8))
    let insert = try field(f, "ICH")
    #expect(insert.rawValue == UInt32(Int(value) % 8))
    #expect(insert.status == (value % 8 == 7 ? "interpreted" : "invalid"))
    #expect(!insert.meaning.contains("CH1"))
    let video = try reconciledPack(reconciled([0x61, 0, value, value, 0xff], offset: 253), 0x61).fields
    #expect(try field(video, "REC_M").rawValue == UInt32(Int(value) / 16 % 4))
    for (id, divisor, width): (String, Int, Int) in [
      ("FF",128,2), ("FS",64,2), ("FC",32,2), ("IL",16,2), ("SF",8,2), ("SC",4,2), ("BCS",1,4)] {
      #expect(try field(video, id).rawValue == UInt32(Int(value) / divisor % width))
    }
  }
  let professional = try reconciledPack(reconciled([0x51,0,0,0x80,0xff],offset:483,smpte:true),0x51)
  #expect(!professional.fields.contains { $0.id == "ICH" || $0.id == "REC_M" })
}

@Test func reconciledTransparentPayloadPreserves28BitsWithoutTypeWideMeaning() throws {
  for type: UInt8 in [0x56, 0x66] {
    for payload: UInt32 in [0, 1, 15, 16, 0x01234567, 0x0fffffff] + (0..<28).map({ UInt32(1) << $0 }) {
      for selector: UInt8 in 0...15 {
        let raw: [UInt8] = [type, UInt8(payload % 16) * 16 | selector,
          UInt8(payload / 16 % 256), UInt8(payload / 4096 % 256), UInt8(payload / 1048576)]
        let f = DVCorpusSemantics.enrich([], pack: raw, isPAL: false)
        #expect(try field(f,"DATA28").rawValue == payload)
        #expect(try field(f,"DATA28").numeric?.bitWidth == 28)
        #expect(try field(f,"DATA_TYPE").rawValue == UInt32(selector))
        #expect(f.allSatisfy { $0.status == "uninterpreted" })
      }
    }
    let offset = type == 0x56 ? 483 : 253
    let raw: [UInt8] = [type, 0x71, 0x56, 0x34, 0x12]
    let report = try reconciled(raw, offset: offset, repeated: true)
    let pack = try reconciledPack(report, type)
    #expect(try field(pack.fields,"DATA28").rawValue == 0x01234567)
    #expect(pack.rawHex == String(format:"%02X 71 56 34 12",type))
    #expect(pack.observationCount == 2 && pack.locations?.count == 2)
    #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
    let invalid = try reconciledPack(reconciled(raw,offset:offset,invalid:true),type)
    #expect(invalid.fields.allSatisfy { $0.status == "invalid" })
    #expect(try reconciledPack(reconciled(raw,offset:offset,smpte:true),type).fields.isEmpty)
  }
}

@Test func reconciledDateWeekdayZoomAndPanFixturesRetainEncodedValues() throws {
  for type: UInt8 in [0x52,0x62] {
    for weekday: UInt8 in 0...7 {
      let raw: [UInt8] = [type,0xff,0x29,weekday * 32 | 2,0x24]
      let f = DVCorpusSemantics.enrich(DVSupplementalPackSemantics.decode(raw,isPAL:false),pack:raw,isPAL:false)
      #expect(try field(f,"WEEKDAY").rawValue == UInt32(weekday))
      #expect(try field(f,"REC_MONTH").meaning == "02")
      #expect(DVPackSemanticReport.recordedDate(from:raw) == "YY 24-02-29 (century unknown)")
    }
  }
  for (zoom,meaning,status): (UInt8,String,String) in [(0x79,"7.9×","interpreted"), (0x7e,"≥ 8×","interpreted"), (0x7f,"No information","unavailable")] {
    let raw: [UInt8] = [0x71,0xc0,0x3d,0xff,zoom]
    let pack = try reconciledPack(reconciled(raw,offset:253),0x71)
    let z = try field(pack.fields,"ZOOM_MAGNITUDE")
    #expect(z.rawValue == UInt32(zoom) && z.meaning == meaning && z.status == status)
    #expect(z.confidence == .normativeConfirmed)
    let pan = try field(pack.fields,"HP_SPEED")
    #expect(pan.rawValue == 0x3d && pan.status == "uninterpreted" && pan.confidence == .conflictingEvidence)
    #expect(pack.rawHex.contains("3D"))
  }
  let p = DVCorpusSemantics.enrich([],pack:[0x71,0,0x1d,0,0],isPAL:false)
  #expect(try field(p,"HP_SPEED").rawValue == 0x1d)
  let c = DVCorpusSemantics.enrich(DVSupplementalPackSemantics.decode([0x70,0xc0,7,0x1f,0x7f],isPAL:false),pack:[0x70,0xc0,7,0x1f,0x7f],isPAL:false)
  #expect(try field(c,"WB_PRESET").status == "unavailable")
  let gain = try field(c,"AGC_DB_CANDIDATE")
  #expect(gain.meaning == "18 dB (patent candidate)" && gain.confidence == .provisional)
  #expect(gain.reference.contains("MANUFACTURER_REFERENCE") && !gain.reference.contains("PRIMARY_STANDARD"))
}

@Test func reconciledCameraAllocationNowHasPrimaryReferences() {
  #expect(DVPackCatalog.entry(0x72).allocation == "reserved")
  #expect(DVPackCatalog.entry(0x7a).allocation == "reserved")
  for header: UInt8 in 0x70...0x7f {
    #expect(DVPackCatalog.entry(header).confidence == .normativeConfirmed)
    #expect(DVPackCatalog.entry(header).evidence.contains("IEC 61834-4:1998"))
  }
}
