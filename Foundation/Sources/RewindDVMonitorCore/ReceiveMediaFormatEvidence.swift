// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cheap, descriptive CIP observations AFTER raw preservation. Not an admission
/// gate, decoder, loss counter, or authority to end reception. Empty packets do
/// not establish a recorded format. Offline reconstruction validates again.
public struct ReceiveMediaFormatEvidence: Sendable, Equatable {
  public enum Format: String, Sendable { case dv, hdv }
  public private(set) var dvPayloadRecords: UInt64 = 0
  public private(set) var hdvPayloadRecords: UInt64 = 0
  public private(set) var hdvClaimedPayloadRecords: UInt64 = 0
  public private(set) var sawHDVEnvelope = false
  public var isMixed: Bool { dvPayloadRecords > 0 && hdvClaimedPayloadRecords > 0 }
  public var requiresHDVExport: Bool { hdvClaimedPayloadRecords > 0 || (sawHDVEnvelope && dvPayloadRecords == 0) }
  public init() {}

  @discardableResult
  public mutating func observe(_ payload: Data, transferStatus: UInt16,
                               sourceNode: UInt8) -> Format? {
    if claimsHDV(payload, transferStatus: transferStatus, sourceNode: sourceNode) {
      sawHDVEnvelope = true
      if payload.count > 16 { hdvClaimedPayloadRecords &+= 1 }
    }
    let format = Self.format(of: payload, transferStatus: transferStatus, sourceNode: sourceNode)
    switch format {
    case .dv: dvPayloadRecords &+= 1
    case .hdv: hdvPayloadRecords &+= 1
    case nil: break
    }
    return format
  }

  /// A source-bound MPEG CIP claim selects the strict HDV verifier even when
  /// its geometry is invalid. It must not fall back to a zero-frame DV success.
  public func claimsHDV(_ payload: Data, transferStatus: UInt16, sourceNode: UInt8) -> Bool {
    guard payload.count >= 16, payload.count <= 4096, sourceNode < 64,
      transferStatus & 0x1f == 0x11 else { return false }
    return payload.withUnsafeBytes { bytes in
      let p = bytes.bindMemory(to: UInt8.self)
      return p[8] & 0xc0 == 0 && p[8] & 0x3f == sourceNode && p[12] == 0xa0
    }
  }

  public static func format(of payload: Data, transferStatus: UInt16,
                            sourceNode: UInt8) -> Format? {
    guard payload.count > 16 else { return nil }
    return envelopeFormat(of: payload, transferStatus: transferStatus, sourceNode: sourceNode)
  }

  /// Includes empty CIP envelopes for parser routing, not recorded-format proof.
  public static func envelopeFormat(of payload: Data, transferStatus: UInt16,
                                    sourceNode: UInt8) -> Format? {
    guard payload.count >= 16, payload.count <= 4096, sourceNode < 64,
      transferStatus & 0x1f == 0x11 else { return nil }
    return payload.withUnsafeBytes { bytes in
      let p = bytes.bindMemory(to: UInt8.self)
      guard p[8] & 0xc0 == 0, p[8] & 0x3f == sourceNode,
        p[12] & 0xc0 == 0x80 else { return nil }
      let count = payload.count - 16
      switch p[12] & 0x3f {
      case 0 where p[9] == 120 && p[10] & 0xfb == 0:
        return count.isMultiple(of: 480 + (p[10] & 4 == 0 ? 0 : 4)) ? .dv : nil
      // IEC 61883-4: DBS 6 quadlets, FN 3, SPH present. Descriptive
      // geometry agrees with Apple's AVCVideoServices MPEG2Receiver;
      // the archival HDV assembler additionally validates DBC/fragments.
      case 0x20 where p[9] == 6 && p[10] == 0xc4 && p[13] & 0x7f == 0:
        return count.isMultiple(of: 24) ? .hdv : nil
      default: return nil
      }
    }
  }
}
