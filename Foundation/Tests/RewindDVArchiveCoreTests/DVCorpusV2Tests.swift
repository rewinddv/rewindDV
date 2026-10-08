import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

// Numeric partitions independently established from pinned BSD/MIT implementations
// and public patent EP1668434A1; the additive 68 row is a provisional user-research
// coordinate oracle. PC byte:low bit:width:aggregate, in numeric order.
// Public-source locators and coalescing rules are retained with the review receipt.
// No field IDs, descriptive registry inventory, or old oracle rows are used here.
private let independentlySourcedPartitions = """
00 1:0:2:0 1:2:3:0 1:5:2:0 1:7:1:0 2:0:4:0 2:4:4:0 3:0:8:0 4:0:4:0 4:4:4:0
01 1:0:1:0 1:1:7:0 2:0:8:0 3:0:8:0 4:0:8:0
08 1:0:8:0 2:0:1:0 2:1:3:0 2:4:4:0 3:0:8:0 4:0:5:0 4:5:3:0
0B 1:0:1:0 1:1:7:0 2:0:8:0 3:0:8:0 4:0:4:0 4:4:1:0 4:5:1:0 4:6:1:0 4:7:1:0
13 1:0:6:0 1:6:1:0 1:7:1:0 2:0:7:0 2:7:1:0 3:0:7:0 3:7:1:0 4:0:6:0 4:6:2:0
14 1:0:4:0 1:4:4:0 2:0:4:0 2:4:4:0 3:0:4:0 3:4:4:0 4:0:4:0 4:4:4:0
18 1:0:8:0 2:0:1:0 2:1:3:0 2:4:4:0 3:0:8:0 4:0:8:0
42 1:0:6:0 1:6:2:0 2:0:5:0 2:5:3:0 3:0:5:0 3:5:3:0 4:0:4:0 4:4:4:0
50 1:0:6:0 1:6:1:0 1:7:1:0 2:0:4:0 2:4:1:0 2:5:2:0 2:7:1:0 3:0:5:0 3:5:1:0 3:6:1:0 3:7:1:0 4:0:3:0 4:3:3:0 4:6:1:0 4:7:1:0
51 1:0:2:0 1:2:2:0 1:4:2:0 1:6:2:0 2:0:3:0 2:3:3:0 2:6:1:0 2:7:1:0 3:0:7:0 3:7:1:0 4:0:7:0 4:7:1:0
52 1:0:6:0 1:6:1:0 1:7:1:0 2:0:6:0 2:6:2:0 3:0:5:0 3:5:3:0 4:0:8:0 1:0:8:1
53 1:0:6:0 1:6:2:0 2:0:7:0 2:7:1:0 3:0:7:0 3:7:1:0 4:0:6:0 4:6:2:0
54 1:0:4:0 1:4:4:0 2:0:4:0 2:4:4:0 3:0:4:0 3:4:4:0 4:0:4:0 4:4:4:0
55 1:0:3:0 1:3:3:0 1:6:2:0 2:0:3:0 2:3:3:0 2:6:2:0 3:0:8:0 4:0:8:0
56 1:0:4:0 1:4:4:0 2:0:8:0 3:0:8:0 4:0:8:0
60 1:0:8:0 2:0:4:0 2:4:2:0 2:6:1:0 2:7:1:0 3:0:5:0 3:5:1:0 3:6:2:0 4:0:8:0
61 1:0:2:0 1:2:2:0 1:4:2:0 1:6:2:0 2:0:3:0 2:3:1:0 2:4:2:0 2:6:1:0 2:7:1:0 3:0:2:0 3:2:1:0 3:3:1:0 3:4:1:0 3:5:1:0 3:6:1:0 3:7:1:0 4:0:7:0 4:7:1:0
62 1:0:6:0 1:6:1:0 1:7:1:0 2:0:6:0 2:6:2:0 3:0:5:0 3:5:3:0 4:0:8:0 1:0:8:1
63 1:0:6:0 1:6:2:0 2:0:7:0 2:7:1:0 3:0:7:0 3:7:1:0 4:0:6:0 4:6:2:0
64 1:0:4:0 1:4:4:0 2:0:4:0 2:4:4:0 3:0:4:0 3:4:4:0 4:0:4:0 4:4:4:0
65 1:0:8:0 2:0:8:0 3:0:8:0 4:0:8:0
66 1:0:4:0 1:4:4:0 2:0:8:0 3:0:8:0 4:0:8:0
68 1:0:8:0 2:0:1:0 2:1:3:0 2:4:4:0 3:0:8:0 4:0:8:0
70 1:0:6:0 1:6:2:0 2:0:4:0 2:4:4:0 3:0:5:0 3:5:3:0 4:0:7:0 4:7:1:0
71 1:0:5:0 1:5:1:0 1:6:2:0 2:0:6:0 2:6:1:0 2:7:1:0 3:0:8:0 4:0:4:0 4:4:3:0 4:7:1:0
7F 1:0:8:0 2:0:8:0 3:0:8:0 4:0:7:0 4:7:1:0
"""

