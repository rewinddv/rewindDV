// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// All closed Inspector STATUS queries use a boot-monotonic sequence. Uptime survives
/// app restarts; a new driver after reboot starts with an empty high-water mark.
struct InspectorAttemptSequence {
  private(set) var last: UInt64 = 0
  mutating func next(uptimeNanoseconds: UInt64) throws -> UInt64 {
    guard last < UInt64.max else { throw ControlWireError.invalid("Inspector sequence exhausted") }
    last = max(uptimeNanoseconds, last + 1)
    return last
  }
}

enum ControlWireError: Error, LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let reason): return reason
    }
  }
}

/// Fixed-width little-endian, same-host ABI. Never use Swift struct layout as a wire format.
struct WireReader {
  let data: Data
  func integer<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) throws -> T {
    guard offset >= 0, offset <= data.count, MemoryLayout<T>.size <= data.count - offset else {
      throw ControlWireError.invalid("Truncated driver reply at byte \(offset)")
    }
    return data.withUnsafeBytes {
      T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self))
    }
  }
  func string(_ offset: Int, count: Int) throws -> String {
    guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
      throw ControlWireError.invalid("Truncated device name")
    }
    let bytes = data[offset..<(offset + count)].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
  }
}

struct FoundationCapabilities: Sendable {
  let flags: UInt32
  init(data: Data) throws {
    let r = WireReader(data: data)
    guard data.count == 24, try r.integer(0, as: UInt32.self) == 1,
      try r.integer(4, as: UInt32.self) == 24,
      try r.integer(12, as: UInt32.self) == 7,
      try r.integer(16, as: UInt32.self) == 1,
      try r.integer(20, as: UInt32.self) == 4
    else {
      throw ControlWireError.invalid("Driver capability ABI does not match this candidate")
    }
    flags = try r.integer(8)
    guard flags == 0x3ff else {
      throw ControlWireError.invalid("Driver safety capabilities do not match the required closed control contract")
    }
  }
}

struct DiscoveredDeck: Identifiable, Equatable, Sendable {
  let guid: UInt64
  let generation: UInt32
  let node: UInt8
  let state: UInt8
  let vendor: String
  let model: String
  var id: UInt64 { guid }
  var isOperational: Bool { state == 1 && node < 63 }
  var guidText: String { String(format: "0x%016llX", guid) }
  var name: String { [vendor, model].filter { !$0.isEmpty }.joined(separator: " ") }

  static func decode(_ data: Data) throws -> [DiscoveredDeck] {
    let r = WireReader(data: data)
    let count: UInt32 = try r.integer(0)
    guard data.count >= 8, count <= 63 else {
      throw ControlWireError.invalid("Invalid device count")
    }
    var cursor = 8
    var devices: [DiscoveredDeck] = []
    var identifiers = Set<UInt64>()
    for _ in 0..<count {
      guard cursor <= data.count, data.count - cursor >= 152 else {
        throw ControlWireError.invalid("Truncated device record")
      }
      let guid: UInt64 = try r.integer(cursor)
      let units: UInt8 = try r.integer(cursor + 22)
      guard guid != 0, identifiers.insert(guid).inserted else {
        throw ControlWireError.invalid("Missing or ambiguous device identity")
      }
      devices.append(
        DiscoveredDeck(
          guid: guid, generation: try r.integer(cursor + 16),
          node: try r.integer(cursor + 20), state: try r.integer(cursor + 21),
          vendor: try r.string(cursor + 24, count: 64), model: try r.string(cursor + 88, count: 64))
      )
      cursor += 152
      let unitBytes = Int(units) * 160
      guard unitBytes <= data.count - cursor else {
        throw ControlWireError.invalid("Truncated unit records")
      }
      cursor += unitBytes
    }
    guard cursor == data.count else {
      throw ControlWireError.invalid("Unexpected discovery payload tail")
    }
    return devices
  }
}

