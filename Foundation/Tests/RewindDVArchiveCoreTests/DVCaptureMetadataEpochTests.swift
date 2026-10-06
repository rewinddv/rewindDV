// Adapted from RewindDV Build158 DVCaptureMetadataEpochTests.swift; module import renamed.
import CryptoKit
import Foundation
@testable import RewindDVArchiveCore
import Testing

private let dvDIFBlockBytes = 80

private enum FixtureAudioRate {
  case hz32000
  case hz44100
  case hz48000

  var rateCode: UInt8 {
    switch self {
    case .hz32000: 2
    case .hz44100: 1
    case .hz48000: 0
    }
  }
}

private func difBlock(section: UInt8, sequence: Int, number: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0xff, count: dvDIFBlockBytes)
  bytes[0] = section << 5
  bytes[1] = UInt8(sequence << 4)
  bytes[2] = UInt8(number)
  if section == 0 {
    bytes[3] = 0 // This fixture is 525/60, not DSF=1 (625/50).
    bytes[4] = 0
    bytes[5] = 0
    bytes[6] = 0
    bytes[7] = 0
  }
  return bytes
}

private func putPack(_ pack: [UInt8], at offset: Int, in block: inout [UInt8]) {
  precondition(pack.count == 5)
  block.replaceSubrange(offset..<(offset + 5), with: pack)
}

private func ntscFrame(
  rate: FixtureAudioRate?,
  malformedRateCode: Bool = false,
  lastSequenceRate: FixtureAudioRate? = nil,
  timecodeFrame: UInt8 = 1
) -> Data {
  var output = Data()
  output.reserveCapacity(120_000)
  for sequence in 0..<10 {
    output.append(contentsOf: difBlock(section: 0, sequence: sequence, number: 0))
    for number in 0..<2 {
      var block = difBlock(section: 1, sequence: sequence, number: number)
      if sequence == 0, number == 0 {
        putPack([0x13, timecodeFrame, 0x00, 0x00, 0x01], at: 6, in: &block)
      }
      output.append(contentsOf: block)
    }
    for number in 0..<3 {
      output.append(contentsOf: difBlock(section: 2, sequence: sequence, number: number))
    }
    for number in 0..<9 {
      var block = difBlock(section: 3, sequence: sequence, number: number)
      let observedRate = sequence == 9 ? (lastSequenceRate ?? rate) : rate
      if number == 0, let observedRate {
        let code: UInt8 = malformedRateCode ? 7 : observedRate.rateCode
        putPack([0x50, 0x00, 0x00, 0x00, code << 3], at: 3, in: &block)
      }
      output.append(contentsOf: block)
    }
    for number in 0..<135 {
      output.append(contentsOf: difBlock(section: 4, sequence: sequence, number: number))
    }
  }
  precondition(output.count == 120_000)
  return output
}

@Test func conflictingAAUXRatesWithinOneFrameRemainUntagged() {
  let result = DVCaptureMetadataEpochAnalyzer.analyze(
    data: ntscFrame(
      rate: .hz32000, lastSequenceRate: .hz48000))

  #expect(result.frames[0].audioSampleRate == .conflicting)
  #expect(result.audioSampleRateEpochs[0].classification == .conflicting)
  #expect(result.audioSampleRateEpochs[0].derivedTrackSampleRateHz == nil)
}

private func joined(_ frames: [Data]) -> Data {
  frames.reduce(into: Data()) { $0.append($1) }
}

