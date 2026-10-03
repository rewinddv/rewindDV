// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

struct DeviceInspectionEntry: Sendable, Identifiable {
  let id = UUID()
  let query: InspectorQuery
  let disposition: String
  let facts: [InspectorFact]
  let response: [UInt8]
}

struct DeviceInspectionReport: Sendable {
  let deck: DiscoveredDeck
  let observedAt: Date
  let receiptURL: URL
  let entries: [DeviceInspectionEntry]
  let completion: String
  let controlLockedOut: Bool
  let route: FoundationRoute
  let validatedTransportState: [UInt8]?
  /// Compact passive journals contain many independent, durable observations.
  /// Nil preserves the immutable-per-directory receipt identity of older paths.
  var observationID: UUID? = nil
  var validatedDeckTimecode: [UInt8]? = nil
  var receiptIdentity: String { receiptURL.absoluteString + "#" + (observationID?.uuidString ?? "") }
}

/// An explicit inventory catalog, not an arbitrary AV/C interface.
enum InspectorQuery: Equatable, Sendable {
  case unitInfo
  case subunitInfo(page: UInt8)
  case unitPlugInfo
  case tapeMediumInfo
  case tapeTransportState
  case tapeAbsoluteTrackNumber
  case tapeTimecode

  var isTapeState: Bool { self == .tapeMediumInfo || self == .tapeTransportState || self == .tapeAbsoluteTrackNumber || self == .tapeTimecode }

  var title: String {
    switch self {
    case .unitInfo: "Unit information"
    case .subunitInfo(let page): "Subunits · page \(page)"
    case .unitPlugInfo: "Unit plugs"
    case .tapeMediumInfo: "Tape medium status"
    case .tapeTransportState: "Tape transport status"
    case .tapeAbsoluteTrackNumber: "Absolute track number"
    case .tapeTimecode: "Deck timecode"
    }
  }

  var frame: [UInt8] {
    switch self {
    case .unitInfo: [0x01, 0xff, 0x30, 0xff, 0xff, 0xff, 0xff, 0xff]
    case .subunitInfo(let page): [0x01, 0xff, 0x31, (page << 4) | 7, 0xff, 0xff, 0xff, 0xff]
    case .unitPlugInfo: [0x01, 0xff, 0x02, 0x00, 0xff, 0xff, 0xff, 0xff]
    case .tapeMediumInfo: [0x01, 0x20, 0xda, 0x7f, 0x7f]
    case .tapeTransportState: [0x01, 0x20, 0xd0, 0x7f]
    case .tapeAbsoluteTrackNumber: AVCTapeStatusDecoder.absoluteTrackStatusRequest
    case .tapeTimecode: AVCTapeStatusDecoder.timecodeStatusRequest
    }
  }

  var kind: UInt8 {
    switch self { case .unitInfo: 1; case .subunitInfo: 2; case .unitPlugInfo: 3; case .tapeMediumInfo: 4; case .tapeTransportState: 5; case .tapeAbsoluteTrackNumber: 6; case .tapeTimecode: 7 }
  }
  var page: UInt8 { if case .subunitInfo(let page) = self { page } else { 0 } }

  func encode(operationID: UInt64, attemptID: UInt64, route: FoundationRoute) throws -> Data {
    guard operationID != 0, attemptID != 0, page <= 7 else {
      throw ControlWireError.invalid("Invalid inspection identity or page")
    }
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    append(UInt32(1)); append(UInt32(72)); append(operationID); append(attemptID)
    append(route.guid); append(route.driverInstanceID); append(route.deviceIncarnation)
    append(route.routeEpoch); append(route.generation); append(route.nodeID)
    append(kind); append(page); append(UInt64(0))
    return data
  }
}

struct InspectorCapabilities {
  init(data: Data) throws {
    let reader = WireReader(data: data)
    let expected: [UInt32] = [1,40,127,127,7,1,128,512,2,0]
    guard data.count == 40 else { throw ControlWireError.invalid("Inspector capability size mismatch") }
    for (index, value) in expected.enumerated() {
      guard try reader.integer(index * 4, as: UInt32.self) == value else {
        throw ControlWireError.invalid("Inspector safety capability mismatch")
      }
    }
  }
}

struct InspectorResult: Sendable {
  static let wireBytes = 1_284
  struct Event: Sendable {
    let timestamp: UInt64
    let classification: UInt32
    let bytes: [UInt8]
  }
  let stages: UInt32
  let classification: UInt32
  let status: Int32
  let routeState: UInt32
  let responseOverflow: UInt32
  let decodedFields: UInt32
  let events: [Event]

