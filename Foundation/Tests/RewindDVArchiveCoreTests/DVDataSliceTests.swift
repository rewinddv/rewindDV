// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func nonzeroSlice(_ bytes: Data) -> Data {
  (Data(repeating: 0xa5, count: 128) + bytes).dropFirst(128)
}

@Test(arguments: [false, true]) func slicedDVFrameRetainsExactMetadataAndCoordinates(pal: Bool) throws {
  let frame = ingestFrame(pal: pal), slice = nonzeroSlice(frame)
  #expect(slice.startIndex == 128)
  #expect(try DVMetadataInventory.inspect(frame: slice, ordinal: 7, byteOffset: 900_000)
    == DVMetadataInventory.inspect(frame: frame, ordinal: 7, byteOffset: 900_000))
  #expect(DVCaptureMetadataEpochAnalyzer.analyze(data: slice)
    == DVCaptureMetadataEpochAnalyzer.analyze(data: frame))
  let expected = try DVFrameForensics.inspect(frame: frame, ordinal: 7, offset: 900_000)
  let observed = try DVFrameForensics.inspect(frame: slice, ordinal: 7, offset: 900_000)
  #expect(observed.summary == expected.summary)
  #expect(observed.blocks == expected.blocks)
  #expect(observed.audioErrors == expected.audioErrors)
  #expect(DVFrameForensics.hexDump(nonzeroSlice(frame.prefix(41)), sourceOffset: 900_000)
    == DVFrameForensics.hexDump(frame.prefix(41), sourceOffset: 900_000))
}

@Test(arguments: [false, true]) func slicedPacketsReconstructIdenticalBytes(pal: Bool) {
  let frame = ingestFrame(pal: pal)
  var assembler = DVDIFPacketAssembler(), output: [Data] = []
  for packet in ingestPackets(frame) {
    output += assembler.consumePreservedPacket(nonzeroSlice(packet), transferStatus: 0x11, expectedSourceNode: 7)
  }
  assembler.finish()
  #expect(output == [frame])
  #expect(assembler.rejectedPackets == 0)
  #expect(assembler.incompleteFrames == 0)
  #expect(assembler.discontinuities == 0)
  _ = assembler.consumePreservedPacket(nonzeroSlice(Data([0])), transferStatus: 0x11, expectedSourceNode: 7)
  #expect(assembler.rejectedPackets == 1)
}