struct FoundationRoute: Equatable, Sendable {
  static let wireBytes = 48
  let guid: UInt64
  let driverInstanceID: UInt64
  let deviceIncarnation: UInt64
  let routeEpoch: UInt64
  let generation: UInt32
  let nodeID: UInt16
  var node: UInt8 { UInt8(nodeID & 0x3f) }

  init(data: Data) throws {
    let r = WireReader(data: data)
    guard data.count == Self.wireBytes, try r.integer(0, as: UInt32.self) == 1,
      try r.integer(4, as: UInt32.self) == Self.wireBytes,
      try r.integer(46, as: UInt16.self) == 0
    else {
      throw ControlWireError.invalid("Invalid route authorization ABI")
    }
    guid = try r.integer(8)
    driverInstanceID = try r.integer(16)
    deviceIncarnation = try r.integer(24)
    routeEpoch = try r.integer(32)
    generation = try r.integer(40)
    nodeID = try r.integer(44)
    guard guid != 0, driverInstanceID != 0, deviceIncarnation != 0, routeEpoch != 0,
      nodeID != 0xffff, nodeID & 0x3f < 63
    else {
      throw ControlWireError.invalid("Unbound route authorization")
    }
  }
}

enum DeckCommand: UInt32, CaseIterable, Identifiable, Sendable {
  case play = 1
  case stop = 2
  case rewind = 3
  case fastForward = 4
  case shuttleForward = 5
  case shuttleReverse = 6
  var id: UInt32 { rawValue }
  var title: String {
    switch self {
    case .play: "Play tape"
    case .stop: "Stop tape"
    case .rewind: "Rewind tape"
    case .fastForward: "Fast-forward tape"
    case .shuttleForward: "Forward picture search"
    case .shuttleReverse: "Reverse picture search"
    }
  }
  var symbol: String {
    switch self {
    case .play: "play.fill"
    case .stop: "stop.fill"
    case .rewind: "backward.fill"
    case .fastForward: "forward.fill"
    case .shuttleForward: "forward.end.fill"
    case .shuttleReverse: "backward.end.fill"
    }
  }
  var frame: [UInt8] {
    switch self {
    case .play: [0, 0x20, 0xc3, 0x75]
    case .stop: [0, 0x20, 0xc4, 0x60]
    case .rewind: [0, 0x20, 0xc4, 0x65]
    case .fastForward: [0, 0x20, 0xc4, 0x75]
    case .shuttleForward: [0, 0x20, 0xc3, 0x3f]
    case .shuttleReverse: [0, 0x20, 0xc3, 0x4f]
    }
  }
  func encode(operationID: UInt64, attemptID: UInt64, route: FoundationRoute) throws -> Data {
    guard operationID != 0, attemptID != 0 else {
      throw ControlWireError.invalid("Zero control identity")
    }
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    append(UInt32(1))
    append(UInt32(72))
    append(operationID)
    append(attemptID)
    append(route.guid)
    append(rawValue)
    append(UInt32(0))
    append(route.driverInstanceID)
    append(route.deviceIncarnation)
    append(route.routeEpoch)
    append(route.generation)
    append(route.nodeID)
    append(UInt16(0))
    return data
  }
}