@Test func corpusV2EveryHeaderAndEveryExactMask() throws {
  #expect(DVPackCatalog.entries.count == 256)
  #expect(Set(DVPackCatalog.entries.map(\.header)).count == 256)
  for h in UInt8.min...UInt8.max { #expect(DVPackCatalog.entry(h).header == h) }
  #expect(DVPackCatalog.components.count == 216)
  #expect(DVPackCatalog.components.filter(\.aggregate).count == 2)
  struct Coordinate: Hashable {
    let pack: UInt8; let byte: Int; let low: Int; let width: Int; let aggregate: Bool
  }
  var expectedCoordinates = Set<Coordinate>()
  for line in independentlySourcedPartitions.split(separator: "\n") {
    let parts = line.split(separator: " ")
    let pack = try #require(UInt8(parts[0], radix: 16))
    for interval in parts.dropFirst() {
      let values = interval.split(separator: ":").compactMap { Int($0) }
      #expect(values.count == 4)
      let expected = Coordinate(pack: pack, byte: values[0], low: values[1], width: values[2], aggregate: values[3] == 1)
      #expect(expectedCoordinates.insert(expected).inserted)
      let c = try #require(DVPackCatalog.components.first {
        $0.pack == expected.pack && $0.byte == expected.byte && $0.shift == expected.low
          && $0.width == expected.width && $0.aggregate == expected.aggregate
      })
      // Arithmetic oracle uses quotient/remainder, not production mask/shift.
      let divisor = Int(pow(2.0, Double(expected.low)))
      let modulus = Int(pow(2.0, Double(expected.width)))
      #expect(Int(c.mask) == (modulus - 1) * divisor)
      for byte in 1...4 {
        for value in 0...255 {
          var raw: [UInt8] = [pack,0,0,0,0]
          raw[byte] = UInt8(value)
          let result = byte == expected.byte ? value / divisor % modulus : 0
          #expect(c.extract(raw) == UInt8(result))
        }
      }
      #expect(c.extract([pack, 0]) == nil)
      #expect(c.extract([pack ^ 0xff, 0, 0, 0, 0]) == nil)
    }
  }
  #expect(expectedCoordinates.count == 216)
  #expect(Set(DVPackCatalog.components.map {
    Coordinate(pack: $0.pack, byte: $0.byte, low: $0.shift, width: $0.width, aggregate: $0.aggregate)
  }) == expectedCoordinates)
  #expect(Set(DVPackCatalog.components.map(\.id)).count == 216)
  // Supplementary compatibility checksum, NOT the independent layout oracle.
  // Protects the preexisting report ID-to-coordinate schema against ID swaps.
  let identityRows = DVPackCatalog.components.filter { $0.pack != 0x68 }.map {
    "\($0.id)|\($0.pack)|\($0.byte)|\($0.mask)|\($0.shift)|\($0.width)|\($0.aggregate)"
  }.sorted().joined(separator: "\n")
  #expect(SHA256.hash(data: Data(identityRows.utf8)).map { String(format: "%02x", $0) }.joined()
    == "f109188977353cb8d3e7f11e6fe1106331c2b02e82e74c20de7b252c7e6d4688")
  for pack in Set(DVPackCatalog.components.map(\.pack)) {
    for byte in 1...4 {
      let fields = DVPackCatalog.components.filter { $0.pack == pack && $0.byte == byte && !$0.aggregate }
      var coverage: UInt8 = 0
      for f in fields { #expect(coverage & f.mask == 0); coverage |= f.mask }
      #expect(coverage == 255)
    }
  }
  for h in UInt8(0xa0)...0xef { #expect(DVPackCatalog.entry(h).allocation == "unassigned"); #expect(DVPackCatalog.entry(h).confidence == .normativeConfirmed) }
  #expect(DVPackCatalog.entry(0xff).evidence.contains("discrepancy"))
  #expect(DVPackCatalog.components.filter { $0.pack == 0x51 }.allSatisfy { $0.qualifier.contains("Consumer layout") && $0.qualifier.contains("professional") })
  #expect(DVPackCatalog.entry(0xf1).allocation != DVPackCatalog.entry(0x25).allocation)
}

private func corpusReport(_ pack: [UInt8], offset: Int = 253, tfInvalid: Bool = false, absolute: Bool = true) throws -> DVPackSemanticReport {
  var frame = semanticFrame()
  frame.replaceSubrange(offset..<(offset+5), with: pack)
  if tfInvalid { frame[offset == 86 ? 7 : offset == 483 ? 5 : 6] |= 128 }
  return DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 9, byteOffset: 700), absoluteOffsetsKnown: absolute)
}