@Test func true32KFramesProduceOnlyA32KDerivedTrackEpoch() {
  let raw = joined([
    ntscFrame(rate: .hz32000, timecodeFrame: 1),
    ntscFrame(rate: .hz32000, timecodeFrame: 2),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(result.sourceByteCount == UInt64(raw.count))
  #expect(result.completeFrameCount == 2)
  #expect(result.frames.map(\.audioSampleRate) == [.known32000Hz, .known32000Hz])
  #expect(result.audioSampleRateEpochs.count == 1)
  #expect(result.audioSampleRateEpochs[0].classification == .known32000Hz)
  #expect(result.audioSampleRateEpochs[0].derivedTrackSampleRateHz == 32_000)
  #expect(result.audioSampleRateEpochs[0].byteCount == 240_000)
}

@Test func true48KFramesProduceOnlyA48KDerivedTrackEpoch() {
  let raw = joined([
    ntscFrame(rate: .hz48000, timecodeFrame: 1),
    ntscFrame(rate: .hz48000, timecodeFrame: 2),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(result.frames.map(\.audioSampleRate) == [.known48000Hz, .known48000Hz])
  #expect(result.audioSampleRateEpochs.count == 1)
  #expect(result.audioSampleRateEpochs[0].derivedTrackSampleRateHz == 48_000)
}

@Test func true44Point1KFramesProduceOnlyA44Point1KDerivedTrackEpoch() {
  let raw = joined([
    ntscFrame(rate: .hz44100, timecodeFrame: 1),
    ntscFrame(rate: .hz44100, timecodeFrame: 2),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(
    result.frames.map(\.audioSampleRate) == [
      .known44100Hz, .known44100Hz,
    ])
  #expect(result.audioSampleRateEpochs.count == 1)
  #expect(result.audioSampleRateEpochs[0].classification == .known44100Hz)
  #expect(result.audioSampleRateEpochs[0].derivedTrackSampleRateHz == 44_100)
}

@Test func standby32KThenProgram48KRequiresTwoExactlyTaggedDerivedEpochs() {
  let raw = joined([
    ntscFrame(rate: .hz32000, timecodeFrame: 1),
    ntscFrame(rate: .hz48000, timecodeFrame: 2),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(
    result.audioSampleRateEpochs.map(\.classification) == [
      .known32000Hz, .known48000Hz,
    ])
  #expect(
    result.audioSampleRateEpochs.map(\.derivedTrackSampleRateHz) == [
      32_000, 48_000,
    ])
  #expect(result.audioSampleRateEpochs.map(\.fileByteOffset) == [0, 120_000])
  #expect(result.audioSampleRateEpochs.allSatisfy { $0.byteCount == 120_000 })
}

@Test func laterTrue32KStartsANew32KTagInsteadOfInheriting48K() {
  let raw = joined([
    ntscFrame(rate: .hz48000, timecodeFrame: 1),
    ntscFrame(rate: .hz32000, timecodeFrame: 2),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(
    result.audioSampleRateEpochs.map(\.derivedTrackSampleRateHz) == [
      48_000, 32_000,
    ])
}

@Test func malformedAndAbsentAAUXNeverBorrowANeighboringSampleRate() {
  let raw = joined([
    ntscFrame(rate: .hz32000),
    ntscFrame(rate: .hz48000, malformedRateCode: true),
    ntscFrame(rate: nil),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(
    result.frames.map(\.audioSampleRate) == [
      .known32000Hz, .malformed, .absent,
    ])
  #expect(
    result.audioSampleRateEpochs.map(\.derivedTrackSampleRateHz) == [
      32_000, nil, nil,
    ])
  #expect(result.frames[1].aauxSourcePacks.count == 10)
  #expect(result.frames[2].aauxSourcePacks.isEmpty)
}

@Test func rawTimecodeIsExposedButCannotSplitAnAudioRateEpoch() {
  let raw = joined([
    ntscFrame(rate: .hz32000, timecodeFrame: 1),
    ntscFrame(rate: .hz32000, timecodeFrame: 29),
  ])
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)

  #expect(
    result.frames.map { $0.sourceTimecodePacks.first?.rawBytes } == [
      [0x13, 0x01, 0x00, 0x00, 0x01],
      [0x13, 0x1d, 0x00, 0x00, 0x01],
    ])
  #expect(result.audioSampleRateEpochs.count == 1)
  #expect(result.timecodeAuthority.contains("never_controls"))
}

@Test func rawBytesAndCaptureEdgesRemainHashBoundAndUnmodified() {
  var raw = Data(repeating: 0xaa, count: 80)
  raw.append(ntscFrame(rate: .hz48000))
  raw.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
  let before = raw
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)
  let expectedHash = SHA256.hash(data: raw).map {
    String(format: "%02x", $0)
  }.joined()

  #expect(raw == before)
  #expect(result.sourceSHA256 == expectedHash)
  #expect(result.frames.count == 1)
  #expect(result.frames[0].fileByteOffset == 80)
  #expect(
    result.unclassifiedExtents == [
      DVUnclassifiedCaptureExtent(
        fileByteOffset: 0, byteCount: 80, reason: .beforeFirstFrame),
      DVUnclassifiedCaptureExtent(
        fileByteOffset: 120_080, byteCount: 4, reason: .trailingBytes),
    ])
}

@Test func manifestEncodingIsCanonicalAndDeterministic() throws {
  let result = DVCaptureMetadataEpochAnalyzer.analyze(
    data: ntscFrame(rate: .hz32000))
  let first = try DVCaptureMetadataEpochAnalyzer.canonicalJSONData(result)
  let second = try DVCaptureMetadataEpochAnalyzer.canonicalJSONData(result)

  #expect(first == second)
  #expect(first.last == 0x0a)
  #expect(
    String(decoding: first, as: UTF8.self).contains(
      "\"derived_track_sample_rate_hz\":32000"))
  #expect(
    !String(decoding: first, as: UTF8.self).contains(
      "derivedTrackSampleRateHz"))
  #expect(
    try JSONDecoder().decode(
      DVCaptureMetadataEpochManifest.self, from: first) == result)
}

@Test func fileAnalyzerMatchesInMemoryAnalyzerExactly() throws {
  var raw = Data(repeating: 0x55, count: 160)
  raw.append(ntscFrame(rate: .hz48000, timecodeFrame: 9))
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "RewindDV-Build158-audio-epochs-\(UUID().uuidString).dv")
  defer { try? FileManager.default.removeItem(at: url) }
  try raw.write(to: url, options: .withoutOverwriting)

  #expect(
    try DVCaptureMetadataEpochAnalyzer.analyze(url: url)
      == DVCaptureMetadataEpochAnalyzer.analyze(data: raw))
}


@Test(arguments: [0, 9])
func invalidAudioTransmissionNeverQualifiesRate(sequence: Int) {
  let good = ntscFrame(rate: .hz48000)
  var invalid = good
  invalid[sequence * 150 * 80 + 5] |= 0x80
  let raw = good + invalid + good
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)
  #expect(result.completeFrameCount == 3)
  #expect(result.frames.map(\.audioSampleRate) == [.known48000Hz, .malformed, .known48000Hz])
  #expect(result.audioSampleRateEpochs.map(\.derivedTrackSampleRateHz) == [48_000, nil, 48_000])
  #expect(result.frames[1].aauxSourcePacks == DVCaptureMetadataEpochAnalyzer.analyze(data: invalid).frames[0].aauxSourcePacks.map {
    DVRawMetadataPackObservation(fileByteOffset: $0.fileByteOffset + 120_000,
      difSequence: $0.difSequence, difSection: $0.difSection, difBlock: $0.difBlock,
      packSlotByteOffset: $0.packSlotByteOffset, rawBytes: $0.rawBytes)
  })
}

