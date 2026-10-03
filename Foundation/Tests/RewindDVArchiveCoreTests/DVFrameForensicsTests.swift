import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func audioFrame(pal: Bool = false, nonlinear: Bool = false, size: UInt8? = nil) -> Data {
  semanticFrame(pal: pal, audio: [0x50, size ?? (nonlinear ? (pal ? 16 : 27) : (pal ? 24 : 20)),
    nonlinear ? 0x20 : 0, pal ? 0xa0 : 0x80, nonlinear ? 0xd1 : 0xc0])
}
private func inspect(_ data: Data, offset: UInt64 = 240_000) throws -> DVFrameForensics {
  try DVFrameForensics.inspect(frame: data, ordinal: 2, offset: offset)
}

@Test(arguments: [false, true]) func forensicEveryVideoSTAHasExactByteAndSequence(pal: Bool) throws {
  var frame = audioFrame(pal: pal)
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 4 { frame[at + 3] = 0xa7 }
  let before = frame
  let result = try inspect(frame)
  #expect(frame == before)
  #expect(result.summary.videoStatusBySequence == Array(repeating: 135, count: pal ? 12 : 10))
  for block in result.blocks where block.section == 4 {
    #expect(block.videoSTA == 10)
    #expect(frame[Int(block.sourceByteOffset - 240_000) + 3] == 0xa7)
    #expect(block.number < 135 && block.sequence < (pal ? 12 : 10))
  }
  #expect(result.blocks.count == (pal ? 1800 : 1500))
}

@Test(arguments: [false, true]) func forensicAudioExcludesPaddingAndPreservesExactCodes(pal: Bool) throws {
  var frame = audioFrame(pal: pal)
  let samples = pal ? 1920 : 1600
  // Fill all audio capacity with error sentinels; only declared samples count.
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 3 {
    for index in stride(from: at + 8, to: at + 80, by: 2) { frame[index] = 0x80; frame[index + 1] = 0 }
  }
  let result = try inspect(frame)
  #expect(result.summary.audioSamplesExamined == samples * 2)
  #expect(result.audioChannels.map(\.sampleCount) == [samples, samples])
  #expect(result.audioChannels.map(\.sampleRate) == [48_000, 48_000])
  #expect(result.audioErrors.count == samples * 2)
  #expect(Set(result.audioErrors.map { "\($0.channel):\($0.sample)" }).count == samples * 2)
  #expect(result.summary.audioErrorsBySequence.reduce(0, +) == samples * 2)
  for error in result.audioErrors {
    #expect(error.sample < samples && error.channel < 2 && error.code == 0x8000)
    #expect(error.bitMasks == [0xff, 0xff])
    let offset = Int(error.byteOffsets[0] - 240_000)
    #expect(frame[offset] == 0x80 && frame[offset + 1] == 0)
  }
}

@Test(arguments: [false, true]) func forensicNonlinearSamplesUseBothExactNibbleMasks(pal: Bool) throws {
  var frame = audioFrame(pal: pal, nonlinear: true)
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 3 {
    for index in stride(from: at + 8, to: at + 80, by: 3) {
      frame[index] = 0x80; frame[index + 1] = 0x80; frame[index + 2] = 0
    }
  }
  let samples = pal ? 1280 : 1080
  let result = try inspect(frame)
  #expect(result.audioErrors.count == samples * 4)
  #expect(result.summary.audioSamplesExamined == samples * 4)
  #expect(result.audioChannels.map(\.sampleCount) == Array(repeating: samples, count: 4))
  #expect(result.audioChannels.map(\.sampleRate) == Array(repeating: 32_000, count: 4))
  #expect(Set(result.audioErrors.map { "\($0.channel):\($0.sample)" }).count == samples * 4)
  for error in result.audioErrors {
    #expect(error.code == 0x800 && error.sample < samples && error.channel < 4)
    #expect(error.bitMasks == [0xff, error.channel % 2 == 0 ? 0xf0 : 0x0f])
    #expect(error.byteOffsets[1] - error.byteOffsets[0] == (error.channel % 2 == 0 ? 2 : 1))
  }
}

