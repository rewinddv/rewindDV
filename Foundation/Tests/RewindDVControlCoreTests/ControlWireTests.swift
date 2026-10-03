import Foundation
import Testing

@testable import RewindDVControlCore

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in data: inout Data) {
  var le = value.littleEndian
  withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}

@Test func fullSonyIdentityAndTruncation() throws {
  var data = Data(repeating: 0, count: 160)
  put(UInt32(1), at: 0, in: &data)
  put(UInt64(0xa1b2c3d4e5f60718), at: 8, in: &data)
  put(UInt32(4), at: 24, in: &data)
  data[28] = 1
  let decks = try DiscoveredDeck.decode(data)
  #expect(decks[0].guidText == "0xA1B2C3D4E5F60718")
  #expect(decks[0].node == 1 && decks[0].generation == 4)
  for size in 0..<data.count {
    #expect(throws: ControlWireError.self) { try DiscoveredDeck.decode(data.prefix(size)) }
  }
  data[30] = 1
  #expect(throws: ControlWireError.self) { try DiscoveredDeck.decode(data) }
}

@Test func capabilityGateIsExact() throws {
  var data = Data(repeating: 0, count: 24)
  for (offset, value) in [(0, 1), (4, 24), (8, 1023), (12, 7), (16, 1), (20, 4)] {
    put(UInt32(value), at: offset, in: &data)
  }
  _ = try FoundationCapabilities(data: data)
  put(UInt32(511), at: 8, in: &data)
  #expect(throws: ControlWireError.self) { try FoundationCapabilities(data: data) }
  put(UInt32(255), at: 8, in: &data)
  #expect(throws: ControlWireError.self) { try FoundationCapabilities(data: data) }
}

private func routeFixture() -> Data {
  var data = Data(repeating: 0, count: 48)
  put(UInt32(1), at: 0, in: &data)
  put(UInt32(48), at: 4, in: &data)
  put(UInt64(0xa1b2c3d4e5f60718), at: 8, in: &data)
  for (offset, value) in [(16, 5), (24, 6), (32, 7)] { put(UInt64(value), at: offset, in: &data) }
  put(UInt32(4), at: 40, in: &data)
  put(UInt16(1), at: 44, in: &data)
  return data
}

@Test func exactCommandRequestWire() throws {
  let route = try FoundationRoute(data: routeFixture())
  for command in DeckCommand.allCases {
    let data = try command.encode(operationID: 1, attemptID: 2, route: route)
    #expect(data.count == 72)
    let r = WireReader(data: data)
    #expect(try r.integer(24, as: UInt64.self) == 0xa1b2c3d4e5f60718)
    #expect(try r.integer(32, as: UInt32.self) == command.rawValue)
    #expect(try r.integer(40, as: UInt64.self) == 5)
    #expect(try r.integer(48, as: UInt64.self) == 6)
    #expect(try r.integer(56, as: UInt64.self) == 7)
    #expect(try r.integer(64, as: UInt32.self) == 4)
    #expect(try r.integer(68, as: UInt16.self) == 1)
  }
  #expect(throws: ControlWireError.self) {
    try DeckCommand.play.encode(operationID: 0, attemptID: 1, route: route)
  }
}

@Test func malformedOrUnboundRouteAuthorizationFailsClosed() throws {
  for offset in [8, 16, 24, 32] {
    var data = routeFixture()
    put(UInt64(0), at: offset, in: &data)
    #expect(throws: ControlWireError.self) { try FoundationRoute(data: data) }
  }
  for size in 0..<48 {
    #expect(throws: ControlWireError.self) {
      try FoundationRoute(data: routeFixture().prefix(size))
    }
  }
  var data = routeFixture()
  put(UInt16(0xffff), at: 44, in: &data)
  #expect(throws: ControlWireError.self) { try FoundationRoute(data: data) }
}

private func acceptedFixture() -> Data {
  var data = Data(repeating: 0, count: 2324)
  for (offset, value) in [
    (0, 1), (4, 2324), (48, 1), (52, 159), (64, 1), (68, 4), (72, 1), (112, 4), (164, 4), (172, 3),
    (176, 4),
  ] { put(UInt32(value), at: offset, in: &data) }
  for offset in [8, 16, 24, 32, 40, 80, 88, 96, 104, 120, 128, 136, 148, 156] {
    put(UInt64(1), at: offset, in: &data)
  }
  put(UInt16(1), at: 116, in: &data)
  put(UInt16(1), at: 168, in: &data)
  data.replaceSubrange(144..<148, with: DeckCommand.play.frame)
  data.replaceSubrange(180..<184, with: [9, 0x20, 0xc3, 0x75])
  return data
}

@Test func acceptedIsNotWireOrMotionProof() throws {
  var data = acceptedFixture()
  #expect(try ControlResult(data: data).accepted)
  data[180] = 0x0a
  #expect(try !ControlResult(data: data).accepted)
  put(UInt32(513), at: 176, in: &data)
  #expect(throws: ControlWireError.self) { try ControlResult(data: data) }
  put(UInt32(4), at: 176, in: &data)
  put(UInt32(223), at: 52, in: &data)
  #expect(throws: ControlWireError.self) { try ControlResult(data: data) }
}

@Test func unknownOrInvalidatedRouteCannotBeAccepted() throws {
  for routeState in [UInt32(0), UInt32(2)] {
    var data = acceptedFixture()
    put(routeState, at: 64, in: &data)
    #expect(try !ControlResult(data: data).accepted)
  }
  for offset in [80, 88, 96, 104, 120] {
    var data = acceptedFixture()
    put(UInt64(0), at: offset, in: &data)
    #expect(try !ControlResult(data: data).accepted)
  }
}

@Test func mismatchedOrLostResponseEvidenceCannotBeAccepted() throws {
  for (offset, value) in [(76, 1), (112, 5), (164, 5), (172, 4)] {
    var data = acceptedFixture()
    put(UInt32(value), at: offset, in: &data)
    #expect(try !ControlResult(data: data).accepted)
  }
  var data = acceptedFixture()
  put(UInt64(2), at: 156, in: &data)
  #expect(try !ControlResult(data: data).accepted)
  put(UInt32(5), at: 72, in: &data)
  #expect(throws: ControlWireError.self) { try ControlResult(data: data) }
}

@Test func truncatedOrUnboundResultFailsClosed() throws {
  let fixture = acceptedFixture()
  for size in [0, 40, 148, 580, 2323] {
    #expect(throws: ControlWireError.self) { try ControlResult(data: fixture.prefix(size)) }
  }
  for offset in [8, 16, 24, 32, 40] {
    var data = fixture
    put(UInt64(0), at: offset, in: &data)
    #expect(throws: ControlWireError.self) { try ControlResult(data: data) }
  }
}

@Test func hiddenResultBytesAreRejected() throws {
  for offset in [184, 692, 2323] {
    var data = acceptedFixture()
    data[offset] = 1
    #expect(throws: ControlWireError.self) { try ControlResult(data: data) }
  }
}
