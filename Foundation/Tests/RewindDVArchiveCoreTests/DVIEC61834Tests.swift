import Foundation
import Testing
@testable import RewindDVArchiveCore

private func iec(_ p: [UInt8], mic: Bool = false, mpeg: Bool = false, pro: Bool = false) throws -> DVIEC61834.Decoded {
  var c = DVIEC61834.Context(); c.mic = mic; c.mpeg = mpeg; c.professionalCamera = pro
  return try #require(DVIEC61834.decode(p,context:c))
}
private func value(_ d: DVIEC61834.Decoded, _ id: String) throws -> DVPackSemanticReport.Field {
  try #require(d.fields.first { $0.id == id })
}

@Test func iecTextHeaderAllCodesAndIndependentTypes() throws {
  for h: UInt8 in [8,24,40,56,72,88,104,120,136,152] {
    for tdp in 0...511 {
      let d = try iec([h,UInt8(tdp&255),UInt8(0xA0 | (tdp>>8) | 14),0x42,0xff],mpeg:h == 152)
      #expect(try value(d,"TDP").rawValue == tdp)
      #expect(try value(d,"OPN").rawValue == 7)
      #expect(try value(d,"TEXT_TYPE").status == ([104,152].contains(h) ? "interpreted":"reserved"))
    }
  }
  for code in UInt8(0)...255 {
    var c = DVIEC61834.Context(); c.menuTopic = true
    let d = try #require(DVIEC61834.decode([8,0,0,0x42,code],context:c))
    #expect(try value(d,"AREA_NO").rawValue == code>>5)
    #expect(try value(d,"TOPIC_TAG").rawValue == code&31)
    let topic = try iec([7,code,0,0,0x80])
    #expect(try value(topic,"LANGUAGE_TAG").rawValue == code>>5)
    #expect(try value(topic,"TOPIC_TAG").rawValue == code&31)
  }
  #expect(try value(iec([0x28,0,0x20,0x42,255]),"TEXT_TYPE").status == "reserved")
  #expect(try value(iec([0x18,0,0x20,0x42,255]),"TEXT_TYPE").status == "interpreted")
}
@Test func iecAbsoluteTrackAllBitsAndTagControls() throws {
  for bit in 0..<23 {
    let n = 1<<bit
    for bf in 0...1 {
      let d = try iec([0x0b,UInt8((n&127)<<1|bf),UInt8((n>>7)&255),UInt8((n>>15)&255),0xf0])
      #expect(try value(d,"ATN").rawValue == n)
      #expect(try value(d,"BF").rawValue == bf)
    }
  }
  #expect(try value(iec([0x0b,255,255,255,255]),"ATN").rawValue == 0x7fffff)
  for tag in UInt8(0)...15 {
    #expect(try value(iec([0x0b,1,0,0,0xf0|tag]),"TAG_ID").status == (tag < 12 ? "interpreted":tag == 15 ? "unavailable":"reserved"))
  }
  #expect(try value(iec([15,1,0,0,15]),"TAG_CONT").meaning == "Overrecording prohibited")
  #expect(try value(iec([15,1,0,0,31]),"TAG_CONT").meaning == "Already played")
}
@Test func iecProgrammeBinaryYearAndClock() throws {
  for year in 0...127 {
    let d = try iec([0x42,0xBB,0xB7,UInt8((year>>4)<<5)|31,UInt8((year&15)<<4)|12],mic:true)
    #expect(try value(d,"YEAR7").rawValue == year)
    #expect(try value(d,"YEAR7").status == (year < 100 ? "interpreted":year == 127 ? "unavailable":"invalid"))
    #expect(try value(d,"PROGRAMME_MINUTES").meaning == "59")
    #expect(try value(d,"PROGRAMME_HOURS").meaning == "23")
    #expect(try value(d,"PROGRAMME_DAY").meaning == "31")
    #expect(try value(d,"PROGRAMME_MONTH").meaning == "12")
    #expect(try value(d,"WEEKDAY").rawValue == 5)
  }
  for code in UInt8(0)...63 {
    #expect(try value(iec([0x42,code,0,1,1],mic:true),"PROGRAMME_MINUTES").status == (code < 60 ? "interpreted":code == 63 ? "unavailable":"invalid"))
  }
}
@Test func iecCatalogueAndRecordingWeekday() throws {
  let first = try iec([0x16,0x1e,0x32,0x54,0x76])
  #expect(first.fields.filter { $0.id.hasPrefix("N") }.map(\.rawValue) == [1,2,3,4,5,6,7])
  let second = try iec([0x16,0x8f,0x09,0x21,0xf3])
  #expect(second.fields.filter { $0.id.hasPrefix("N") }.map(\.rawValue) == [8,9,0,1,2,3])
  for h: UInt8 in [0x52,0x62,0x92] {
    for weekday: UInt8 in 0...7 {
      let d = try iec([h,0xc9,0xc1,weekday<<5|0x12,0x99],mpeg:h == 0x92)
      #expect(try value(d,"WEEKDAY").rawValue == weekday)
      #expect(try value(d,"REC_YEAR").meaning == "99")
      #expect(try value(d,"REC_MONTH").meaning == "12")
    }
  }
}
@Test func iecAudioAndVideoControlWidthsAreDistinct() throws {
  for byte in UInt8.min...UInt8.max {
    let a = try iec([0x51,0xff,byte,0xa0,0xff],mic:true)
    #expect(try value(a,"REC_M").rawValue == (byte>>3)&7)
    #expect(try value(a,"ICH").rawValue == byte&7)
    let tape = try iec([0x51,0xff,byte,0xa0,0xff])
    #expect(try value(tape,"ICH").status == (byte&7 == 7 ? "interpreted":"invalid"))
    let v = try iec([0x61,0xff,byte,byte,0xff])
    #expect(try value(v,"REC_M").rawValue == (byte>>4)&3)
    for (id,bit) in [("FF",7),("FS",6),("FC",5),("IL",4),("SF",3),("SC",2)] {
      #expect(try value(v,id).rawValue == (byte>>bit)&1)
    }
    #expect(try value(v,"BCS").rawValue == byte&3)
    #expect(try value(v,"BCS").status == (byte&3 < 2 ? "interpreted":"reserved"))
  }
}
@Test func iecTransparentPayloadAll28Bits() throws {
  for bit in 0..<28 {
    let n = UInt32(1)<<bit
    let d = try iec([0x66,UInt8((n&15)<<4)|1,UInt8((n>>4)&255),UInt8((n>>12)&255),UInt8((n>>20)&255)])
    #expect(try value(d,"DATA28").rawValue == n)
    #expect(try value(d,"SIGNAL_DATA").rawValue == n&0x3fff)
  }
  #expect(try value(iec([0x66,255,255,255,255]),"DATA28").rawValue == 0xfffffff)
}
@Test func iecCameraZoomAndDisputedPanRemainLossless() throws {
  for z in UInt8(0)...127 {
    let d = try iec([0x71,0xc0,0,0,z])
    let f = try value(d,"ZOOM_MAGNITUDE")
    #expect(f.rawValue == z)
    #expect(f.status == (z == 127 ? "unavailable":z == 126 || z&15 <= 9 ? "interpreted":"invalid"))
  }
  for (z,meaning): (UInt8,String) in [(0x79,"7.9×"),(0x7e,"≥ 8×"),(0x7f,"No information")] {
    #expect(try value(iec([0x71,0xc0,0,0,z]),"ZOOM_MAGNITUDE").meaning == meaning)
  }
  for code in UInt8(0)...63 {
    let f = try value(iec([0x71,0xc0,code,0,0]),"HP_SPEED")
    #expect(f.rawValue == code)
    #expect(f.confidence == ((30...61).contains(code) ? .conflictingEvidence:.normativeConfirmed))
    if (30...61).contains(code) { #expect(f.status == "uninterpreted") }
  }
  let gain = try iec([0x70,0xc0,7,31,0])
  #expect(try value(gain,"AGC_DB_CANDIDATE").confidence == .provisional)
  #expect(try value(gain,"AGC_DB_CANDIDATE").reference.contains("Sony"))
  #expect(try value(gain,"WB_PRESET").status == "unavailable")
}
@Test func iecAmendmentInventoryAndMPEGIsolation() throws {
  #expect(DVPackCatalog.entries.count == 256)
  #expect(Set(DVPackCatalog.entries.map(\.header)).count == 256)
  #expect(DVPackCatalog.entry(0x97).allocation == "named")
  #expect((0xa0...0xef).allSatisfy { DVPackCatalog.entry(UInt8($0)).allocation == "unassigned" })
  #expect(DVPackCatalog.entry(0xff).allocation == "maker-defined")
  #expect(DVPackCatalog.entry(0xff).evidence.contains("discrepancy"))
  for h: UInt8 in 0x90...0x9f {
    #expect(DVIEC61834.decode([h,0,0,0,0])?.fields.isEmpty == true)
    #expect(!DVPackCatalog.permitsSDObservation(h,context:"vaux-frame"))
  }
  let etn = try iec([0x97,0xa5,0x12,0x34,0x56],mpeg:true)
  #expect(try value(etn,"ETN").rawValue == 0x563412)
  #expect(try value(etn,"SPH").rawValue == 2)
  #expect(try value(etn,"PT").rawValue == 5)
  #expect(try value(etn,"ETN").status == "uninterpreted")
  let pid = try iec([0x95,0,2,0x34,0x52],mpeg:true)
  #expect(try value(pid,"PID").rawValue == 0x1234)
  #expect(try value(pid,"PID_TYPE").rawValue == 2)
}
@Test func iecAllDefinedLayoutsAccountForPayloadBits() throws {
  for entry in DVPackCatalog.entries where ["named","maker-code","maker-defined"].contains(entry.allocation) {
    for fill: UInt8 in [0,1,0x55,0xaa,0xff] {
      for pro in [false,true] {
        let d = try iec([entry.header,fill,fill,fill,fill],mic:true,mpeg:true,pro:pro)
        #expect(!d.layout.isEmpty)
        var masks = [UInt8](repeating:0,count:5)
        for f in d.layout {
          for slice in f.slices {
            #expect((1...4).contains(slice.byte))
            #expect(slice.width > 0 && slice.shift >= 0 && slice.width+slice.shift <= 8)
            let overlap = masks[slice.byte]&slice.mask
            #expect(overlap == 0 || f.id == "AGC_DB_CANDIDATE" || ["FMODE","RMODE"].contains(f.id),"Unexpected overlap \(entry.header) \(f.id)")
            masks[slice.byte] |= slice.mask
          }
        }
        #expect(Array(masks[1...4]) == [255,255,255,255],"Unaccounted payload bits \(entry.header)")
      }
    }
  }
}
@Test func iecMicAndTapeScopesRemainDistinct() {
  for h: UInt8 in [0,1,2,3,4,5,0x1f,0x42,0x7b] {
    for scope in ["subcode-frame","vaux-frame","aaux-channel1"] {
      #expect(!DVPackCatalog.permitsSDObservation(h,context:scope))
    }
  }
}

@Test func iecProfessionalPrecisionAndPhysicalConversions() throws {
  for h: UInt8 in [0x75,0x76,0x77,0x7c] {
    for code in 0...1023 {
      // A distinct channel value prevents swapped precision fragments passing.
      let d = try iec([h,UInt8(code>>2),0x80,0x40,0x40|UInt8(code&3)|0x18],pro:true)
      let suffix = [0x75:"PEDESTAL",0x76:"GAMMA",0x77:"DETAIL",0x7c:"FLARE"][Int(h)]!
      let f = try value(d,(h == 0x77 ? "MASTER_":"G_")+suffix)
      #expect(f.rawValue == code)
      #expect(f.status == (code == 1023 ? "unavailable":"interpreted"))
      #expect(try value(d,(h == 0x77 ? "H_":"R_")+suffix).rawValue == 514)
      #expect(try value(d,(h == 0x77 ? "V_":"B_")+suffix).rawValue == 257)
    }
  }
  for (p,id,meaning): ([UInt8],String,String) in [
    ([0x74,0x20,0x80,0x00,0x49],"MASTER_GAIN","0 dB"),
    ([0x74,0x20,0x80,0x00,0x49],"B_GAIN","-6 dB"),
    ([0x74,0x20,0x80,0x00,0x49],"ND_FILTER","0.0625 transmission ratio"),
    ([0x75,0x80,0x00,0xfe,0xff],"G_PEDESTAL","0 mV"),
    ([0x75,0x80,0x00,0xfe,0xff],"R_PEDESTAL","-320 mV"),
    ([0x76,0x80,0x00,0xfe,0xff],"G_GAMMA","0.45 gamma"),
    ([0x7c,0x80,0x00,0xfe,0xff],"R_FLARE","-64 %"),
    ([0x7e,0x80,0x80,255,255],"KNEE_POINT","700 mV"),
    ([0x73,0x08,0x20,0x64,0xcb],"IRIS","2 f-number"),
    ([0x73,0x08,0x20,0x64,0xcb],"ZOOM","50 m"),
    ([0x7f,0x0a,0x00,255,255],"SSP1","0.0009765625 s")
  ] { #expect(try value(iec(p,pro:true),id).meaning == meaning) }
  for form: UInt8 in [0,128] {
    let d = try iec([0x7d,form|64,64,64,64],pro:true)
    let expected = form == 0 ? [1,3,4,6]:[0,2,5,7]
    for area in expected { #expect(try value(d,"SHADING_AREA_\(area)").meaning == "0 %") }
  }
  #expect(try value(iec([0x7e,128,128,255,255]),"KNEE_SLOPE").confidence == .conflictingEvidence)
  var c = DVIEC61834.Context(); c.horizontalPeriodSeconds = 0.000064
  let shutter = try #require(DVIEC61834.decode([0x7f,255,255,125,128],context:c))
  #expect(try value(shutter,"CONSUMER_SHUTTER").meaning == "0.008 s")
}
@Test func iecEnvironmentAndCoordinates() throws {
  // BCD digits: 23.4 C, positive, 1013 hPa.
  let d = try iec([0x6c,0x48,0x23,0x3a,0x01])
  #expect(try value(d,"TEMPERATURE").meaning == "23.4 °C")
  #expect(try value(d,"PRESSURE").meaning == "1013 hPa")
  #expect(try value(iec([0x6c,0x49,0x23,0x01,0xf0]),"HEIGHT").meaning == "123.4 m")
  let longitude = try iec([0x6d,0x30,0x95,0x22,0xff])
  #expect(try value(longitude,"DEGREES").meaning == "122")
  #expect(try value(longitude,"HEMISPHERE").meaning == "West")
  #expect(try value(iec([0x6d,0x81,0,0x90,255]),"DEGREES").status == "invalid")
}
@Test func iecSourceCombinationsAndGenreVariants() throws {
  for (p,meaning): ([UInt8],String) in [
    ([0x60,255,255,0,255],"Camera"),([0x60,0xee,0xee,0x40,255],"MUSE line"),
    ([0x60,255,255,0x40,255],"Line"),([0x60,0x12,0xf0,0x80,255],"Cable"),
    ([0x60,0x12,0xf0,0xc0,0],"Tuner"),([0x60,0xee,0xee,0xc0,255],"Prerecorded tape"),
    ([0x60,255,255,0xc0,255],"No information")
  ] { #expect(try value(iec(p),"SRC").meaning == meaning) }
  #expect(try value(iec([0x60,0x12,0xf0,0,255]),"SRC").status == "invalid")
  var c = DVIEC61834.Context(); c.genreBasicCategory = 2
  let g = try #require(DVIEC61834.decode([6,0x14,0xff,0xf9,0x8b],context:c))
  #expect(try value(g,"CATEGORY").meaning == "Sports: Tennis")
  #expect(try value(g,"ORN0").meaning == "Wimbledon")
  #expect(try value(g,"ORN1").status == "unavailable")
  #expect(try value(g,"ORN2").meaning == "Championship")
  #expect(try value(iec([6,0x14,0x7f,0xf9,0x8b]),"ORN0").status == "reserved")
}
@Test func iecContextAlternativesDoNotInventCompanions() throws {
  for h: UInt8 in [0x13,0x23,0x33,0x43,0x53,0x63,0x93] {
    var c = DVIEC61834.Context(); c.mpeg = true
    #expect(try value(#require(DVIEC61834.decode([h,0,0,0,0],context:c)),"S1").status == "uninterpreted")
    c.binaryCompanion = false
    let d = try #require(DVIEC61834.decode([h,0x40,0x80,0x80,0xc0],context:c))
    if h == 0x13 { #expect(try value(d,"BF").rawValue == 0) }
    else { #expect(try value(d,"S2").status == "invalid") }
    c.binaryCompanion = true
    #expect(try value(#require(DVIEC61834.decode([h,0,0,0,0],context:c)),"S2").status == "uninterpreted")
  }
  for system in [0,1,3] {
    var c = DVIEC61834.Context(); c.teletextSystem = system
    let d = try #require(DVIEC61834.decode([12,0x12,0x34,0x56,0x78],context:c))
    #expect(d.layout.reduce(0) { $0+$1.slices.reduce(0) { $0+$1.width } } == 32)
    #expect(try value(d,system == 0 ? "PROGRAMME":"PAGE").meaning == (system == 3 ? "12":"412"))
  }
  for h: UInt8 in [0xf0,0xf1,0xfe,0xff] {
    #expect(DVIEC61834.decode([h,0x12,0x34,0x56,0x78]) != nil)
  }
  #expect(try value(iec([0xf0,0x12,0x34,0x56,0x78]),"OPTION_COUNT").rawValue == 0x234)
  for n in 0...4 { #expect(DVIEC61834.decode(Array(repeating:0,count:n))?.fields.isEmpty == true) }
}
@Test func iecTextAndLineSequencesPreservePartialAndPadding() throws {
  typealias O = DVIECSequences.Observation
  let text = [O([0x18,2,0x0e,0x42,255]),O([0x19,65,66,255,255]),O([0x19,67,68,69,70])]
  let complete = try #require(DVIECSequences.assemble(text).first)
  #expect(complete.payload == [65,66,255,255,67,68,69,70])
  #expect(complete.status == "complete byte queue" && complete.characterSets?["GL"] == 0x42)
  #expect(DVIECSequences.assemble(Array(text.prefix(2))).first?.status == "incomplete byte queue")
  #expect(DVIECSequences.assemble(text+text).count == 2)
  #expect(DVIECSequences.assemble([text[0],O([0x19,0,0,0,0],qualified:false),text[2]]).first?.payload == [])
  for (q,width) in [(0,2),(1,4),(2,8)] {
    let header = O([0x80,20,0xc8,3,UInt8(q<<6)])
    let line = try #require(DVIECSequences.assemble([header,O([0x81,0xff,0xff,0xff,0xff])]).first)
    let component = try #require(line.components?.first)
    #expect(component.samples == Array(repeating:UInt8((1<<width)-1),count:3))
    #expect(component.status == "complete")
    #expect(component.padding.count == 32/width-3)
    let bad = DVIECSequences.assemble([header,O([0x81,0xff,0xff,0xff,0])]).first
    #expect(bad?.components?.first?.status == "invalid padding")
  }
  let paired = DVIECSequences.assemble([O([0x80,20,0xc8,6,128]),O([0x82,1,2,3,255]),O([0x83,4,5,6,255])],chroma:.paired)
  #expect(paired.first?.components?.map(\.samples) == [[1,2,3],[4,5,6]])
  #expect(paired.first?.components?.allSatisfy { $0.status == "complete" } == true)
  #expect(DVIECSequences.level(3,bits:2) == 192)
  #expect(DVIECSequences.level(15,bits:4) == 240)
  #expect(DVIECSequences.level(0,bits:4) == nil)
  #expect(DVIECSequences.level(255,bits:8) == 255)
  for pal in [false,true] { for id in UInt8(0)...255 {
    let t = DVIECSequences.teletextID(id,isPAL:pal)
    #expect(t.raw == id && t.system == id>>6 && t.lineCode == id&31)
    #expect(t.lineCode == 31 ? t.status == "terminate":true)
  } }
  #expect(DVIECSequences.teletextID(0x20,isPAL:false).lineNumber == 272)
  #expect(DVIECSequences.teletextID(0x20,isPAL:true).lineNumber == 318)
  #expect(DVIEC61834.characterSets(code:0x6c,option:5)?["GR"] == 0x53)
  #expect(DVIEC61834.characterSets(code:0x6c,option:0)?["GR"] == 0x59)
  #expect(DVIEC61834.characterSets(code:0x6c,option:7) == nil)
}

@Test func iecKeyEmbeddedFAndMPEGServiceRemainFaithful() throws {
  #expect(DVIEC61834.keyDigits([0x0d,0x24,0xe1,0x3f,0xff]) == "3FE124")
  #expect(DVIEC61834.keyDigits([0x0d,255,255,255,255]) == "")
  #expect(DVIEC61834.keyDigits([0x0d,0]) == nil)
  let service = try value(iec([0x90,0x12,0x34,0,255],mpeg:true),"SERVICE_ID")
  #expect(service.rawValue == 0x3412 && service.status == "uninterpreted")
  #expect(service.qualifier?.contains("byte significance") == true)
  for st in [4,5,6] {
    var c = DVIEC61834.Context(); c.mpeg = true; c.mpegSourceType = st
    let d = try #require(DVIEC61834.decode([0x91,0,0xff,0,0],context:c))
    #expect(try value(d,"TPL").meaning == (st == 4 ? "2 repetitions":"No repetition"))
    #expect(try value(d,"REC_M").status == "invalid")
  }
}

@Test func iecSequenceScopeAndReportRoundTrip() throws {
  func report(section: UInt8) -> DVPackSemanticReport {
    let bytes: [[UInt8]] = [[0x80,20,0xc8,3,128],[0x81,1,2,3,255]]
    let packs = bytes.enumerated().map { index, raw in
      var p = DVPackSemanticReport.Pack(id:"test-\(index)",typeHex:String(format:"0x%02X",raw[0]),name:"Synthetic",
        rawHex:raw.map { String(format:"%02X",$0) }.joined(separator:" "),sourceByteOffsets:[],status:"Synthetic",fields:[])
      p.locations = [.init(frameOrdinal:0,frameByteOffset:nil,sequence:0,section:section,block:0,slot:index,
        localByteOffset:3+index*5,absoluteByteOffset:nil,transmission:"valid")]
      return p
    }
    return .init(schemaVersion:3,frameOrdinal:0,frameByteOffset:nil,frameSHA256:"synthetic",format:"IEC 61834 consumer DV",
      formatEvidence:"synthetic",packs:packs,missingPrincipalPacks:[])
  }
  #expect(DVIECSequences.inspect(report(section:3),isPAL:false).isEmpty)
  #expect(DVIECSequences.inspect(report(section:1),isPAL:false).isEmpty)
  var current = report(section:2)
  current.sequences = DVIECSequences.inspect(current,isPAL:false)
  #expect(current.sequences?.first?.components?.first?.samples == [1,2,3])
  let encoder = JSONEncoder(), decoder = JSONDecoder()
  #expect(try decoder.decode(DVPackSemanticReport.self,from:encoder.encode(current)) == current)
  var json = try #require(JSONSerialization.jsonObject(with:encoder.encode(current)) as? [String:Any])
  json.removeValue(forKey:"sequences"); json["schema_version"] = 2
  let legacy = try decoder.decode(DVPackSemanticReport.self,from:JSONSerialization.data(withJSONObject:json))
  #expect(legacy.schemaVersion == 2 && legacy.sequences == nil)
}
