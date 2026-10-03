// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Clean-room Swift implementation informed by IEC 61883-4 packet structure and
// locally retained Apple AVCVideoServices/libiec61883 behavioral references.
// Raw capture is preserved before this descriptive parser is invoked.
import CryptoKit
import Foundation

public struct HDVRawProvenanceExtent: Codable, Equatable, Sendable {
  public let recordSequence: UInt64
  public let rawByteOffset: UInt64
  public let byteCount: UInt64

  public init(recordSequence: UInt64, rawByteOffset: UInt64, byteCount: UInt64) {
    self.recordSequence = recordSequence
    self.rawByteOffset = rawByteOffset
    self.byteCount = byteCount
  }
}

public enum HDVTransportDiagnosticKind: String, Codable, Sendable {
  case rejectedPreservedPacket = "rejected_preserved_packet"
  case dbcDiscontinuity = "dbc_discontinuity"
  case transportGap = "transport_gap"
  case leadingSourceFragment = "leading_source_fragment"
  case discardedSourceFragment = "discarded_source_fragment"
  case transportSyncByte = "transport_sync_byte"
  case transportErrorIndicator = "transport_error_indicator"
  case transportStructure = "transport_structure"
  case continuityCounter = "continuity_counter"
  case duplicateTransportPacket = "duplicate_transport_packet"
  case nullTransportPacket = "null_transport_packet"
}

public struct HDVTransportDiagnostic: Codable, Equatable, Sendable {
  public let kind: HDVTransportDiagnosticKind
  public let message: String
  public let recordSequence: UInt64?
  public let rawByteOffset: UInt64?
  public let transportPacketOrdinal: UInt64?
  public let PID: UInt16?

  public init(
    kind: HDVTransportDiagnosticKind, message: String,
    recordSequence: UInt64? = nil, rawByteOffset: UInt64? = nil,
    transportPacketOrdinal: UInt64? = nil, PID: UInt16? = nil
  ) {
    self.kind = kind
    self.message = message
    self.recordSequence = recordSequence
    self.rawByteOffset = rawByteOffset
    self.transportPacketOrdinal = transportPacketOrdinal
    self.PID = PID
  }
}

public struct HDVTransportStreamUnit: Codable, Equatable, Sendable {
  public let ordinal: UInt64
  /// Exact four bytes carried before the 188-byte transport packet.
  public let sourcePacketHeader: Data
  /// Exact 188 bytes accepted from the source packet. No TS flags are repaired.
  public let transportPacket: Data
  public let firstCIPDBC: UInt8
  public let provenance: [HDVRawProvenanceExtent]
  public let PID: UInt16
  public let transportErrorIndicator: Bool
  public let payloadUnitStartIndicator: Bool
  public let adaptationFieldControl: UInt8
  public let continuityCounter: UInt8

  public var SHA256: String {
    CryptoKit.SHA256.hash(data: transportPacket).map { String(format: "%02x", $0) }.joined()
  }
}

public struct HDVTransportSummary: Codable, Equatable, Sendable {
  public fileprivate(set) var acceptedTransportPackets: UInt64 = 0
  public fileprivate(set) var acceptedTransportBytes: UInt64 = 0
  public fileprivate(set) var rejectedPreservedPackets: UInt64 = 0
  public fileprivate(set) var CIPDBCDiscontinuities: UInt64 = 0
  public fileprivate(set) var knownTransportGapEvents: UInt64 = 0
  public fileprivate(set) var leadingSourceFragments: UInt64 = 0
  public fileprivate(set) var discardedSourceFragments: UInt64 = 0
  public fileprivate(set) var transportSyncByteErrors: UInt64 = 0
  public fileprivate(set) var transportErrorIndicatorPackets: UInt64 = 0
  public fileprivate(set) var transportStructureErrors: UInt64 = 0
  public fileprivate(set) var continuityCounterObservations: UInt64 = 0
  public fileprivate(set) var exactDuplicateTransportPackets: UInt64 = 0
  public fileprivate(set) var nullTransportPackets: UInt64 = 0

  public init() {}
}

public struct HDVTransportConsumeResult: Equatable, Sendable {
  public let units: [HDVTransportStreamUnit]
  public let diagnostics: [HDVTransportDiagnostic]

  public init(units: [HDVTransportStreamUnit], diagnostics: [HDVTransportDiagnostic]) {
    self.units = units
    self.diagnostics = diagnostics
  }
}

public struct HDVTransportFinishResult: Equatable, Sendable {
  public let diagnostics: [HDVTransportDiagnostic]
  public let summary: HDVTransportSummary

  public init(diagnostics: [HDVTransportDiagnostic], summary: HDVTransportSummary) {
    self.diagnostics = diagnostics
    self.summary = summary
  }
}