@Test func corpusV2UnknownFFAndQuarantinedLayoutsKeepAllEvidence() throws {
  for h: UInt8 in [0xff,0xa0,0xf0,0xf1,0x56,0x66,0x7b,0x94] {
    let offset = h == 0x56 ? 483 : 253
    let report = try corpusReport([h,1,2,3,4], offset: offset, absolute: false)
    let pack = try #require(report.packs.first { $0.typeHex == String(format: "0x%02X",h) && $0.rawHex.hasSuffix("01 02 03 04") })
    #expect(pack.sourceByteOffsets.isEmpty)
    #expect(report.frameByteOffset == nil)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    #expect(json["frame_byte_offset"] == nil)
    #expect(try JSONDecoder().decode(DVPackSemanticReport.self, from: JSONEncoder().encode(report)) == report)
    #expect(pack.locations?.first?.localByteOffset == offset)
    #expect(pack.locations?.first?.absoluteByteOffset == nil)
    #expect(pack.locations?.first?.frameByteOffset == nil)
    #expect(pack.rawComponents == nil)
    if h == 0x56 || h == 0x66 {
      #expect(pack.fields.first { $0.id == "DATA28" }?.status == "uninterpreted")
      #expect(pack.fields.allSatisfy { $0.confidence == .normativeConfirmed })
      #expect(pack.normativeLayout?.count == 2)
    }
    if h == 0xff { #expect(pack.status.contains("non-FF payload")) }
    #expect(report.packs.reduce(0) { $0+$1.observationCount } == 660)
  }
  let invalid = try corpusReport([0x70,8,0,0,4], tfInvalid: true)
  let camera = try #require(invalid.packs.first { $0.typeHex == "0x70" })
  #expect(camera.fields.allSatisfy { $0.status == "invalid" && $0.confidence != .unknown })
  #expect(camera.rawComponents?.allSatisfy { $0.status == "invalid" && $0.confidence != .unknown } == true)
  let misplaced = try corpusReport([0x70,8,0,0,4], offset: 86)
  #expect(misplaced.packs.first { $0.typeHex == "0x70" }?.fields.isEmpty == false) // subcode common optional area is allowed
}

@Test func corpusV2ShutterEveryRawValueAndCameraExceptions() throws {
  for raw in 0..<32768 {
    let values = DVCorpusSemantics.enrich([], pack: [0x7f,0xff,0xff,UInt8(raw & 255),UInt8(raw >> 8)|128], isPAL: false)
    let shutter = try #require(values.first { $0.id == "CONSUMER_SHUTTER" })
    #expect(shutter.rawValue == raw)
    #expect(shutter.status == (raw == 32767 ? "unavailable" : "uninterpreted"))
    #expect(shutter.confidence == (raw == 0 ? .conflictingEvidence : .implementationCorroborated))
    #expect(!shutter.meaning.contains("seconds"))
  }
  for (raw, text, state): (UInt8,String,String) in [(0,"F1","interpreted"),(61,"Below F1.0","interpreted"),(62,"Closed iris","interpreted"),(63,"No information","unavailable")] {
    let fields = DVCorpusSemantics.enrich([],pack:[0x70,raw,14,0,127],isPAL:false)
    #expect(fields.first { $0.id == "IRIS" }?.meaning == text)
    #expect(fields.first { $0.id == "IRIS" }?.status == state)
    #expect(fields.first { $0.id == "FOCUS" }?.status == "unavailable")
    #expect(fields.first { $0.id == "AGC" }?.confidence == .conflictingEvidence)
  }
  let motion = DVCorpusSemantics.enrich([],pack:[0x71,30,62,255,126],isPAL:false)
  #expect(motion.first { $0.id == "VP_SPEED" }?.meaning == "> 29 lines/field")
  #expect(motion.first { $0.id == "HP_SPEED" }?.meaning == "> 122 pixels/field")
  #expect(motion.first { $0.id == "FOCAL_LENGTH" }?.status == "unavailable")
  #expect(motion.first { $0.id == "ZOOM_MAGNITUDE" }?.meaning == "≥ 8×")
  #expect(motion.filter { $0.status == "interpreted" && $0.id != "ZOOM_MAGNITUDE" }.allSatisfy { $0.confidence == .mostLikely })
  #expect(motion.first { $0.id == "ZOOM_MAGNITUDE" }?.confidence == .conflictingEvidence)
}

@Test(arguments: [false, true]) func cameraPanBoundariesAndDirectionAreScanRelative(pal: Bool) throws {
  // All speed codes and independent direction bits; unused and stabilizer bits
  // must not change the interpretation. Overflow is a range, not a sample value.
  for vertical in [false, true] {
    let limit = vertical ? 31 : 63
    let id = vertical ? "VP_SPEED" : "HP_SPEED"
    for raw in 0...limit {
      for direction: UInt8 in [0, 1] {
        let p: [UInt8] = vertical
          ? [0x71, UInt8(raw) | direction << 5 | 0xc0, 0xff, 0xff, 0xff]
          : [0x71, 0xff, UInt8(raw) | direction << 6 | 0x80, 0xff, 0xff]
        let fields = DVCorpusSemantics.enrich([], pack: p, isPAL: pal)
        let speed = try #require(fields.first { $0.id == id })
        #expect(speed.rawValue == raw)
        let disputed = !vertical && (30...61).contains(raw)
        #expect(speed.numeric?.relation == (raw == limit ? "unknown" : raw == limit - 1 ? "greaterThan" : disputed ? "disputed" : "exact"))
        #expect(speed.status == (raw == limit ? "unavailable" : disputed ? "uninterpreted" : "interpreted"))
        if disputed { #expect(speed.confidence == .conflictingEvidence) }
        let expected = raw == limit ? "No information" : raw == limit - 1
          ? (vertical ? "> 29 lines/field" : "> 122 pixels/field")
          : disputed ? "Disputed ordinary-range code \(raw); no speed selected"
          : (vertical ? "\(raw) lines/field" : "\(raw * 2) pixels/field")
        #expect(speed.meaning == expected)
        let dir = try #require(fields.first { $0.id == (vertical ? "VPD" : "HPD") })
        #expect(dir.rawValue == direction && dir.status == "interpreted")
        #expect(dir.meaning == (direction == 0 ? "Along raster scanning" : "Against raster scanning"))
        #expect(dir.qualifier?.contains("Not physical left/right/up/down") == true)
        #expect(dir.reference.contains("US5845044A") && dir.confidence == .mostLikely)
        #expect(try JSONDecoder().decode(DVPackSemanticReport.Field.self, from: JSONEncoder().encode(speed)) == speed)
      }
    }
  }
}

@Test func cameraZoomKeepsEveryRawCodeAndExposesLayoutDisagreement() throws {
  for raw: UInt8 in 0...127 {
    for disabled: UInt8 in [0, 128] {
      let fields = DVCorpusSemantics.enrich([], pack: [0x71,0xff,0xff,0xff,raw | disabled], isPAL: false)
      let zoom = try #require(fields.first { $0.id == "ZOOM_MAGNITUDE" })
      #expect(zoom.rawValue == raw)
      #expect(fields.first { $0.id == "ZEN" }?.rawValue == UInt32(disabled >> 7))
      if raw == 127 {
        #expect(zoom.status == "unavailable" && zoom.numeric?.relation == "unknown")
      } else {
        #expect(zoom.confidence == .conflictingEvidence)
        #expect(zoom.qualifier?.contains("code 126 >4×") == true)
        #expect(zoom.qualifier?.contains("Applicable final IEC layout unresolved") == true)
        if raw == 126 {
          #expect(zoom.meaning == "≥ 8×" && zoom.numeric?.relation == "atLeast")
        } else if raw & 15 > 9 {
          #expect(zoom.status == "uninterpreted" && zoom.numeric?.relation == "raw")
        } else {
          #expect(zoom.status == "interpreted")
          #expect(zoom.meaning == String(format: "%.1f×", Double(raw >> 4) + Double(raw & 15) / 10))
        }
      }
    }
  }
  let pack: [UInt8] = [0x71,30,62,255,126]
  let invalid = try corpusReport(pack, tfInvalid: true)
  #expect(invalid.packs.first { $0.typeHex == "0x71" }?.fields.allSatisfy { $0.status == "invalid" } == true)
  let misplaced = try corpusReport(pack, offset: 86)
  #expect(misplaced.packs.first { $0.typeHex == "0x71" }?.fields.isEmpty == false)
}

@Test func corpusV2SpeedTextBinaryAndConsumerLetterbox() throws {
  for (code, expected): (UInt8,String) in [(0,"0×"),(1,"Below 1/16× (range, not exact speed)"),(2,"1/16×"),(15,"1/3×"),(16,"0.5×"),(32,"1×"),(127,"No information")] {
    let f = DVCorpusSemantics.enrich([],pack:[0x51,0,0,code,0],isPAL:false)
    #expect(f.first { $0.id == "SPD" }?.meaning == expected)
  }
  for type: UInt8 in [0x14,0x54,0x64] {
    let r = try corpusReport([type,0x21,0x43,0x65,0x87],offset:type == 0x14 ? 86 : type == 0x54 ? 483 : 253)
    #expect(r.packs.first { $0.typeHex == String(format:"0x%02X",type) }?.fields.map(\.rawValue) == [1,2,3,4,5,6,7,8])
  }
  let text = try corpusReport([0x08,255,1,2,3],offset:86)
  #expect(text.packs.first { $0.typeHex == "0x08" }?.fields.first { $0.id == "TDP" }?.rawValue == 511)
  let unknown = try corpusReport([0x28,255,1,2,3],offset:86)
  #expect(unknown.packs.first { $0.typeHex == "0x28" }?.rawComponents == nil)
  let disp = DVCorpusSemantics.enrich([],pack:[0x61,0,1,0,0],isPAL:false)
  #expect(disp.first?.confidence == .independentlyCorroborated)
  #expect(disp.first?.meaning == "4:3 — letterboxed")
  #expect(disp.first?.rawValue == 1 && disp.first?.status == "interpreted")
  #expect(disp.first?.reference.contains("MANUFACTURER_REFERENCE: Sony") == true)
}

@Test func corpusV2HistoricalSchemaDoesNotPromoteConfidence() throws {
  let report = try corpusReport([0x70,8,0,0,4])
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String:Any])
  object["schema_version"] = 1
  object.removeValue(forKey:"structuralMetadata"); object.removeValue(forKey:"absoluteOffsetsKnown")
  var packs = object["packs"] as! [[String:Any]]
  for i in packs.indices {
    packs[i].removeValue(forKey:"locations"); packs[i].removeValue(forKey:"rawComponents"); packs[i].removeValue(forKey:"catalogEvidence")
    var fields = packs[i]["fields"] as! [[String:Any]]
    for j in fields.indices { fields[j].removeValue(forKey:"confidence"); fields[j].removeValue(forKey:"qualifier"); fields[j].removeValue(forKey:"numeric") }
    packs[i]["fields"] = fields
  }
  object["packs"] = packs
  let old = try JSONDecoder().decode(DVPackSemanticReport.self,from: JSONSerialization.data(withJSONObject:object))
  #expect(old.schemaVersion == 1 && old.structuralMetadata == nil)
  #expect(old.packs.flatMap(\.fields).allSatisfy { $0.confidence == .unknown && $0.numeric == nil })
  #expect(DVMetadataConfidence.mostLikely.label == "Most likely — not 100% confirmed")
  #expect(DVMetadataConfidence.normativeConfirmed.label == "Confirmed")
}