  init(data: Data, requestID: UInt64, operationID: UInt64, attemptID: UInt64,
    route: FoundationRoute, query: InspectorQuery) throws {
    let r = WireReader(data: data)
    guard data.count == Self.wireBytes else { throw ControlWireError.invalid("Inspector result size mismatch") }
    for (offset, value) in [(0,UInt32(1)),(4,UInt32(Self.wireBytes)),(112,route.generation),
      (116,UInt32(query.kind)),(132,UInt32(0)),(136,UInt32(query.frame.count))] {
      guard try r.integer(offset, as: UInt32.self) == value else { throw ControlWireError.invalid("Inspector result header mismatch") }
    }
    for (offset, value) in [(8,requestID),(16,operationID),(24,attemptID),(32,route.guid),
      (40,route.driverInstanceID),(48,route.deviceIncarnation),(56,route.routeEpoch)] {
      guard value != 0, try r.integer(offset, as: UInt64.self) == value else {
        throw ControlWireError.invalid("Inspector result identity mismatch")
      }
    }
    guard try r.integer(148, as: UInt16.self) == route.nodeID,
      data[150] == query.page, data[151] == 0,
      Array(data[188..<196]) == query.frame + Array(repeating: 0, count: 8 - query.frame.count),
      data[178..<188].allSatisfy({ $0 == 0 }) else {
      throw ControlWireError.invalid("Inspector result request mismatch")
    }
    stages = try r.integer(120)
    classification = try r.integer(124)
    status = try r.integer(128)
    routeState = try r.integer(152)
    responseOverflow = try r.integer(144)
    decodedFields = try r.integer(156)
    guard stages & ~UInt32(0xff) == 0, stages & 0x21 == 0x21,
      classification <= 9, routeState <= 2, decodedFields & ~UInt32(7) == 0,
      try r.integer(80, as: UInt64.self) != 0,
      try r.integer(104, as: UInt64.self) >= r.integer(80, as: UInt64.self) else {
      throw ControlWireError.invalid("Inspector terminal state mismatch")
    }
    let count: UInt32 = try r.integer(140)
    guard count <= 2 else { throw ControlWireError.invalid("Inspector evidence count overflow") }
    let fcpAttempt: UInt64 = try r.integer(64)
    var resultEvents: [Event] = []
    for index in 0..<Int(count) {
      let offset = 196 + index * 544
      let length: UInt32 = try r.integer(offset + 28)
      guard length <= 512, try r.integer(offset + 22, as: UInt16.self) == 0,
        data[(offset + 32 + Int(length))..<(offset + 544)].allSatisfy({ $0 == 0 }) else {
        throw ControlWireError.invalid("Malformed inspector response event")
      }
      // Mismatched responses are evidence, not successful observations. Binding
      // of any interpreted terminal response is checked separately below.
      let eventClass: UInt32 = try r.integer(offset + 24)
      if eventClass == classification, status == 0 {
        guard fcpAttempt != 0, try r.integer(offset + 8, as: UInt64.self) == fcpAttempt,
          try r.integer(offset + 16, as: UInt32.self) == route.generation,
          try r.integer(offset + 20, as: UInt16.self) & 0x3f == route.nodeID & 0x3f else {
          throw ControlWireError.invalid("Inspector terminal response route mismatch")
        }
      }
      resultEvents.append(.init(timestamp: try r.integer(offset), classification: eventClass,
        bytes: Array(data[(offset + 32)..<(offset + 32 + Int(length))])))
    }
    guard data[(196 + Int(count) * 544)..<Self.wireBytes].allSatisfy({ $0 == 0 }) else {
      throw ControlWireError.invalid("Nonzero unused inspector evidence")
    }
    events = resultEvents
  }

  func interpretation(for query: InspectorQuery) throws -> InspectorInterpretation? {
    guard status == 0, routeState == 1, stages & 0x3b == 0x3b,
      responseOverflow == 0,
      let terminal = events.last, terminal.classification == classification else { return nil }
    guard [UInt32(3),4,5,7].contains(classification) else { return nil }
    if classification == 7 && query != .tapeTransportState { return nil }
    if classification == 3 {
      guard stages & 0x40 != 0, decodedFields == (query.isTapeState ? 0 : UInt32(1) << (query.kind - 1)) else {
        throw ControlWireError.invalid("Stable response has no validated inventory fields")
      }
    }
    return try InspectorInterpretation.decode(terminal.bytes, query: query)
  }
}

