// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func browserField(_ value:UInt32,_ status:String="interpreted",meaning:String="f-number") -> DVPackSemanticReport.Field {
 .init(id:"IRIS",name:"Recorded iris",rawValue:value,meaning:meaning,status:status,reference:"PRIMARY_STANDARD: synthetic-test reference §10.1",confidence:.normativeConfirmed)
}
private func browserReport(_ fields:[DVPackSemanticReport.Field]) -> DVPackSemanticReport {
 let packs=fields.enumerated().map { index,field in
  DVPackSemanticReport.Pack(id:"test\(index)",typeHex:"0x70",name:"Camera",rawHex:"70 FF FF FF FF",sourceByteOffsets:[UInt64(index*5)],status:"Synthetic test",fields:[field])
 }
 return .init(schemaVersion:3,frameOrdinal:0,frameByteOffset:0,frameSHA256:"synthetic",format:"IEC 61834 consumer DV",formatEvidence:"Synthetic presentation test",packs:packs,missingPrincipalPacks:[])
}
@Test func browserCoalescesOnlyExactInterpretationsAndRetainsAllObservations() {
 let r=browserReport([browserField(8),browserField(8),browserField(9),browserField(8,"conflicting")])
 let entries=DVInspectorBrowser.entries(r)
 #expect(entries.count == 3)
 let repeated=entries.first { $0.count == 2 }
 #expect(repeated?.observations.count == 2)
 #expect(repeated?.observations.joined().contains("Source byte 5") == true)
 #expect(entries.contains { $0.badge == "Conflicting" })
 #expect(Set(entries.map(\.id)).count == 3)
}
@Test func browserSearchUsesReadableNamesValuesPackIdsAndReferences() {
 let entries=DVInspectorBrowser.entries(browserReport([browserField(8,meaning:"8 f-number")]))
 for term in ["iris","f/8","0x70","10.1"] {
  #expect(DVInspectorBrowser.filter(entries,query:term,category:.camera).count == 1)
 }
 #expect(DVInspectorBrowser.filter(entries,query:"iris",category:.audio).isEmpty)
 #expect(DVInspectorBrowser.filter(entries,query:"something absent",category:.all).isEmpty)
}
@Test func browserDistinguishesAbsentInapplicableAndUnqualifiedValues() {
 let entries=DVInspectorBrowser.entries(browserReport([
  browserField(63,"unavailable",meaning:"No information"),
  browserField(0,"unavailable",meaning:"Not used"),
  browserField(1,"unavailable",meaning:"Matching header unavailable")]))
 #expect(Set(entries.compactMap(\.badge)) == ["Not recorded","Not applicable","Unavailable"])
 #expect(entries.first{$0.badge == "Not recorded"}?.value == "Not recorded")
}
@Test func browserLineComponentKeepsIdentityExpectedCountAndPadding() {
 var r=browserReport([])
 r.sequences=DVIECSequences.assemble([.init([0x80,1,0x90,3,0x80]),.init([0x81,1,2,3,255])])
 let entries=DVInspectorBrowser.entries(r)
 let component=entries.first { $0.name == "Line component 1" }
 #expect(component?.category == .video)
 #expect(component?.value.contains("0x81") == true)
 #expect(component?.value.contains("3 expected samples") == true)
 #expect(component?.value.contains("1 padding samples") == true)
}