@Test func forensicAudioAmbiguityDoesNotInventZeroErrorCoverage() throws {
  for kind in 0..<8 {
    var frame = audioFrame()
    for seq in 0..<10 {
      let header = seq * 12_000, pack = header + 6 * 80 + 3
      switch kind {
      case 0: frame[pack] = 0xff // no source pack
      case 1: frame[pack + 4] = 0xc7 // unsupported quantization
      case 2: frame[header + 5] |= 0x80 // AP1 invalid (not AP2)
      case 3: for i in 4...7 { frame[header + i] = 1 } // SMPTE not qualified here
      case 4: frame[pack + 3] |= 0x20 // wrong field system
      case 5: frame[pack + 1] = 63 // outside actual capacity
      case 6: frame[pack + 2] |= 0x20 // channel count contradicts 16-bit mode
      default: for block in 0..<150 { frame[header + block * 80 + 1] |= 0x08 } // unsupported DIF channel
      }
    }
    let result = try inspect(frame)
    #expect(result.summary.audioSamplesExamined == 0)
    #expect(result.audioChannels.isEmpty)
    #expect(result.summary.audioCoverage.contains("unassessed"))
  }
  var conflict = audioFrame()
  // Differing AF_SIZE in first half invalidates only that half.
  conflict[12_000 + 6 * 80 + 4] = 21
  conflict[12_000 + 6 * 80 + 7] = 0xc8 // conflicting recognized sample rate
  let partial = try inspect(conflict)
  #expect(partial.summary.audioSamplesExamined == 1600)
  #expect(partial.audioChannels.map(\.channel) == [1])
  #expect(partial.summary.audioCoverage.hasPrefix("1/2"))
  #expect(partial.summary.conflictingMetadataValues > 0)
}

@Test(arguments: [false, true]) func forensicGeometryTilesEveryRasterPixelExactlyOnce(pal: Bool) throws {
  let height = pal ? 576 : 480
  var coverage = [UInt8](repeating: 0, count: 720 * height)
  for seq in 0..<(pal ? 12 : 10) {
    for block in 0..<135 {
      let r = try #require(DVVideoBlockGeometry.region(sequence: seq, block: block, pal: pal))
      #expect(r.x >= 0 && r.y >= 0 && r.x + r.width <= 720 && r.y + r.height <= height)
      for y in r.y..<(r.y + r.height) { for x in r.x..<(r.x + r.width) { coverage[y * 720 + x] += 1 } }
    }
  }
  #expect(coverage.allSatisfy { $0 == 1 })
  #expect(DVVideoBlockGeometry.region(sequence: -1, block: 0, pal: pal) == nil)
  #expect(DVVideoBlockGeometry.region(sequence: 0, block: 135, pal: pal) == nil)
  // Fixed coordinates cross-checked against FFmpeg dv.c's separate shuffle representation.
  let first = try #require(DVVideoBlockGeometry.region(sequence: 0, block: 0, pal: pal))
  #expect(first.x == 288 && first.y == 96)
  let edge = try #require(DVVideoBlockGeometry.region(sequence: 0, block: 124, pal: false))
  #expect(edge.x == 704 && edge.y == 192 && edge.width == 16 && edge.height == 16)
}

@Test func forensicPALSMPTE411HasItsOwnGeometryAndFormatGate() throws {
  var coverage = [UInt8](repeating: 0, count: 720 * 576)
  for seq in 0..<12 { for block in 0..<135 {
    let r = try #require(DVVideoBlockGeometry.region(sequence: seq, block: block, layout: .pal411))
    #expect(r.x >= 0 && r.y >= 0 && r.x + r.width <= 720 && r.y + r.height <= 576)
    for y in r.y..<(r.y + r.height) { for x in r.x..<(r.x + r.width) { coverage[y * 720 + x] += 1 } }
  } }
  #expect(coverage.allSatisfy { $0 == 1 })
  let pal = semanticFrame(smpte: true, pal: true, video: [0x60, 0xff, 0xff, 0xe0, 0xff])
  #expect(try inspect(pal).videoLayout == .pal411)
  #expect(try inspect(semanticFrame(pal: true, video: [0x60, 0xff, 0xff, 0xe0, 0xff])).videoLayout == .pal420)
  #expect(try inspect(semanticFrame(video: [0x60, 0xff, 0xff, 0xc2, 0xff])).videoLayout == nil)
}

