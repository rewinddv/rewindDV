import Foundation
import Testing

@testable import RewindDVMonitorCore

private let previewSourceNode: UInt8 = 7

/// Construct the physical DIF order independently of the assembler's index math:
/// header, two subcode blocks, three VAUX blocks, then nine audio/video groups.
private func syntheticDIFFrame(isPAL: Bool) -> Data {
  var frame = Data()
  for sequence in 0..<(isPAL ? 12 : 10) {
    func block(section: UInt8, number: Int) -> Data {
      var result = Data((0..<80).map {
        UInt8(truncatingIfNeeded: sequence * 37 + Int(section) * 19 + number * 11 + $0)
      })
      result[0] = section << 5 | 0x1f
      result[1] = UInt8(sequence << 4) | 7
      result[2] = UInt8(number)
      if section == 0 { result[3] = isPAL ? 0x80 : 0 }
      return result
    }
    frame.append(block(section: 0, number: 0))
    for number in 0..<2 { frame.append(block(section: 1, number: number)) }
    for number in 0..<3 { frame.append(block(section: 2, number: number)) }
    for group in 0..<9 {
      frame.append(block(section: 3, number: group))
      for number in (group * 15)..<((group + 1) * 15) {
        frame.append(block(section: 4, number: number))
      }
    }
  }
  return frame
}

private func previewPackets(
  frame: Data, initialDBC: UInt8 = 0, blocksPerPacket: Int = 1,
  sourcePacketHeader: Bool = false
) -> [Data] {
  precondition((1...8).contains(blocksPerPacket))
  var dbc = initialDBC
  var packets: [Data] = []
  for start in stride(from: 0, to: frame.count, by: 480 * blocksPerPacket) {
    let end = min(start + 480 * blocksPerPacket, frame.count)
    // Prefix is retained OHCI metadata; CIP is network byte order.
    var packet = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
      previewSourceNode, 120, sourcePacketHeader ? 4 : 0, dbc, 0x80, 0, 0xff, 0xff])
    for offset in stride(from: start, to: end, by: 480) {
      if sourcePacketHeader { packet.append(contentsOf: [0xde, 0xad, 0xbe, 0xef]) }
      packet.append(frame[offset..<(offset + 480)])
    }
    packets.append(packet)
    dbc &+= UInt8((end - start) / 480)
  }
  return packets
}

private func assemble(
  _ packets: [Data], using assembler: inout DVPreviewPacketAssembler
) -> [Data] {
  packets.flatMap {
    assembler.consumePreservedPacket($0, transferStatus: 0x11,
      expectedSourceNode: previewSourceNode)
  }
}

@Test(arguments: [false, true])
func previewAssemblerPreservesEveryDIFByteAndCompletesWithoutNextFrame(isPAL: Bool) {
  let frame = syntheticDIFFrame(isPAL: isPAL)
  #expect(frame.count == (isPAL ? 144_000 : 120_000))
  var assembler = DVPreviewPacketAssembler()
  let packets = previewPackets(frame: frame, initialDBC: 250)
  #expect(assemble(Array(packets.dropLast()), using: &assembler).isEmpty)
  #expect(assemble([packets.last!], using: &assembler) == [frame])
  #expect(assembler.discontinuities == 0)
  #expect(assembler.rejectedPackets == 0)
  #expect(assembler.incompleteFrames == 0)
}

@Test(arguments: [false, true])
func receiverDoesNotRequireTimecodeOrAudioVideoMetadata(isPAL: Bool) {
  var frame = syntheticDIFFrame(isPAL: isPAL)
  for block in stride(from: 0, to: frame.count, by: 80) {
    let section = frame[block] >> 5
    // Retain DIF IDs/structure and video payload, remove all subcode/VAUX
    // metadata and AAUX packs. No timecode, sample-rate or camera facts exist.
    if section == 1 || section == 2 {
      frame.replaceSubrange((block + 3)..<(block + 80), with: repeatElement(UInt8(0xff), count: 77))
    } else if section == 3 {
      frame.replaceSubrange((block + 3)..<(block + 8), with: repeatElement(UInt8(0xff), count: 5))
    }
  }
  var assembler = DVPreviewPacketAssembler()
  #expect(assemble(previewPackets(frame: frame), using: &assembler) == [frame])
  #expect(assembler.rejectedPackets == 0 && assembler.incompleteFrames == 0)
}

@Test(arguments: [false, true])
func previewAssemblerHandlesMultipleSourceBlocksAndOptionalHeaders(isPAL: Bool) {
  let frame = syntheticDIFFrame(isPAL: isPAL)
  for sourceHeader in [false, true] {
    for blocksPerPacket in [2, 7, 8] {
      var assembler = DVPreviewPacketAssembler()
      let packets = previewPackets(frame: frame, initialDBC: 253,
        blocksPerPacket: blocksPerPacket, sourcePacketHeader: sourceHeader)
      #expect(assemble(packets, using: &assembler) == [frame])
      #expect(assembler.discontinuities == 0)
    }
  }
}

