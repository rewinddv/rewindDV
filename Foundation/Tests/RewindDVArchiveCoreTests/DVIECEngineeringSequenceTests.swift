// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func sequenceFrame() -> Data {
  var bytes = Data()
  for sequence in 0..<10 {
    func block(_ section: Int, _ number: Int) {
      var b = Data(repeating: 255, count: 80)
      b[0] = UInt8(section << 5); b[1] = UInt8(sequence << 4) | 4; b[2] = UInt8(number)
      if section == 0 { b[3] = 0; for i in 4...7 { b[i] = 0 } }
      if section == 4 { b[3] = 0 }
      bytes.append(b)
    }
    block(0, 0)
    for i in 0..<2 { block(1, i) }
    for i in 0..<3 { block(2, i) }
    for i in 0..<9 { block(3, i); for j in i*15..<i*15+15 { block(4, j) } }
  }
  for slot in 0..<3 {
    bytes[83 + slot*8] = 0x80
    bytes[84 + slot*8] = UInt8(slot)
    bytes[85 + slot*8] = 255
  }
  bytes.replaceSubrange(86..<91, with: [0x18, 2, 0x0e, 0x42, 255])
  bytes.replaceSubrange(94..<99, with: [0x19, 65, 66, 67, 68])
  bytes.replaceSubrange(102..<107, with: [0x19, 69, 70, 71, 72])
  return bytes
}

@Test func independentSubcodeSequenceRequiresValidSyncIdentity() throws {
  let original = sequenceFrame()
  for badSlot in [-1, 0, 1, 2] {
    var bytes = original
    if badSlot >= 0 { bytes[84 + badSlot*8] = 15 } // impossible sync index
    let sourceSnapshot = bytes
    let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0)
    let report = DVPackSemanticReport.inspect(inventory)
    let text = report.sequences?.first { $0.kind == "text" }
    if badSlot == 0 { #expect(text == nil) }
    else {
      #expect(text?.status == (badSlot < 0 ? "complete byte queue" : "incomplete byte queue"))
      #expect(text?.payload == (badSlot == 1 ? [] : badSlot == 2 ? [65,66,67,68] : [65,66,67,68,69,70,71,72]))
    }
    // Qualification changes never remove or modify the source-bound packs.
    let observations = report.packs.filter { ["0x18", "0x19"].contains($0.typeHex) }
    #expect(observations.count == 3)
    #expect(observations.flatMap(\.sourceByteOffsets).sorted() == [86,94,102])
    #expect(observations.map(\.rawHex).sorted() == ["18 02 0E 42 FF", "19 41 42 43 44", "19 45 46 47 48"])
    #expect(bytes == sourceSnapshot)
  }
}

@Test func independentSequenceMissingExtentCannotFillAQueueHole() throws {
  var bytes = sequenceFrame()
  bytes.replaceSubrange(313..<318, with: [0x68,1,0x0e,0x42,255])
  bytes.replaceSubrange(403..<408, with: [0x69,65,66,67,68])
  let source = try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 120000)
  let partial = DVMetadataInventory(schemaVersion: source.schemaVersion, frameOrdinal: source.frameOrdinal,
    frameByteOffset: source.frameByteOffset, frameByteCount: source.frameByteCount, frameSHA256: source.frameSHA256,
    extents: source.extents.filter { !($0.sequence == 0 && $0.section == 2 && $0.block == 1) },
    packs: source.packs, audioSampleRate: source.audioSampleRate, nonzeroVideoStatusBlocks: source.nonzeroVideoStatusBlocks,
    positionInterpretation: source.positionInterpretation)
  for absolute in [false, true] {
    let report = DVPackSemanticReport.inspect(partial, absoluteOffsetsKnown: absolute)
    let text = try #require(report.sequences?.first { $0.observations.first?.bytes.first == 0x68 })
    #expect(text.status == "incomplete byte queue" && text.payload.isEmpty)
    #expect(report.packs.contains { $0.rawHex == "69 41 42 43 44" })
    #expect(text.observations.first?.location?.localByteOffset == 313)
    #expect(text.observations.first?.location?.absoluteByteOffset == (absolute ? 120313 : nil))
  }
}

@Test func independentSequenceLegitimateWrapsAndAudioHalfBoundaries() throws {
  // Physical offsets independently follow the fixture's DIF block order.
  for (header, start, end, complete): (UInt8, Int, Int, Bool) in [
    (0x68,313,323,true),       // VAUX block0 slot14 -> block1 slot0
    (0x68,473,12243,true),     // VAUX sequence0 end -> sequence1 start
    (0x18,126,166,true),       // subcode block0 slot5 -> block1 slot0
    (0x58,10723,12483,true),   // AAUX sequence0 block8 -> sequence1 block0
    (0x58,58723,60483,false)   // AAUX sequence4 -> sequence5 crosses audio half
  ] {
    var bytes = sequenceFrame()
    // Clear the first test fixture's subcode packs so only this queue is tested.
    for at in [86,94,102] { bytes.replaceSubrange(at..<at+5, with: [UInt8](repeating:255,count:5)) }
    bytes.replaceSubrange(start..<start+5, with: [header,1,0x0e,0x42,255])
    bytes.replaceSubrange(end..<end+5, with: [header+1,65,66,67,68])
    if header == 0x18 {
      bytes.replaceSubrange(123..<126, with: [0x80,5,255])
      bytes.replaceSubrange(163..<166, with: [0x80,6,255])
    }
    let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0)
    let report = DVPackSemanticReport.inspect(inventory, absoluteOffsetsKnown: false)
    let text = try #require(report.sequences?.first)
    #expect(text.status == (complete ? "complete byte queue" : "incomplete byte queue"))
    #expect(text.payload == (complete ? [65,66,67,68] : []))
    #expect(text.observations.first?.location?.absoluteByteOffset == nil)
  }
}