@Test(arguments: [DVVideoBlockGeometry.Layout.ntsc411, .pal420, .pal411])
func forensicPictureAndPackClicksResolveOriginalByteRanges(layout: DVVideoBlockGeometry.Layout) throws {
  let frame = semanticFrame(smpte: layout == .pal411, pal: layout.isPAL,
    video: [0x60, 0xff, 0xff, layout.isPAL ? 0xe0 : 0xc0, 0xff])
  let result = try inspect(frame)
  #expect(result.videoLayout == layout)
  for block in result.blocks where block.section == 4 {
    let r = try #require(DVVideoBlockGeometry.region(sequence: block.sequence, block: block.number, layout: layout))
    #expect(result.block(atRasterX: r.x + r.width / 2, y: r.y + r.height / 2) == block)
    let index = Int(block.sourceByteOffset - 240_000)
    #expect(frame[index] >> 5 == 4 && frame[index + 1] >> 4 == block.sequence && frame[index + 2] == block.number)
  }
  for pack in result.semantics.packs { for offset in pack.sourceByteOffsets {
    let block = try #require(result.block(containingSourceByte: offset))
    #expect(offset >= block.sourceByteOffset && offset + 5 <= block.sourceByteOffset + 80)
    let start = Int(offset - 240_000)
    #expect(frame[start..<(start + 5)].map { String(format: "%02X", $0) }.joined(separator: " ") == pack.rawHex)
  } }
  #expect(result.block(atRasterX: 720, y: 0) == nil)
  #expect(result.block(containingSourceByte: UInt64.max) == nil)
}

@Test func forensicTimelineSeparatesLabelsFromLossAndHandlesUnknowns() throws {
  func value(_ f: UInt8, date: [UInt8]? = nil, audio: UInt8 = 0xc0) throws -> DVFrameTimelineEvidence.Point {
    var data = audioFrame()
    for seq in 0..<10 {
      let base = seq * 12_000
      data.replaceSubrange((base + 80 + 6)..<(base + 80 + 11), with: [0x13, f, 0, 0, 0])
      data[base + 6 * 80 + 7] = audio
      if let date { data.replaceSubrange((base + 3 * 80 + 13)..<(base + 3 * 80 + 18), with: date) }
    }
    let inventory = try DVMetadataInventory.inspect(frame: data, ordinal: 0, byteOffset: 0)
    return DVFrameTimelineEvidence.inspect(inventory, report: DVPackSemanticReport.inspect(inventory))
  }
  let a = try value(0), b = try value(1)
  #expect(a.timecodeLabel == "00:00:00:00" && b.timecodeFrame == 1)
  #expect(DVFrameTimelineEvidence.changes(from: a, to: b).isEmpty)
  #expect(DVFrameTimelineEvidence.changes(from: b, to: a) == [.timecodeTransition])
  let bad = try value(0xff)
  #expect(bad.timecodeFrame == nil)
  #expect(DVFrameTimelineEvidence.changes(from: b, to: bad).contains(.timecodeTransition))
  let dated = try value(2, date: [0x62, 0xff, 0x21, 0x09, 0x26], audio: 0xc8)
  #expect(dated.recordedDate == "26-09-21")
  #expect(DVFrameTimelineEvidence.changes(from: b, to: dated) == [.recordedDateTransition, .formatTransition])
  #expect(DVFrameTimelineEvidence.changes(from: nil, to: dated).isEmpty)
}

private func withForensicFiles(_ body: (URL, URL, URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-Forensics-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root, root.appendingPathComponent("source.dv"), root.appendingPathComponent("map"))
}

