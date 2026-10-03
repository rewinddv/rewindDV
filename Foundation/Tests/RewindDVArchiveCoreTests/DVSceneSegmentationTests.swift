import Foundation
import CryptoKit
import Testing
@testable import RewindDVArchiveCore

private func sceneFrame(pal: Bool = false, start: Bool = false, end: Bool = false, aspect: UInt8 = 0, rate: UInt8 = 0) -> Data {
  semanticFrame(pal: pal, audio: [0x50, pal ? 24 : 20, 0, pal ? 0xa0 : 0x80, 0xc0 | (rate << 3)],
    audioControl: [0x51, 0, (start ? 0 : 0x80) | (end ? 0 : 0x40) | 0x0f, 0x80, 0xff],
    video: [0x60, 0xff, 0xff, pal ? 0xe0 : 0xc0, 0xff],
    videoControl: [0x61, 0, (start ? 0 : 0x80) | aspect, 0xf0, 0xff])
}
private func sceneObservation(_ data: Data, _ ordinal: UInt64) throws -> DVSceneSegmentation.Observation {
  .inspect(DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: data, ordinal: ordinal, byteOffset: ordinal * UInt64(data.count))))
}
private func detectScenes(_ frames: [Data]) throws -> DVSceneSegmentation.Detector {
  var detector = DVSceneSegmentation.Detector()
  for (index, frame) in frames.enumerated() { try detector.consume(sceneObservation(frame, UInt64(index))) }
  return detector
}
private func withSceneFiles(_ body: (URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewindDV-SceneTest-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}

@Test func sceneStartRunsCoalesceAndOnlyKnownDeassertionRearms() throws {
  let frames = [sceneFrame(), sceneFrame(start: true), sceneFrame(start: true), sceneFrame(), sceneFrame(start: true)]
  let result = try detectScenes(frames)
  #expect(result.boundaries.map(\.frame) == [1, 4])
  // Both independent AAUX sequence halves plus the VAUX marker corroborate it.
  #expect(result.boundaries.allSatisfy { $0.decision == .pending && $0.reasons.count == 3 }, "\(result.boundaries.map(\.reasons))")
  #expect(result.boundaries[0].before.frame == 0 && result.boundaries[0].after.frame == 1)
  #expect(!result.boundaries[0].after.packs.isEmpty)
  #expect(try detectScenes([sceneFrame(start: true), sceneFrame(start: true)]).boundaries.isEmpty)
}

@Test func sceneEndRunCutRetainsAllMarkedFramesAndEOFDoesNotCreateEmptyScene() throws {
  let result = try detectScenes([sceneFrame(), sceneFrame(end: true), sceneFrame(end: true), sceneFrame()])
  #expect(result.boundaries.map(\.frame) == [3])
  #expect(result.boundaries[0].reasons.first?.contains("recording-end") == true)
  #expect(try detectScenes([sceneFrame(), sceneFrame(end: true)]).boundaries.isEmpty)
}

@Test func sceneChangesCombineAspectAndAudioWithoutInventingSemanticLabels() throws {
  let result = try detectScenes([sceneFrame(), sceneFrame(aspect: 2, rate: 2), sceneFrame(aspect: 2, rate: 2)])
  #expect(result.boundaries.map(\.frame) == [1])
  #expect(result.boundaries[0].reasons.contains { $0.contains("DISP") })
  #expect(result.boundaries[0].reasons.contains { $0.contains("SMP") })
  #expect(!result.boundaries[0].reasons.contains { $0.contains("16:9") })
}

@Test func sceneMissingAndConflictingValuesNeverBecomeFormatCuts() throws {
  var gap = sceneFrame()
  for sequence in 0..<10 {
    // Remove VAUX source control and AAUX control, preserving frame structure.
    gap.replaceSubrange((sequence * 150 + 3) * 80 + 8..<(sequence * 150 + 3) * 80 + 13, with: [UInt8](repeating: 255, count: 5))
    gap.replaceSubrange((sequence * 150 + 22) * 80 + 3..<(sequence * 150 + 22) * 80 + 8, with: [UInt8](repeating: 255, count: 5))
  }
  let missing = try detectScenes([sceneFrame(start: true), gap, sceneFrame(start: true)])
  #expect(missing.boundaries.isEmpty && missing.incomplete > 0)
  var conflict = sceneFrame()
  conflict[3 * 80 + 10] = 0x82 // one DISP differs from the other nine
  let result = try detectScenes([sceneFrame(), conflict, sceneFrame()])
  #expect(result.boundaries.isEmpty && result.incomplete == 1)
}

@Test func sceneApplicationFormatChangesRemainExplicitAndUnsupportedIdentityIsNotGuessed() throws {
  let result = try detectScenes([sceneFrame(), semanticFrame(smpte: true)])
  #expect(result.boundaries.count == 1)
  #expect(result.boundaries[0].reasons.contains("DV application-format change"))
  var unknown = sceneFrame()
  for seq in 0..<10 { for byte in 4...7 { unknown[seq * 12_000 + byte] = 7 } }
  #expect(try detectScenes([sceneFrame(), unknown, sceneFrame()]).boundaries.isEmpty)
}

@Test(arguments: [false, true]) func reviewedScenesPreserveEveryByteAndRestoreDecisions(pal: Bool) async throws {
  try await withSceneFiles { root in
    let sourceURL = root.appendingPathComponent("master.dv"), mapURL = root.appendingPathComponent("map")
    let bytes = sceneFrame(pal: pal) + sceneFrame(pal: pal, start: true) + sceneFrame(pal: pal, start: true)
      + sceneFrame(pal: pal, aspect: 2) + sceneFrame(pal: pal, aspect: 2)
    try bytes.write(to: sourceURL)
    let receipt = try DVTapeEvidenceMapExporter.create(source: sourceURL, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let source = try DVVerifiedFrameSource(url: sourceURL, snapshot: receipt.sourceSnapshot)
    let fresh = try await DVSceneSegmentation.analyze(map: map, source: source)
    #expect(fresh.boundaries.map(\.frame) == [1, 3] && fresh.pendingCount == 2)
    let rejectedOutput = root.appendingPathComponent("unreviewed")
    await #expect(throws: Error.self) { try await DVSceneSegmentation.publish(plan: fresh, map: map, source: source, destination: rejectedOutput, exportDV: true) }
    #expect(!FileManager.default.fileExists(atPath: rejectedOutput.path))
    var reviewed = fresh
    reviewed.boundaries[0].decision = .accepted; reviewed.boundaries[0].note = "Visual review ✓"
    reviewed.boundaries[1].decision = .rejected
    #expect(reviewed.segments.map(\.first) == [0, 1] && reviewed.segments.map(\.endExclusive) == [1, 5])
    let out = root.appendingPathComponent("scenes")
    let result = try await DVSceneSegmentation.publish(plan: reviewed, map: map, source: source, destination: out, exportDV: true)
    #expect(result.outputs.count == 2 && result.concatenatedSHA256 == receipt.sourceSnapshot.sourceSHA256)
    var joined = Data()
    for output in result.outputs {
      let data = try Data(contentsOf: out.appendingPathComponent(output.file))
      #expect(UInt64(data.count) == output.bytes)
      #expect(DVSceneSegmentation.hex(SHA256.hash(data: data)) == output.sha256)
      joined.append(data)
    }
    let unchanged = try Data(contentsOf: sourceURL)
    #expect(joined == bytes && unchanged == bytes)
    let restored = try DVSceneSegmentation.restore(out.appendingPathComponent("review.json"), against: fresh)
    #expect(restored.boundaries == reviewed.boundaries)
    await #expect(throws: Error.self) { try await DVSceneSegmentation.publish(plan: reviewed, map: map, source: source, destination: out, exportDV: true) }
    let draft = root.appendingPathComponent("draft")
    let saved = try await DVSceneSegmentation.publish(plan: fresh, map: map, source: source, destination: draft, exportDV: false)
    #expect(saved.outputs.isEmpty && saved.concatenatedSHA256 == nil)
    #expect(try DVSceneSegmentation.restore(draft.appendingPathComponent("review.json"), against: fresh).pendingCount == 2)
    var tampered = reviewed; tampered.boundaries[0].note = String(repeating: "a", count: 5000)
    await #expect(throws: Error.self) { try await DVSceneSegmentation.publish(plan: tampered, map: map, source: source, destination: root.appendingPathComponent("tampered"), exportDV: false) }
  }
}

@Test func sceneReviewRefusesChangedEvidenceSymlinkAndMalformedInput() async throws {
  try await withSceneFiles { root in
    let url = root.appendingPathComponent("master.dv"), mapURL = root.appendingPathComponent("map")
    try (sceneFrame() + sceneFrame(start: true)).write(to: url)
    let receipt = try DVTapeEvidenceMapExporter.create(source: url, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL), source = try DVVerifiedFrameSource(url: url, snapshot: receipt.sourceSnapshot)
    let plan = try await DVSceneSegmentation.analyze(map: map, source: source)
    let review = root.appendingPathComponent("review.json")
    var altered = plan; altered.boundaries.removeAll()
    try DVSceneSegmentation.encode(altered).write(to: review)
    #expect(throws: Error.self) { try DVSceneSegmentation.restore(review, against: plan) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: review)
    #expect(throws: Error.self) { try DVSceneSegmentation.restore(link, against: plan) }
    try Data("{".utf8).write(to: review)
    #expect(throws: Error.self) { try DVSceneSegmentation.restore(review, against: plan) }
    let handle = try FileHandle(forWritingTo: url); try handle.seek(toOffset: 1000); try handle.write(contentsOf: Data([0])); try handle.close()
    await #expect(throws: Error.self) { try await DVSceneSegmentation.analyze(map: map, source: source) }
    await #expect(throws: Error.self) { try await DVSceneSegmentation.publish(plan: plan, map: map, source: source, destination: root.appendingPathComponent("changed"), exportDV: false) }
  }
}

@Test func sceneCancellationDoesNotPublishCompletion() async throws {
  try await withSceneFiles { root in
    let url = root.appendingPathComponent("master.dv"), mapURL = root.appendingPathComponent("map")
    try sceneFrame().write(to: url)
    let receipt = try DVTapeEvidenceMapExporter.create(source: url, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL), source = try DVVerifiedFrameSource(url: url, snapshot: receipt.sourceSnapshot)
    let plan = try await DVSceneSegmentation.analyze(map: map, source: source)
    let out = root.appendingPathComponent("cancelled")
    let worker = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DVSceneSegmentation.publish(plan: plan, map: map, source: source, destination: out, exportDV: true)
    }
    await #expect(throws: Error.self) { try await worker.value }
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("scenes.json").path))
  }
}