@Test func corpusV2SubcodeCoordinatesAndFragmentValidity() throws {
  var frame = semanticFrame()
  // First triplet in the first sequence; valid FR, sync identity and ID bytes.
  for slot in 0..<3 { frame[83+slot*8] = 0x80; frame[84+slot*8] = UInt8(slot); frame[85+slot*8] = 255 }
  frame[84] = 0x30 // low fragment 1, BF 1, sync 0
  frame[92] = 0x21 // middle fragment 2, sync 1
  frame[100] = 0x32 // upper fragment 3, sync 2
  func inspect() throws -> DVPackSemanticReport { DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:frame,ordinal:0,byteOffset:120000)) }
  let report = try inspect()
  let atn = try #require(report.structuralMetadata?.first { $0.id == "atn-0-0-0" })
  let expectedATN: UInt32 = 98_561
  let actualATN = try #require(atn.fields.first?.rawValue)
  #expect(actualATN == expectedATN)
  #expect(atn.fields.first?.status == "interpreted")
  #expect(atn.locations.map(\.slot) == [0,1,2])
  #expect(atn.locations.first?.absoluteByteOffset == 120083)
  frame[92] = 0x2f
  let invalid = try inspect()
  #expect(invalid.structuralMetadata?.first { $0.id == "atn-0-0-0" }?.fields.first?.status == "invalid")
}

