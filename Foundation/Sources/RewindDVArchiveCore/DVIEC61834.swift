// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Part 4 interpretation of preserved pack bytes. Context is supplied by the
/// caller; a byte pattern never establishes the recording format or MIC identity.
public enum DVIEC61834 {
  public static let interpretationVersion = 4
  public struct Context: Sendable {
    public var isPAL = false
    public var mic = false
    public var mpeg = false
    public var professionalCamera = false
    public var menuTopic: Bool? = nil
    public var binaryCompanion: Bool? = nil
    public var horizontalPeriodSeconds: Double? = nil
    public var teletextSystem: Int? = nil
    public var mpegSourceType: Int? = nil
    public var genreBasicCategory: Int? = nil
    public init() {}
  }
  public struct Slice: Codable, Equatable, Sendable {
    public let byte: Int
    public let shift: Int
    public let width: Int
    public var mask: UInt8 { UInt8(((1 << width) - 1) << shift) }
    public init(_ byte: Int, _ shift: Int = 0, _ width: Int = 8) {
      self.byte = byte; self.shift = shift; self.width = width
    }
  }
  public struct LayoutField: Codable, Equatable, Sendable {
    public let id: String
    /// Least-significant fragment first; no byte-order inference by consumers.
    public let slices: [Slice]
    public let encoding: String
    public let reference: String
    public var rangeLower: Int? = nil
    public var rangeUpper: Int? = nil
    public var sentinel: Int? = nil
    public var fixed: Int? = nil
    public var labels: [Int:String]? = nil
  }
  public struct Decoded: Sendable {
    public let fields: [DVPackSemanticReport.Field]
    public let layout: [LayoutField]
  }
  static func reference(_ header: UInt8) -> String {
    let group = Int(header >> 4), subclause = Int(header & 15) + 1
    return group == 9
      ? "PRIMARY_STANDARD: IEC 61834-4:1998/AMD1:2010 §13.\(subclause)"
      : "PRIMARY_STANDARD: IEC 61834-4:1998 §\(group == 15 ? 12 : group + 3).\(subclause)"
  }
  struct Reader {
    let bytes: [UInt8]
    let context: Context
    var fields: [DVPackSemanticReport.Field] = []
    var layout: [LayoutField] = []
    var ref: String { reference(bytes[0]) }
    mutating func add(_ id: String, _ slices: [Slice], encoding: String = "binary",
      range: ClosedRange<Int>? = nil, sentinel: Int? = nil, labels: [Int: String]? = nil,
      fixed: Int? = nil, unit: String = "", rule: String = "", note: String? = nil,
      convert: ((Double) -> Double)? = nil) {
      var value: UInt32 = 0, shift = 0
      for s in slices {
        value |= UInt32((bytes[s.byte] & s.mask) >> s.shift) << shift
        shift += s.width
      }
      var number = Int(value), status = "interpreted", meaning = "\(value)"
      if encoding == "BCD" {
        number = 0; var v = value, scale = 1
        repeat {
          if v & 15 > 9 { status = "invalid" }
          number += Int(v & 15) * scale; v >>= 4; scale *= 10
        } while v != 0
      }
      if sentinel == Int(value) { status = "unavailable"; meaning = "No information" }
      else if let fixed {
        status = value == fixed ? "interpreted" : "invalid"
        meaning = value == fixed ? "Required bits conform" : "Required bits differ; source retained"
      } else if status == "invalid" || (range != nil && !range!.contains(number)) {
        status = "invalid"; meaning = "Invalid \(encoding) code \(value)"
      } else if let labels {
        meaning = labels[number] ?? "Reserved code"
        if labels[number] == nil { status = "reserved" }
      } else if encoding == "opaque" {
        status = "uninterpreted"; meaning = "Preserved code \(value)"
      } else {
        meaning = convert.map { String(format: "%.12g", $0(Double(number))) } ?? (encoding == "BCD" && shift > 4 ? String(format:"%02d",number):"\(number)")
        if !unit.isEmpty { meaning += (unit == "×" ? "":" ") + unit }
      }
      fields.append(.init(id: id, name: id.replacingOccurrences(of: "_", with: " "), rawValue: value,
        meaning: meaning, status: status, reference: ref, confidence: .normativeConfirmed,
        qualifier: note, numeric: .init(bitWidth: shift, unit: unit, relation: status == "interpreted" ? "exact" : "raw", rule: rule.isEmpty ? encoding : rule)))
      layout.append(.init(id: id, slices: slices, encoding: encoding, reference: ref, rangeLower:range?.lowerBound,rangeUpper:range?.upperBound,sentinel:sentinel,fixed:fixed,labels:labels))
    }
    mutating func field(_ id: String, _ byte: Int, _ shift: Int = 0, _ width: Int = 8,
      encoding: String = "binary", range: ClosedRange<Int>? = nil, sentinel: Int? = nil,
      labels: [Int:String]? = nil, fixed: Int? = nil, unit: String = "", rule: String = "",
      note: String? = nil, convert: ((Double)->Double)? = nil) {
      add(id, [Slice(byte, shift, width)], encoding: encoding, range: range, sentinel: sentinel,
        labels: labels, fixed: fixed, unit: unit, rule: rule, note: note, convert: convert)
    }
    mutating func qualify(_ id: String, meaning: String, status: String = "uninterpreted",
      confidence: DVMetadataConfidence = .normativeConfirmed, source: String? = nil, note: String? = nil, relation: String? = nil,
      unit: String? = nil, rule: String? = nil) {
      guard let i = fields.firstIndex(where: { $0.id == id }) else { return }
      let f = fields[i]
      fields[i] = .init(id: f.id, name: f.name, rawValue: f.rawValue, meaning: meaning, status: status,
        reference: source ?? f.reference, confidence: confidence, qualifier: note ?? f.qualifier, numeric: f.numeric.map { .init(bitWidth:$0.bitWidth,unit:unit ?? $0.unit,relation:relation ?? (status == "interpreted" ? $0.relation:confidence == .conflictingEvidence ? "disputed":"raw"),rule:rule ?? $0.rule) })
    }
    mutating func micFlag(_ id: String, _ byte: Int, _ shift: Int, _ zero: String, _ one: String) {
      field(id, byte, shift, 1, labels: [0:zero, 1:one], fixed: context.mic ? nil : 1,
        note: "MIC meaning applies only to MIC; tape requires one.")
    }
    mutating func opaquePayload() { for b in 1...4 { field("PC\(b)", b, encoding: "opaque") } }
    mutating func atn(_ lowFlag: String = "BF") {
      add("ATN", [.init(1,1,7), .init(2), .init(3)], unit: "tracks", note: "Recorded position reference; not a measured current deck position.")
      if lowFlag == "TT" { micFlag("TT",1,0,"Event may be absent on tape","Event present on tape") }
      else { field("BF",1,0,1,labels:[0:"Discontinuity before this track",1:"No discontinuity before this track"]) }
    }
    mutating func clock(position: Bool) {
      field("FRAMES",1,0,6,encoding:"BCD",range:0...(context.isPAL ? 24:29),sentinel:position ? nil:63)
      field("SECONDS",2,0,position ? 8:7,encoding:"BCD",range:0...59,sentinel:position ? nil:127)
      field("MINUTES",3,0,position ? 8:7,encoding:"BCD",range:0...59,sentinel:position ? nil:127)
      field("HOURS",4,0,position ? 8:6,encoding:"BCD",range:0...23,sentinel:position ? nil:63)
      if position {
        field("DF",1,6,1,labels:[0:"Drop-frame sequence",1:"Non-drop-frame sequence"],note:"Consumer digital VCR requires zero; external SMPTE/EBU sequence rules apply. This is not the title-timecode S1 field.")
        field("PC1_FIXED",1,7,1,fixed:1)
      } else {
        for (id,b,s) in [("S1",1,6),("S2",1,7),("S3",2,7),("S4",3,7),("S5",4,6),("S6",4,7)] {
          let blankFlag = bytes[0] == 0x13 && id == "S2" && context.binaryCompanion == false
          field(blankFlag ? "BF":id,b,s,1,encoding: context.binaryCompanion == true ? "opaque":"binary",
            fixed: context.binaryCompanion == false && !blankFlag ? 1:nil,
            note:"S1–S6 require the companion binary pack and applicable SMPTE/EBU profile.")
          if context.binaryCompanion == nil {
            qualify(id,meaning:"Companion-pack context not established; raw flag retained")
          }
        }
      }
    }
    mutating func date() {
      field("ZONE_CODE",1,0,6,encoding:"BCD",range:0...23,sentinel:63,unit:"hours modulo 24 from GMT",
        note:"Encoded modulo-day offset. No signed-zone or century policy inferred.")
      field("TM",1,6,1,labels:[0:"30-minute component",1:"No 30-minute component"])
      field("DS",1,7,1,labels:[0:"Daylight-saving time",1:"Normal time"])
      field("DAY",2,0,6,encoding:"BCD",range:1...31,sentinel:63)
      field("DATE_FIXED",2,6,2,fixed:3)
      field("MONTH",3,0,5,encoding:"BCD",range:1...12,sentinel:31)
      field("WEEKDAY",3,5,3,sentinel:7,labels:weekdays)
      field("YEAR",4,encoding:"BCD",range:0...99,sentinel:255,note:"Last two year digits; century is application policy.")
      let day = Int(bytes[2]&15) + 10*Int((bytes[2]>>4)&3)
      let month = Int(bytes[3]&15) + 10*Int((bytes[3]>>4)&1)
      let year = Int(bytes[4]&15) + 10*Int(bytes[4]>>4)
      if (1...12).contains(month), fields.contains(where: {$0.id == "DAY" && $0.status == "interpreted"}),
         fields.contains(where: {$0.id == "MONTH" && $0.status == "interpreted"}) {
        // February 29 in year 00 cannot establish a century or leap status.
        let validYear = fields.contains { $0.id == "YEAR" && $0.status == "interpreted" }
        let limit = [31,!validYear || year % 4 == 0 ? 29:28,31,30,31,30,31,31,30,31,30,31][month-1]
        if day > limit { qualify("DAY",meaning:"Impossible day/month combination; bytes retained",status:"invalid") }
      }
    }
  }
  /// §3.14: leading F nibbles are unused; embedded F remains a key digit.
  /// This describes recorded metadata and does not implement access control.
  public static func keyDigits(_ bytes: [UInt8]) -> String? {
    guard bytes.count == 5, bytes[0] == 0x0d else { return nil }
    let digits = bytes.dropFirst().reversed().flatMap { [$0>>4,$0&15] }
    return digits.drop(while: { $0 == 15 }).map { String($0,radix:16,uppercase:true) }.joined()
  }
  static let weekdays = [0:"Sunday",1:"Monday",2:"Tuesday",3:"Wednesday",4:"Thursday",5:"Friday",6:"Saturday"]
  static func dictionary(_ values: [String]) -> [Int:String] { Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset,$0.element) }) }

  /// Returns nil only for a family whose field implementation is still pending.
  /// A malformed input or inapplicable MPEG context returns no interpreted fields.
  public static func decode(_ bytes: [UInt8], context: Context = Context()) -> Decoded? {
    guard bytes.count == 5 else { return Decoded(fields:[],layout:[]) }
    let h = bytes[0]
    guard !(0x90...0x9f).contains(h) || context.mpeg else { return Decoded(fields:[],layout:[]) }
    var r = Reader(bytes:bytes,context:context)
    let low = h & 15
    if low == 8 && h < 0xa0 {
      r.add("TDP",[.init(1),.init(2,0,1)],unit:context.mic ? "text bytes after PC3":"following text packs")
      r.field("OPN",2,1,3,encoding:"opaque",note:"EBU SPB 492 option; seven also indicates unused.")
      var types = [0:"Name",1:"Memo",2:"Station",3:"Model",6:"Operator",8:"Outline",9:"Full screen",12:"One-byte font",13:"Two-byte font",14:"Graphic"]
      if ![0x08,0x78,0x88].contains(h) { types[7] = "Subtitle" }
      if [0x28,0x38].contains(h) { types.removeValue(forKey:2); types.removeValue(forKey:3) }
      if h == 0x78 { types[4] = "Lens"; types[5] = "Filter" }
      if h == 0x88 { types.removeValue(forKey:8) }
      if [0x68,0x98].contains(h) { types[10] = "Teletext header" }
      r.field("TEXT_TYPE",2,4,4,sentinel:15,labels:types)
      r.field("TEXT_CODE",3,labels:DVIEC61834.textCodeLabels,note:"§3.9 charset designation; glyph decoding additionally requires ISO 2022 and the designated national/teletext standard.")
      if h == 8 && !context.mic && context.menuTopic != false {
        r.field("AREA_NO",4,5,3,sentinel:7,labels:[0:"AAUX channel 1",1:"AAUX channel 2",2:"AAUX channel 3",3:"AAUX channel 4",4:"VAUX",5:"Subcode"])
        r.field("TOPIC_TAG",4,0,5,sentinel:31)
        if context.menuTopic == nil {
          for id in ["AREA_NO","TOPIC_TAG"] { r.qualify(id,meaning:"Menu-form candidate; menu/full-mode context not established") }
        }
      } else if context.mic { r.field("MIC_TEXT_BYTE0",4,encoding:"opaque",note:"First text byte; TDP counts bytes after PC3, not five-byte tape packs.") }
      else { r.field("TEXT_FIXED",4,fixed:255) }
    } else if low == 9 && h < 0xa0 {
      r.opaquePayload()
    } else if [0x10,0x11,0x20,0x21,0x30,0x31,0x40,0x41,0x0a,0x0e,0x1a,0x1e,0x2a,0x2e,0x3a,0x3e,0x4a,0x4e,0x5a,0x5e,0x6a,0x6e,0x8a,0x8e,0x9a,0x9e].contains(h) {
      r.clock(position:true)
    } else if [0x13,0x23,0x33,0x43,0x53,0x63,0x93].contains(h) {
      r.clock(position:false)
    } else if [0x14,0x24,0x34,0x44,0x54,0x64,0x94].contains(h) {
      for b in 1...4 { for n in 0...1 { r.field("BG\(2*b-1+n)",b,n*4,4,encoding:"opaque",note:"Binary-group interpretation requires the corresponding timecode flags and external SMPTE/EBU definition.") } }
    } else if [0x1b,0x2b,0x3b,0x4b,0x5b,0x6b,0x8b,0x9b].contains(h) {
      r.atn("TT"); r.micFlag("TEXT",4,7,"Text present","Text absent")
      r.genre(4)
      if h == 0x9b { r.qualify("GEN",meaning:"§13.12 diagram says PID TYPE; prose says GENRE. Neither interpretation selected.",confidence:.conflictingEvidence) }
    } else if [0x2f,0x3f,0x4f,0x5f,0x6f,0x8f,0x9f].contains(h) {
      r.atn()
      if [0x2f,0x3f].contains(h) { r.field("PC4_FIXED",4,fixed:255) }
      else {
        r.field("TNT",4,2,3,sentinel:7,fixed:context.mic ? nil:7)
        r.field("PC4_LOW_FIXED",4,0,2,fixed:3)
        if h == 0x4f {
          r.micFlag("PY",4,5,"Already played","Not yet played")
          r.micFlag("RP",4,6,"Overrecording prohibited","Overrecording allowed")
          r.field("SR",4,7,1,encoding:"opaque",note:"Track-pitch-dependent SP/reserved selector.")
        } else { r.field("PC4_FIXED",4,5,3,fixed:7) }
      }
    } else {
      switch h {
      case 0x07:
        r.field("LANGUAGE_TAG",1,5,3,labels:[0:"Main language",1:"Optional language 1",2:"Optional language 2",3:"Optional language 3",4:"Optional language 4",5:"Optional language 5",6:"Optional language 6",7:"Optional language 7"])
        r.field("TOPIC_TAG",1,0,5,sentinel:31,labels:[0:"Menu",1:"TOC"])
        if (2...30).contains(bytes[1]&31) { r.qualify("TOPIC_TAG",meaning:"§3.8 calls this reserved; §3.9 permits menu-defined topics",confidence:.conflictingEvidence) }
        r.field("RE",2,7,1,note:"Renewal toggle; meaning requires previous topic observation.")
        r.field("LPU",2,0,7,encoding:"BCD",range:0...79)
        r.field("DM",3,7,1,labels:[0:"Standard density",1:"High density"])
        r.field("SCRL",3,6,1,labels:[0:"Scroll",1:"No scroll"])
        r.field("HV",3,5,1,labels:[0:"Vertical",1:"Horizontal bottom row"])
        if bytes[3]&0x60 == 0x60 {
          r.qualify("SCRL",meaning:"No information",status:"unavailable")
          r.qualify("HV",meaning:"No information",status:"unavailable")
        } else if bytes[3]&0x40 != 0 { r.qualify("HV",meaning:"No scroll; direction inapplicable",status:"unavailable") }
        r.field("CL",3,4,1,labels:[0:"Clear previous page",1:"Keep previous page"])
        r.field("RASTER_COLOR",3,0,4,labels:dictionary(["Black","Red","Green","Yellow","Blue","Magenta","Cyan","White","Transparent","Dim red","Dim green","Dim yellow","Dim blue","Dim magenta","Dim cyan","Gray"]))
        r.field("PU",4,0,7,encoding:"BCD",range:0...79); r.field("PAGE_FIXED",4,7,1,fixed:1)
      case 0x0b:
        r.atn(); r.micFlag("TEXT",4,7,"Text present","Text absent")
        r.micFlag("TT",4,6,"Event validity uncertain","Event valid")
        r.field("HL",4,5,1,labels:[0:"Hold ATN",1:"Renew ATN"])
        r.field("TAG_FIXED",4,4,1,fixed:1)
        r.field("TAG_ID",4,0,4,sentinel:15,labels:dictionary(["Index","Skip start","PP","Programme-play start","Zone play","Still audio/video","Still video","Last recording point","Date change","Time change","Recording start","Playback start"]))
      case 0x0f:
        r.atn(); r.field("TAG_CONT",4,encoding:"opaque")
        if bytes[4] == 15 || bytes[4] == 31 {
          r.qualify("TAG_CONT",meaning:bytes[4] == 15 ? "Overrecording prohibited":"Already played",status:"interpreted")
        } else if bytes[4] >> 6 != 0 {
          // The derived subfields intentionally overlap the raw TAG_CONT container.
          r.qualify("TAG_CONT",meaning:["Reserved","Play once","Play twice","Repeat until stopped"][Int(bytes[4]>>6)],status:(bytes[4]&7)>5 || ((bytes[4]>>3)&7)>5 ? "reserved":"interpreted")
          r.field("FMODE",4,3,3,labels:dictionary(["None","Play","Slow","Cue","Fast forward","Strobe"]))
          r.field("RMODE",4,0,3,labels:dictionary(["None","Reverse play","Reverse slow","Review","Rewind","Reverse strobe"]))
        } else { r.qualify("TAG_CONT",meaning:"Reserved control",status:"reserved") }
      case 0x0d:
        for b in 1...4 { r.field("KEY\(2*b-2)",b,0,4,encoding:"opaque"); r.field("KEY\(2*b-1)",b,4,4,encoding:"opaque") }
      case 0x12,0x22,0x32:
        r.field(h == 0x12 ? "TCHNO":"CHNO",1,encoding:"BCD",range:0...99)
        if h != 0x12 { r.field(h == 0x22 ? "TPNO":"PNO",2,encoding:"BCD",range:0...99) }
        else { r.field("PC2_FIXED",2,fixed:255) }
        r.field("PC3_FIXED",3,fixed:255); r.field("PC4_FIXED",4,fixed:255)
      case 0x15:
        r.add("CNO",[.init(1),.init(2,0,4)],encoding:"BCD",range:0...999)
        r.field("CNO_FIXED",2,4,4,fixed:15)
        r.add("RANDOM_NO",[.init(3),.init(4)],encoding:"opaque",note:"Numbering procedure is unspecified.")
      case 0x16:
        let form = bytes[1]&15
        r.field("CATALOGUE_FORM",1,0,4,labels:[14:"First seven digits",15:"Remaining six digits"])
        if form == 14 || form == 15 {
          let start = form == 14 ? 1:8
          r.field("N\(start)",1,4,4,encoding:"BCD",range:0...9,sentinel:15)
          for b in 2...4 { for n in 0...1 {
            let digit = start + (b-2)*2 + n + 1
            if digit <= 13 { r.field("N\(digit)",b,n*4,4,encoding:"BCD",range:0...9,sentinel:15) }
            else { r.field("CATALOGUE_FIXED",b,n*4,4,fixed:15) }
          } }
        } else { for b in 2...4 { r.field("PC\(b)",b,encoding:"opaque") }; r.field("PC1_UPPER",1,4,4,encoding:"opaque") }
      case 0x1c,0x1d:
        for b in 1...4 { r.field("C\((h == 0x1c ? 0:4)+b-1)",b,encoding:"opaque",sentinel:255,note:"Alphanumeric code; C7 is the most significant character.") }
      case 0x42:
        r.field("REC_MODE",1,6,2,labels:dictionary(["Video","Audio","Video and audio","Duplicate"]))
        r.field("PROGRAMME_MINUTES",1,0,6,range:0...59,sentinel:63)
        r.field("PROGRAMME_HOURS",2,0,5,range:0...23,sentinel:31)
        r.field("WEEKDAY",2,5,3,sentinel:7,labels:weekdays)
        r.field("PROGRAMME_DAY",3,0,5,range:1...31)
        r.field("PROGRAMME_MONTH",4,0,4,range:1...12,sentinel:15)
        r.add("YEAR7",[.init(4,4,4),.init(3,5,3)],range:0...99,sentinel:127,note:"Binary last two digits; century remains application policy.")
        let day = Int(bytes[3]&31), month = Int(bytes[4]&15)
        let year = Int(bytes[4]>>4) | Int(bytes[3]>>5)<<4
        if (1...12).contains(month), (1...31).contains(day) {
          // Invalid/unavailable years and year 00 cannot exclude February 29.
          let limit = [31,year >= 100 || year % 4 == 0 ? 29:28,31,30,31,30,31,31,30,31,30,31][month-1]
          if day > limit { r.qualify("PROGRAMME_DAY",meaning:"Impossible day/month combination; bytes retained",status:"invalid") }
        }
      case 0x52,0x62,0x92: r.date()
      case 0x55:
        let languages = dictionary(["Unknown","English","Spanish","French","German","Italian","Other","None"])
        for b in 1...2 {
          let p = b == 1 ? "MAIN":"SECOND"
          r.field(p+"_LANGUAGE",b,3,3,labels:languages)
          r.field(p+"_AUDIO_TYPE",b,0,3,labels:dictionary(b == 1 ? ["Unknown","Mono","Simulated stereo","Stereo","Surround stereo","Data","Other","None"]:["Unknown","Mono","Video description","Non-programme audio","Effects","Data","Other","None"]))
          r.field("PC\(b)_FIXED",b,6,2,fixed:3)
        }
        r.field("PC3_FIXED",3,fixed:255); r.field("PC4_FIXED",4,fixed:255)
      case 0x56,0x66:
        r.field("DATA_TYPE",1,0,4,sentinel:h == 0x66 ? 15:nil,labels:h == 0x66 ? [0:"Video ID",1:"WSS",2:"EDTV-2 line 22",3:"EDTV-2 line 285"]:[:])
        r.add("DATA28",[.init(1,4,4),.init(2),.init(3),.init(4)],encoding:"opaque",note:"Physical container; meaningful signal width is type-dependent.")
        if h == 0x66, (bytes[1]&15) < 4 {
          let width = [20,14,24,24][Int(bytes[1]&15)]
          let payload = r.fields.last!.rawValue
          let mask = (UInt32(1)<<width)-1
          r.fields.append(.init(id:"SIGNAL_DATA",name:"Signal payload",rawValue:payload&mask,meaning:"\(width)-bit signal data; signal semantics require the referenced VBI standard",status:"uninterpreted",reference:r.ref,confidence:.normativeConfirmed,numeric:.init(bitWidth:width,unit:"bits",relation:"raw",rule:"Low meaningful bits of DATA28")))
        }
      case 0x70,0x71,0x73...0x77,0x7b...0x7f: r.camera()
      case 0x80:
        r.add("LINES",[.init(1),.init(2,0,3)],range:1...1250)
        r.field("CM",2,3,1,labels:[0:"Common to both fields",1:"Frame line number"])
        r.field("CLF",2,4,2,encoding:"opaque",note:"Valid only with EN=0; colour-frame system is required.")
        r.field("EN",2,6,1,labels:[0:"Colour-frame code valid",1:"Colour-frame code invalid"])
        r.field("BW",2,7,1,labels:[0:"Monochrome",1:"Colour"])
        r.add("TSD",[.init(3),.init(4,0,3)],range:1...2047)
        r.field("SMPL",4,3,3,labels:[0:"13.5 MHz",1:"27 MHz",2:"6.75 MHz",3:"1.35 MHz"])
        r.field("QUL",4,6,2,sentinel:3,labels:[0:"2 bits",1:"4 bits",2:"8 bits"])
      case 0x81...0x83: r.opaquePayload()
      case 0x65:
        r.opaquePayload()
        // Part 4 delegates signal semantics; preserve the existing separately
        // attributed implementation parity checks without promoting them to IEC.
        r.fields = DVSupplementalPackSemantics.decode(bytes,isPAL:context.isPAL)
        r.layout = r.layout.enumerated().map { i,f in LayoutField(id:r.fields[i].id,slices:f.slices,encoding:f.encoding,reference:f.reference) }
      case 0xf0:
        r.field("MAKER_CODE",1,encoding:"opaque",note:"Assignment is not defined by Part 4.")
        r.add("OPTION_COUNT",[.init(2),.init(3,0,2)],unit:"following option packs")
        r.field("MAKER_PC3",3,2,6,encoding:"opaque"); r.field("MAKER_PC4",4,encoding:"opaque")
      case 0xf1...0xfe: r.opaquePayload()
      case 0xff:
        for b in 1...4 { r.field("NO_INFO_PC\(b)",b,fixed:255) }
        for field in r.fields {
          r.qualify(field.id,meaning:"Amended Table 1 labels FF OPTION; unchanged §12.16 requires FF padding. Source conflict retained.",confidence:.conflictingEvidence,
            note:field.rawValue == 255 ? "Base NO INFO padding check: met. This does not resolve amended OPTION allocation.":"Base NO INFO padding check: violated. This conditional check does not establish invalidity under amended OPTION allocation.")
        }
      default: if !r.additional() { return nil }
      }
    }
    // Preserve report field identities used by old journals and the timeline.
    var aliases: [String:String] = [:]
    if h == 0x13 { for id in ["HOURS","MINUTES","SECONDS","FRAMES"] { aliases[id] = "TC_"+id } }
    if [0x53,0x63,0x93].contains(h) { for id in ["HOURS","MINUTES","SECONDS","FRAMES"] { aliases[id] = "REC_"+id } }
    if [0x52,0x62,0x92].contains(h) { for id in ["YEAR","MONTH","DAY"] { aliases[id] = "REC_"+id } }
    if h == 0x70 { aliases["FCM"] = "FOCUS_MODE" }
    let fields = r.fields.map { f in
      DVPackSemanticReport.Field(id:aliases[f.id] ?? f.id,name:f.name,rawValue:f.rawValue,
        meaning:f.meaning,status:f.status,reference:f.reference,confidence:f.confidence,
        qualifier:f.qualifier,numeric:f.numeric)
    }
    let layout = r.layout.map { f in LayoutField(id:aliases[f.id] ?? f.id,slices:f.slices,encoding:f.encoding,reference:f.reference,rangeLower:f.rangeLower,rangeUpper:f.rangeUpper,sentinel:f.sentinel,fixed:f.fixed,labels:f.labels) }
    return Decoded(fields:fields,layout:layout)
  }
}

