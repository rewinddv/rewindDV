// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Display-only evidence. This never authorizes tape motion or ends reception.
struct DeckTimecodeDisplayState: Equatable, Sendable {
  private(set) var text: String?
  private(set) var sampledAt: UInt64?
  private(set) var unavailableReason: String? = "Not yet observed"
  mutating func observe(_ response: [UInt8], at uptime: UInt64) {
    guard let value = AVCTapeStatusDecoder.timecode(response) else {
      unavailable("Invalid or unavailable deck reply"); return
    }
    text = value.text; sampledAt = uptime; unavailableReason = nil
  }
  mutating func unavailable(_ reason: String) { unavailableReason = reason }
  func label(at uptime: UInt64) -> String {
    if let unavailableReason { return text == nil ? "Unavailable: \(unavailableReason)" : "Stale: \(unavailableReason)" }
    guard let sampledAt, uptime >= sampledAt, uptime - sampledAt <= 2_000_000_000 else { return "Stale deck observation" }
    return "Deck-reported · sampled"
  }
  static func maySample(transport: [UInt8]?, receiving: Bool, stopping: Bool) -> Bool {
    guard !receiving, !stopping, let transport, transport.count == 4,
      transport[1] == 0x20, transport[2] == 0xc4 else { return false }
    // The serialized observer supplies a route-bound, interpreted reply. An
    // exact transition toward STOP may still coast for seconds. Permit a fresh
    // display-only timecode query after CONTROL has completed, without promoting
    // this transition to stable STOP or allowing a query during receive/drain.
    if transport == [0x0b,0x20,0xc4,0x60] { return true }
    guard transport[0] == 0x0c else { return false }
    return [UInt8(0x60), 0x45, 0x65, 0x75].contains(transport[3])
  }
  static func minimumSampleIntervalNanoseconds(transport: [UInt8]?, rapidWinding: Bool = false) -> UInt64 {
    if transport == [0x0c,0x20,0xc4,0x60] { return 500_000_000 }
    return rapidWinding ? 1_000_000 : 150_000_000
  }
}

/// Supervised app-only winding experiment, not a 1kHz device-rate promise.
/// Each cycle awaits both replies and durable receipts before the next begins.
/// Bounds apply to the rapid cadence only; they never stop tape motion.
struct WindRefreshBurst {
  private let startedAt: UInt64
  private(set) var cycles = 0
  init(startedAt: UInt64) { self.startedAt = startedAt }
  mutating func nextInterval(at now: UInt64) -> Duration {
    let rapid = now >= startedAt && now - startedAt < 5_000_000_000 && cycles < 64
    if cycles < 64 { cycles += 1 }
    return rapid ? .milliseconds(1) : .milliseconds(50)
  }
}

enum InspectorCompletionPolling {
  /// This polls a LOCAL result, never retransmits AV/C. Accelerated polling is
  /// admitted only for idle, exact-route, compact winding STATUS observations.
  static func interval(rapidIdle: Bool, notReadyCount: Int) -> Duration {
    guard rapidIdle else { return .milliseconds(50) }
    if notReadyCount < 10 { return .milliseconds(1) }
    if notReadyCount < 50 { return .milliseconds(5) }
    return .milliseconds(50)
  }
}

enum TapeStopPollingPolicy {
  /// Short bounded burst; a slow/stuck deck returns to the normal low-rate
  /// cadence. Neither elapsed time nor count is evidence of mechanical STOP.
  static func interval(afterObservation count: Int) -> Duration {
    count < 20 ? .milliseconds(250) : .seconds(1)
  }
}

