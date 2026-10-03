// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

// AV/C General 4.0, 9.3 (printed pp43–44), and Tape Recorder/Player 2.4,
// 4.30/Table47 (printed p68). SPECIFIC INQUIRY is not CONTROL execution.
enum TransportCapabilityCatalog {
  static let commands: [DeckCommand] = [.play, .stop, .rewind, .fastForward, .shuttleForward, .shuttleReverse]
  static func inquiry(_ command: DeckCommand) -> [UInt8] { [2] + command.frame.dropFirst() }
  static func validate(_ data: Data) throws {
    let data = Data(data); let r = WireReader(data: data)
    guard data.count == 176 else { throw ControlWireError.invalid("Capability catalog size mismatch") }
    for (i, v) in [UInt32(1),176,6,0x3f,1,128,512,2].enumerated() {
      guard try r.integer(i * 4, as: UInt32.self) == v else {
        throw ControlWireError.invalid("Capability catalog safety contract mismatch")
      }
    }
    for (i, command) in commands.enumerated() {
      let o = 32 + i * 24
      guard try r.integer(o, as: UInt32.self) == command.rawValue,
        try r.integer(o+4, as: UInt32.self) == (command.rawValue >= DeckCommand.fastForward.rawValue ? 0x0d : 0x0b),
        try r.integer(o+8, as: UInt32.self) == 4, try r.integer(o+12, as: UInt32.self) == 4,
        Array(data[(o+16)..<(o+20)]) == inquiry(command),
        Array(data[(o+20)..<(o+24)]) == command.frame else {
        throw ControlWireError.invalid("Capability catalog command mismatch")
      }
    }
  }
  static func request(_ command: DeckCommand, operationID: UInt64, attemptID: UInt64,
    route: FoundationRoute) throws -> Data {
    guard operationID != 0, attemptID != 0 else { throw ControlWireError.invalid("Zero probe identity") }
    var data = Data()
    func append<T: FixedWidthInteger>(_ v: T) {
      var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    append(UInt32(1)); append(UInt32(72)); append(operationID); append(attemptID)
    append(route.guid); append(route.driverInstanceID); append(route.deviceIncarnation)
    append(route.routeEpoch); append(route.generation); append(route.nodeID)
    append(UInt16(0)); append(command.rawValue); append(UInt32(0))
    return data
  }
}

enum TransportSupport: UInt32, Sendable {
  case unknown = 0, implemented = 1, notImplemented = 2
  var title: String {
    switch self { case .unknown: "Unknown"; case .implemented: "Reported supported"; case .notImplemented: "Reported unsupported" }
  }
}

struct TransportCapabilityResult: Sendable {
  static let wireBytes = 1264
  let support: TransportSupport
  let status: Int32
  let routeState: UInt32
  let classification: UInt32
  let conditionalAuthorization: Bool
  let responses: [[UInt8]]
  var cleanObservation: Bool { status == 0 && routeState == 1 && support != .unknown }