@Test func corpusV2ATNConflictsAndInvalidTransmissionNeverSelectPosition() throws {
  var frame = semanticFrame()
  for slot in 0..<6 { frame[83+slot*8] = 128; frame[84+slot*8] = UInt8(slot); frame[85+slot*8] = 255 }
  frame[84] = 0x20 // first triplet ATN=1; second triplet ATN=0
  func read() throws -> DVPackSemanticReport { DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:frame, ordinal:0, byteOffset:0)) }
  let conflict = try read().structuralMetadata!.filter { $0.id.hasPrefix("atn-0-0-") }
  #expect(conflict.count == 2)
  #expect(conflict.flatMap(\.fields).allSatisfy { $0.status == "conflicting" && $0.confidence == .implementationCorroborated })
  frame[7] |= 128
  let invalid = try read().structuralMetadata!.filter { $0.id.hasPrefix("sync-0-") || $0.id.hasPrefix("atn-0-") }
  #expect(invalid.flatMap(\.fields).allSatisfy { $0.status == "invalid" && $0.confidence != .unknown })
}

@Test func corpusAllOnesRemainContextualAndDisagreementIsNotMalformed() throws {
  for h: UInt8 in [0x14, 0x54, 0x64] {
    let offset = h == 0x14 ? 86 : h == 0x54 ? 483 : 253
    let report = try corpusReport([h,255,255,255,255], offset: offset)
    let pack = try #require(report.packs.first { $0.typeHex == String(format: "0x%02X", h) })
    #expect(pack.fields.count == 8)
    #expect(pack.fields.allSatisfy { $0.rawValue == 15 && $0.status == "uninterpreted" })
  }
  for h: UInt8 in [0x08,0x56,0x66] {
    let fields = DVCorpusSemantics.enrich([], pack: [h,255,255,255,255], isPAL: false)
    #expect(!fields.isEmpty && fields.allSatisfy { $0.status == "uninterpreted" })
  }
  var frame = semanticFrame()
  frame.replaceSubrange(253..<258, with: [0x70,0xc0,0,0,4])
  frame.replaceSubrange(258..<263, with: [0x70,0xc8,0,0,4])
  let report = DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 0, byteOffset: 0))
  let iris = report.packs.flatMap(\.fields).filter { $0.id == "IRIS" }
  #expect(iris.count == 2)
  #expect(iris.allSatisfy { $0.status == "conflicting" && $0.confidence == .normativeConfirmed })
  #expect(Set(iris.map(\.rawValue)) == [0,8])
}

