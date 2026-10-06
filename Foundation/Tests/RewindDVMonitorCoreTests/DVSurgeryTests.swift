import Foundation
import Testing
import CryptoKit
import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func surgeryFrame(pal: Bool = true, start: Bool? = nil, timecode: Int? = nil) -> Data {
  var d = Data(repeating: 255, count: pal ? 144000 : 120000)
  for sequence in 0..<(pal ? 12 : 10) {
    for local in 0..<150 {
      let section: Int, number: Int
      if local == 0 { section = 0; number = 0 }
      else if local < 3 { section = 1; number = local - 1 }
      else if local < 6 { section = 2; number = local - 3 }
      else if (local - 6) % 16 == 0 { section = 3; number = (local - 6) / 16 }
      else { section = 4; number = local - 7 - (local - 6) / 16 }
      let at = sequence * 12000 + local * 80
      d[at] = UInt8(section << 5) | 31; d[at + 1] = UInt8(sequence << 4) | 7; d[at + 2] = UInt8(number)
      if section == 0 {
        d[at + 3] = pal ? 0xbf : 0x3f
        for i in 4...7 { d[at + i] = 0x78 }
      }
      if section == 2, let start { d.replaceSubrange((at + 3)..<(at + 8), with: [0x61,0xff,start ? 0x48 : 0xc8,0xff,0xff]) }
      if section == 1, let timecode {
        let f = UInt8((timecode / 10) << 4 | timecode % 10)
        for slot in stride(from: 6, through: 46, by: 8) { d.replaceSubrange((at + slot)..<(at + slot + 5), with: [0x13,f,0,0,0]) }
      }
    }
  }
  return d
}
private func withSurgery(_ bytes: Data, _ body: (URL, URL) throws -> Void) throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: folder) }
  let source = folder.appendingPathComponent("original.dv")
  try bytes.write(to: source, options: .withoutOverwriting)
  try body(source, folder)
}

@Test func surgeryMixedFormatCutsReassembleOriginalAndSaveVerifiedReceipts() throws {
  let bytes = surgeryFrame(pal: false) + surgeryFrame() + surgeryFrame(start: false) + surgeryFrame(start: true) + surgeryFrame(pal: false)
  try withSurgery(bytes) { url, folder in
    let clip = try DVSurgeryClip.read(url)
    #expect(clip.timeline.frameCount == 5)
    #expect(clip.segments.map(\.first) == [0,1,3,4])
    #expect(clip.segments[2].reason == "Recording start")
    let automatic = try clip.ranges(first: 0, end: 5, splitScenes: false)
    #expect(automatic.map(\.firstFrame) == [0,1,4])
    let ranges = try clip.ranges(first: 0, end: 5, splitScenes: true)
    #expect(ranges.map(\.firstFrame) == [0,1,3,4])
    let destination = folder.appendingPathComponent("exports")
    let receipt = try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: destination)
    var combined = Data()
    for item in receipt.outputs {
      let saved = try Data(contentsOf: destination.appendingPathComponent(item.file))
      #expect(saved == bytes.subdata(in: Int(item.pieces[0].range.byteOffset)..<Int(item.pieces[0].range.byteOffset + item.pieces[0].range.byteCount)))
      #expect(item.sha256 == SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined())
      combined.append(saved)
    }
    #expect(combined == bytes)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("surgery.json").path))
    #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: destination) }
  }
}
@Test func surgeryTimestampRoundingAndValidationUseMixedCadence() throws {
  try withSurgery(surgeryFrame(pal: false) + surgeryFrame() + surgeryFrame()) { url, _ in
    let clip = try DVSurgeryClip.read(url)
    #expect(clip.boundary(at: 0.016) == 0)
    #expect(clip.boundary(at: 0.017) == 1)
    #expect(clip.boundary(at: 0.052) == 1)
    #expect(clip.boundary(at: 0.054) == 2)
    #expect(clip.boundary(at: 100) == 3)
    #expect(try clip.ranges(first: 1, end: 3, splitScenes: false).first?.byteCount == 288000)
    #expect(throws: (any Error).self) { try clip.ranges(first: 2, end: 2, splitScenes: false) }
    #expect(throws: (any Error).self) { try clip.ranges(first: -1, end: 3, splitScenes: false) }
    #expect(throws: (any Error).self) { try clip.ranges(first: 0, end: 4, splitScenes: false) }
  }
  #expect(DVSurgeryClip.parseTime("01:02:03.125") == 3723.125)
  #expect(DVSurgeryClip.parseTime("90.5") == 90.5)
  for input in ["nan","inf","-1","1:60","0::1","1.5:02","1e2",""] { #expect(DVSurgeryClip.parseTime(input) == nil) }
}
@Test func surgeryDoesNotBridgeMissingOrConflictingMarkers() throws {
  let clear = surgeryFrame(start: false), start = surgeryFrame(start: true), unknown = surgeryFrame()
  var conflict = start; conflict[12000 + 3 * 80 + 5] = 0xc8
  var invalid = start; invalid[6] |= 128
  for data in [clear + conflict, clear + invalid] {
    try withSurgery(data) { url, _ in
      let clip = try DVSurgeryClip.read(url); #expect(clip.segments.count == 1)
    }
  }
  try withSurgery(clear + start + unknown + start + clear + start) { url, _ in
    let clip = try DVSurgeryClip.read(url); #expect(clip.segments.map(\.first) == [0,1,5])
  }
  try withSurgery(surgeryFrame(timecode: 0) + surgeryFrame(timecode: 1) + surgeryFrame(timecode: 9)) { url, _ in
    let clip = try DVSurgeryClip.read(url); #expect(clip.segments.map(\.first) == [0,2])
  }
}
@Test func surgeryRejectsSourceMutationTruncationAndUnalignedExports() throws {
  let frame = surgeryFrame()
  try withSurgery(frame + frame) { url, folder in
    let clip = try DVSurgeryClip.read(url)
    let ranges = try clip.ranges(first: 0, end: 2, splitScenes: false)
    var mutation = frame + frame; mutation[1000] ^= 1; try mutation.write(to: url)
    #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: folder.appendingPathComponent("mutated")) }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("mutated").path))
    try (frame + frame).write(to: url)
    let bad = DVSurgeryByteExporter.Range(firstFrame: 0, endFrameExclusive: 1, byteOffset: 80, byteCount: 144000, startSeconds: 0, endSeconds: 0.04, format: "PAL")
    let dest = folder.appendingPathComponent("unaligned")
    #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: [bad], destination: dest) }
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("surgery.json").path))
  }
  var unsupported = frame; unsupported[4] = 0x7a
  for data in [frame.dropLast(), unsupported] { try withSurgery(Data(data)) { url, _ in #expect(throws: (any Error).self) { try DVSurgeryClip.read(url) } } }
}
@Test func surgeryNeverAuthorizesTapeTransport() {
  let policy = WorkspaceCapabilities(source: .surgery, fileReady: true, deckSelected: true,
    fastForwardSupported: true, liveMonitoring: true, shuttleForwardSupported: true, shuttleReverseSupported: true)
  #expect(MonitorAction.allCases.allSatisfy { !policy.allows($0) })
}

@Test(arguments: [DVSurgeryByteExporter.Layout.separate, .merged])
func surgeryAbortsChangedSourceDuringCopyWithoutCompletionMarker(layout: DVSurgeryByteExporter.Layout) throws {
  let frame = surgeryFrame()
  var bytes = Data(); for _ in 0..<130 { bytes.append(frame) }
  try withSurgery(bytes) { url, folder in
    let clip = try DVSurgeryClip.read(url), dest = folder.appendingPathComponent("changed-during-copy")
    let ranges = try clip.ranges(first: 0, end: 130, splitScenes: false)
    let writer = try FileHandle(forWritingTo: url); defer { try? writer.close() }
    var changed = false
    #expect(throws: (any Error).self) {
      try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: dest, layout: layout) { _ in
        if !changed {
          changed = true
          try! writer.seek(toOffset: 1000); try! writer.write(contentsOf: Data([0])); try! writer.synchronize()
        }
      }
    }
    #expect(changed)
    #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("surgery.json").path))
  }
}