@Test func sceneCancellationAfterWritingKeepsIncompleteOutputsWithoutMarker() async throws {
  try await withSceneFiles { root in
    let url = root.appendingPathComponent("master.dv"), mapURL = root.appendingPathComponent("map")
    try sceneFrame().write(to: url)
    let receipt = try DVTapeEvidenceMapExporter.create(source: url, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL), source = try DVVerifiedFrameSource(url: url, snapshot: receipt.sourceSnapshot)
    let plan = try await DVSceneSegmentation.analyze(map: map, source: source)
    let out = root.appendingPathComponent("cancelled-after-write")
    let worker = Task {
      try await DVSceneSegmentation.publish(plan: plan, map: map, source: source, destination: out, exportDV: true) { _, _ in
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("intent.json").path) {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("scene-000001.dv.partial").path))
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("scenes.json").path))
  }
}

@Test func sceneMissingTimecodeAndRecordedDatesDoNotDeleteOrSplitFrames() throws {
  // Fixture has all-FF timecode/date packs. The repeated frames still form one
  // full partition; visual content and unknown timestamps are not cut criteria.
  let detector = try detectScenes([sceneFrame(), sceneFrame(), sceneFrame()])
  #expect(detector.boundaries.isEmpty)
  var firstHalfOnly = sceneFrame()
  for seq in 0..<5 { firstHalfOnly[(seq * 150 + 22) * 80 + 5] &= 0x7f }
  let scoped = try detectScenes([sceneFrame(), firstHalfOnly])
  #expect(scoped.boundaries.count == 1 && scoped.boundaries[0].reasons.count == 1)
  #expect(scoped.boundaries[0].reasons[0].contains("aaux-sequence-half-1"))
}