private extension DVIEC61834.Reader {
  mutating func camera() {
    let p = bytes, h = p[0]
    switch h {
    case 0x70:
      field("IRIS",1,0,6,sentinel:63,unit:"f-number",rule:"2^(code/8)",convert:{pow(2,$0/8)})
      if p[1]&63 == 61 { qualify("IRIS",meaning:"Below F1.0",status:"interpreted") }
      if p[1]&63 == 62 { qualify("IRIS",meaning:"Closed iris",status:"interpreted") }
      field("CAMERA_FIXED",1,6,2,fixed:3)
      field("AGC",2,0,4,range:0...13,sentinel:15,note:"The supplied final publication has an empty equation after 'where'; no IEC dB conversion can be verified.")
      if p[2]&15 < 14 {
        field("AGC_DB_CANDIDATE",2,0,4,unit:"dB",rule:"-3+3*G",convert:{-3+3*$0})
        qualify("AGC_DB_CANDIDATE",meaning:"\(Int(p[2]&15)*3-3) dB (patent candidate)",confidence:.provisional,
          source:"MANUFACTURER_REFERENCE: Sony US5845044A, col.6; final IEC §10.1 equation missing",note:"Secondary conversion; not device calibration.")
      }
      field("AE_MODE",2,4,4,sentinel:15,labels:DVIEC61834.dictionary(["Automatic","Gain priority","Shutter priority","Iris priority","Manual"]))
      field("WB_PRESET",3,0,5,sentinel:31,labels:DVIEC61834.dictionary(["Candle","Incandescent","Low-temperature fluorescent","High-temperature fluorescent","Sunlight","Cloudy","Other"]))
      field("WB_MODE",3,5,3,sentinel:7,labels:DVIEC61834.dictionary(["Automatic","Hold","One-push","Preset"]))
      field("FCM",4,7,1,labels:[0:"Automatic",1:"Manual"])
      field("FOCUS",4,0,7,sentinel:127,unit:"cm",rule:"(code>>2)*10^(code&3)",convert:{Double(Int($0)>>2)*pow(10,Double(Int($0)&3))})
    case 0x71:
      field("VP_SPEED",1,0,5,sentinel:31,unit:"lines/field")
      if p[1]&31 == 30 { qualify("VP_SPEED",meaning:"> 29 lines/field",status:"interpreted",relation:"greaterThan") }
      field("VPD",1,5,1,labels:[0:"Along raster scanning",1:"Against raster scanning"],note:"Not physical left/right/up/down camera movement.")
      field("CAMERA_FIXED",1,6,2,fixed:3)
      field("HP_SPEED",2,0,6,sentinel:63,unit:"pixels/field",rule:"2*PS; literal ordinary range 0...0x1D",convert:{$0*2})
      if (30...61).contains(p[2]&63) { qualify("HP_SPEED",meaning:"Disputed horizontal-pan code; no speed selected",confidence:.conflictingEvidence,note:"§10.2 ordinary bound is 0x1D; sentinel 0x3E refers to >122 pixels/field. No silent correction to 0x3D.",relation:"disputed") }
      if p[2]&63 == 62 { qualify("HP_SPEED",meaning:"> 122 pixels/field",status:"interpreted",relation:"greaterThan") }
      field("HPD",2,6,1,labels:[0:"Along raster scanning",1:"Against raster scanning"],note:"Not physical left/right/up/down camera movement.")
      field("IS",2,7,1,labels:[0:"Enabled",1:"Disabled"])
      field("FOCAL_LENGTH",3,sentinel:255,unit:"mm (35-mm equivalent)",rule:"(code>>1)*10^(code&1)",convert:{Double(Int($0)>>1)*pow(10,Double(Int($0)&1))})
      field("ZOOM_MAGNITUDE",4,0,7,sentinel:127,unit:"×",rule:"(code>>4)+(code&15)/10",convert:{Double(Int($0)>>4)+Double(Int($0)&15)/10})
      let z = p[4]&127
      if z == 126 { qualify("ZOOM_MAGNITUDE",meaning:"≥ 8×",status:"interpreted",relation:"atLeast") }
      else if z != 127 && z&15 > 9 { qualify("ZOOM_MAGNITUDE",meaning:"Invalid decimal zoom code",status:"invalid") }
      field("ZEN",4,7,1,labels:[0:"Enabled",1:"Disabled"])
    case 0x73:
      field("FCM",1,7,1,labels:[0:"Automatic",1:"Manual"])
      field("FOCUS",1,0,7,sentinel:127,unit:"cm",rule:"(code>>2)*10^(code&3)",convert:{Double(Int($0)>>2)*pow(10,Double(Int($0)&3))})
      field("IRIS",2,sentinel:255,unit:"f-number",rule:"sqrt(2)^(IP/16) = 2^(IP/32)",convert:{pow(2,$0/32)})
      if p[2] == 254 { qualify("IRIS",meaning:"Closed iris",status:"interpreted") }
      field("ZOOM",3,sentinel:255,unit:"m",rule:"(code>>1)*10^(code&1); literal §10.4 unit m",convert:{Double(Int($0)>>1)*pow(10,Double(Int($0)&1))})
      field("EXTENDER",4,2,4,unit:"×",rule:"EX/4",convert:{$0/4})
      field("IRIS_CONT",4,0,2,sentinel:3,labels:[0:"Automatic",1:"One-push automatic",2:"Manual"])
      field("LENS_FIXED",4,6,2,fixed:3)
    case 0x74:
      field("GM",1,7,1,labels:[0:"Automatic gain",1:"Manual gain"])
      field("MASTER_GAIN",1,0,7,sentinel:127,unit:"dB",rule:"(code-32)/2",convert:{($0-32)/2})
      field("R_GAIN",2,sentinel:255,unit:"dB",rule:"(code-128)*6/128",convert:{($0-128)*6/128})
      field("B_GAIN",3,sentinel:255,unit:"dB",rule:"(code-128)*6/128",convert:{($0-128)*6/128})
      field("ND_FILTER",4,4,4,sentinel:15,unit:"transmission ratio",rule:"2^-NF",convert:{pow(2,-$0)})
      field("CC_FILTER",4,0,4,sentinel:15,labels:[8:"3200 K to 3200 K",9:"4300 K to 3200 K",10:"5600 K to 3200 K",12:"6300 K to 3200 K"])
    case 0x75,0x76,0x77,0x7c:
      let extended = p[4]&128 == 0, centre = extended ? 512.0:128.0
      let suffix = h == 0x75 ? "PEDESTAL":h == 0x76 ? "GAMMA":h == 0x77 ? "DETAIL":"FLARE"
      let channels = h == 0x77 ? ["MASTER","H","V"]:["G","R","B"]
      field("QF",4,7,1,labels:[0:"10-bit values",1:"8-bit values"])
      field("PRECISION_FIXED",4,6,1,fixed:1)
      for b in 1...3 {
        let slices: [DVIEC61834.Slice] = extended ? [.init(4,(b-1)*2,2),.init(b)]:[.init(b)]
        let id = channels[b-1]+"_"+suffix
        let unit = h == 0x75 ? "mV":h == 0x7c ? "%":h == 0x77 ? "× preset":"gamma"
        add(id,slices,sentinel:extended ? 1023:255,unit:unit,rule:h == 0x77 ? "code/centre; absolute mV requires preset calibration":"offset binary around \(Int(centre))",convert:{v in
          switch h {
          case 0x75: return (v-centre)*(extended ? 0.625:2.5)
          case 0x76: return 0.45+(v-centre)*0.15/centre
          case 0x7c: return (v-centre)*(extended ? 0.125:0.5)
          default: return v/centre
          }
        })
        if h == 0x77 {
          qualify(id,meaning:fields.last!.meaning,status:fields.last!.status,
            note:"Relative preset ratio. §10.8 also assigns the top ordinary code 2000 mV, inconsistent with exact centre=1000 mV scaling. No absolute mV inferred.")
        }
        if !extended { field(channels[b-1]+"_EXTENSION_UNUSED",4,(b-1)*2,2,encoding:"opaque",note:"Not part of the selected 8-bit value.") }
      }
    case 0x7d:
      let areas = p[1]&128 == 0 ? [1,3,4,6]:[0,2,5,7]
      field("SHADING_FORM",1,7,1,labels:[0:"Edge centres",1:"Corners"])
      add("CHANNEL",[.init(2,7,1),.init(3,7,1)],sentinel:3,labels:[0:"Green",1:"Red",2:"Blue"])
      field("WB",4,7,1,labels:[0:"White shading",1:"Black shading"])
      for b in 1...4 {
        field("SHADING_AREA_\(areas[b-1])",b,0,7,sentinel:127,unit:"%",rule:"(code-64)*(white ? 1 : 0.5)",note:"Relative to centre under zero-dB gain; 3×3 area grid, centre excluded.",convert:{($0-64)*(p[4]&128 == 0 ? 1:0.5)})
      }
    case 0x7e:
      field("KNEE_POINT",1,sentinel:255,unit:"mV",rule:"700+(code-128)*2.5",convert:{700+($0-128)*2.5})
      field("KNEE_SLOPE",2,encoding:"binary",sentinel:255)
      if p[2] != 255 { qualify("KNEE_SLOPE",meaning:"Raw knee slope; §10.15 gives 0x80=15% and 15% per LSB but calls the encoding straight binary",confidence:.conflictingEvidence,note:"No offset or scaling correction invented.") }
      field("PC3_FIXED",3,fixed:255); field("PC4_FIXED",4,fixed:255)
    case 0x7b,0x7f:
      if context.professionalCamera {
        for b in 1...2 { field("SSP\(b)",b,sentinel:255,unit:"s",rule:"2^-SSP",convert:{pow(2,-$0)}) }
        field("PC3_FIXED",3,fixed:255); field("SHUTTER_FIXED",4,0,7,fixed:127)
      } else {
        field("PC1_FIXED",1,fixed:255); field("PC2_FIXED",2,fixed:255)
        add("CONSUMER_SHUTTER",[.init(3),.init(4,0,7)],sentinel:32767,unit:"horizontal periods",rule:"duration=SPD*TH; TH must come from recording profile")
        let raw = Int(p[3]) | (Int(p[4]&127)<<8)
        if raw == 0 { qualify("CONSUMER_SHUTTER",meaning:"Not used",status:"unavailable") }
        else if raw != 32767, let t = context.horizontalPeriodSeconds, t.isFinite, t > 0 {
          let duration = Double(raw)*t
          if duration.isFinite {
            qualify("CONSUMER_SHUTTER",meaning:String(format:"%.12g s",duration),status:"interpreted",note:"TH supplied by the recording profile; raw SPD is retained.",unit:"s",rule:"SPD * TH; TH supplied in seconds by the recording profile")
          } else {
            qualify("CONSUMER_SHUTTER",meaning:"Supplied horizontal period overflows duration; raw SPD retained",note:"No finite duration in seconds can be established from the supplied profile.")
          }
        }
      }
      if h == 0x7b { field("TEXT",4,7,1,labels:[0:"Text present",1:"Text absent"]) }
      else { field("PC4_HIGH_FIXED",4,7,1,fixed:1) }
    default: break
    }
  }
}

