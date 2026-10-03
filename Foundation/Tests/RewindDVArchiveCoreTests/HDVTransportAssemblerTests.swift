// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Synthetic wire fixtures only; these tests do not qualify real hardware.
import Foundation
import Testing
@testable import RewindDVArchiveCore

func hdvTSPacket(
  pid: UInt16 = 0x101, counter: UInt8 = 0, tei: Bool = false,
  payloadStart: Bool = false, sync: UInt8 = 0x47, fill: UInt8 = 0x55
) -> Data {
  var bytes = Data(repeating: fill, count: 188)
  bytes[0] = sync
  bytes[1] = UInt8((pid >> 8) & 0x1f) | (tei ? 0x80 : 0) | (payloadStart ? 0x40 : 0)
  bytes[2] = UInt8(pid & 0xff)
  bytes[3] = 0x10 | (counter & 0x0f)
  return bytes
}

func hdvSourcePacket(_ ts: Data, sph: [UInt8] = [0x01, 0x23, 0x45, 0x67]) -> Data {
  Data(sph) + ts
}

func hdvCIP(
  blocks: Data, dbc: UInt8, node: UInt8 = 7, timeShifted: Bool = false
) -> Data {
  precondition(blocks.count.isMultiple(of: 24))
  var result = Data(repeating: 0, count: 16)
  result[8] = node
  result[9] = 6
  result[10] = 0xc4 // FN=3, QPC=0, SPH=1, reserved=0
  result[11] = dbc
  result[12] = 0xa0 // EOH=1, FMT=IEC 61883-4 MPEG-2
  result[13] = timeShifted ? 0x80 : 0
  result.append(blocks)
  return result
}

@Test func hdvAssemblesSourcePacketAcrossIsochronousPacketsWithExactProvenance() {
  let source = hdvSourcePacket(hdvTSPacket())
  var assembler = HDVTransportAssembler()
  let first = assembler.consumePreservedPacket(hdvCIP(blocks: Data(source.prefix(72)), dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 4,
    rawPayloadByteOffset: 1_000)
  #expect(first.units.isEmpty)
  let second = assembler.consumePreservedPacket(hdvCIP(blocks: Data(source.dropFirst(72)), dbc: 3),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 5,
    rawPayloadByteOffset: 2_000)
  #expect(second.diagnostics.isEmpty)
  #expect(second.units.count == 1)
  #expect(second.units[0].sourcePacketHeader == source.prefix(4))
  #expect(second.units[0].transportPacket == source.dropFirst(4))
  #expect(second.units[0].provenance == [
    .init(recordSequence: 4, rawByteOffset: 1_016, byteCount: 72),
    .init(recordSequence: 5, rawByteOffset: 2_016, byteCount: 120)
  ])
  #expect(assembler.summary.acceptedTransportPackets == 1)
}

@Test func hdvNormalizesSlicedDataAndAcceptsTimeShiftedFDF() {
  let packet = hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0, timeShifted: true)
  var storage = Data([9, 8, 7]) + packet
  storage.removeFirst(3)
  var assembler = HDVTransportAssembler()
  let result = assembler.consumePreservedPacket(storage, transferStatus: 0x11,
    expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 72)
  #expect(result.units.count == 1)
  #expect(result.diagnostics.isEmpty)
}

