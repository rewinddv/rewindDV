import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func mergeFrame(_ id: Int, pal: Bool = false, nonlinear: Bool = false, smpte: Bool = false) -> Data {
  var frame = semanticFrame(smpte: smpte, pal: pal,
    audio: [0x50, 0x40 | (nonlinear ? (pal ? 16 : 27) : (pal ? 24 : 20)), nonlinear ? 0x20 : 0,
      pal ? 0xa0 : 0x80, nonlinear ? 0xd1 : 0xc0], video: [0x60,0xff,0xff,pal ? 0xe0 : 0xc0,0xff])
  // Original synthetic frame identities in reserved bytes; no camera identity
  // or timecode semantics are being asserted by this fixture.
  frame[9] = UInt8(truncatingIfNeeded: id); frame[10] = UInt8(truncatingIfNeeded: id >> 8)
  frame[7 * 80 + 12] = UInt8(truncatingIfNeeded: id)
  return frame
}
private func damagedVideo(_ frame: Data) -> Data { var d = frame; d[7 * 80 + 3] = 0x10; d[7 * 80 + 10] = 0; return d }
private func mergeFiles(_ frames: [[Data]], body: ([DVMultiPass.Input], URL, [URL]) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("multipass-test-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  var inputs: [DVMultiPass.Input] = [], sources: [URL] = []
  for (i, frames) in frames.enumerated() {
    let file = root.appendingPathComponent("\(i).dv"), mapURL = root.appendingPathComponent("map-\(i)")
    try frames.reduce(into: Data(), { $0.append($1) }).write(to: file, options: .withoutOverwriting)
    let receipt = try DVTapeEvidenceMapExporter.create(source: file, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let source = try DVVerifiedFrameSource(url: file, snapshot: receipt.sourceSnapshot)
    inputs.append(.init(map: map, source: source)); sources.append(file)
  }
  try await body(inputs, root, sources)
}
private func approve(_ plan: DVMultiPass.Plan) -> DVMultiPass.Plan {
  var result = plan
  for i in result.reviews.indices {
    result.reviews[i].choice = result.candidates.first { $0.baseFrame == result.reviews[i].baseFrame && $0.eligible }!.id
  }
  return result
}

@Test(arguments: [false,true]) func multiPassWholeFrameMergeAndEveryOutputProvenance(pal: Bool) async throws {
  let good = (0..<9).map { mergeFrame($0,pal: pal) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, files in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.map(\.baseFrame) == [4], "\(plan.candidates)")
    #expect(plan.candidates[0].anchors.count == 4 && plan.candidates[0].eligible)
    let output = root.appendingPathComponent("out")
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: output, exportDV: true) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    let receipt = try await DVMultiPass.publish(plan: approve(plan), inputs: inputs, destination: output, exportDV: true)
    let bytes = try Data(contentsOf: output.appendingPathComponent("merged.dv")), donor = try Data(contentsOf: files[1])
    #expect(bytes == donor && receipt.replacements == 1 && receipt.mediaSHA256 == DVMultiPass.hash(bytes))
    let rows = try Data(contentsOf: output.appendingPathComponent("provenance.ndjson")).split(separator: 10)
    #expect(rows.count == 9)
    for (i, line) in rows.enumerated() {
      let record = try JSONDecoder().decode(DVMultiPass.Provenance.self, from: Data(line))
      #expect(record.outputFrame == i && record.sourceFrame == i && record.sourcePass == (i == 4 ? 1 : 0))
      let size = pal ? 144000 : 120000
      #expect(record.sourceByteOffset == i * size && record.outputByteOffset == i * size)
      #expect(record.frameSHA256 == DVMultiPass.hash(bytes.subdata(in: i * size..<(i + 1) * size)))
    }
    #expect(try Data(contentsOf: files[0]) == base.reduce(into: Data(), { $0.append($1) }))
  }
}

@Test(arguments: [false,true]) func multiPassAudioCorrectionsRespectExactSampleBits(nonlinear: Bool) async throws {
  let good = (0..<9).map { mergeFrame($0, nonlinear: nonlinear) }; var base = good
  base[4][6 * 80 + 8] = 0x80
  if nonlinear { base[4][6 * 80 + 10] &= 0x0f } else { base[4][6 * 80 + 9] = 0 }
  try await mergeFiles([base,good]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.candidates.first?.eligible == true, "\(plan.candidates)")
    #expect(plan.candidates.first?.before.audioErrors == 1)
  }
  var altered = good
  // Healthy neighboring sample must not be silently taken from another pass.
  altered[4][6 * 80 + (nonlinear ? 9 : 10)] ^= 1
  try await mergeFiles([base,altered]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty)
  }
}

@Test func multiPassHealthyVideoSegmentAndMetadataCannotBeReplaced() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  var changed = good; changed[4][13 * 80 + 12] ^= 1 // video block 6, outside damaged 0–4 segment
  try await mergeFiles([base,changed]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty && plan.candidates.first?.reason.contains("already-good") == true)
  }
  changed = good; changed[4][9] ^= 128 // metadata identity differs
  try await mergeFiles([base,changed]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty && plan.comparisons[0].unresolvedBaseRanges.contains { $0.first <= 4 && $0.endExclusive > 4 })
  }
}