private extension DVIEC61834.Reader {
  mutating func genre(_ byte: Int) {
    field("GEN",byte,0,7,sentinel:127,labels:DVIEC61834.genreLabels,note:"§3.3; category 14 points to text, 15 permits a companion GENRE refinement.")
  }
  mutating func rights() {
    field("CGMS",1,6,2,labels:[0:"Copy unrestricted",2:"One generation",3:"Copy prohibited"])
    field("ISR",1,4,2,sentinel:3,labels:[0:"Analogue input",1:"Digital input"])
    field("CMP",1,2,2,sentinel:3,labels:[0:"Once",1:"Twice",2:"Three or more"])
    field("SS",1,0,2,sentinel:3,labels:[0:"Scrambled, restricted",1:"Scrambled, unrestricted",2:"Restricted, possibly descrambled"])
  }
  mutating func tuner() {
    field("TUN",4,encoding:"opaque",sentinel:255)
    guard bytes[4] != 255 else { return }
    let area = Int(bytes[4]>>5), satellite = Int(bytes[4]&31)
    let names = area == 0 ? [0:"UHF/VHF",2:"ASTRA A+B",3:"ASTRA C+D",4:"TELECOM France",5:"TELECOM-2"]:
      area == 6 ? [0:"UHF/VHF",1:"BS",2:"SCC-A",3:"SCC-B",4:"JCSAT-1",5:"JCSAT-2"]:[0:"UHF/VHF"]
    qualify("TUN",meaning:"\(area < 2 ? "Europe/Africa":area < 6 ? "Americas":"Asia/Oceania"), \(names[satellite] ?? "reserved satellite code")",status:names[satellite] == nil ? "reserved":"interpreted")
  }
  mutating func additional() -> Bool {
    let p = bytes, h = p[0]
    switch h {
    case 0x00:
      field("ME",1,7,1,labels:[0:"MIC event data may differ from tape",1:"MIC event data reliable"])
      field("PC1_FIXED",1,5,2,fixed:3)
      field("MULTI_BYTES",1,2,3,labels:[0:"4 bytes",1:"8 bytes",2:"16 bytes",7:"Unlimited"])
      field("MEMORY_TYPE",1,0,2,labels:[0:"EEPROM",1:"FeRAM"])
      for (id,shift) in [("LAST_BANK_SIZE",0),("SPACE0_SIZE",4)] {
        field(id,2,shift,4,range:0...8,sentinel:15,unit:"bytes",rule:"256*2^code",convert:{256*pow(2,$0)})
      }
      for (id,code) in [("LAST_BANK_SIZE",p[2]&15),("SPACE0_SIZE",p[2]>>4)] where (9...14).contains(code) {
        qualify(id,meaning:"Reserved memory size",status:"reserved")
      }
      field("SPACE1_BANK_COUNT",3)
      if p[3] == 0 && p[2]&15 != 15 { qualify("LAST_BANK_SIZE",meaning:"Zero bank count requires no last bank",status:"invalid") }
      field("TAPE_THICKNESS",4,encoding:"BCD",range:0...99,unit:"µm",rule:"BCD/10",convert:{$0/10})
    case 0x01:
      field("PC1_FIXED",1,0,1,fixed:1)
      add("TAPE_LENGTH",[.init(1,1,7),.init(2),.init(3)],unit:"10-µm tracks")
      field("PC4_FIXED",4,fixed:255)
    case 0x02:
      field("SR",1,7,1,encoding:"opaque",note:"Recording pitch selector; requires recording profile.")
      field("RP",2,7,1,labels:[0:"Overrecording prohibited",1:"Overrecording allowed"])
      field("TCF",2,5,2,labels:[0:"Weekly",1:"One-time weekdays",3:"Year/month/day"])
      field("MONTH",2,0,5,encoding:"BCD",range:1...12,sentinel:31)
      field("YEAR",3,encoding:"BCD",range:0...99,sentinel:255,note:"Century policy is external.")
      let tcf = (p[2]>>5)&3
      if tcf == 3 { field("DAY",1,0,7,encoding:"BCD",range:1...31) }
      else {
        for i in 0...6 { field("DAY_\(i)",1,6-i,1,labels:tcf == 2 ? [:]:[0:"Scheduled",1:"Not scheduled"],note:"Sunday=0 through Saturday=6.") }
      }
      micFlag("TEXT",4,7,"Text present","Text absent"); genre(4)
    case 0x03:
      field("START_MINUTES",1,encoding:"BCD",range:0...59)
      field("START_HOURS",2,encoding:"BCD",range:0...23)
      field("STOP_MINUTES",3,encoding:"BCD",range:0...59)
      field("STOP_HOURS",4,0,6,encoding:"BCD",range:0...23)
      field("REC_TYPE",4,6,2,sentinel:3,labels:[0:"Television",1:"Television and teletext",2:"Teletext"])
    case 0x04:
      clock(position:true)
      fields.removeAll { $0.id == "PC1_FIXED" }; layout.removeAll { $0.id == "PC1_FIXED" }
      field("PR",1,7,1,labels:[0:"Playback start",1:"Recording start"])
    case 0x05:
      atn(); field("PR",4,7,1,labels:[0:"Playback start",1:"Recording start"])
      field("PC4_FIXED_HIGH",4,6,1,fixed:1); field("HL",4,5,1,labels:[0:"Hold",1:"Renew"])
      field("PC4_FIXED_LOW",4,0,5,fixed:31)
    case 0x06:
      field("FORM",1,0,1,labels:[0:"Genre",1:"Tag number"])
      if p[1]&1 == 1 {
        field("TAG_ID",1,1,3,labels:[3:"Index",5:"Skip",6:"PP"])
        field("PC1_FIXED",1,4,4,fixed:15)
        add("TAG_ID_NUMBER",[.init(2),.init(3)],encoding:"BCD",range:0...9999)
        field("PC4_FIXED",4,fixed:255)
      } else {
        field("SITUATION",1,5,3,sentinel:7,labels:[0:"Live",1:"Prerecorded"])
        field("CATEGORY",1,1,4,encoding:"opaque",note:"Category vocabulary depends on the companion basic genre, §3.7.")
        if let basic = context.genreBasicCategory, (0...7).contains(basic) {
          let code = basic*16 + Int((p[1]>>1)&15)
          qualify("CATEGORY",meaning:DVIEC61834.genreLabels[code] ?? "No information",status:"interpreted")
        }
        field("SUBCATEGORY",2,0,7,sentinel:127,labels:context.genreBasicCategory == 2 ? DVIEC61834.sportsSubcategories[Int((p[1]>>1)&15)] ?? [:]:[:])
        if context.genreBasicCategory == nil && p[2]&127 != 127 { qualify("SUBCATEGORY",meaning:"Companion basic category required") }
        field("OT0",2,7,1,labels:[0:"Reserved ornament group 0",1:"Ornament group 1"])
        field("ORN2",3,0,4,sentinel:15,labels:DVIEC61834.dictionary(["League","Tournament","Series","Tour","Open","Regatta","Games","Cup","Bowl","Championship","Title match","Grand prix"]))
        add("ORN1",[.init(3,4,4),.init(4,0,2)],sentinel:63,labels:DVIEC61834.ornaments)
        field("ORN0",4,2,6,sentinel:63,labels:p[2]&128 != 0 ? DVIEC61834.ornaments:[:])
      }
    case 0x0c:
      guard let system = context.teletextSystem, [0,1,3].contains(system) else {
        opaquePayload(); for id in fields.map(\.id) { qualify(id,meaning:"Teletext system not established; Japan, UK and NABTS layouts differ") }; return true
      }
      if system == 0 {
        add("PROGRAMME",[.init(1),.init(2,0,4)],encoding:"BCD",range:0...999)
        field("MAGAZINE",2,4,4,encoding:"BCD",range:0...9)
        field("PAGE",3,encoding:"BCD",range:0...99); field("TOTAL_PAGES",4,encoding:"BCD",range:0...99)
      } else if system == 3 {
        field("PAGE",1,encoding:"BCD",range:0...99); field("MAGAZINE",2,0,4,encoding:"BCD",range:0...9)
        field("PC2_FIXED",2,4,4,fixed:15); field("SUBPAGE",3,encoding:"BCD",range:0...99)
        field("TOTAL_SUBPAGES",4,encoding:"BCD",range:0...99)
      } else {
        add("PAGE",[.init(1),.init(2,0,4)],encoding:"BCD",range:0...999)
        add("MAGAZINE",[.init(2,4,4),.init(3)],encoding:"BCD",range:0...999)
        field("MORE_PAGES",4,encoding:"BCD",range:0...99)
      }
    case 0x17:
      let first = p[1]&3 == 2
      if first {
        field("ISRC_FORM",1,0,2,fixed:2)
        add("I1",[.init(1,2,6)],encoding:"opaque"); add("I2",[.init(2,0,6)],encoding:"opaque")
        add("I3",[.init(2,6,2),.init(3,0,4)],encoding:"opaque")
        add("I4",[.init(3,4,4),.init(4,0,2)],encoding:"opaque"); field("I5",4,2,6,encoding:"opaque")
      } else {
        field("ISRC_FORM",1,0,4,fixed:15)
        field("I6",1,4,4,encoding:"BCD",range:0...9)
        for b in 2...4 { for n in 0...1 { field("I\(7+(b-2)*2+n)",b,n*4,4,encoding:"BCD",range:0...9) } }
      }
    case 0x1f:
      atn(); field("SR",4,7,1,encoding:"opaque",note:"Track pitch profile required.")
      field("RE",4,6,1,note:"Renewal toggle; previous observation needed."); field("PC4_FIXED",4,0,6,fixed:63)
    case 0x50:
      field("LF",1,7,1,labels:[0:"Locked",1:"Unlocked"]); field("PC1_FIXED",1,6,1,fixed:1)
      let rate = Int((p[4]>>3)&7), pal = p[3]&32 != 0
      let bases = pal ? [1896,1742,1264]:[1580,1452,1053], maxima = pal ? [48,44,32]:[40,37,27]
      field("AF_SIZE",1,0,6,range:rate < 3 ? 0...maxima[rate]:nil,unit:"samples/frame",rule:"source-system/rate base + code",convert:rate < 3 ? {Double(bases[rate])+$0}:nil)
      if rate >= 3 { qualify("AF_SIZE",meaning:"Sampling code reserved; no sample count inferred") }
      field("SM",2,7,1,labels:[0:"Multiple stereo pairs",1:"Lumped"])
      field("CHN",2,5,2,labels:[0:"One channel/block",1:"Two channels/block"])
      field("PA",2,4,1,labels:[0:"Paired",1:"Independent"])
      if p[2]&128 != 0 && p[2]&16 == 0 { qualify("PA",meaning:"Lumped arrangement requires independent channels",status:"invalid") }
      let ch = (p[2]>>5)&3
      let am: [Int:String] = p[2]&128 == 0 ? (ch == 0 ? [0:"Left",1:"Right",2:"Mono",14:"Unknown",15:"No audio"]:[0:"L/R",1:"M1/none",2:"M1/M2",3:"LS/RS",4:"C/S",5:"C/none",6:"C/M1",14:"Unknown",15:"No audio"]):DVIEC61834.dictionary(["L,R,C,S","L,R,C,M","L,R,C,none","L,R,LS,RS","Lmix,Rmix,T,WO,Q1,Q2","L,R,C,WO,LS,RS,Lmix,Rmix","L,R,C,WO,LS1,RS1,LS2,RS2","L,R,C,WO,LS,RS,LC,RC"])
      field("AM",2,0,4,labels:ch < 2 ? am:[:],note:"Lumped labels are ordered channel assignments; §8.1 supplies mixing coefficients.")
      field("PC3_FIXED",3,7,1,fixed:1); field("ML",3,6,1,labels:[0:"Multiple languages",1:"Not multiple languages"])
      field("FIELD_SYSTEM",3,5,1,labels:[0:"60 fields",1:"50 fields"])
      field("STYPE",3,0,5,labels:[0:"SD",2:"HD 1125/1250"])
      field("EF",4,7,1,labels:[0:"Emphasis on",1:"Emphasis off"])
      field("TC",4,6,1,labels:[1:"50/15 µs"])
      field("SMP",4,3,3,labels:[0:"48 kHz",1:"44.1 kHz",2:"32 kHz"])
      field("QU",4,0,3,labels:[0:"16-bit linear",1:"12-bit nonlinear",2:"20-bit linear"])
    case 0x51,0x61:
      rights(); field("REC_S",2,7,1,labels:[0:"Start marker set",1:"Start marker clear"])
      if h == 0x51 {
        field("REC_E",2,6,1,labels:[0:"End marker set",1:"End marker clear"])
        field("REC_M",2,3,3,labels:[1:"Original",3:"One-channel insert",4:"Four-channel insert",5:"Two-channel insert",7:"Invalid recording"])
        if (p[2]>>3)&7 == 7 { qualify("REC_M",meaning:"Recording marked invalid",status:"invalid") }
        field("ICH",2,0,3,labels:[0:"CH1",1:"CH2",2:"CH3",3:"CH4",4:"CH1+2",5:"CH3+4",6:"All four",7:"No information"],fixed:context.mic ? nil:7,note:"Insert-channel meaning is MIC-only; tape requires 111.")
        field("DRF",3,7,1,labels:[0:"Reverse",1:"Forward"])
        field("SPD",3,0,7,sentinel:127,unit:"×",rule:"piecewise §8.2",convert:{v in
          let c = Int(v)
          if c == 0 { return 0 }; if c < 16 { return 1/Double(18-c) }
          return pow(2,Double((c>>4)-2))+Double(c&15)*pow(2,Double((c>>4)-6))
        })
        if p[3]&127 == 1 { qualify("SPD",meaning:"Less than 1/16×",status:"interpreted",relation:"lessThan") }
        if p[3]&127 == 126 { qualify("SPD",meaning:"At least 60×",status:"interpreted",relation:"atLeast") }
      } else {
        field("PC2_FIXED6",2,6,1,fixed:1); field("PC2_FIXED3",2,3,1,fixed:1)
        field("REC_M",2,4,2,labels:[0:"Original",2:"Insert",3:"Invalid recording"])
        if (p[2]>>4)&3 == 3 { qualify("REC_M",meaning:"Recording marked invalid",status:"invalid") }
        let bcs = p[3]&3
        field("DISP",2,0,3,labels:bcs == 0 ? [0:"4:3 full frame",1:"16:9 content letterboxed centrally",2:"16:9 full frame, anamorphic"]:bcs == 1 ? DVIEC61834.dictionary(["4:3 full frame","14:9 letterbox centre","14:9 letterbox top","16:9 letterbox centre","16:9 letterbox top",">16:9 letterbox centre","14:9 full frame centre","16:9 full frame, anamorphic"]):[:],note:"Content aspect description does not change stored raster dimensions.")
        field("FF",3,7,1,labels:[0:"Repeat selected field",1:"Both fields"])
        field("FS",3,6,1,labels:[0:"Field 2 first",1:"Field 1 first"])
        field("FC",3,5,1,labels:[0:"Same picture",1:"Different picture"])
        field("IL",3,4,1,labels:[0:"Noninterlaced",1:"Interlaced or unrecognized"])
        field("SF",3,3,1,labels:[0:"Fields simultaneous",1:"Normal field interval"],note:"IEC name ST; stable report ID SF retained.")
        field("SC",3,2,1,labels:[0:"Still camera",1:"Not still camera"])
        field("BCS",3,0,2,labels:[0:"Broadcast type 0",1:"Broadcast type 1"],note:"IEC name BCSYS; stable report ID BCS retained.")
      }
      field("PC4_FIXED",4,7,1,fixed:1); genre(4)
    case 0x60,0x90:
      if h == 0x60 {
        add("TV_CHANNEL",[.init(1),.init(2,0,4)],encoding:"BCD",range:1...999,sentinel:4095)
        if p[1] == 238 && p[2]&15 == 14 { qualify("TV_CHANNEL",meaning:"Prerecorded tape or MUSE line, depending on source",status:"interpreted") }
        field("BW",2,7,1,labels:[0:"Monochrome",1:"Colour"])
        field("EN",2,6,1,labels:[0:"Colour-frame code valid",1:"Colour-frame code invalid"])
        field("CLF",2,4,2,labels:p[3]&32 == 0 ? [0:"A",1:"B"]:[0:"Fields 1/2",1:"Fields 3/4",2:"Fields 5/6",3:"Fields 7/8"])
        if p[2]&192 != 128 { qualify("CLF",meaning:"Colour-frame identification not applicable",status:"unavailable") }
      } else {
        add("SERVICE_ID",[.init(1),.init(2)],encoding:"opaque",note:"PC1 and PC2 container, PC1 low for raw reporting. §13.1 does not label byte significance; programme-number interpretation requires the applicable MPEG profile/PMT. Symmetric sentinel tests below do not depend on byte order.")
      }
      field("SRC",3,6,2,labels:[0:"Camera",1:"Line",2:"Cable",3:"Tuner, prerecorded or unavailable"])
      field("FIELD_SYSTEM",3,5,1,labels:[0:"60 fields",1:"50 fields"])
      field("STYPE",3,0,5,labels:h == 0x60 ? [0:"SD",2:"HD 1125/1250"]:[0:"Not used",2:"Not used",4:"MPEG2-TS 25 Mb/s",5:"MPEG2-TS 12.5 Mb/s",6:"MPEG2-TS 6.25 Mb/s"])
      tuner()
      if h == 0x90 {
        let service = UInt16(p[1]) | UInt16(p[2])<<8, src = p[3]>>6
        if src < 3, service != 0, p[4] == 255 { qualify("SRC",meaning:["Camera","Line","Cable"][Int(src)],status:"interpreted") }
        else if src == 3, service == 0, p[4] == 255 { qualify("SRC",meaning:"Prerecorded tape",status:"interpreted") }
        else if src == 3, service == 65535, p[4] == 255 { qualify("SRC",meaning:"No information",status:"unavailable") }
        else if src == 3, service != 0, fields.first(where:{$0.id == "TUN"})?.status == "interpreted" { qualify("SRC",meaning:"Tuner",status:"interpreted") }
        else { qualify("SRC",meaning:"Undefined source/service/tuner combination",status:"invalid") }
      }
      if h == 0x60 {
        let channel = Int(p[1]) | Int(p[2]&15)<<8, src = p[3]>>6
        let numericChannel = fields.first { $0.id == "TV_CHANNEL" }?.status == "interpreted" && channel != 0xeee
        let outcome: (String,String)
        if p[4] == 255, channel == 0xfff, src == 0 { outcome = ("Camera","interpreted") }
        else if p[4] == 255, src == 1, [0xeee,0xfff].contains(channel) { outcome = (channel == 0xeee ? "MUSE line":"Line","interpreted") }
        else if p[4] == 255, src == 2, numericChannel { outcome = ("Cable","interpreted") }
        else if src == 3, numericChannel, fields.first(where:{$0.id == "TUN"})?.status == "interpreted" { outcome = ("Tuner","interpreted") }
        else if p[4] == 255, src == 3, channel == 0xeee { outcome = ("Prerecorded tape","interpreted") }
        else if p[4] == 255, src == 3, channel == 0xfff { outcome = ("No information","unavailable") }
        else { outcome = ("Source/channel/tuner combination is not defined; bytes retained","invalid") }
        qualify("SRC",meaning:outcome.0,status:outcome.1)
      }
    case 0x67:
      opaquePayload()
      for id in fields.map(\.id) { qualify(id,meaning:"Teletext sequence bytes; packet boundaries require preceding ID byte and referenced teletext system. No per-pack boundary guessed.") }
    case 0x6c: environment()
    case 0x6d:
      let longitude = p[1]&128 == 0
      field("COORDINATE_FORM",1,7,1,labels:[0:"Longitude",1:"Latitude"])
      field("SECONDS",1,0,7,encoding:"BCD",range:0...59)
      field("MINUTES",2,0,7,encoding:"BCD",range:0...59)
      field("HEMISPHERE",2,7,1,labels:longitude ? [0:"East",1:"West"]:[0:"North",1:"South"])
      add("DEGREES",longitude ? [.init(3),.init(4,0,1)]:[.init(3)],encoding:"BCD",range:0...(longitude ? 180:90))
      field("PC4_FIXED",4,longitude ? 1:0,longitude ? 7:8,fixed:longitude ? 127:255)
      let d = Int(p[3]&15)+10*Int(p[3]>>4)+(longitude ? 100*Int(p[4]&1):0)
      if d == (longitude ? 180:90) && ((p[1]&127) != 0 || (p[2]&127) != 0) { qualify("DEGREES",meaning:"Coordinate exceeds endpoint",status:"invalid") }
    case 0x91:
      field("CGMS",1,6,2,labels:[0:"Copy unrestricted",2:"One generation",3:"Copy prohibited"])
      field("TPH",1,3,3,encoding:"binary",sentinel:7)
      let tph = Int((p[1]>>3)&7), st = context.mpegSourceType
      if let st, [4,5,6].contains(st), tph != 7 {
        let repetitions = [0:36,1:18,2:9,3:5]
        let valid = tph < 2 || (tph == 2 && st >= 5) || (tph == 3 && st == 6)
        qualify("TPH",meaning:valid ? "\(repetitions[tph]!) repetitions":"Reserved code for source type",status:valid ? "interpreted":"reserved")
      } else if tph != 7 { qualify("TPH",meaning:"MPEG source type required to interpret repetitions") }
      field("TPL",1,2,1,encoding:"opaque",note:"0: two repetitions at 25 Mb/s, none at 12.5/6.25 Mb/s; 1: absent.")
      if p[1]&4 != 0 { qualify("TPL",meaning:"No data",status:"unavailable") }
      else if let st, [4,5,6].contains(st) { qualify("TPL",meaning:st == 4 ? "2 repetitions":"No repetition",status:"interpreted") }
      field("SS",1,0,2,sentinel:3,labels:[0:"Scrambled",2:"Descrambled or originally clear"])
      field("REC_S",2,7,1,labels:[0:"Start",1:"Not start"]); field("PC2_FIXED",2,6,1,fixed:1)
      field("REC_M",2,4,2,labels:[0:"Original",2:"Insert",3:"Invalid recording"])
      if (p[2]>>4)&3 == 3 { qualify("REC_M",meaning:"Recording marked invalid",status:"invalid") }
      field("MR",2,3,1,labels:[0:"Multiple services",1:"Single service"])
      field("HD_SD",2,2,1,labels:[0:"SD MPEG2",1:"HD MPEG2"])
      field("AUD_MODE",2,0,2,labels:[0:"MPEG2 layer 1/2",1:"AC-3"])
      if p[2]&7 == 7 { for id in ["HD_SD","AUD_MODE"] { qualify(id,meaning:"No information",status:"unavailable") } }
      field("SB_SIZE",3,6,2,encoding:"opaque",note:"ETS 300 468 short_smoothing_buffer_descriptor")
      field("SB_LEAK_RATE",3,0,6,encoding:"opaque",note:"ETS 300 468 short_smoothing_buffer_descriptor")
      field("REC_E",4,7,1,labels:[0:"End",1:"Not end"]); genre(4)
    case 0x95:
      field("PC1_RESERVED",1,encoding:"opaque")
      field("STREAM_TYPE",2,encoding:"opaque",note:"ISO/IEC 13818-1 PMT stream_type; meaningful only for PID TYPE=0.")
      add("PID",[.init(3),.init(4,0,5)])
      field("PID_TYPE",4,5,2,labels:[0:"Elementary stream",1:"PMT",2:"PCR"])
      field("PC4_RESERVED",4,7,1,encoding:"opaque")
    case 0x97:
      for (id,s,w) in [("SF1",7,1),("SF2",6,1),("SPH",4,2),("REE",3,1),("PT",0,3)] {
        field(id,1,s,w,encoding:"opaque",note:"Semantics delegated to IEC 61834-11 §8.3.4.")
      }
      add("ETN",[.init(2),.init(3),.init(4)],encoding:"opaque",note:"24-bit extended track code; IEC 61834-11 §8.3.4 supplies semantics.")
    default: return false
    }
    return true
  }
  mutating func environment() {
    let p = bytes, height = p[1]&1 != 0
    field("ENV_FORM",1,0,1,labels:[0:"Temperature/pressure",1:"Height/depth"])
    field("CATEGORY",1,1,2,labels:[0:"Marine",1:"Mountain"])
    field(height ? "FM":"CF",1,3,1,labels:height ? [0:"Feet",1:"Metres"]:[0:"Fahrenheit",1:"Celsius"])
    if height {
      field("NP",4,4,1,labels:[0:"Negative",1:"Positive"])
      add("HEIGHT",[.init(1,4,4),.init(2),.init(3),.init(4,0,4)],encoding:"BCD",range:0...999999,unit:p[1]&8 == 0 ? "ft":"m",rule:"signed BCD/10",convert:{$0/10*(p[4]&16 == 0 ? -1:1)})
      field("PC4_FIXED",4,5,3,fixed:7)
    } else {
      field("NP",3,1,1,labels:[0:"Negative",1:"Positive"])
      add("TEMPERATURE",[.init(1,4,4),.init(2),.init(3,0,1)],encoding:"BCD",range:0...1999,unit:p[1]&8 == 0 ? "°F":"°C",rule:"signed BCD/10",convert:{$0/10*(p[3]&2 == 0 ? -1:1)})
      field("PRESSURE_FORMAT",3,2,1,labels:[0:"hPa",1:"atm"])
      add("PRESSURE",[.init(3,4,4),.init(4),.init(3,3,1)],encoding:"BCD",range:0...1999,unit:p[3]&4 == 0 ? "hPa":"atm",rule:p[3]&4 == 0 ? "BCD":"BCD/10",convert:{$0/(p[3]&4 == 0 ? 1:10)})
    }
  }
}
