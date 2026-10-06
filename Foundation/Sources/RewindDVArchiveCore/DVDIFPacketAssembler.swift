// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Selectively adapted from the ASFireWire DVFrameAssembler/CIP receiver mapping.
// Shared structural assembly: caller preserves original transport bytes first.
// Complete structure is not evidence of pristine source content or wire continuity.
import Foundation

public struct DVDIFPacketAssembler: Sendable {
  public private(set) var rejectedPackets: UInt64 = 0
  public private(set) var discontinuities: UInt64 = 0
  public private(set) var incompleteFrames: UInt64 = 0
  /// Context only, never proof that upstream loss was harmless or absent.
  public private(set) var dbcDiscontinuitiesAfterEmptyPackets: UInt64 = 0
  public private(set) var dbcDiscontinuitiesDiscardingPartialFrames: UInt64 = 0
  public private(set) var terminalPartialFrames: UInt64 = 0
  private var sawEmptyPacket = false
  private var expectedDBC: UInt8?
  private var bytes = Data()
  private var seen: [Bool] = []
  private var blocksReceived = 0
  private var damaged = false

  public init() {}

  public mutating func reset() {
    self = Self()
  }

  /// Explicit end of a source extent; count an incomplete tail exactly once.
  public mutating func finish() {
    if !seen.isEmpty { terminalPartialFrames &+= 1 }
    discardPartial()
  }

  /// Known raw-ring loss invalidates partial assembly even when DBC wrapped.
  /// Keep run counters: a discontinuity must not erase earlier diagnostics.
  public mutating func markTransportGap() {
    discontinuities &+= 1
    expectedDBC = nil
    sawEmptyPacket = false
    discardPartial()
  }

  /// OHCI receive timestamp + isoch header (8 bytes), then network-order CIP.
  /// No filtering result is an archival loss claim: raw bytes remain separate.
  public mutating func consumePreservedPacket(
    _ packet: Data, transferStatus: UInt16,
    expectedSourceNode: UInt8
  ) -> [Data] {
    guard packet.count >= 16, packet.count <= 4096 else {
      reject()
      return []
    }
    // Data subsequences may retain their original indices. The ordinary
    // zero-based receive path keeps its existing storage and allocation cost.
    let packet = packet.startIndex == 0 ? packet : Data(packet)
    guard transferStatus & 0x1f == 0x11,
      expectedSourceNode < 64,
      packet[8] & 0xc0 == 0, packet[12] & 0xc0 == 0x80,
      packet[8] & 0x3f == expectedSourceNode, packet[12] & 0x3f == 0,
      packet[10] & 0xfb == 0
    else {
      reject()
      return []
    }
    let mediaBytes = packet.count - 16
    if mediaBytes == 0 { sawEmptyPacket = true; return [] }
    let sourceHeaderBytes = packet[10] & 4 == 0 ? 0 : 4
    let sourceStride = 480 + sourceHeaderBytes
    guard packet[9] == 120, mediaBytes.isMultiple(of: sourceStride) else {
      reject()
      return []
    }
    let count = mediaBytes / sourceStride
    let dbc = packet[11]
    if let expectedDBC, dbc != expectedDBC {
      discontinuities &+= 1
      if sawEmptyPacket { dbcDiscontinuitiesAfterEmptyPackets &+= 1 }
      if !seen.isEmpty { dbcDiscontinuitiesDiscardingPartialFrames &+= 1 }
      discardPartial()
    }
    sawEmptyPacket = false
    expectedDBC = dbc &+ UInt8(count)
    var completed: [Data] = []
    for packetOffset in stride(from: 16 + sourceHeaderBytes, to: packet.count, by: sourceStride) {
      for blockOffset in stride(from: packetOffset, to: packetOffset + 480, by: 80) {
        let section = Int(packet[blockOffset] >> 5)
        let sequence = Int(packet[blockOffset + 1] >> 4)
        let blockNumber = Int(packet[blockOffset + 2])
        if section == 0 && sequence == 0 && blockNumber == 0 {
          discardPartial()
          let sequences = packet[blockOffset + 3] & 0x80 == 0 ? 10 : 12
          bytes = Data(repeating: 0, count: sequences * 150 * 80)
          seen = Array(repeating: false, count: sequences * 150)
        }
        guard !seen.isEmpty else { continue }
        let within: Int
        switch section {
        case 0 where blockNumber == 0: within = 0
        case 1 where blockNumber < 2: within = 1 + blockNumber
        case 2 where blockNumber < 3: within = 3 + blockNumber
        case 3 where blockNumber < 9: within = 6 + blockNumber * 16
        case 4 where blockNumber < 135: within = 7 + blockNumber / 15 + blockNumber
        default:
          damaged = true
          continue
        }
        let index = sequence * 150 + within
        guard index < seen.count else {
          damaged = true
          continue
        }
        guard !seen[index] else {
          damaged = true
          continue
        }
        bytes.replaceSubrange(
          index * 80..<(index + 1) * 80,
          with: packet[blockOffset..<(blockOffset + 80)])
        seen[index] = true
        blocksReceived += 1
        if blocksReceived == seen.count {
          if !damaged { completed.append(bytes) } else { incompleteFrames &+= 1 }
          bytes = Data()
          seen = []
          blocksReceived = 0
          damaged = false
        }
      }
    }
    return completed
  }

  private mutating func reject() {
    rejectedPackets &+= 1
    expectedDBC = nil
    sawEmptyPacket = false
    discardPartial()
  }

  private mutating func discardPartial() {
    if !seen.isEmpty { incompleteFrames &+= 1 }
    bytes = Data()
    seen = []
    blocksReceived = 0
    damaged = false
  }
}