@Test func numericContractsSurviveWithoutDisplayTextParsing() throws {
  let fields = DVCorpusSemantics.enrich([], pack: [0x71,30,62,12,126], isPAL: false)
  #expect(fields.first { $0.id == "VP_SPEED" }?.numeric?.relation == "greaterThan")
  #expect(fields.first { $0.id == "HP_SPEED" }?.numeric?.unit == "pixels/field")
  #expect(fields.first { $0.id == "ZOOM_MAGNITUDE" }?.numeric?.relation == "atLeast")
  let speed = try #require(DVCorpusSemantics.enrich([], pack: [0x51,0,0,2,0], isPAL: false).first { $0.id == "SPD" })
  #expect(speed.numeric?.bitWidth == 7 && speed.numeric?.rule.contains("1/(18-code)") == true)
  #expect(try JSONDecoder().decode(DVPackSemanticReport.Field.self, from: JSONEncoder().encode(speed)) == speed)
  let shutter = DVCorpusSemantics.enrich([], pack: [0x7f,0,0,0x34,0x92], isPAL: false).first { $0.id == "CONSUMER_SHUTTER" }
  #expect(shutter?.rawValue == 0x1234 && shutter?.numeric?.bitWidth == 15 && shutter?.numeric?.unit == "unknown")
}