struct InspectorFact: Equatable, Sendable, Identifiable {
  let label: String
  let value: String
  var id: String { label }
}

struct InspectorInterpretation: Equatable, Sendable {
  let disposition: String
  let facts: [InspectorFact]
  /// Only a valid implemented SUBUNIT INFO page can establish termination.
  let lastSubunitPage: Bool

  static func decode(_ bytes: [UInt8], query: InspectorQuery) throws -> Self {
    if query.isTapeState { return try decodeTapeState(bytes, query: query) }
    if case .subunitInfo(let page) = query, page > 7 {
      throw ControlWireError.invalid("Subunit page is out of range")
    }
    guard bytes.count >= 3, bytes[1] == 0xff, bytes[2] == query.frame[2] else {
      throw ControlWireError.invalid("Uncorrelated inspector response")
    }
    switch bytes[0] {
    case 0x08: return Self(disposition: "Not implemented", facts: [], lastSubunitPage: false)
    case 0x0a: return Self(disposition: "Rejected in current state", facts: [], lastSubunitPage: false)
    case 0x0b: return Self(disposition: "IN TRANSITION — invalid for this inventory query; no retry sent", facts: [], lastSubunitPage: false)
    case 0x0f: return Self(disposition: "Interim — not a final status", facts: [], lastSubunitPage: false)
    case 0x0c: break
    default: throw ControlWireError.invalid("Unexpected response code for STATUS query")
    }
    guard bytes.count == 8 else {
      throw ControlWireError.invalid("Inventory status requires exactly eight response bytes")
    }
    var facts: [InspectorFact] = []
    var lastPage = false
    switch query {
    case .unitInfo:
      guard bytes[3] == 7 else { throw ControlWireError.invalid("Invalid UNIT INFO reserved operand") }
      guard bytes[4] >> 3 != 0x1e else { throw ControlWireError.invalid("Extended unit type remains uninterpreted") }
      facts.append(.init(label: "Unit type", value: subunitType(bytes[4] >> 3)))
      facts.append(.init(label: "Unit (vendor-defined)", value: String(bytes[4] & 7)))
      let company = UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
      facts.append(.init(label: "Reported company ID", value: company == 0xffffff ? "Unknown" : String(format: "0x%06X", company)))
    case .subunitInfo(let page):
      guard bytes[3] == (page << 4) | 7 else { throw ControlWireError.invalid("Subunit page mismatch") }
      var encounteredEnd = false
      var types = Set<UInt8>()
      for (index, entry) in bytes[4...7].enumerated() {
        if entry == 0xff { encounteredEnd = true; continue }
        guard !encounteredEnd, types.insert(entry >> 3).inserted, entry >> 3 != 0x1f, entry >> 3 != 0x1e,
          entry & 7 <= 4 else { throw ControlWireError.invalid("Invalid or contradictory subunit entry") }
        facts.append(.init(label: "Entry \(index + 1)", value: "\(subunitType(entry >> 3)) · IDs 0–\(entry & 7)"))
      }
      lastPage = encounteredEnd
      if facts.isEmpty { facts.append(.init(label: "Subunits on this page", value: "None reported")) }
    case .unitPlugInfo:
      guard bytes[3] == 0 else { throw ControlWireError.invalid("Unit plug subfunction mismatch") }
      for (index, label) in ["Isochronous inputs", "Isochronous outputs", "External inputs", "External outputs"].enumerated() {
        let count = bytes[index + 4]
        guard count <= 31 else { throw ControlWireError.invalid("Uninterpreted unit plug count; raw status retained") }
        facts.append(.init(label: label, value: String(count)))
      }
    case .tapeMediumInfo, .tapeTransportState, .tapeAbsoluteTrackNumber, .tapeTimecode:
      throw ControlWireError.invalid("Tape query must use its typed interpreter")
    }
    return Self(disposition: "Implemented status", facts: facts, lastSubunitPage: lastPage)
  }