@Test func surgeryMergesDisjointSegmentsWithoutChangingBytesOrInventingContinuity() throws {
  let a = surgeryFrame(timecode: 0), b = surgeryFrame(timecode: 9), c = surgeryFrame(timecode: 18)
  try withSurgery(a + b + c) { url, folder in
    let clip = try DVSurgeryClip.read(url)
    let ranges = try clip.selectedRanges([2, 0])
    #expect(ranges.map(\.firstFrame) == [0, 2])
    #expect(throws: (any Error).self) { try clip.selectedRanges([99]) }
    let dest = folder.appendingPathComponent("merged")
    let receipt = try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: dest, layout: .merged)
    #expect(receipt.outputs.count == 1)
    let output = try #require(receipt.outputs.first)
    let saved = try Data(contentsOf: dest.appendingPathComponent(output.file))
    #expect(saved == a + c)
    #expect(output.byteCount == 288000)
    #expect(output.pieces.map(\.range) == ranges)
    #expect(output.pieces.map(\.outputByteOffset) == [0, 144000])
    #expect(output.pieces.map(\.outputFirstFrame) == [0, 1])
    #expect(output.sha256 == SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined())
    #expect(try Data(contentsOf: url) == a + b + c)
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dest.appendingPathComponent("surgery.json"))) as? [String: Any])
    #expect(json["layout"] as? String == "merged")
    #expect(json["schemaVersion"] as? Int == 2)
    #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: ranges, destination: dest, layout: .merged) }
    for invalid in [[], ranges.reversed().map { $0 }, [ranges[0], ranges[0]]] {
      let bad = folder.appendingPathComponent(UUID().uuidString)
      #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: invalid, destination: bad, layout: .merged) }
      #expect(!FileManager.default.fileExists(atPath: bad.path))
    }
  }
}

@Test func surgeryMergeChecksActualProfilesEvenWhenRangeLabelsLie() throws {
  var profileOne = surgeryFrame()
  for offset in stride(from: 0, to: profileOne.count, by: 12000) {
    for byte in 4...7 { profileOne[offset + byte] = 0x79 }
  }
  for second in [surgeryFrame(pal: false), profileOne] {
    try withSurgery(surgeryFrame() + second) { url, folder in
      let clip = try DVSurgeryClip.read(url)
      // One forged range spanning two profiles must not evade compatibility checks.
      let r = DVSurgeryByteExporter.Range(firstFrame: 0, endFrameExclusive: 2, byteOffset: 0,
        byteCount: clip.timeline.byteCount, startSeconds: 0, endSeconds: clip.timeline.durationSeconds, format: "PAL")
      let dest = folder.appendingPathComponent("bad-merge")
      #expect(throws: (any Error).self) { try DVSurgeryByteExporter.export(source: url, expectedSHA256: clip.sha256, ranges: [r], destination: dest, layout: .merged) }
      #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("surgery.json").path))
      #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("merged.dv").path))
    }
  }
}