/// Bounded IEC 61883-4 source-packet assembly. IEC 61883-4 carries one
/// 192-byte source packet (four-byte SPH plus 188-byte MPEG-2 TS packet) as
/// eight 24-byte data blocks: DBS=6 quadlets, FN=3, SPH=1. DBC counts data
/// blocks, so a source packet can span multiple isochronous packets.
public struct HDVTransportAssembler: Sendable {
  public private(set) var summary = HDVTransportSummary()

  private struct ContinuityState: Sendable {
    let lastPayloadCounter: UInt8
  }

  private var expectedDBC: UInt8?
  private var fragment = Data()
  private var fragmentExtents: [HDVRawProvenanceExtent] = []
  private var fragmentFirstDBC: UInt8 = 0
  private var nextOrdinal: UInt64 = 0
  private var priorTransportPacket: Data?
  // MPEG-2 TS PID is 13 bits, so this state is strictly bounded.
  private var continuity = Array<ContinuityState?>(repeating: nil, count: 8_192)

  public init() {}

  public mutating func reset() { self = Self() }

  public mutating func consumePreservedPacket(
    _ preservedPacket: Data, transferStatus: UInt16, expectedSourceNode: UInt8,
    recordSequence: UInt64, rawPayloadByteOffset: UInt64
  ) -> HDVTransportConsumeResult {
    // Foundation.Data slices retain their original indices. Normalize this
    // bounded public input once so all wire offsets remain zero-relative.
    let packet = Data(preservedPacket)
    var diagnostics: [HDVTransportDiagnostic] = []
    // A callback with no captured isochronous bytes supplies no CIP/DBC
    // evidence and must not disturb an in-progress source packet.
    if packet.isEmpty { return .init(units: [], diagnostics: []) }
    guard packet.count >= 16, packet.count <= 4_096,
      transferStatus & 0x1f == 0x11, expectedSourceNode < 64,
      packet[8] & 0xc0 == 0, packet[8] & 0x3f == expectedSourceNode,
      packet[9] == 6,
      packet[10] >> 6 == 3, (packet[10] >> 3) & 0x07 == 0,
      packet[10] & 0x04 == 0x04, packet[10] & 0x03 == 0,
      packet[12] & 0xc0 == 0x80, packet[12] & 0x3f == 0x20,
      (packet[13] == 0 || packet[13] == 0x80), packet[14] == 0, packet[15] == 0
    else {
      reject(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
        diagnostics: &diagnostics,
        reason: "OHCI/CIP header is not a supported IEC 61883-4 MPEG-2 packet")
      return .init(units: [], diagnostics: diagnostics)
    }

    let mediaByteCount = packet.count - 16
    guard mediaByteCount.isMultiple(of: 24) else {
      reject(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
        diagnostics: &diagnostics,
        reason: "IEC 61883-4 payload is not an integral number of 24-byte data blocks")
      return .init(units: [], diagnostics: diagnostics)
    }
    guard let mediaOffset = rawPayloadByteOffset.addingExactly(16) else {
      reject(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
        diagnostics: &diagnostics, reason: "raw provenance offset overflow")
      return .init(units: [], diagnostics: diagnostics)
    }

    let dbc = packet[11]
    if let expectedDBC, expectedDBC != dbc {
      summary.CIPDBCDiscontinuities &+= 1
      diagnostics.append(.init(kind: .dbcDiscontinuity,
        message: "CIP DBC did not continue by the preceding data-block count",
        recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset))
      discardFragment(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
        diagnostics: &diagnostics)
    }

    let blockCount = mediaByteCount / 24
    expectedDBC = dbc &+ UInt8(truncatingIfNeeded: blockCount)
    if blockCount == 0 { return .init(units: [], diagnostics: diagnostics) }

    var units: [HDVTransportStreamUnit] = []
    var blockIndex = 0
    while blockIndex < blockCount {
      let blockDBC = dbc &+ UInt8(truncatingIfNeeded: blockIndex)
      if fragment.isEmpty, blockDBC & 0x07 != 0 {
        let skipped = min(8 - Int(blockDBC & 0x07), blockCount - blockIndex)
        summary.leadingSourceFragments &+= 1
        diagnostics.append(.init(kind: .leadingSourceFragment,
          message: "capture begins or resumes inside an IEC 61883-4 source packet; fragment retained only in raw evidence",
          recordSequence: recordSequence,
          rawByteOffset: mediaOffset.addingExactly(UInt64(blockIndex * 24))))
        blockIndex += skipped
        continue
      }
      if fragment.isEmpty { fragmentFirstDBC = blockDBC }

      let sourceStart = 16 + blockIndex * 24
      let bytesNeeded = 192 - fragment.count
      let available = (blockCount - blockIndex) * 24
      let take = min(bytesNeeded, available)
      guard let extentOffset = rawPayloadByteOffset.addingExactly(UInt64(sourceStart)) else {
        reject(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
          diagnostics: &diagnostics, reason: "raw provenance offset overflow")
        return .init(units: units, diagnostics: diagnostics)
      }
      fragment.append(packet[sourceStart..<(sourceStart + take)])
      appendExtent(recordSequence: recordSequence, rawByteOffset: extentOffset,
        byteCount: UInt64(take))
      blockIndex += take / 24

      if fragment.count == 192 {
        let sourcePacketHeader = Data(fragment.prefix(4))
        let transportPacket = Data(fragment.dropFirst(4))
        let ordinal = nextOrdinal
        nextOrdinal &+= 1
        let header = Self.parseTransportHeader(transportPacket)
        let unit = HDVTransportStreamUnit(ordinal: ordinal,
          sourcePacketHeader: sourcePacketHeader, transportPacket: transportPacket,
          firstCIPDBC: fragmentFirstDBC, provenance: fragmentExtents,
          PID: header.pid, transportErrorIndicator: header.tei,
          payloadUnitStartIndicator: header.pusi,
          adaptationFieldControl: header.adaptation, continuityCounter: header.counter)
        summary.acceptedTransportPackets &+= 1
        summary.acceptedTransportBytes &+= 188
        diagnose(unit, header: header, diagnostics: &diagnostics)
        units.append(unit)
        fragment.removeAll(keepingCapacity: true)
        fragmentExtents.removeAll(keepingCapacity: true)
      }
    }
    return .init(units: units, diagnostics: diagnostics)
  }