@Test func adversarialAuditKeepsPrimaryMICGeometrySeparateFromApplicability() throws {
  let components = DVPackCatalog.components.filter { $0.pack == 0x00 || $0.pack == 0x01 }
  #expect(components.count == 14)
  #expect(components.allSatisfy { $0.confidence == .normativeConfirmed && $0.reference.contains("IEC 61834-4:1998") && $0.qualifier.contains("MIC was not acquired") })
  let report = try corpusReport([0x01, 0x03, 0x02, 0x01, 0xff], offset: 86)
  let pack = try #require(report.packs.first { $0.typeHex == "0x01" })
  #expect(pack.fields.isEmpty) // MIC was not acquired; tape occurrence is not promoted.
  #expect(pack.rawHex == "01 03 02 01 FF")
  #expect(pack.rawComponents == nil)
  let tag = DVCorpusSemantics.enrich([], pack: [0x0b, 3, 2, 1, 255], isPAL: false)
  #expect(tag.first { $0.id == "ATN_OR_LENGTH" }?.reference.contains("PRIMARY_STANDARD") == false)
  let invalid = try corpusReport([0x01,3,2,1,255], offset: 86, tfInvalid: true)
  #expect(invalid.packs.first { $0.typeHex == "0x01" }?.fields.allSatisfy { $0.status == "invalid" } == true)
}

@Test func adversarialCameraEvidenceDoesNotTurnCandidatesIntoMeasurements() throws {
  for code: UInt8 in 0...13 {
    let gain = try #require(DVCorpusSemantics.enrich([], pack: [0x70, 8, code, 0, 4], isPAL: false).first { $0.id == "AGC" })
    #expect(gain.rawValue == code && gain.status == "uninterpreted")
    #expect(gain.qualifier?.contains("camera disagreement") == true)
  }
  let focal = try #require(DVCorpusSemantics.enrich([], pack: [0x71,0,0,70,127], isPAL: false).first { $0.id == "FOCAL_LENGTH" })
  #expect(focal.meaning == "35 mm equivalent")
  #expect(focal.reference.contains("WO2012165218A1") && focal.confidence == .mostLikely)
  let shutter = try #require(DVCorpusSemantics.enrich([], pack: [0x7f,255,255,25,128], isPAL: false).first { $0.id == "CONSUMER_SHUTTER" })
  #expect(shutter.rawValue == 25 && shutter.status == "uninterpreted" && shutter.numeric?.relation == "raw")
  #expect(shutter.qualifier?.contains("34000") == true)
}

@Test func recordingClockResearchPreservesExactDigitsAndInvalidStates() throws {
  for seconds: UInt8 in [0x01, 0x02, 0x02, 0x04, 0x6a, 0x7f] {
    let report = try corpusReport([0x63,0xff,seconds,0x15,0x12])
    let value = try #require(report.packs.first { $0.typeHex == "0x63" }?.fields.first { $0.id == "REC_SECONDS" })
    #expect(value.rawValue == seconds)
    #expect(value.reference.contains("PRIMARY_STANDARD: IEC 61834-4:1998 §9.4"))
    #expect(value.status == (seconds == 0x6a ? "invalid" : seconds == 0x7f ? "unavailable" : "interpreted"))
  }
  #expect(DVPackCatalog.entry(0x70).name == "Consumer Camera 1")
  #expect(DVPackCatalog.entry(0x71).name == "Consumer Camera 2")
  #expect(DVPackCatalog.entry(0x72).name.lowercased().contains("reserved"))
  #expect(DVPackCatalog.entry(0x7f).name == "Shutter")
}
