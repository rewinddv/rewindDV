// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func frame(_ packs: [[UInt8]]) -> Data {
 var result = Data()
 for seq in 0..<10 {
  func block(_ section: Int, _ number: Int) {
   var b = Data(repeating: 255, count: 80)
   b[0] = UInt8(section << 5); b[1] = UInt8(seq << 4) | 4; b[2] = UInt8(number)
   if section == 0 { b[3] = 0; for i in 4...7 { b[i] = 0 } }
   if section == 2 && seq == 0 && number == 0 {
    for (i,p) in packs.enumerated() { b.replaceSubrange((3+i*5)..<(8+i*5),with:p) }
   }
   if section == 4 { b[3] = 0 }
   result.append(b)
  }
  block(0,0); for i in 0..<2 { block(1,i) }; for i in 0..<3 { block(2,i) }
  for i in 0..<9 { block(3,i); for j in i*15..<i*15+15 { block(4,j) } }
 }
 return result
}

@Test func independentConflictingBroadcastSystemsCannotChooseAspect() throws {
 // Keep DISP fixed while flipping only its contextual selector. The two
 // established contexts have contradictory full-frame aspect semantics.
 let bytes = frame([[0x61,255,0xca,0xfc,255],[0x61,255,0xca,0xfd,255]])
 let inventory = try DVMetadataInventory.inspect(frame:bytes,ordinal:0,byteOffset:0)
 let specs = DVTechnicalSpecifications.make(path:"synthetic",byteCount:120000,inventory:inventory)
 let row = try #require(specs.sections.flatMap(\.rows).first { $0.label == "Tape-reported display aspect ratio" })
 #expect(row.value == "Conflicting values — no selection")
 #expect(LiveDVMedia(frame:bytes)?.widescreen == nil)
 #expect(specs.semanticReport?.packs.filter { $0.typeHex == "0x61" }.count == 2)
}

@Test func independentDisplayAspectUsesEstablishedBroadcastContext() throws {
 for (bcs, disp, expected, widescreen): (UInt8,UInt8,String,Bool?) in [
  (0,2,"16:9",true), (1,2,"4:3 — 14:9 letterbox top",false),
  (1,7,"16:9",true), (0,1,"4:3 — letterboxed",false)
 ] {
  let bytes = frame([[0x61,255,0xc8|disp,0xfc|bcs,255]])
  let inventory = try DVMetadataInventory.inspect(frame:bytes,ordinal:0,byteOffset:0)
  let specs = DVTechnicalSpecifications.make(path:"synthetic",byteCount:120000,inventory:inventory)
  #expect(specs.sections.flatMap(\.rows).first { $0.label == "Tape-reported display aspect ratio" }?.value == expected)
  #expect(LiveDVMedia(frame:bytes)?.widescreen == widescreen)
 }
}