  public mutating func markTransportGap(
    recordSequence: UInt64? = nil, rawPayloadByteOffset: UInt64? = nil
  ) -> [HDVTransportDiagnostic] {
    summary.knownTransportGapEvents &+= 1
    expectedDBC = nil
    var diagnostics = [HDVTransportDiagnostic(kind: .transportGap,
      message: "upstream raw transport accounting reports a gap; exact missing TS count is unknown",
      recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset)]
    discardFragment(recordSequence: recordSequence, rawByteOffset: rawPayloadByteOffset,
      diagnostics: &diagnostics)
    return diagnostics
  }

  public mutating func finish() -> HDVTransportFinishResult {
    var diagnostics: [HDVTransportDiagnostic] = []
    discardFragment(recordSequence: nil, rawByteOffset: nil, diagnostics: &diagnostics)
    expectedDBC = nil
    return .init(diagnostics: diagnostics, summary: summary)
  }

  private mutating func reject(
    recordSequence: UInt64, rawByteOffset: UInt64,
    diagnostics: inout [HDVTransportDiagnostic], reason: String
  ) {
    summary.rejectedPreservedPackets &+= 1
    diagnostics.append(.init(kind: .rejectedPreservedPacket, message: reason,
      recordSequence: recordSequence, rawByteOffset: rawByteOffset))
    expectedDBC = nil
    discardFragment(recordSequence: recordSequence, rawByteOffset: rawByteOffset,
      diagnostics: &diagnostics)
  }

  private mutating func discardFragment(
    recordSequence: UInt64?, rawByteOffset: UInt64?,
    diagnostics: inout [HDVTransportDiagnostic]
  ) {
    guard !fragment.isEmpty else { return }
    summary.discardedSourceFragments &+= 1
    diagnostics.append(.init(kind: .discardedSourceFragment,
      message: "incomplete IEC 61883-4 source packet remains only in raw evidence",
      recordSequence: recordSequence, rawByteOffset: rawByteOffset))
    fragment.removeAll(keepingCapacity: true)
    fragmentExtents.removeAll(keepingCapacity: true)
  }

  private mutating func appendExtent(
    recordSequence: UInt64, rawByteOffset: UInt64, byteCount: UInt64
  ) {
    if let last = fragmentExtents.last,
      last.recordSequence == recordSequence,
      last.rawByteOffset.addingExactly(last.byteCount) == rawByteOffset {
      fragmentExtents[fragmentExtents.count - 1] = .init(recordSequence: recordSequence,
        rawByteOffset: last.rawByteOffset, byteCount: last.byteCount + byteCount)
    } else {
      fragmentExtents.append(.init(recordSequence: recordSequence,
        rawByteOffset: rawByteOffset, byteCount: byteCount))
    }
  }