@Test(arguments: ["duplicate", "block-range", "header-system"])
func inconsistentFrameIdentityRemainsUnclassified(mutation: String) {
  var invalid = ntscFrame(rate: .hz48000)
  switch mutation {
  case "duplicate": invalid[15 * 80 + 2] = 1 // duplicate video1; video0 absent
  case "block-range": invalid[15 * 80 + 2] = 135
  default: invalid[9 * 150 * 80 + 3] |= 0x80
  }
  let good = ntscFrame(rate: .hz32000)
  let raw = invalid + good
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)
  #expect(result.completeFrameCount == 1)
  #expect(result.frames.first?.fileByteOffset == 120_000)
  #expect(result.frames.first?.audioSampleRate == .known32000Hz)
  #expect(result.unclassifiedExtents == [DVUnclassifiedCaptureExtent(
    fileByteOffset: 0, byteCount: 120_000, reason: .incompleteFrame)])
  #expect(result.sourceSHA256 == SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
}

@Test func malformedFrameRetentionIsBoundedAndNextFrameRecovers() {
  let header = Data(difBlock(section: 0, sequence: 0, number: 0))
  var repeated = difBlock(section: 1, sequence: 0, number: 0)
  for offset in stride(from: 6, through: 46, by: 8) {
    putPack([0x13, 0, 0, 0, 0], at: offset, in: &repeated)
  }
  var accumulator = DVCaptureMetadataEpochAnalyzer.FrameAccumulator(fileByteOffset: 0)
  accumulator.consume(header, at: 0)
  var malformed = header
  for index in 1...4_000 {
    accumulator.consume(Data(repeated), at: UInt64(index * 80))
    malformed.append(contentsOf: repeated)
  }
  // Frame-local memory must remain bounded even without another start header.
  #expect(accumulator.sourceTimecodePacks.count <= 12 * 2 * 6)
  #expect(accumulator.blockCount <= 1_801)
  #expect(accumulator.materialize(sourceFrameOrdinal: 0) == nil)
  let good = ntscFrame(rate: .hz48000)
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: malformed + good)
  #expect(result.completeFrameCount == 1)
  #expect(result.frames.first?.fileByteOffset == UInt64(malformed.count))
  #expect(result.unclassifiedExtents == [DVUnclassifiedCaptureExtent(
    fileByteOffset: 0, byteCount: UInt64(malformed.count), reason: .incompleteFrame)])
}


