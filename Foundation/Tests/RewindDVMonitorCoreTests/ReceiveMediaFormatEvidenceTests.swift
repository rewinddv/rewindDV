import Foundation
import XCTest
import RewindDVArchiveCore
@testable import RewindDVMonitorCore

final class ReceiveMediaFormatEvidenceTests: XCTestCase {
  private func packet(hdv: Bool, bytes: Int? = nil) -> Data {
    var value = Data(repeating: 0, count: 16 + (bytes ?? (hdv ? 192 : 480)))
    value[8] = 1; value[9] = hdv ? 6 : 120
    value[10] = hdv ? 0xc4 : 0; value[12] = hdv ? 0xa0 : 0x80
    return value
  }
  func testFormatsAreSeparateAndMixedEvidenceIsExplicit() {
    var evidence = ReceiveMediaFormatEvidence()
    XCTAssertEqual(evidence.observe(packet(hdv: false), transferStatus: 0x11, sourceNode: 1), .dv)
    XCTAssertFalse(evidence.isMixed)
    XCTAssertEqual(evidence.observe(packet(hdv: true), transferStatus: 0x11, sourceNode: 1), .hdv)
    XCTAssertTrue(evidence.isMixed)
    XCTAssertEqual(evidence.dvPayloadRecords, 1)
    XCTAssertEqual(evidence.hdvPayloadRecords, 1)
  }
  func testEmptyPacketsNeverChooseOutputFormat() {
    var evidence = ReceiveMediaFormatEvidence()
    for hdv in [false, true] {
      XCTAssertNil(evidence.observe(packet(hdv: hdv, bytes: 0), transferStatus: 0x11, sourceNode: 1))
      XCTAssertEqual(ReceiveMediaFormatEvidence.envelopeFormat(of: packet(hdv: hdv, bytes: 0),
        transferStatus: 0x11, sourceNode: 1), hdv ? .hdv : .dv)
    }
    XCTAssertEqual(evidence.dvPayloadRecords, 0)
    XCTAssertEqual(evidence.hdvPayloadRecords, 0)
    XCTAssertTrue(evidence.sawHDVEnvelope)
    XCTAssertTrue(evidence.requiresHDVExport)
    XCTAssertFalse(evidence.isMixed)
  }
  func testMalformedHDVNeverFallsBackToZeroFrameDVVerification() {
    var evidence = ReceiveMediaFormatEvidence()
    var malformed = packet(hdv: true); malformed[9] = 0
    XCTAssertNil(evidence.observe(malformed, transferStatus: 0x11, sourceNode: 1))
    XCTAssertTrue(evidence.requiresHDVExport)
    XCTAssertEqual(evidence.hdvPayloadRecords, 0)
    _ = evidence.observe(packet(hdv: false), transferStatus: 0x11, sourceNode: 1)
    XCTAssertTrue(evidence.isMixed)
    XCTAssertTrue(evidence.requiresHDVExport)
  }
  func testInvalidRouteStatusAndGeometryCannotClaimHDV() {
    let valid = packet(hdv: true)
    XCTAssertNil(ReceiveMediaFormatEvidence.format(of: valid, transferStatus: 0x10, sourceNode: 1))
    XCTAssertNil(ReceiveMediaFormatEvidence.format(of: valid, transferStatus: 0x11, sourceNode: 2))
    for offset in [8, 9, 10, 12, 13] {
      var invalid = valid; invalid[offset] ^= 0x40
      XCTAssertNil(ReceiveMediaFormatEvidence.format(of: invalid, transferStatus: 0x11, sourceNode: 1))
    }
    XCTAssertNil(ReceiveMediaFormatEvidence.format(of: packet(hdv: true, bytes: 191), transferStatus: 0x11, sourceNode: 1))
  }
  func testFragmentGeometryAndDataSlicesAreSafe() {
    let fragment = packet(hdv: true, bytes: 24)
    let prefixed = Data([0]) + fragment
    XCTAssertEqual(ReceiveMediaFormatEvidence.format(of: prefixed.dropFirst(), transferStatus: 0x11, sourceNode: 1), .hdv)
    for count in 0...16 {
      XCTAssertNil(ReceiveMediaFormatEvidence.format(of: Data(repeating: 0, count: count), transferStatus: 0x11, sourceNode: 1))
    }
  }
  func testTimeShiftedMPEGFlagDoesNotRejectHDV() {
    var value = packet(hdv: true); value[13] = 0x80
    XCTAssertEqual(ReceiveMediaFormatEvidence.format(of: value, transferStatus: 0x11, sourceNode: 1), .hdv)
  }
  func testDVRoutingPreservesNTSCAndPALFrameBytesAndCounters() {
    for sequences in [10, 12] {
      var frame = Data()
      for sequence in 0..<sequences {
        func appendBlock(_ section: UInt8, _ number: UInt8) {
          var block = Data(repeating: 0xff, count: 80)
          block[0] = section << 5 | 0x1f; block[1] = UInt8(sequence << 4) | 7
          block[2] = number
          if section == 0 { block[3] = sequences == 12 ? 0x80 : 0 }
          frame.append(block)
        }
        appendBlock(0, 0)
        for n in 0..<2 { appendBlock(1, UInt8(n)) }
        for n in 0..<3 { appendBlock(2, UInt8(n)) }
        for group in 0..<9 {
          appendBlock(3, UInt8(group))
          for n in 0..<15 { appendBlock(4, UInt8(group * 15 + n)) }
        }
      }
      var original = DVDIFPacketAssembler(), routed = DVDIFPacketAssembler()
      var evidence = ReceiveMediaFormatEvidence()
      var before: [Data] = [], after: [Data] = []
      for offset in stride(from: 0, to: frame.count, by: 480) {
        var value = packet(hdv: false)
        value[11] = UInt8(truncatingIfNeeded: offset / 480)
        value.replaceSubrange(16..<496, with: frame[offset..<(offset + 480)])
        before += original.consumePreservedPacket(value, transferStatus: 0x11, expectedSourceNode: 1)
        evidence.observe(value, transferStatus: 0x11, sourceNode: 1)
        if !evidence.claimsHDV(value, transferStatus: 0x11, sourceNode: 1) {
          after += routed.consumePreservedPacket(value, transferStatus: 0x11, expectedSourceNode: 1)
        }
      }
      original.finish(); routed.finish()
      XCTAssertEqual(before, [frame]); XCTAssertEqual(after, before)
      XCTAssertEqual(original.rejectedPackets, routed.rejectedPackets)
      XCTAssertEqual(original.discontinuities, routed.discontinuities)
      XCTAssertEqual(original.incompleteFrames, routed.incompleteFrames)
      XCTAssertFalse(evidence.requiresHDVExport)
    }
  }
}