  init(data input: Data, requestID: UInt64, operationID: UInt64, attemptID: UInt64,
    route: FoundationRoute, command: DeckCommand) throws {
    let data = Data(input); let r = WireReader(data: data)
    guard data.count == Self.wireBytes else { throw ControlWireError.invalid("Capability result size mismatch") }
    for (offset, value) in [(0,UInt32(1)),(4,UInt32(Self.wireBytes)),(112,route.generation),
      (116,command.rawValue),(132,0),(136,4),(164,0)] {
      guard try r.integer(offset, as: UInt32.self) == value else { throw ControlWireError.invalid("Capability result header mismatch") }
    }
    for (offset, value) in [(8,requestID),(16,operationID),(24,attemptID),(32,route.guid),
      (40,route.driverInstanceID),(48,route.deviceIncarnation),(56,route.routeEpoch)] {
      guard value != 0, try r.integer(offset, as: UInt64.self) == value else {
        throw ControlWireError.invalid("Capability result identity mismatch")
      }
    }
    let stages: UInt32 = try r.integer(120)
    classification = try r.integer(124); status = try r.integer(128)
    routeState = try r.integer(152)
    let rawSupport: UInt32 = try r.integer(156)
    let authorization: UInt32 = try r.integer(160)
    let count: UInt32 = try r.integer(140)
    let overflow: UInt32 = try r.integer(144)
    guard let decodedSupport = TransportSupport(rawValue: rawSupport), classification <= 4,
      routeState <= 2, authorization <= 2, count <= 2,
      stages & ~UInt32(0x1ff) == 0, stages & 0x21 == 0x21,
      try r.integer(148, as: UInt16.self) == route.nodeID,
      try r.integer(150, as: UInt16.self) == 0,
      Array(data[168..<172]) == TransportCapabilityCatalog.inquiry(command),
      data[172..<176].allSatisfy({ $0 == 0 }),
      try r.integer(80, as: UInt64.self) != 0,
      try r.integer(104, as: UInt64.self) >= r.integer(80, as: UInt64.self) else {
      throw ControlWireError.invalid("Capability terminal state mismatch")
    }
    var evidence: [[UInt8]] = []
    let fcpAttempt: UInt64 = try r.integer(64)
    for i in 0..<Int(count) {
      let o = 176 + i * 544
      let length: UInt32 = try r.integer(o+28)
      let eventClass: UInt32 = try r.integer(o+24)
      guard length <= 512, eventClass <= 4, try r.integer(o+22, as: UInt16.self) == 0,
        data[(o+32+Int(length))..<(o+544)].allSatisfy({ $0 == 0 }) else {
        throw ControlWireError.invalid("Malformed capability response evidence")
      }
      let bytes = Array(data[(o+32)..<(o+32+Int(length))])
      if i == Int(count)-1 && decodedSupport != .unknown {
        guard fcpAttempt != 0, try r.integer(o+8, as: UInt64.self) == fcpAttempt,
          try r.integer(o, as: UInt64.self) >= r.integer(88, as: UInt64.self),
          try r.integer(o, as: UInt64.self) <= r.integer(104, as: UInt64.self),
          try r.integer(o+16, as: UInt32.self) == route.generation,
          try r.integer(o+20, as: UInt16.self) & 0x3f == route.nodeID & 0x3f,
          eventClass == classification,
          bytes == [decodedSupport == .implemented ? 0x0c : 0x08] + command.frame.dropFirst() else {
          throw ControlWireError.invalid("Uncorrelated capability support response")
        }
      }
      evidence.append(bytes)
    }
    guard data[(176+Int(count)*544)..<Self.wireBytes].allSatisfy({ $0 == 0 }) else {
      throw ControlWireError.invalid("Nonzero unused capability evidence")
    }
    if decodedSupport != .unknown {
      let expectedClass: UInt32 = decodedSupport == .implemented ? 2 : 3
      let expectedStage: UInt32 = decodedSupport == .implemented ? 0x40 : 0x80
      guard status == 0, routeState == 1, overflow == 0, count > 0,
        try r.integer(72, as: UInt64.self) != 0,
        stages & 0x3f == 0x3f, stages & 0xc0 == expectedStage, classification == expectedClass,
        try r.integer(88, as: UInt64.self) >= r.integer(80, as: UInt64.self),
        try r.integer(96, as: UInt64.self) >= r.integer(88, as: UInt64.self),
        try r.integer(104, as: UInt64.self) >= r.integer(88, as: UInt64.self) else {
        throw ControlWireError.invalid("Unproven capability support state")
      }
    }
    let permits = authorization == 2
    let requiresProof = command == .fastForward || command == .shuttleForward || command == .shuttleReverse
    guard !permits || (requiresProof && decodedSupport == .implemented && stages & 0x100 != 0),
      (stages & 0x100 != 0) == permits,
      !requiresProof || authorization != 1 else {
      throw ControlWireError.invalid("Invalid conditional control authorization")
    }
    support = decodedSupport; conditionalAuthorization = permits; responses = evidence
  }
}

struct TransportCapabilityEntry: Sendable, Identifiable {
  let command: DeckCommand
  let support: TransportSupport
  let detail: String
  let responses: [[UInt8]]
  let conditionalAuthorization: Bool
  var id: UInt32 { command.rawValue }
}

struct TransportCapabilityReport: Sendable {
  let route: FoundationRoute
  let observedAt: Date
  let receiptURL: URL
  let entries: [TransportCapabilityEntry]
  let completion: String
  let lockedOut: Bool
  func permits(_ command: DeckCommand, on current: FoundationRoute?) -> Bool {
    guard command == .fastForward || command == .shuttleForward || command == .shuttleReverse else {
      return false
    }
    return !lockedOut && current == route && entries.contains {
      $0.command == command && $0.support == .implemented && $0.conditionalAuthorization
    }
  }
  func permitsFastForward(on current: FoundationRoute?) -> Bool {
    permits(.fastForward, on: current)
  }
}
