// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func completedFields(_ frame:Data,_ header:String,_ id:String) throws -> [DVPackSemanticReport.Field] {
 let r=DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:frame,ordinal:0,byteOffset:0))
 return r.packs.filter { $0.typeHex == header }.flatMap(\.fields).filter { $0.id == id }
}
private func userFrame(_ clock:[UInt8]?,_ binary:[UInt8],smpte:Bool=true,pal:Bool=false) -> Data {
 var f=semanticFrame(smpte:smpte,pal:pal)
 if smpte { for seq in 0..<(pal ? 12:10) { f[seq*12000+3]=(pal ? 128:0)|63;f[seq*12000+4]=0xf9;for b in 5...7 { f[seq*12000+b]=0x79 } } }
 // First two subcode sync blocks; preserve valid IDs and original test bytes.
 let clockOffset=smpte ? 110:86, binaryOffset=smpte ? 118:94
 for slot in 0..<6 { f[83+slot*8] = smpte && ![0].contains(slot) ? 0xf0:0x80; f[84+slot*8]=UInt8(slot);f[85+slot*8]=255 }
 if smpte { f[83]=0x90 }
 if let clock { f.replaceSubrange(clockOffset..<clockOffset+5,with:clock) }
 f.replaceSubrange(binaryOffset..<binaryOffset+5,with:binary)
 return f
}
@Test(arguments:[false,true]) func completionUserBitsDateAndZoneFollowRecordedUsage(pal:Bool) throws {
 let clock:[UInt8]=pal ? [0x13,0,0,0x80,0x40]:[0x13,0,0,0,0xc0]
 let f=userFrame(clock,[0x14,0x18,0x11,0x04,0x47],pal:pal)
 #expect(try completedFields(f,"0x14","USER_RECORDED_DATE").first?.meaning == "Year 04 · month 11 · day 18")
 #expect(try completedFields(f,"0x14","USER_TIME_ZONE").first?.meaning == "UTC−07:00")
 #expect(try completedFields(f,"0x14","USER_DAYLIGHT_SAVING").first?.meaning == "In effect")
 #expect(try completedFields(f,"0x13","CLOCK_REFERENCE").first?.meaning.contains("external") == true)
 #expect(try completedFields(f,"0x14","BG8").first?.rawValue == 4)
}
@Test func completionUserBitsMissingAndConflictingContextDoesNotChooseMeaning() throws {
 let binary:[UInt8]=[0x14,0x18,0x11,0x04,0x07]
 let missing=userFrame(nil,binary)
 #expect(try completedFields(missing,"0x14","USER_RECORDED_DATE").isEmpty)
 #expect(try completedFields(missing,"0x14","USER_BITS_USAGE").first?.status == "uninterpreted")
 var conflict=userFrame([0x13,0,0,0,0x80],binary)
 conflict.replaceSubrange(126..<131,with:[0x13,0,0,0x80,0])
 #expect(try completedFields(conflict,"0x14","USER_RECORDED_DATE").isEmpty)
 #expect(try completedFields(conflict,"0x14","USER_BITS_USAGE").first?.status == "uninterpreted")
 // Page/line multiplex is distinct from date even with a clock-reference bit.
 let page=userFrame([0x13,0,0,0x80,0xc0],binary)
 #expect(try completedFields(page,"0x14","USER_RECORDED_DATE").isEmpty)
}
@Test func completionISOCharacterOrderAndUnknownSetsRemainBounded() {
 #expect(DVTimecodeUserBits.binaryFields([0x14,0x44,0x43,0x42,0x41],usage:1).first{$0.id == "USER_BITS_TEXT"}?.meaning == "ISO 646 candidate: ABCD")
 for byte in [UInt8(0x1b),0x80,0x23,0x5b] {
  #expect(DVTimecodeUserBits.binaryFields([0x14,byte,0x43,0x42,0x41],usage:1).first{$0.id == "USER_BITS_TEXT"}?.status == "uninterpreted")
 }
}
@Test func completionST309MJDConflictAndInvalidDatesStayExplicit() {
 let mjd=DVTimecodeUserBits.binaryFields([0x14,0x18,0x97,0x04,0x80],usage:4)
 #expect(mjd.first{$0.id == "USER_RECORDED_DATE"}?.meaning.contains("1995-01-01") == true)
 #expect(mjd.first{$0.id == "USER_RECORDED_DATE"}?.confidence == .conflictingEvidence)
 for p:[UInt8] in [[0x14,0x31,0x04,0x04,0],[0x14,0x1a,0x11,0x04,0],[0x14,0x29,0x02,0x03,0]] {
  #expect(DVTimecodeUserBits.binaryFields(p,usage:4).first{$0.id == "USER_RECORDED_DATE"}?.status == "invalid")
 }
}
@Test func completionST309TimeZoneTableIncludesHalfHoursAndSpecialCodes() {
 let cases:[UInt8:String]=[0:"UTC+00:00",0x12:"UTC−12:00",0x13:"UTC+13:00",0x25:"UTC+01:00",0x0a:"UTC−00:30",0x1f:"UTC−11:30",0x2a:"UTC+11:30",0x3f:"UTC+00:30",0x32:"UTC+12:45"]
 for (code,label) in cases { #expect(DVTimecodeUserBits.timeZone(code).meaning == label) }
 for code:UInt8 in 0...63 {
  let valid=cases[code] != nil || (code&15<10 && code>>4<=2 && Int(code>>4)*10+Int(code&15)<=25) || [0,1,2,3].contains(code>>4) && code&15>=10
  #expect((DVTimecodeUserBits.timeZone(code).status == "interpreted") == valid)
 }
 #expect(DVTimecodeUserBits.timeZone(0x38).status == "uninterpreted")
 #expect(DVTimecodeUserBits.timeZone(0x39).status == "unavailable")
}
@Test(arguments:[false,true]) func completionSMPTETransportAndPhaseHaveExactBounds(pal:Bool) throws {
 let speed=try completedFields(semanticFrame(smpte:true,pal:pal,audioControl:[0x51,0x3c,0x0f,0xe4,0xff]),"0x51","SPD")
 #expect(speed.first?.meaning == (pal ? "1×":"0.833333333333×"))
 #expect(try completedFields(semanticFrame(smpte:true,pal:pal,audioControl:[0x51,0x3c,0x0f,0xff,0xff]),"0x51","SPD").first?.status == "invalid")
 for (code,status): (UInt8,String) in [(0x88,"interpreted"),(0x78,"interpreted"),(0x80,"reserved"),(0x7f,"unavailable")] {
  #expect(try completedFields(semanticFrame(smpte:true,pal:pal,video:[0x60,0xff,0xff,0xc0,code]),"0x60","VISC").first?.status == status)
 }
 #expect(try completedFields(semanticFrame(smpte:true),"0x60","PC1_FIXED").first?.status == "interpreted")
}
@Test func completionIECBinaryCompanionAndShutterRequireSourceContext() throws {
 let good=userFrame([0x13,0,0,0,0x80],[0x14,0x18,0x11,0x04,7],smpte:false)
 #expect(try completedFields(good,"0x13","BGF_USAGE").first?.meaning == "Recorded date and time zone")
 var f=semanticFrame()
 f.replaceSubrange(253..<258,with:[0x7f,0xff,0xff,0x7d,0x80])
 let supported=try completedFields(f,"0x7F","CONSUMER_SHUTTER")
 #expect(supported.first?.confidence == .provisional)
 #expect(supported.first?.meaning.contains("0.007944") == true)
 // A contradictory source profile removes the inferred horizontal period.
 f.replaceSubrange(12243..<12248,with:[0x60,0xff,0xff,0xc2,0xff])
 #expect(try completedFields(f,"0x7F","CONSUMER_SHUTTER").first?.numeric?.unit == "horizontal periods")
}
@Test func completionIECGenreCompanionMustBeUnambiguousAndSameArea() throws {
 var f=semanticFrame(videoControl:[0x61,0xff,0xc8,0xfc,0xaf])
 f.replaceSubrange(253..<258,with:[0x06,0x06,1,0xff,0xff])
 #expect(try completedFields(f,"0x06","CATEGORY").first?.meaning.contains("Ball games") == true)
 f.replaceSubrange(12248..<12253,with:[0x61,0xff,0xc8,0xfc,0x9f])
 #expect(try completedFields(f,"0x06","CATEGORY").first?.status == "uninterpreted")
}
@Test func completionTextOnlyRendersCompleteUnshiftedTextAndPreservesPadding() throws {
 func sequence(_ head:[UInt8],_ body:[UInt8],qualified:Bool=true) -> DVIECSequences.Sequence? {
  DVIECSequences.assemble([.init(head),.init(body,qualified:qualified)]).first
 }
 let header:[UInt8]=[0x68,1,0x0e,0x42,0xff]
 #expect(sequence(header,[0x69,84,69,83,84])?.decodedText == "TEST")
 #expect(sequence(header,[0x69,65,32,32,32])?.decodedText == "A   ")
 for bytes:[UInt8] in [[0x69,65,27,66,67],[0x69,65,0xff,66,67]] { #expect(sequence(header,bytes)?.decodedText == nil) }
 #expect(sequence(header,[0x69,84,69,83,84],qualified:false)?.decodedText == nil)
 #expect(sequence([0x68,1,0xce,0x42,0xff],[0x69,84,69,83,84])?.decodedText == nil)
 let s=try #require(sequence(header,[0x69,84,69,83,84]))
 #expect(try JSONDecoder().decode(DVIECSequences.Sequence.self,from:JSONEncoder().encode(s)) == s)
 #expect(DVIEC61834.characterSetName(0x42).contains("US"))
}
@Test(arguments:[false,true]) func completionTeletextUsesOnlyEstablishedFirstIdentifier(pal:Bool) {
 let input:[[UInt8]]=[[0x68,1,0xae,0x42,0xff],[0x0c,0x12,0xf3,4,5],[0x67,0xc0,0x11,0x22,0x33]]
 let s=DVIECSequences.assemble(input.map { .init($0) },isPAL:pal).first
 #expect(s?.firstTeletextID?.system == 3)
 #expect(s?.firstTeletextID?.lineNumber == (pal ? 6:10))
 #expect(s?.teletextInformation?.first{$0.id == "PAGE"}?.meaning == "12")
 var reserved=input;reserved[2][1]=0x80
 let unknown=DVIECSequences.assemble(reserved.map { .init($0) },isPAL:pal).first
 #expect(unknown?.firstTeletextID?.status == "reserved")
 #expect(unknown?.teletextInformation == nil)
}

@Test(arguments:[false,true]) func completionRejectsInvalidCompanionSyncIds(pal:Bool) throws {
 for smpte in [false,true] {
  let clock:[UInt8]=pal ? [0x13,0,0,0x80,0]:[0x13,0,0,0,0x80]
  let original=userFrame(clock,[0x14,0x18,0x11,4,7],smpte:smpte,pal:pal)
  for slot in smpte ? [3,4]:[0,1] {
   var damaged=original;damaged[84+slot*8]=15
   #expect(try completedFields(damaged,"0x14","USER_RECORDED_DATE").isEmpty)
   #expect(damaged != original)
  }
  if smpte {
   let report=DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:original,ordinal:0,byteOffset:0))
   let structural=report.structuralMetadata?.filter{$0.id.hasPrefix("sync-")}.flatMap(\.fields) ?? []
   #expect(structural.contains { $0.id == "ID_LOW4" && $0.status == "interpreted" })
   #expect(!structural.contains { $0.id == "ATN_FRAGMENT" })
  }
 }
}
@Test func completionUnsupportedSMPTERecordingBinaryPacksStayUnqualified() throws {
 let r=semanticFrame(smpte:true,audio:[0x53,0,0,0,0x80],audioControl:[0x54,0x18,0x11,4,7])
 #expect(try completedFields(r,"0x54","USER_RECORDED_DATE").isEmpty)
 #expect(try completedFields(r,"0x54","USER_BITS_HEX").isEmpty)
}
@Test func completionGenreNonrefiningCounterpartStillCreatesAmbiguity() throws {
 var f=semanticFrame(videoControl:[0x61,0xff,0xc8,0xfc,0xaf])
 f.replaceSubrange(253..<258,with:[6,6,1,0xff,0xff])
 f.replaceSubrange(12248..<12253,with:[0x61,0xff,0xc8,0xfc,0x93])
 #expect(try completedFields(f,"0x06","CATEGORY").first?.status == "uninterpreted")
}
@Test func completionCatalogueAndPartialRecordingCodePreserveLeadingZeros() throws {
 var f=semanticFrame()
 f.replaceSubrange(253..<258,with:[0x16,0x0e,0x21,0x43,0x65])
 f.replaceSubrange(258..<263,with:[0x16,0x7f,0x98,0x10,0xf2])
 f.replaceSubrange(263..<268,with:[0x17,0x0f,0x14,0x32,0x54])
 let r=DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:f,ordinal:0,byteOffset:1000))
 #expect(r.sequences?.first{$0.kind == "catalogue number"}?.decodedText == "0123456789012")
 #expect(r.sequences?.first{$0.kind == "catalogue number"}?.observations.count == 2)
 #expect(r.packs.filter{$0.typeHex == "0x16"}.flatMap(\.fields).filter{$0.id == "CATALOGUE_FORM"}.allSatisfy{$0.status == "interpreted"})
 #expect(r.packs.filter{$0.typeHex == "0x17"}.flatMap(\.fields).first{$0.id == "ISRC_YEAR_SUFFIX"}?.meaning == "04")
 #expect(r.packs.filter{$0.typeHex == "0x17"}.flatMap(\.fields).first{$0.id == "ISRC_DESIGNATION"}?.meaning == "12345")
 #expect(r.packs.flatMap{$0.locations ?? []}.allSatisfy{["valid","invalid","unavailable"].contains($0.transmission)})
 // A second first-form value makes assembly ambiguous, never selects a pair.
 f.replaceSubrange(268..<273,with:[0x16,0x1e,0x21,0x43,0x65])
 let conflicting=DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:f,ordinal:0,byteOffset:1000))
 #expect(conflicting.sequences?.contains{$0.kind == "catalogue number"} != true)
}
@Test func completionMixedSyncQualificationKeepsUniqueStableIdentityAndRawLocations() throws {
 var f=userFrame([0x13,0,0,0,0x80],[0x14,0x18,0x11,4,7],smpte:false)
 f.replaceSubrange(102..<107,with:[0x14,0x18,0x11,4,7]);f[100]=15
 let inventory=try DVMetadataInventory.inspect(frame:f,ordinal:0,byteOffset:777)
 let a=DVPackSemanticReport.inspect(inventory),b=DVPackSemanticReport.inspect(inventory)
 #expect(a == b)
 #expect(Set(a.packs.map(\.id)).count == a.packs.count)
 let pairs=a.packs.filter{$0.typeHex == "0x14"}
 #expect(pairs.count == 2)
 #expect(pairs.flatMap(\.sourceByteOffsets).sorted() == [871,879])
 #expect(pairs.filter{$0.id.hasSuffix(":associated")}.flatMap(\.fields).contains{$0.id == "USER_RECORDED_DATE"})
 #expect(!pairs.filter{$0.id.hasSuffix(":unqualified")}.flatMap(\.fields).contains{$0.id == "USER_RECORDED_DATE"})
}
@Test func completionComplementaryCoordinatesAndShadingDoNotCreateFalseConflicts() throws {
 var f=semanticFrame()
 let packs:[[UInt8]]=[[0x6d,0x30,0x20,0x18,0xfe],[0x6d,0x95,0x10,0x45,0xff],[0x7d,0x40,0x40,0x40,0x40],[0x7d,0x40,0xc0,0x40,0x40],[0x7d,0xc0,0x40,0x40,0xc0]]
 for (i,p) in packs.enumerated() { f.replaceSubrange(253+i*5..<258+i*5,with:p) }
 let r=DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame:f,ordinal:0,byteOffset:0))
 #expect(!r.packs.filter{["0x6D","0x7D"].contains($0.typeHex)}.flatMap(\.fields).contains{$0.status == "conflicting"})
 // Another longitude differs within the same form and still raises conflict.
 f.replaceSubrange(278..<283,with:[0x6d,0x30,0x20,0x19,0xfe])
 #expect(try completedFields(f,"0x6D","DEGREES").contains{$0.status == "conflicting"})
}