@Test func multiPassDivergentDonorsRefuseRatherThanVote() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  var other = good; other[4][7 * 80 + 13] ^= 1
  try await mergeFiles([base,good,other]) { inputs, root, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty && plan.candidates.count == 2)
    #expect(plan.candidates.allSatisfy { !$0.eligible && $0.reason.contains("Conflicting") })
    #expect(plan.comparisons.allSatisfy { $0.unresolvedBaseRanges.contains { $0.first <= 4 && $0.endExclusive > 4 } })
    let output = root.appendingPathComponent("retained")
    _ = try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: output, exportDV: true)
    #expect(try Data(contentsOf: output.appendingPathComponent("merged.dv")) == base.reduce(into: Data(), { $0.append($1) }))
  }
}

@Test func multiPassAgreeingDonorsRemainExplicitChoices() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good,good]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.count == 1 && plan.pending == 1 && plan.candidates.filter(\.eligible).count == 2)
  }
}

@Test func multiPassTrimmedDonorAlignsButInteriorLossDoesNotGuess() async throws {
  let good = (0..<10).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,Array(good.dropFirst(2))]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.candidates.first?.eligible == true && plan.candidates.first?.donorFrame == 2)
  }
  var drop = good; drop.remove(at: 3)
  try await mergeFiles([base,drop]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty)
  }
}

@Test func multiPassRepeatedIdentitiesCrossingAnchorsAndEdgesAreRefused() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  var duplicate = good; duplicate.append(good[4])
  try await mergeFiles([base,duplicate]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty)
  }
  var crossing = good; crossing.swapAt(1,7)
  try await mergeFiles([base,crossing]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(!plan.comparisons[0].monotonicAnchors && plan.reviews.isEmpty)
  }
  base = good; base[0] = damagedVideo(base[0]); base[8] = damagedVideo(base[8])
  try await mergeFiles([base,good]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty)
  }
}

@Test func multiPassNoMeasuredImprovementAndUnsupportedLayoutCannotMerge() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var different = good; different[4][7 * 80 + 13] ^= 1
  try await mergeFiles([good,different]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty && plan.candidates.first?.reason.contains("No measured") == true)
  }
  let smpte = (0..<9).map { mergeFrame($0,smpte:true) }; var bad = smpte; bad[4] = damagedVideo(bad[4])
  try await mergeFiles([bad,smpte]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty)
  }
}

@Test func multiPassReviewRestoresOnlyAgainstFreshEvidence() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, _ in
    let fresh = try await DVMultiPass.compare(inputs), approved = approve(fresh)
    let output = root.appendingPathComponent("review")
    _ = try await DVMultiPass.publish(plan: approved, inputs: inputs, destination: output, exportDV: false)
    let restored = try DVMultiPass.restore(output.appendingPathComponent("review.json"), against: fresh)
    #expect(restored == approved && !FileManager.default.fileExists(atPath: output.appendingPathComponent("merged.dv").path))
    var forged = approved; forged.reviews[0].choice = "4:99:4"
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: forged, inputs: inputs, destination: root.appendingPathComponent("forged"), exportDV: true) }
    forged = approved; forged.reviews[0].note = String(repeating:"x",count:4097)
    #expect(throws: Error.self) { try DVMultiPass.validatedReview(forged, against: fresh) }
  }
}

@Test func multiPassMutationCollisionAndCancellationNeverPublishCompletion() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, files in
    let plan = approve(try await DVMultiPass.compare(inputs))
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: root, exportDV: true) }
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: inputs[0].map.mapDirectory.appendingPathComponent("nested"), exportDV: true) }
    let worker = Task { try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: root.appendingPathComponent("cancel"), exportDV: true) }
    worker.cancel(); await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel/merge.json").path))
    var bytes = try Data(contentsOf: files[1]); bytes[7 * 80 + 20] ^= 1; try bytes.write(to: files[1])
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: root.appendingPathComponent("changed"), exportDV: true) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("changed/merge.json").path))
  }
}

@Test func multiPassIdenticalInputsDoNotInventRecovery() async throws {
  let good = (0..<9).map { mergeFrame($0) }
  try await mergeFiles([good,good]) { inputs, _, _ in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.isEmpty && plan.candidates.isEmpty && plan.comparisons[0].uniqueExactFrames == 9)
    await #expect(throws: Error.self) { try await DVMultiPass.compare([inputs[0]]) }
    await #expect(throws: Error.self) { try await DVMultiPass.compare(Array(repeating: inputs[0], count: 9)) }
  }
}