/// Normative definitions are not permission to send a command, nor device support.
/// No dispatch or generic packet builder exists in this catalog. The driver keeps
/// its independent closed, typed allowlist; STATUS/NOTIFY/CONTROL are distinct.
enum AVCSpecificationCatalog {
  static let revision = "TA 2004005 / AV/C Tape Recorder/Player 2.4 / 2004-09-01"
  static let sourceSHA256 = "1feebabb10c03772124e88b375c47a12a6ef3a1d9ca3d25c5c07473077b048a1"
  enum Support: String, Sendable { case mandatory, recommended, optional, dependent, undefined }
  enum ControlDisposition: String, Sendable {
    case existingTypedTransportSubset
    case unavailablePendingImplementationAndQualification
    case excludedFromPreservationProduct
  }
  struct Definition: Sendable {
    let opcode: UInt8
    let name: String
    let section: String
    let control: Support
    let status: Support
    let notify: Support
    let controlDisposition: ControlDisposition
  }
  // Tables 5 and A-1; '*' remains dependent, never converted to support on a deck.
  // Excluded CONTROL families include writing and capture-affecting setup/presets.
  // Cataloged read support on these families does NOT enable their CONTROL form.
  static let tapeCommands: [Definition] = [
    .init(opcode: 0x40, name: "Edit mode", section: "4.7", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x45, name: "Preset", section: "4.16", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x50, name: "Search mode", section: "4.23", control: .undefined, status: .recommended, notify: .optional, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x51, name: "Time code", section: "4.28", control: .dependent, status: .dependent, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x52, name: "Absolute track number", section: "4.3", control: .dependent, status: .dependent, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x53, name: "Recording date", section: "4.19", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x54, name: "Recording time", section: "4.21", control: .undefined, status: .optional, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x55, name: "Forward", section: "4.8", control: .recommended, status: .undefined, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x56, name: "Backward", section: "4.5", control: .recommended, status: .undefined, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x57, name: "Relative time counter", section: "4.22", control: .recommended, status: .recommended, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x59, name: "SMPTE/EBU time code", section: "4.25", control: .optional, status: .optional, notify: .optional, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x5a, name: "Binary group", section: "4.6", control: .optional, status: .optional, notify: .optional, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x5c, name: "SMPTE/EBU recording time", section: "4.24", control: .optional, status: .optional, notify: .optional, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x60, name: "Open MIC", section: "4.13", control: .dependent, status: .recommended, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x61, name: "Read MIC", section: "4.17", control: .recommended, status: .undefined, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x62, name: "Write MIC", section: "4.31", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x70, name: "Analog audio output mode", section: "4.1", control: .optional, status: .optional, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x71, name: "Audio mode", section: "4.4", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x72, name: "Area mode", section: "4.2", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0x78, name: "Output signal mode", section: "4.14", control: .optional, status: .mandatory, notify: .optional, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0x79, name: "Input signal mode", section: "4.9", control: .optional, status: .mandatory, notify: .optional, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0xc1, name: "Load medium", section: "4.10", control: .optional, status: .undefined, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0xc2, name: "Record", section: "4.18", control: .dependent, status: .undefined, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0xc3, name: "Play", section: "4.15", control: .dependent, status: .undefined, notify: .undefined, controlDisposition: .existingTypedTransportSubset),
    .init(opcode: 0xc4, name: "Wind", section: "4.30", control: .dependent, status: .undefined, notify: .undefined, controlDisposition: .existingTypedTransportSubset),
    .init(opcode: 0xca, name: "Marker", section: "4.11", control: .recommended, status: .recommended, notify: .optional, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0xd0, name: "Transport state", section: "4.29", control: .undefined, status: .mandatory, notify: .optional, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0xd2, name: "Tape recording format", section: "4.27", control: .dependent, status: .dependent, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
    .init(opcode: 0xd3, name: "Tape playback format", section: "4.26", control: .dependent, status: .dependent, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0xda, name: "Medium info", section: "4.12", control: .undefined, status: .recommended, notify: .undefined, controlDisposition: .unavailablePendingImplementationAndQualification),
    .init(opcode: 0xdb, name: "Recording speed", section: "4.20", control: .optional, status: .optional, notify: .undefined, controlDisposition: .excludedFromPreservationProduct),
  ]
}

/// Offline payload decoder only. Caller must first validate transaction identity,
/// transport status, route generation, and freshness; decoding grants no authority.
enum AVCTapeStatusDecoder {
  // TA 2004005 section 4.28, figures 72/73 (printed p66). STATUS only;
  // the CONTROL/search form is deliberately unavailable. No DF/PAL flag exists
  // in this reply: do not infer a frame rate or drop-frame numbering from it.
  static let timecodeStatusRequest: [UInt8] = [0x01,0x20,0x51,0x71,0xff,0xff,0xff,0xff]
  struct DeckTimecode: Equatable, Sendable {
    let hours: Int, minutes: Int, seconds: Int
    let frames: Int?
    var text: String {
      String(format: "%02d:%02d:%02d:", hours, minutes, seconds)
        + (frames.map { String(format: "%02d", $0) } ?? "--")
    }
  }
  static func timecode(_ bytes: [UInt8]) -> DeckTimecode? {
    guard bytes.count == 8, Array(bytes.prefix(4)) == [0x0c,0x20,0x51,0x71] else { return nil }
    func bcd(_ byte: UInt8, maximum: Int) -> Int? {
      guard byte & 15 <= 9, byte >> 4 <= 9 else { return nil }
      let value = Int(byte >> 4) * 10 + Int(byte & 15)
      return value <= maximum ? value : nil
    }
    guard let hours = bcd(bytes[7], maximum: 23), let minutes = bcd(bytes[6], maximum: 59),
      let seconds = bcd(bytes[5], maximum: 59),
      bytes[4] == 0x7f || bcd(bytes[4], maximum: 29) != nil else { return nil }
    return DeckTimecode(hours: hours, minutes: minutes, seconds: seconds,
      frames: bytes[4] == 0x7f ? nil : bcd(bytes[4], maximum: 29))
  }
  // Table 46/47. Unknown states remain raw; observation never enables RECORD.
  static func transportMeaning(_ bytes: [UInt8]) -> String {
    guard bytes.count == 4, bytes[1] == 0x20 else { return "Malformed response" }
    guard bytes[0] == 0x0c else { return "Not a stable transport observation" }
    switch (bytes[2], bytes[3]) {
    case (0xc1, 0x60): return "Ejected / no medium reported"
    case (0xc4, 0x30): return "Emergency stop · automatic operation must stop"
    case (0xc4, 0x31): return "Condensation/dew stop · possible transport damage risk"
    case (0xc4, 0x60): return "Stopped · does not establish BOT/EOT"
    case (0xc4, 0x45): return "High-speed rewind"
    case (0xc4, 0x65): return "Rewind"
    case (0xc4, 0x75): return "Fast forward"
    case (0xc3, 0x75): return "Forward playback"
    case (0xc3, 0x65): return "Reverse playback"
    case (0xc3, 0x7d): return "Forward playback paused"
    case (0xc3, 0x6d): return "Reverse playback paused"
    case (0xc2, _): return "Recording mode reported externally; rewindDV never requests recording"
    default: return "Other/uninterpreted state; raw operands retained"
    }
  }
  // TA 2004005 section 4.3, figures 14/15. Typed idle-only Inspector STATUS.
  static let absoluteTrackStatusRequest: [UInt8] = [0x01,0x20,0x52,0x71,0xff,0xff,0xff,0xff]
  struct DVTrack: Equatable {
    let number: UInt32
    let blankFlag: Bool
    let rawResponse: [UInt8]
  }
  static func dvTrack(_ bytes: [UInt8]) -> DVTrack? {
    guard bytes.count == 8, Array(bytes.prefix(4)) == [0x0c,0x20,0x52,0x71],
      bytes[7] == 0xff else { return nil } // DVCR / no additional information only.
    let packed = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16
    let track = packed >> 1
    // Preserve unavailable all-ones separately; never invent a position.
    guard track != 0x7fffff else { return nil }
    return DVTrack(number: track, blankFlag: packed & 1 != 0, rawResponse: bytes)
  }
  enum Medium: Equatable {
    case dvCassette(size: String, recordingInhibited: Bool)
    case absent
    case unknown
  }
  static func medium(_ bytes: [UInt8]) -> Medium {
    guard bytes.count == 5, Array(bytes.prefix(3)) == [0x0c,0x20,0xda] else { return .unknown }
    if bytes[3] == 0x60 && bytes[4] == 0x7f { return .absent }
    let sizes: [UInt8: String] = [0x31:"standard", 0x32:"small", 0x33:"medium"]
    guard let size = sizes[bytes[3]],
      (bytes[3] == 0x33 ? [UInt8(0x40),0x41] : [UInt8(0x30),0x31,0x40,0x41]).contains(bytes[4]) else { return .unknown }
    return .dvCassette(size: size, recordingInhibited: bytes[4] & 1 != 0)
  }
}