struct ControlResult: Sendable {
  static let maximumWireBytes = 2324
  struct ResponseEvent: Sendable {
    let timestamp: UInt64
    let fcpAttemptID: UInt64
    let generation: UInt32
    let nodeID: UInt16
    let classification: UInt32
    let bytes: [UInt8]
  }
  let requestID: UInt64
  let operationID: UInt64
  let attemptID: UInt64
  let guid: UInt64
  let driverInstanceID: UInt64
  let command: DeckCommand
  let stages: UInt32
  let status: Int32
  let routeState: UInt32
  var routeInvalidated: Bool { routeState == 2 }
  let responseEventOverflow: UInt32
  let fcpAttemptID: UInt64
  let deviceIncarnation: UInt64
  let routeEpoch: UInt64
  let asyncTransportHandle: UInt64
  let generation: UInt32
  let nodeID: UInt16
  let admittedTimestamp: UInt64
  let routeBoundTimestamp: UInt64
  let asyncAcceptedTimestamp: UInt64
  let request: [UInt8]
  let responseEvents: [ResponseEvent]
  var node: UInt8 { UInt8(nodeID & 0x3f) }
  var response: [UInt8] { responseEvents.last?.bytes ?? [] }
  var accepted: Bool {
    guard status == 0, stages & 0x19f == 0x9f, routeState == 1,
      responseEventOverflow == 0, fcpAttemptID != 0, deviceIncarnation != 0,
      routeEpoch != 0, nodeID != 0xffff, node < 63,
      asyncTransportHandle != 0, admittedTimestamp != 0,
      routeBoundTimestamp >= admittedTimestamp, asyncAcceptedTimestamp >= routeBoundTimestamp,
      let terminal = responseEvents.last, terminal.classification == 3,
      terminal.fcpAttemptID == fcpAttemptID, terminal.generation == generation,
      terminal.nodeID & 0x3f == nodeID & 0x3f,
      terminal.timestamp >= routeBoundTimestamp
    else { return false }
    return terminal.bytes == [0x09] + Array(command.frame.dropFirst())
  }
  init(data: Data) throws {
    let r = WireReader(data: data)
    guard data.count == Self.maximumWireBytes, try r.integer(0, as: UInt32.self) == 1,
      try r.integer(4, as: UInt32.self) == Self.maximumWireBytes,
      try r.integer(60, as: UInt32.self) == 0,
      try r.integer(68, as: UInt32.self) == 4,
      try r.integer(64, as: UInt32.self) <= 2,
      try r.integer(118, as: UInt16.self) == 0,
      let command = DeckCommand(rawValue: try r.integer(48, as: UInt32.self))
    else {
      throw ControlWireError.invalid("Invalid control result ABI")
    }
    let count: UInt32 = try r.integer(72)
    guard count <= 4 else { throw ControlWireError.invalid("Invalid response event count") }
    self.command = command
    requestID = try r.integer(8)
    operationID = try r.integer(16)
    attemptID = try r.integer(24)
    guid = try r.integer(32)
    driverInstanceID = try r.integer(40)
    stages = try r.integer(52)
    status = try r.integer(56)
    routeState = try r.integer(64)
    responseEventOverflow = try r.integer(76)
    fcpAttemptID = try r.integer(80)
    deviceIncarnation = try r.integer(88)
    routeEpoch = try r.integer(96)
    asyncTransportHandle = try r.integer(104)
    generation = try r.integer(112)
    nodeID = try r.integer(116)
    admittedTimestamp = try r.integer(120)
    routeBoundTimestamp = try r.integer(128)
    asyncAcceptedTimestamp = try r.integer(136)
    request = Array(data[144..<148])
    var events: [ResponseEvent] = []
    for index in 0..<Int(count) {
      let offset = 148 + index * 544
      let length: UInt32 = try r.integer(offset + 28)
      let classification: UInt32 = try r.integer(offset + 24)
      guard length <= 512, (1...6).contains(classification),
        try r.integer(offset + 22, as: UInt16.self) == 0,
        data[(offset + 32 + Int(length))..<(offset + 544)].allSatisfy({ $0 == 0 })
      else {
        throw ControlWireError.invalid("Invalid response event")
      }
      events.append(
        ResponseEvent(
          timestamp: try r.integer(offset),
          fcpAttemptID: try r.integer(offset + 8), generation: try r.integer(offset + 16),
          nodeID: try r.integer(offset + 20), classification: classification,
          bytes: Array(data[(offset + 32)..<(offset + 32 + Int(length))])))
    }
    responseEvents = events
    guard data[(148 + Int(count) * 544)..<Self.maximumWireBytes].allSatisfy({ $0 == 0 }) else {
      throw ControlWireError.invalid("Nonzero unused response evidence")
    }
    guard request == command.frame, stages & ~UInt32(0x19f) == 0, stages & 0x11 == 0x11,
      requestID != 0, operationID != 0, attemptID != 0, guid != 0, driverInstanceID != 0
    else {
      throw ControlWireError.invalid("Unbound or contradictory control result")
    }
  }
}