@Test func multiPassForgedEvidenceAndMixedSystemsAreRejected() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, _ in
    let fresh = try await DVMultiPass.compare(inputs)
    var candidates = fresh.candidates; candidates[0].reason = "Forged qualification"
    let forged = DVMultiPass.Plan(version: fresh.version, inputs: fresh.inputs, comparisons: fresh.comparisons,
      candidates: candidates, reviews: approve(fresh).reviews)
    await #expect(throws: Error.self) { try await DVMultiPass.publish(plan: forged, inputs: inputs, destination: root.appendingPathComponent("forged-proof"), exportDV: true) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("forged-proof").path))
    let review = root.appendingPathComponent("review.json"), link = root.appendingPathComponent("link.json")
    try DVMultiPass.encode(fresh).write(to: review)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: review)
    #expect(throws: Error.self) { try DVMultiPass.restore(link, against: fresh) }
  }
  try await mergeFiles([good,(0..<9).map { mergeFrame($0,pal:true) }]) { inputs, _, _ in
    await #expect(throws: Error.self) { try await DVMultiPass.compare(inputs) }
  }
}

@Test func multiPassPageBoundariesRetainCorrectFrameAndSourceSelection() async throws {
  let good = (0..<265).map { mergeFrame($0) }; var base = good
  for i in [4, 254, 257, 260] { base[i] = damagedVideo(base[i]) }
  try await mergeFiles([base,good]) { inputs, root, files in
    let plan = try await DVMultiPass.compare(inputs)
    #expect(plan.reviews.map(\.baseFrame) == [4,254,257,260])
    let output = root.appendingPathComponent("paged")
    _ = try await DVMultiPass.publish(plan: approve(plan), inputs: inputs, destination: output, exportDV: true)
    let merged = try Data(contentsOf: output.appendingPathComponent("merged.dv")), donor = try Data(contentsOf: files[1])
    #expect(merged == donor)
  }
}

@Test func multiPassCancellationAfterOutputGrowsHasNoCompletionMarker() async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, files in
    let plan = approve(try await DVMultiPass.compare(inputs)), output = root.appendingPathComponent("cancel-writing")
    let worker = Task {
      try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: output, exportDV: true) { stage,_,_ in
        if stage == "Write separate derivative" { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("merge.json").path))
    let partial = try Data(contentsOf: output.appendingPathComponent("merged.dv.partial"))
    #expect(!partial.isEmpty)
    let original = try Data(contentsOf: files[0])
    #expect(original == base.reduce(into: Data(), { $0.append($1) }))
  }
}

@Test(arguments: ["merged.dv.partial", "provenance.ndjson.partial"])
func multiPassIndependentRereadCatchesOutputCorruption(name: String) async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, _ in
    let plan = approve(try await DVMultiPass.compare(inputs)), output = root.appendingPathComponent("corruption")
    do {
      _ = try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: output, exportDV: true) { stage,_,_ in
        if stage == "Write separate derivative" {
          // Inject a disk-output fault, not a source change. The production
          // reread must reject both corrupted DV and a corrupted provenance line.
          let handle = try! FileHandle(forUpdating: output.appendingPathComponent(name))
          let original = try! handle.read(upToCount: 1)!
          try! handle.seek(toOffset: 0)
          try! handle.write(contentsOf: Data([original[0] ^ 0xff])); try! handle.close()
        }
      }
      Issue.record("Corrupted output was published")
    } catch { #expect(error.localizedDescription.contains("reread")) }
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("merge.json").path))
  }
}

@Test(arguments: [false,true]) func multiPassInputMutationDuringOutputNeverCompletes(mapMutation: Bool) async throws {
  let good = (0..<9).map { mergeFrame($0) }; var base = good; base[4] = damagedVideo(base[4])
  try await mergeFiles([base,good]) { inputs, root, files in
    let plan = approve(try await DVMultiPass.compare(inputs)), output = root.appendingPathComponent("input-race")
    let target = mapMutation ? inputs[1].map.mapDirectory.appendingPathComponent(DVTapeEvidenceMapExporter.frameLedgerFileName) : files[1]
    await #expect(throws: Error.self) {
      try await DVMultiPass.publish(plan: plan, inputs: inputs, destination: output, exportDV: true) { stage,_,_ in
        if stage == "Write separate derivative" {
          // Only this isolated test fixture is mutated, after selected bytes
          // were copied. The final input identity barrier must still fail.
          let handle = try! FileHandle(forUpdating: target)
          let original = try! handle.read(upToCount: 1)!
          try! handle.seek(toOffset: 0); try! handle.write(contentsOf: Data([original[0] ^ 0xff])); try! handle.close()
        }
      }
    }
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("merge.json").path))
  }
}

@Test func multiPassMalformedEmptyImportedPlanRejectsWithoutCreatingOutput() async throws {
  let data = Data("{\"version\":\"rewindDV-multipass-1\",\"inputs\":[],\"comparisons\":[],\"candidates\":[],\"reviews\":[]}".utf8)
  let plan = try JSONDecoder().decode(DVMultiPass.Plan.self, from: data)
  try await mergeFiles([[mergeFrame(0)], [mergeFrame(0)]]) { inputs, root, _ in
    for exportDV in [false, true] {
      for supplied in [[], inputs] {
        let output = root.appendingPathComponent(UUID().uuidString)
        await #expect(throws: Error.self) {
          try await DVMultiPass.publish(plan: plan, inputs: supplied, destination: output, exportDV: exportDV)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
      }
    }
  }
}