@Test func previewAssemblerRejectsMalformedTransportAndRecoversOnFreshHeader() {
  let frame = syntheticDIFFrame(isPAL: false)
  let valid = previewPackets(frame: frame)
  let mutations: [(inout Data) -> Void] = [
    { $0 = Data($0.prefix(15)) },
    { $0.append(contentsOf: repeatElement(UInt8(0), count: 4097)) },
    { $0[8] |= 0x40 },
    { $0[8] = previewSourceNode + 1 },
    { $0[9] = 119 },
    { $0[10] = 0x80 },
    { $0[10] = 1 },
    { $0[12] = 0 },
    { $0[12] = 0x81 },
    { $0.removeLast() },
  ]
  for mutate in mutations {
    var assembler = DVPreviewPacketAssembler()
    #expect(assemble([valid[0]], using: &assembler).isEmpty)
    var invalid = valid[1]
    mutate(&invalid)
    #expect(assemble([invalid], using: &assembler).isEmpty)
    #expect(assembler.rejectedPackets == 1)
    #expect(assembler.incompleteFrames == 1)
    #expect(assemble(valid, using: &assembler) == [frame])
  }
  for (status, node) in [(UInt16(0x10), previewSourceNode), (UInt16(0x11), UInt8(64))] {
    var assembler = DVPreviewPacketAssembler()
    #expect(assembler.consumePreservedPacket(valid[0], transferStatus: status,
      expectedSourceNode: node).isEmpty)
    #expect(assembler.rejectedPackets == 1)
  }
}

@Test func previewAssemblerRejectsGapsDuplicatesAndInvalidDIFBlocks() {
  let frame = syntheticDIFFrame(isPAL: false)
  let valid = previewPackets(frame: frame)
  var gap = valid
  gap.remove(at: 12)
  var gapAssembler = DVPreviewPacketAssembler()
  #expect(assemble(gap, using: &gapAssembler).isEmpty)
  #expect(gapAssembler.discontinuities == 1)
  #expect(gapAssembler.incompleteFrames == 1)
  #expect(assemble(valid, using: &gapAssembler) == [frame])

  for invalidBlock in [0, 1, 2] {
    var damaged = valid
    switch invalidBlock {
    case 0: // Duplicate a non-header block while keeping transport continuity.
      damaged[1].replaceSubrange(96..<176, with: damaged[1][16..<96])
    case 1: damaged[1][16] = 7 << 5 // Invalid DIF section.
    default: damaged[1][17] = 15 << 4 // Out-of-range DIF sequence.
    }
    var assembler = DVPreviewPacketAssembler()
    #expect(assemble(damaged, using: &assembler).isEmpty)
    #expect(assemble(valid, using: &assembler) == [frame])
    #expect(assembler.incompleteFrames == 1)
  }
}

@Test func previewAssemblerRejectsIncompleteFrameAndResetsExplicitly() {
  let frame = syntheticDIFFrame(isPAL: true)
  let packets = previewPackets(frame: frame)
  var assembler = DVPreviewPacketAssembler()
  #expect(assemble(Array(packets.prefix(20)), using: &assembler).isEmpty)
  // Fresh header with continuous DBC still must discard the partial old frame.
  #expect(assemble(previewPackets(frame: frame, initialDBC: 20), using: &assembler) == [frame])
  #expect(assembler.incompleteFrames == 1)
  #expect(assembler.discontinuities == 0)
  assembler.reset()
  #expect(assembler.incompleteFrames == 0)
  #expect(assembler.rejectedPackets == 0)
  #expect(assembler.discontinuities == 0)
  #expect(assemble(packets, using: &assembler) == [frame])
}

@Test func previewAssemblerKnownTransportGapRetainsCountersDespiteAlignedWrappedDBC() {
  let frame = syntheticDIFFrame(isPAL: false)
  var assembler = DVPreviewPacketAssembler()
  // Seed all run counters with an earlier malformed packet and partial gap.
  #expect(assemble([Data()], using: &assembler).isEmpty)
  let earlier = previewPackets(frame: frame, initialDBC: 250)
  #expect(assemble([earlier[0], earlier[2]], using: &assembler).isEmpty)
  #expect(assembler.rejectedPackets == 1)
  #expect(assembler.discontinuities == 1)
  #expect(assembler.incompleteFrames == 1)

  let packets = previewPackets(frame: frame, initialDBC: 253)
  #expect(assemble(Array(packets.prefix(3)), using: &assembler).isEmpty)
  #expect(packets[2][11] == 255 && packets[3][11] == 0)
  // Simulate known ring loss of 256 source blocks. DBC alone still matches,
  // including its 255 -> 0 wrap; the explicit gap must invalidate assembly.
  assembler.markTransportGap()
  #expect(assembler.rejectedPackets == 1)
  #expect(assembler.discontinuities == 2)
  #expect(assembler.incompleteFrames == 2)
  #expect(assemble(Array(packets.dropFirst(3)), using: &assembler).isEmpty)
  #expect(assembler.discontinuities == 2)
  #expect(assembler.incompleteFrames == 2)

  // A fresh header can recover without erasing diagnostics from this run.
  let nextDBC = UInt8(truncatingIfNeeded: 253 + packets.count)
  #expect(assemble(previewPackets(frame: frame, initialDBC: nextDBC), using: &assembler) == [frame])
  #expect(assembler.rejectedPackets == 1)
  #expect(assembler.discontinuities == 2)
  #expect(assembler.incompleteFrames == 2)
}
