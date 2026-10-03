import Testing
@testable import RewindDVControlCore

@Test func catalogCoversAllTapeFamiliesWithoutEnablingThem() {
  let expected: [UInt8] = [0x40,0x45,0x50,0x51,0x52,0x53,0x54,0x55,0x56,0x57,0x59,0x5a,0x5c,0x60,0x61,0x62,0x70,0x71,0x72,0x78,0x79,0xc1,0xc2,0xc3,0xc4,0xca,0xd0,0xd2,0xd3,0xda,0xdb]
  let catalog = AVCSpecificationCatalog.tapeCommands
  #expect(catalog.map(\.opcode) == expected)
  #expect(Set(catalog.map(\.section)).count == 31)
  #expect(catalog.filter { $0.controlDisposition == .existingTypedTransportSubset }.map(\.opcode) == [0xc3,0xc4])
  for opcode: UInt8 in [0xc2,0x62,0xca,0x40,0x72,0xd2] {
    #expect(catalog.first { $0.opcode == opcode }?.controlDisposition == .excludedFromPreservationProduct)
  }
  #expect(catalog.first { $0.opcode == 0x52 }?.status == .dependent)
  #expect(catalog.first { $0.opcode == 0xd0 }?.control == .undefined)
}

@Test func atnStatusIsReadOnlyAndDVSpecific() {
  #expect(AVCTapeStatusDecoder.absoluteTrackStatusRequest == [1,0x20,0x52,0x71,255,255,255,255])
  let reply: [UInt8] = [0x0c,0x20,0x52,0x71,0x57,0x34,0x12,0xff]
  let parsed = AVCTapeStatusDecoder.dvTrack(reply)
  #expect(parsed?.number == 0x091a2b)
  #expect(parsed?.blankFlag == true)
  #expect(parsed?.rawResponse == reply)
  for index in [0,1,2,3,7] {
    var bad = reply; bad[index] ^= 1
    #expect(AVCTapeStatusDecoder.dvTrack(bad) == nil)
  }
  #expect(AVCTapeStatusDecoder.dvTrack(Array(reply.dropLast())) == nil)
  #expect(AVCTapeStatusDecoder.dvTrack(reply + [0]) == nil)
  #expect(AVCTapeStatusDecoder.dvTrack([12,32,82,113,255,255,255,255]) == nil)
  #expect(AVCTapeStatusDecoder.dvTrack([12,32,82,113,0,0,0,255])?.number == 0)
  #expect(AVCTapeStatusDecoder.dvTrack([12,32,82,113,0,0,0,255])?.blankFlag == false)
}

@Test func mediumStatusDoesNotGuessAbsentOrWriteProtection() {
  #expect(AVCTapeStatusDecoder.medium([12,32,218,50,49]) == .dvCassette(size: "small", recordingInhibited: true))
  #expect(AVCTapeStatusDecoder.medium([12,32,218,50,48]) == .dvCassette(size: "small", recordingInhibited: false))
  #expect(AVCTapeStatusDecoder.medium([12,32,218,96,127]) == .absent)
  for bytes: [UInt8] in [[],[12,32,218,126,127],[12,32,218,96,0],[9,32,218,96,127],[12,32,218,51,48],[12,32,218,50,127]] {
    #expect(AVCTapeStatusDecoder.medium(bytes) == .unknown)
  }
}

@Test func transportSafetyStatesAreDistinctFromOrdinaryStop() {
  #expect(AVCTapeStatusDecoder.transportMeaning([12,32,196,48]).contains("Emergency"))
  #expect(AVCTapeStatusDecoder.transportMeaning([12,32,196,49]).contains("Condensation"))
  #expect(AVCTapeStatusDecoder.transportMeaning([12,32,196,96]).contains("does not establish BOT/EOT"))
  #expect(AVCTapeStatusDecoder.transportMeaning([11,32,196,96]).contains("Not a stable"))
  #expect(AVCTapeStatusDecoder.transportMeaning([12,32,194,117]).contains("never requests recording"))
  #expect(AVCTapeStatusDecoder.transportMeaning([12,32,196,0]).contains("uninterpreted"))
}