@Test func hdvDBCGapDiscardsOnlyPartialDerivedAssemblyAndRawRemainsAuthority() {
  let source = hdvSourcePacket(hdvTSPacket())
  var assembler = HDVTransportAssembler()
  _ = assembler.consumePreservedPacket(hdvCIP(blocks: Data(source.prefix(72)), dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 100)
  let result = assembler.consumePreservedPacket(hdvCIP(blocks: Data(source.dropFirst(72)), dbc: 4),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 2, rawPayloadByteOffset: 300)
  #expect(result.units.isEmpty)
  #expect(result.diagnostics.map(\.kind).contains(.dbcDiscontinuity))
  #expect(result.diagnostics.map(\.kind).contains(.discardedSourceFragment))
  #expect(assembler.summary.CIPDBCDiscontinuities == 1)
}

@Test func hdvPreservesTEIDuplicatesNullsAndBadSyncWhileReportingThem() {
  let tei = hdvTSPacket(pid: 0x120, counter: 0, tei: true)
  let badSync = hdvTSPacket(pid: 0x121, counter: 0, sync: 0x46)
  let null = hdvTSPacket(pid: 0x1fff, counter: 0)
  let sources = [tei, tei, badSync, null].map { hdvSourcePacket($0) }
  var assembler = HDVTransportAssembler()
  let result = assembler.consumePreservedPacket(
    hdvCIP(blocks: sources.reduce(into: Data()) { $0.append($1) }, dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 1,
    rawPayloadByteOffset: 8)
  #expect(result.units.map(\.transportPacket) == [tei, tei, badSync, null])
  #expect(assembler.summary.transportErrorIndicatorPackets == 2)
  #expect(assembler.summary.exactDuplicateTransportPackets == 1)
  #expect(assembler.summary.transportSyncByteErrors == 1)
  #expect(assembler.summary.nullTransportPackets == 1)
}

@Test func hdvRejectsWrongDBSFNSPHAndDoesNotTreatEmptyCallbackAsDamage() {
  var assembler = HDVTransportAssembler()
  let empty = assembler.consumePreservedPacket(Data(), transferStatus: 0,
    expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 0)
  #expect(empty.units.isEmpty && empty.diagnostics.isEmpty)
  #expect(assembler.summary.rejectedPreservedPackets == 0)
  var malformed = hdvCIP(blocks: hdvSourcePacket(hdvTSPacket()), dbc: 0)
  malformed[9] = 7
  let rejected = assembler.consumePreservedPacket(malformed, transferStatus: 0x11,
    expectedSourceNode: 7, recordSequence: 2, rawPayloadByteOffset: 100)
  #expect(rejected.units.isEmpty)
  #expect(rejected.diagnostics.map(\.kind) == [.rejectedPreservedPacket])
  #expect(assembler.summary.rejectedPreservedPackets == 1)
}

@Test func hdvLeadingAndTerminalFragmentsAreExplicitNotRepaired() {
  let source = hdvSourcePacket(hdvTSPacket())
  var assembler = HDVTransportAssembler()
  let leading = assembler.consumePreservedPacket(
    hdvCIP(blocks: Data(source[24..<120]), dbc: 1), transferStatus: 0x11,
    expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 0)
  #expect(leading.units.isEmpty)
  #expect(leading.diagnostics.map(\.kind).contains(.leadingSourceFragment))
  _ = assembler.consumePreservedPacket(hdvCIP(blocks: Data(source.prefix(48)), dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 2, rawPayloadByteOffset: 200)
  let finish = assembler.finish()
  #expect(finish.diagnostics.map(\.kind) == [.discardedSourceFragment])
  #expect(finish.summary.leadingSourceFragments == 1)
  #expect(finish.summary.discardedSourceFragments == 1)
}

@Test func hdvContinuityHandlesAdaptationOnlyAndDiscontinuityReset() {
  let payload0 = hdvTSPacket(pid: 0x120, counter: 0)
  var adaptationOnly = hdvTSPacket(pid: 0x120, counter: 0)
  adaptationOnly[3] = 0x20
  adaptationOnly[4] = 183
  var discontinuity = adaptationOnly
  discontinuity[5] = 0x80
  let payload1 = hdvTSPacket(pid: 0x120, counter: 1)
  let payload9 = hdvTSPacket(pid: 0x120, counter: 9)
  var assembler = HDVTransportAssembler()
  let clean = assembler.consumePreservedPacket(hdvCIP(blocks:
    hdvSourcePacket(payload0) + hdvSourcePacket(adaptationOnly) + hdvSourcePacket(payload1), dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 0)
  #expect(!clean.diagnostics.map(\.kind).contains(.continuityCounter))
  let reset = assembler.consumePreservedPacket(hdvCIP(blocks:
    hdvSourcePacket(discontinuity) + hdvSourcePacket(payload9), dbc: 24),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 2, rawPayloadByteOffset: 1_000)
  #expect(!reset.diagnostics.map(\.kind).contains(.continuityCounter))
}

@Test func hdvMalformedAdaptationIsPreservedDiagnosedAndNotContinuityAuthority() {
  var malformed = hdvTSPacket(pid: 0x120, counter: 7)
  malformed[3] = 0x30 | 7
  malformed[4] = 183 // invalid for adaptation plus payload
  let next = hdvTSPacket(pid: 0x120, counter: 2)
  var assembler = HDVTransportAssembler()
  let result = assembler.consumePreservedPacket(hdvCIP(blocks:
    hdvSourcePacket(malformed) + hdvSourcePacket(next), dbc: 0),
    transferStatus: 0x11, expectedSourceNode: 7, recordSequence: 1, rawPayloadByteOffset: 0)
  #expect(result.units.map(\.transportPacket) == [malformed, next])
  #expect(result.diagnostics.map(\.kind).contains(.transportStructure))
  #expect(!result.diagnostics.map(\.kind).contains(.continuityCounter))
}
