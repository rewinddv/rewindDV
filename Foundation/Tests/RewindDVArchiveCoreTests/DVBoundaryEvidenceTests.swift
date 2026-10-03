import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private let sourcePackA: [UInt8] = [0x60, 0xff, 0xff, 0x40, 0xff]
private let sourcePackB: [UInt8] = [0x60, 0xff, 0xff, 0x00, 0xff]
private let sourceControlPackA: [UInt8] = [0x61, 0x03, 0x81, 0xfc, 0xff]
private let sourceControlPackB: [UInt8] = [0x61, 0x3f, 0x81, 0xfc, 0xff]

private func boundaryFrame(
  pal: Bool,
  audioRateCode: UInt8 = 0,
  sourceValues: [[UInt8]] = [sourcePackA],
  sourceControlValues: [[UInt8]] = [sourceControlPackA]
) -> Data {
  let sequenceCount = pal ? 12 : 10
  var frame = Data()
  frame.reserveCapacity(sequenceCount * 12_000)

  func selected(_ values: [[UInt8]], sequence: Int) -> [UInt8]? {
    guard !values.isEmpty else { return nil }
    return values[min(sequence, values.count - 1)]
  }
  for sequence in 0..<sequenceCount {
    func append(section: Int, blockNumber: Int) {
      var block = Data(repeating: 0xff, count: 80)
      block[0] = UInt8(section << 5)
      block[1] = UInt8(sequence << 4)
      block[2] = UInt8(blockNumber)
      if section == 0 {
        block[3] = pal ? 0x80 : 0
        for index in 4...7 { block[index] = 0 }
      } else if section == 2, blockNumber == 0,
        let pack = selected(sourceValues, sequence: sequence)
      {
        precondition(pack.count == 5)
        block.replaceSubrange(3..<8, with: pack)
      } else if section == 2, blockNumber == 1,
        let pack = selected(sourceControlValues, sequence: sequence)
      {
        precondition(pack.count == 5)
        block.replaceSubrange(3..<8, with: pack)
      } else if section == 3 {
        block.replaceSubrange(
          3..<8, with: [0x50, 0, 0, 0, audioRateCode << 3])
      } else if section == 4 {
        block[3] = blockNumber == 0 ? 0x10 : 0
      }
      frame.append(block)
    }

    append(section: 0, blockNumber: 0)
    for block in 0..<2 { append(section: 1, blockNumber: block) }
    for block in 0..<3 { append(section: 2, blockNumber: block) }
    for group in 0..<9 {
      append(section: 3, blockNumber: group)
      for block in group * 15..<(group + 1) * 15 {
        append(section: 4, blockNumber: block)
      }
    }
  }
  return frame
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test(arguments: [false, true])
func boundaryEvidenceRetainsBoundedFrameFacts(pal: Bool) throws {
  let rateCode: UInt8 = pal ? 2 : 0
  let frame = boundaryFrame(pal: pal, audioRateCode: rateCode)
  let base: UInt64 = 900_000
  let value = try DVBoundaryEvidence.inspect(
    frame: frame, ordinal: 42, sourceByteOffset: base)

  #expect(value.frameOrdinal == 42)
  #expect(value.frameSourceByteOffset == base)
  #expect(value.frameByteCount == (pal ? 144_000 : 120_000))
  #expect(value.frameSHA256 == sha256(frame))
  #expect(value.videoSystem == (pal ? .pal625_50 : .ntsc525_60))
  #expect(value.audioSampleRate == (pal ? .known32000Hz : .known48000Hz))
  #expect(value.nonzeroVideoSTABlockCount == (pal ? 12 : 10))
  #expect(value.vauxSource.packType == 0x60)
  #expect(value.vauxSource.classification == .singleUniqueRawValueObserved)
  #expect(value.vauxSource.uniqueRawValues.first?.rawBytes == sourcePackA)
  #expect(value.vauxSource.uniqueRawValues.first?.observationSourceByteOffsets.count == (pal ? 12 : 10))
  #expect(value.vauxSource.uniqueRawValues.first?.observationSourceByteOffsets.first == base + 243)
  #expect(value.vauxSourceControl.packType == 0x61)
  #expect(value.vauxSourceControl.uniqueRawValues.first?.observationSourceByteOffsets.first == base + 323)
  #expect(value.interpretationPolicy.contains("no_gray_or_content_deletion"))
  #expect(value.interpretationPolicy.contains("no_tape_recording_truth"))
  #expect(value.interpretationPolicy.contains("no_merge_authority"))
}

@Test func boundaryEvidenceNormalizesSlicedDataIndices() throws {
  let frame = boundaryFrame(pal: false)
  var backing = Data(repeating: 0xa5, count: 17)
  backing.append(frame)
  backing.append(Data(repeating: 0x5a, count: 9))
  let slicedFrame = backing[17..<(17 + frame.count)]

  let value = try DVBoundaryEvidence.inspect(
    frame: slicedFrame, ordinal: 3, sourceByteOffset: 1_000)
  #expect(value.frameSHA256 == sha256(frame))
  #expect(value.frameByteCount == 120_000)
  #expect(value.vauxSource.uniqueRawValues.first?.observationSourceByteOffsets.first == 1_243)
}

@Test func boundaryEvidenceReportsMissingAndMultipleRawValuesWithoutInterpretation() throws {
  let missing = try DVBoundaryEvidence.inspect(
    frame: boundaryFrame(pal: false, sourceValues: [], sourceControlValues: []),
    ordinal: 0, sourceByteOffset: 0)
  #expect(missing.vauxSource.classification == .notObserved)
  #expect(missing.vauxSource.uniqueRawValues.isEmpty)
  #expect(missing.vauxSourceControl.classification == .notObserved)
  #expect(missing.vauxSourceControl.uniqueRawValues.isEmpty)

  let multiple = try DVBoundaryEvidence.inspect(
    frame: boundaryFrame(
      pal: false,
      sourceValues: [sourcePackA, sourcePackB],
      sourceControlValues: [sourceControlPackA, sourceControlPackB]),
    ordinal: 1, sourceByteOffset: 0)
  #expect(multiple.vauxSource.classification == .multipleUniqueRawValuesObserved)
  #expect(multiple.vauxSource.uniqueRawValues.map(\.rawBytes) == [sourcePackB, sourcePackA])
  #expect(multiple.vauxSourceControl.classification == .multipleUniqueRawValuesObserved)
  #expect(multiple.vauxSourceControl.uniqueRawValues.map(\.rawBytes) == [sourceControlPackA, sourceControlPackB])
}

@Test func boundaryEvidenceRejectsMalformedFramesAndCoordinateOverflow() throws {
  let frame = boundaryFrame(pal: false)
  var wrongSystem = frame
  wrongSystem[3] = 0x80
  var duplicateBlock = frame
  duplicateBlock.replaceSubrange(160..<240, with: frame[80..<160])
  for malformed in [Data(), Data(frame.dropLast()), wrongSystem, duplicateBlock] {
    #expect(throws: (any Error).self) {
      try DVBoundaryEvidence.inspect(frame: malformed, ordinal: 0, sourceByteOffset: 0)
    }
  }
  #expect(throws: (any Error).self) {
    try DVBoundaryEvidence.inspect(frame: frame, ordinal: 0, sourceByteOffset: .max)
  }
}

@Test func boundaryEvidenceIsDetachedFromMutableInputAndCodable() throws {
  var frame = boundaryFrame(pal: false)
  let value = try DVBoundaryEvidence.inspect(frame: frame, ordinal: 7, sourceByteOffset: 80)
  let retainedHash = value.frameSHA256
  let retainedPack = value.vauxSource.uniqueRawValues.first?.rawBytes
  frame[243] = 0xff

  #expect(value.frameSHA256 == retainedHash)
  #expect(value.vauxSource.uniqueRawValues.first?.rawBytes == retainedPack)
  #expect(value.vauxSource.uniqueRawValues.first?.rawBytes == sourcePackA)
  let encoded = try JSONEncoder().encode(value)
  #expect(try JSONDecoder().decode(DVBoundaryEvidence.self, from: encoded) == value)
}
