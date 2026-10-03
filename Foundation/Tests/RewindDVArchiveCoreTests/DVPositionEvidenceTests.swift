import Foundation
import Testing
@testable import RewindDVArchiveCore

private func positionFrame(base: UInt32, pal: Bool = false) -> Data {
  var data = Data()
  let tracks = pal ? 12 : 10
  for sequence in 0..<tracks {
    func append(_ section: Int, _ number: Int) {
      var block = Data(repeating: 0xff, count: 80)
      block[0] = UInt8(section << 5); block[1] = UInt8(sequence << 4) | 4; block[2] = UInt8(number)
      if section == 0 { block[3] = pal ? 0x80 : 0; for n in 4...7 { block[n] = 0 } }
      if section == 1 {
        let packed = (((base + UInt32(sequence)) & 0x7fffff) << 1) | 1
        for group in 0..<2 {
          for index in 0..<3 {
            let fragment = UInt8(truncatingIfNeeded: packed >> (index * 8))
            let offset = 3 + (group * 3 + index) * 8
            block[offset] = (sequence < tracks / 2 ? 0x80 : 0) | (fragment >> 4)
            block[offset + 1] = (fragment << 4) | UInt8(number * 6 + group * 3 + index)
            block[offset + 2] = 0xff
          }
        }
      }
      data.append(block)
    }
    append(0, 0); for n in 0..<2 { append(1, n) }; for n in 0..<3 { append(2, n) }
    for group in 0..<9 { append(3, group); for n in group * 15..<(group + 1) * 15 { append(4, n) } }
  }
  return data
}

private func position(_ frame: Data, ordinal: UInt64 = 0) throws -> DVPositionEvidence {
  DVPositionEvidence.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: ordinal, byteOffset: 0))
}

@Test(arguments: [false, true]) func positionCopiesPreserveRawAndRoundTrip(pal: Bool) throws {
  let frame = positionFrame(base: 500, pal: pal)
  let value = try position(frame)
  #expect(value.classification == .consistent)
  #expect(value.normalizedFrameTrackCandidates == [500])
  #expect(value.copies.count == (pal ? 48 : 40))
  for copy in value.copies {
    for (offset, bytes) in zip(copy.sourceByteOffsets, copy.rawIDs) {
      #expect(Array(frame[Int(offset)..<(Int(offset) + 3)]) == bytes)
    }
  }
  #expect(try JSONDecoder().decode(DVPositionEvidence.self, from: JSONEncoder().encode(value)) == value)
  #expect(value.etnStatus.contains("not_decoded"))
}

@Test func positionRejectsUnsupportedMissingConflictingAndInvalidSync() throws {
  let frame = positionFrame(base: 100)
  var unsupported = frame; unsupported[4] = 1
  #expect(try position(unsupported).classification == .unsupportedApplication)
  var missing = frame
  for seq in 0..<10 { for block in 1...2 { for slot in 0..<6 {
    let offset = seq * 12000 + block * 80 + 3 + slot * 8
    missing.replaceSubrange(offset..<(offset + 3), with: [255,255,255])
  } } }
  #expect(try position(missing).classification == .unavailable)
  var conflict = frame; conflict[84] ^= 0x20
  #expect(try position(conflict).classification == .conflicting)
  var invalid = frame; invalid[85] = 0
  #expect(try position(invalid).classification == .partial)
  var transmission = frame; transmission[7] |= 0x80
  #expect(try position(transmission).classification == .partial)
}

@Test func positionContinuityNeverInfersPacketLossOrUnwraps() throws {
  var observer = DVPositionContinuity()
  #expect(observer.observe(try position(positionFrame(base: 100))).event == "first_consistent_observation")
  #expect(observer.observe(try position(positionFrame(base: 110), ordinal: 1)).event == "expected_forward_increment")
  #expect(observer.observe(try position(positionFrame(base: 110), ordinal: 2)).event == "repeated_position")
  #expect(observer.observe(try position(positionFrame(base: 200), ordinal: 3)).event == "position_jump_not_packet_loss_proof")
  #expect(observer.observe(try position(positionFrame(base: 90), ordinal: 4)).event == "reverse_or_reset_not_resolved")
  var wrap = DVPositionContinuity()
  _ = wrap.observe(try position(positionFrame(base: 0x7ffff0)))
  // Crossing the all-ones unavailable code makes this physical frame partial.
  // Do not bridge that missing observation to manufacture wrap authority.
  #expect(wrap.observe(try position(positionFrame(base: 0x7ffffa), ordinal: 1)).event == "unusable_or_conflicting_position")
  #expect(wrap.observe(try position(positionFrame(base: 4), ordinal: 2)).event == "first_consistent_observation")
}