  private static func parseTransportHeader(_ packet: Data) ->
    (valid: Bool, pid: UInt16, tei: Bool, pusi: Bool, adaptation: UInt8,
      counter: UInt8, scrambled: Bool, adaptationValid: Bool,
      discontinuity: Bool, hasPayload: Bool) {
    guard packet.count == 188 else {
      return (false, 0, false, false, 0, 0, false, false, false, false)
    }
    let adaptation = (packet[3] >> 4) & 0x03
    var adaptationValid = adaptation != 0
    var discontinuity = false
    if adaptation == 2 || adaptation == 3 {
      let length = Int(packet[4])
      adaptationValid = adaptation == 2 ? length == 183 : length <= 182
      if adaptationValid, length >= 1 { discontinuity = packet[5] & 0x80 != 0 }
    }
    return (packet[0] == 0x47,
      UInt16(packet[1] & 0x1f) << 8 | UInt16(packet[2]),
      packet[1] & 0x80 != 0, packet[1] & 0x40 != 0, adaptation,
      packet[3] & 0x0f, packet[3] & 0xc0 != 0, adaptationValid,
      discontinuity, adaptation == 1 || adaptation == 3)
  }

  private mutating func diagnose(
    _ unit: HDVTransportStreamUnit,
    header: (valid: Bool, pid: UInt16, tei: Bool, pusi: Bool, adaptation: UInt8,
      counter: UInt8, scrambled: Bool, adaptationValid: Bool,
      discontinuity: Bool, hasPayload: Bool),
    diagnostics: inout [HDVTransportDiagnostic]
  ) {
    let record = unit.provenance.first?.recordSequence
    let offset = unit.provenance.first?.rawByteOffset
    if !header.valid {
      summary.transportSyncByteErrors &+= 1
      diagnostics.append(.init(kind: .transportSyncByte,
        message: "accepted source packet does not begin with MPEG-2 TS sync byte 0x47",
        recordSequence: record, rawByteOffset: offset,
        transportPacketOrdinal: unit.ordinal, PID: unit.PID))
    }
    if !header.adaptationValid {
      summary.transportStructureErrors &+= 1
      diagnostics.append(.init(kind: .transportStructure,
        message: "reserved adaptation_field_control or invalid adaptation-field length; bytes are preserved unchanged",
        recordSequence: record, rawByteOffset: offset,
        transportPacketOrdinal: unit.ordinal, PID: unit.PID))
    }
    if unit.transportErrorIndicator {
      summary.transportErrorIndicatorPackets &+= 1
      diagnostics.append(.init(kind: .transportErrorIndicator,
        message: "transport_error_indicator is set; bytes are preserved unchanged",
        recordSequence: record, rawByteOffset: offset,
        transportPacketOrdinal: unit.ordinal, PID: unit.PID))
    }
    let duplicate = priorTransportPacket == unit.transportPacket
    if duplicate {
      summary.exactDuplicateTransportPackets &+= 1
      diagnostics.append(.init(kind: .duplicateTransportPacket,
        message: "transport packet exactly duplicates the immediately preceding accepted packet; both are preserved",
        recordSequence: record, rawByteOffset: offset,
        transportPacketOrdinal: unit.ordinal, PID: unit.PID))
    }
    priorTransportPacket = unit.transportPacket
    if unit.PID == 0x1fff {
      summary.nullTransportPackets &+= 1
      diagnostics.append(.init(kind: .nullTransportPacket,
        message: "null transport packet is preserved unchanged",
        recordSequence: record, rawByteOffset: offset,
        transportPacketOrdinal: unit.ordinal, PID: unit.PID))
      return
    }
    let trusted = header.valid && header.adaptationValid && !header.tei && !header.scrambled
    if !trusted || header.discontinuity { continuity[Int(unit.PID)] = nil }
    if trusted, !header.discontinuity, !duplicate,
      let prior = continuity[Int(unit.PID)], header.hasPayload {
      let expected = (prior.lastPayloadCounter &+ 1) & 0x0f
      if unit.continuityCounter != expected {
        summary.continuityCounterObservations &+= 1
        diagnostics.append(.init(kind: .continuityCounter,
          message: "payload continuity_counter differs from the preceding observation for this PID",
          recordSequence: record, rawByteOffset: offset,
          transportPacketOrdinal: unit.ordinal, PID: unit.PID))
      }
    }
    // Adaptation-only packets repeat the preceding payload CC and must not
    // replace the last payload observation. Exact duplicates are likewise not
    // new continuity evidence.
    if trusted, !duplicate, header.hasPayload {
      continuity[Int(unit.PID)] = .init(lastPayloadCounter: unit.continuityCounter)
    }
  }
}

private extension UInt64 {
  func addingExactly(_ other: UInt64) -> UInt64? {
    let result = addingReportingOverflow(other)
    return result.overflow ? nil : result.partialValue
  }
}