@Test(arguments: [false, true])
func metadataFrameCapacityMatchesHeaderAndRetainsOverlongExtent(pal: Bool) {
  let good = ingestFrame(pal: pal)
  let valid = DVCaptureMetadataEpochAnalyzer.analyze(data: good)
  #expect(valid.completeFrameCount == 1)
  #expect(valid.frames.first?.byteCount == UInt64(pal ? 144_000 : 120_000))
  #expect(valid.frames.first?.audioSampleRate == .known48000Hz)
  #expect(valid.unclassifiedExtents.isEmpty)
  var oversized = good
  oversized.append(contentsOf: difBlock(section: 4, sequence: 0, number: 0))
  let result = DVCaptureMetadataEpochAnalyzer.analyze(data: oversized + good)
  #expect(result.completeFrameCount == 1)
  #expect(result.frames.first?.fileByteOffset == UInt64(oversized.count))
  #expect(result.unclassifiedExtents == [DVUnclassifiedCaptureExtent(
    fileByteOffset: 0, byteCount: UInt64(oversized.count), reason: .incompleteFrame)])
}


@Test func displayMetadataSummaryMatchesFullEvidenceAcrossTransitions() throws {
  var raw = Data(repeating: 0x55, count: 160)
  raw.append(joined([
    ntscFrame(rate: .hz32000), ntscFrame(rate: .hz32000),
    ntscFrame(rate: .hz44100), ntscFrame(rate: .hz48000),
    ntscFrame(rate: nil), ntscFrame(rate: .hz48000, malformedRateCode: true),
    ntscFrame(rate: .hz32000, lastSequenceRate: .hz48000),
    Data(ntscFrame(rate: .hz48000).prefix(800)),
    ingestFrame(pal: true), ingestFrame(pal: false),
  ]))
  raw.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dv")
  defer { try? FileManager.default.removeItem(at: url) }
  try raw.write(to: url, options: .withoutOverwriting)
  let manifest = DVCaptureMetadataEpochAnalyzer.analyze(data: raw)
  let summary = try DVCaptureMetadataEpochAnalyzer.analyzeSummary(url: url)
  #expect(summary.sourceByteCount == manifest.sourceByteCount)
  #expect(summary.sourceSHA256 == manifest.sourceSHA256)
  #expect(summary.completeFrameCount == manifest.completeFrameCount)
  #expect(summary.audioSampleRateEpochs == manifest.audioSampleRateEpochs)
  #expect(summary.unclassifiedExtents == manifest.unclassifiedExtents)
  #expect(try DVCaptureMetadataEpochAnalyzer.analyze(url: url) == manifest)
  #expect(try Data(contentsOf: url) == raw)
}

@Test(arguments: [false, true]) func cancelledMetadataScanDoesNotReturnCompleteFileFacts(summaryOnly: Bool) async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dv")
  defer { try? FileManager.default.removeItem(at: url) }
  try ntscFrame(rate: .hz48000).write(to: url, options: .withoutOverwriting)
  let cancelled = await Task.detached {
    withUnsafeCurrentTask { $0?.cancel() }
    do {
      if summaryOnly { _ = try DVCaptureMetadataEpochAnalyzer.analyzeSummary(url: url) }
      else { _ = try DVCaptureMetadataEpochAnalyzer.analyze(url: url) }
      return false
    } catch is CancellationError { return true }
    catch { Issue.record(error); return false }
  }.value
  #expect(cancelled)
}