  private static func decodeTapeState(_ bytes: [UInt8], query: InspectorQuery) throws -> Self {
    guard bytes.count == query.frame.count, bytes[1] == 0x20 else {
      throw ControlWireError.invalid("Malformed tape STATUS response")
    }
    let reportsMode = bytes[0] == 0x0c || bytes[0] == 0x0b
    let opcodeMatches: Bool
    switch query {
    case .tapeMediumInfo: opcodeMatches = bytes[2] == 0xda
    case .tapeAbsoluteTrackNumber: opcodeMatches = bytes[2] == 0x52 && bytes[3] == 0x71
    case .tapeTimecode: opcodeMatches = bytes[2] == 0x51 && bytes[3] == 0x71
    default: opcodeMatches = reportsMode ? [0xc1,0xc2,0xc3,0xc4].contains(bytes[2]) : bytes[2] == 0xd0
    }
    guard opcodeMatches else {
      throw ControlWireError.invalid("Uncorrelated or malformed tape STATUS response")
    }
    let disposition: String
    switch bytes[0] {
    case 0x08: return Self(disposition: "Not implemented", facts: [], lastSubunitPage: false)
    case 0x0a: return Self(disposition: "Rejected in current state", facts: [], lastSubunitPage: false)
    case 0x0c: disposition = "Stable device-reported status — not physical qualification"
    case 0x0b:
      guard query == .tapeTransportState else { throw ControlWireError.invalid("IN TRANSITION is invalid for this tape STATUS query") }
      disposition = "In transition — not stable state proof"
    default: throw ControlWireError.invalid("Invalid tape STATUS response code")
    }
    let hex: (UInt8) -> String = { String(format: "0x%02X", $0) }
    let facts: [InspectorFact]
    if query == .tapeMediumInfo {
      let meaning: String
      switch AVCTapeStatusDecoder.medium(bytes) {
      case .absent: meaning = "No cassette reported"
      case .unknown: meaning = "Unknown or unrecognized cassette/status combination"
      case .dvCassette(let size, let inhibited): meaning = "DV \(size) cassette · recording \(inhibited ? "inhibited" : "not inhibited") by cassette"
      }
      facts = [.init(label: "Cassette type code", value: hex(bytes[3])),
               .init(label: "Grade/write-protect code", value: hex(bytes[4])),
               .init(label: "Medium", value: meaning),
               .init(label: "Preservation policy", value: "Tape writing is never available; BOT/EOT not established")]
    } else if query == .tapeTimecode {
      guard let code = AVCTapeStatusDecoder.timecode(bytes) else {
        throw ControlWireError.invalid("Unavailable or invalid deck timecode; raw response retained")
      }
      facts = [.init(label: "Deck-reported timecode", value: code.text),
        .init(label: "Numbering", value: "Frame rate and drop-frame flag not supplied by this query")]
    } else if query == .tapeAbsoluteTrackNumber {
      if let track = AVCTapeStatusDecoder.dvTrack(bytes) {
        facts = [.init(label: "Recorded absolute track number", value: String(track.number)),
          .init(label: "Blank flag (bf)", value: track.blankFlag ? "1 · reported recording continuity from beginning" : "0 · recording continuity from beginning not established"),
          .init(label: "Position authority", value: "Device-reported DV ATN; correspondence, BOT/EOT and seek accuracy not yet qualified")]
      } else {
        facts = [.init(label: "ATN interpretation", value: "Unavailable or unsupported medium format; original response retained")]
      }
    } else {
      let mode = [0xc1:"Load/eject",0xc2:"Record (observed only; never sent)",0xc3:"Play",0xc4:"Wind"][Int(bytes[2])] ?? "Uninterpreted"
      facts = [.init(label: "Reported transport mode", value: "\(mode) · \(hex(bytes[2]))"),
               .init(label: "Reported state operand", value: hex(bytes[3])),
               .init(label: "Transport meaning", value: AVCTapeStatusDecoder.transportMeaning(bytes)),
               .init(label: "BOT / EOT", value: "Not established by this observation")]
    }
    return Self(disposition: disposition, facts: facts, lastSubunitPage: false)
  }

  private static func subunitType(_ value: UInt8) -> String {
    switch value {
    case 0x00: "Video monitor (0x00)"
    case 0x01: "Audio (0x01)"
    case 0x02: "Printer (0x02)"
    case 0x03: "Disc (0x03)"
    case 0x04: "Tape recorder/player (0x04)"
    case 0x05: "Tuner (0x05)"
    case 0x06: "Conditional access (0x06)"
    case 0x07: "Video camera (0x07)"
    default: String(format: "Uninterpreted type 0x%02X", value)
    }
  }
}