@Test func forensicVerifiedSourceBindsAllBytesAndRefusesChanges() async throws {
  try await withForensicFiles { root, source, map in
    let data = audioFrame()
    try data.write(to: source)
    let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let ledger = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    let record = try await ledger.page(0).records[0]
    let reader = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    #expect(try await reader.frame(record).bytes == data)
    #expect(record.quality != nil)
    var changed = data; changed[1000] ^= 1
    let wrong = root.appendingPathComponent("wrong.dv"); try changed.write(to: wrong)
    #expect(throws: Error.self) { try DVVerifiedFrameSource(url: wrong, snapshot: receipt.sourceSnapshot) }
    let link = root.appendingPathComponent("link.dv")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: Error.self) { try DVVerifiedFrameSource(url: link, snapshot: receipt.sourceSnapshot) }
    let handle = try FileHandle(forWritingTo: source)
    try handle.seek(toOffset: 1000); try handle.write(contentsOf: Data([changed[1000]])); try handle.close()
    await #expect(throws: Error.self) { try await reader.frame(record) }
    try data.write(to: source, options: .atomic)
    await #expect(throws: Error.self) { try await reader.frame(record) }
    let rebound = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    var forged = record; forged.quality = .init(version: 1, videoStatusBySequence: Array(repeating: 1, count: 10),
      audioErrorsBySequence: Array(repeating: 0, count: 10), audioSamplesExamined: 0,
      audioCoverage: "forged", invalidMetadataValues: 0, conflictingMetadataValues: 0)
    await #expect(throws: Error.self) { try await rebound.frame(forged) }
  }
}

@Test func forensicSparseNavigationCrossesPagesFiltersAndDoesNotWrap() async throws {
  try await withForensicFiles { _, source, map in
    let normal = audioFrame()
    var flagged = normal; flagged[7 * 80 + 3] = 0x10
    var data = Data(); for index in 0..<258 { data.append(index == 0 || index == 257 ? flagged : normal) }
    try data.write(to: source)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: map)
    #expect(reader.pageSummaries[0].qualityAssessedFrames == 256)
    #expect(reader.pageSummaries[1].qualityAssessedFrames == 2)
    #expect(try await reader.findIssue(after: nil, forward: true, code: .nonzeroVideoSTA) == 0)
    #expect(try await reader.findIssue(after: 0, forward: true, code: .nonzeroVideoSTA) == 257)
    #expect(try await reader.findIssue(after: 257, forward: false, code: .nonzeroVideoSTA) == 0)
    #expect(try await reader.findIssue(after: 257, forward: true, code: .nonzeroVideoSTA) == nil)
    #expect(try await reader.findIssue(after: UInt64.max, forward: true) == nil)
    #expect(try await reader.findIssue(after: nil, forward: true, code: .audioErrorSentinels) == nil)
    var legacy = try await reader.page(0).records[0]; legacy.quality = nil
    let encoded = try JSONEncoder().encode(legacy)
    #expect(try JSONDecoder().decode(DVTapeEvidenceMapExporter.FrameRecord.self, from: encoded).quality == nil)
  }
}

@Test func forensicReceiptCannotHideLedgerIssueCounts() async throws {
  try await withForensicFiles { _, source, map in
    var data = audioFrame(); data[7 * 80 + 3] = 0x10
    try data.write(to: source)
    _ = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let marker = map.appendingPathComponent(DVTapeEvidenceMapExporter.completionMarkerName)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
    json["issue_counts"] = [] // Ledger and its hash are intact; summary is false.
    try JSONSerialization.data(withJSONObject: json).write(to: marker)
    #expect(throws: Error.self) { try DVTapeEvidenceLedgerReader(mapDirectory: map) }
  }
}

@Test func forensicCancellationAndMalformedInputsNeverPublishBytes() async throws {
  #expect(throws: Error.self) { try inspect(Data(repeating: 0, count: 120_000)) }
  #expect(throws: Error.self) { try inspect(audioFrame(), offset: UInt64.max) }
  try await withForensicFiles { _, source, map in
    try audioFrame().write(to: source)
    let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: map)
    let worker = Task { () throws -> DVVerifiedFrameSource in
      withUnsafeCurrentTask { $0?.cancel() }
      return try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    }
    await #expect(throws: CancellationError.self) { try await worker.value }
  }
}
