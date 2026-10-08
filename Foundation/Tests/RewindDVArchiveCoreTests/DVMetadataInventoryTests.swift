import Foundation
import Testing
@testable import RewindDVArchiveCore

private func inventoryFrame(pal: Bool) -> Data {
  var data = Data()
  for sequence in 0..<(pal ? 12 : 10) {
    func append(_ section: Int, _ number: Int) {
      var block = Data(repeating: 0xff, count: 80)
      block[0] = UInt8(section << 5); block[1] = UInt8(sequence << 4); block[2] = UInt8(number)
      if section == 0 { block[3] = pal ? 0x80 : 0; for n in 4...7 { block[n] = 0 } }
      if section == 1 { block.replaceSubrange(6..<11, with: [0x13, 0, 0, 0, 0]) }
      if section == 2 { block.replaceSubrange(3..<8, with: [0xe1, 1, 2, 3, 4]) }
      if section == 3 { block.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, 0]) }
      if section == 4 { block[3] = number == 0 ? 0x60 : 0 }
      data.append(block)
    }
    append(0, 0); for n in 0..<2 { append(1, n) }; for n in 0..<3 { append(2, n) }
    for group in 0..<9 { append(3, group); for n in group * 15..<(group + 1) * 15 { append(4, n) } }
  }
  return data
}

@Test(arguments: [false, true]) func inventoryRetainsUnknownAndAllMetadataExtents(pal: Bool) throws {
  let data = inventoryFrame(pal: pal)
  let value = try DVMetadataInventory.inspect(frame: data, ordinal: 42, byteOffset: 987654)
  #expect(value.extents.count == (pal ? 1800 : 1500))
  #expect(value.nonzeroVideoStatusBlocks == (pal ? 12 : 10))
  #expect(value.audioSampleRate == .known48000Hz)
  #expect(value.packs.contains { $0.typeHex == "0xE1" && $0.label.contains("Unassigned") })
  for extent in value.extents {
    let offset = Int(extent.sourceByteOffset - value.frameByteOffset)
    #expect(extent.bytes == data.subdata(in: offset..<(offset + extent.bytes.count)))
  }
  let encoded = try JSONEncoder().encode(value)
  #expect(try JSONDecoder().decode(DVMetadataInventory.self, from: encoded) == value)
}

@Test func inventoryRejectsMalformedFrameAndCoordinateOverflow() throws {
  let good = inventoryFrame(pal: false)
  for bad in [Data(), Data(good.dropLast()), Data(repeating: 0, count: 120_000)] {
    #expect(throws: (any Error).self) { try DVMetadataInventory.inspect(frame: bad, ordinal: 0, byteOffset: 0) }
  }
  #expect(throws: (any Error).self) { try DVMetadataInventory.inspect(frame: good, ordinal: 0, byteOffset: .max) }
  var duplicate = good
  duplicate.replaceSubrange(160..<240, with: good[80..<160])
  #expect(throws: (any Error).self) { try DVMetadataInventory.inspect(frame: duplicate, ordinal: 0, byteOffset: 0) }
}
