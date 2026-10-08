// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

// Independently assembled physical DIF identities; no product decoder generates
// expected sizes, boundaries or timing. No private media or normative prose.
private func epochFrame(_ pal: Bool, marker: UInt8) -> Data {
  var result = Data(repeating: 0xff, count: pal ? 144_000 : 120_000)
  for sequence in 0..<(pal ? 12 : 10) {
    let sections = [(0, 0)] + (0..<2).map { (1, $0) } + (0..<3).map { (2, $0) }
      + (0..<9).flatMap { group in [(3, group)] + (0..<15).map { (4, group * 15 + $0) } }
    for (local, identity) in sections.enumerated() {
      let offset = sequence * 12_000 + local * 80
      result[offset] = UInt8(identity.0 << 5); result[offset + 1] = UInt8(sequence << 4)
      result[offset + 2] = UInt8(identity.1)
      if local == 0 { result[offset + 3] = pal ? 0x80 : 0; for i in 4...7 { result[offset + i] = 0 } }
      if identity.0 == 4 { result[offset + 3] = 0; result[offset + 79] = marker }
    }
  }
  return result
}
private func epochHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func epochRoot() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-\(UUID())")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
}

@Test(arguments: [[false], [true], [false, true, false], [true, false, true], [false, false, true], [true, false, false]])
func epochInventoryAndSegmentReconstruction(systems: [Bool]) throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("master.dv")
  let frames = systems.enumerated().map { epochFrame($0.element, marker: UInt8($0.offset)) }
  let bytes = frames.reduce(into: Data()) { $0.append($1) }; try bytes.write(to: source)
  let snapshot = try DVReviewedRangeExporter.inspect(source: source)
  var offset: UInt64 = 0, tick: UInt64 = 0
  for i in systems.indices {
    let frame = try snapshot.frame(UInt64(i))
    #expect(frame.ordinal == UInt64(i) && frame.byteOffset == offset)
    #expect(frame.byteCount == (systems[i] ? 144_000 : 120_000))
    #expect(frame.startTick == tick && frame.durationTicks == (systems[i] ? 1200 : 1001))
    offset += systems[i] ? 144_000 : 120_000; tick += systems[i] ? 1200 : 1001
  }
  #expect(try snapshot.presentationTick(atBoundary: UInt64(systems.count)) == tick)
  #expect(try snapshot.byteOffset(atBoundary: UInt64(systems.count)) == UInt64(bytes.count))
  #expect(snapshot.sourceSHA256 == epochHash(bytes))
  #expect(throws: Error.self) { try snapshot.frame(UInt64(systems.count)) }
  for first in systems.indices {
    let destination = root.appendingPathComponent("range-\(first)")
    let receipt = try DVReviewedRangeExporter.export(source: source, snapshot: snapshot,
      first: UInt64(first), endExclusive: UInt64(systems.count), destination: destination)
    let expected = frames.dropFirst(first).reduce(into: Data()) { $0.append($1) }
    var reconstructed = Data()
    if let segments = receipt.segments {
      var ordinal = UInt64(first)
      for segment in segments {
        #expect(segment.firstSourceFrame == ordinal)
        let data = try Data(contentsOf: destination.appendingPathComponent(segment.file))
        #expect(epochHash(data) == segment.sha256 && UInt64(data.count) == segment.bytes)
        #expect(data == bytes.subdata(in: Int(segment.sourceByteOffset)..<Int(segment.sourceByteEndExclusive)))
        ordinal = segment.endSourceFrameExclusive; reconstructed.append(data)
      }
      #expect(ordinal == UInt64(systems.count))
    } else { reconstructed = try Data(contentsOf: destination.appendingPathComponent("reviewed-range.dv")) }
    #expect(reconstructed == expected && receipt.outputSHA256 == epochHash(expected))
    let json = try Data(contentsOf: destination.appendingPathComponent("provenance.json"))
    #expect(try JSONDecoder().decode(DVReviewedRangeExporter.Receipt.self, from: json) == receipt)
  }
  #expect(try Data(contentsOf: source) == bytes)
}

@Test func epochMapReviewReportsAndVerifiedFrames() async throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let frames = [epochFrame(false, marker: 1), epochFrame(true, marker: 2), epochFrame(false, marker: 3)]
  let bytes = frames.reduce(into: Data()) { $0.append($1) }, source = root.appendingPathComponent("master.dv")
  try bytes.write(to: source)
  let directory = root.appendingPathComponent("map")
  let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: directory)
  let reader = try DVTapeEvidenceLedgerReader(mapDirectory: directory)
  let original = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
  let page = try await reader.page(0)
  #expect(page.records.count == 3)
  for i in [2, 0, 1, 2, 1, 0] {
    let record = page.records[i], verified = try await original.frame(record)
    #expect(verified.bytes == frames[i])
    #expect(record.boundaryEvidence.frameSourceByteOffset == [UInt64(0), 120_000, 264_000][i])
    #expect(record.sourceFrameIdentity?.ordinal == UInt64(i))
    #expect(record.issues.contains { $0.code == .recordingSystemTransition } == (i > 0))
    #expect(record.boundaryEvidence.vauxSource.uniqueRawValues.isEmpty) // Never filled from a neighbour.
  }
  let item = try DVRecoveryReviewJournal.makeRangeItem(binding: reader.binding, firstFrameOrdinal: 0,
    endFrameOrdinalExclusive: 3, issueCodes: [.recordingSystemTransition], summary: "cross epoch")
  #expect(item.sourceByteOffset == 0 && item.sourceByteEndExclusive == 384_000)
  let reportURL = root.appendingPathComponent("reports")
  _ = try await DVAnalysisReportExporter.export(map: reader, source: original, destination: reportURL)
  struct Report: Decodable { let frames: [DVAnalysisReportExporter.Frame] }
  let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: reportURL.appendingPathComponent("analysis.json")))
  #expect(report.frames.map(\.presentationNumerator) == [0, 1001, 2201])
  #expect(report.frames.allSatisfy { $0.presentationDenominator == 30_000 })
  let csv = try String(contentsOf: reportURL.appendingPathComponent("frames.csv"), encoding: .utf8)
  #expect(csv.contains("epoch_id") && csv.contains("pal_625_50") && csv.contains("264000"))
  let external = try DVExternalReportReader.read(reportURL.appendingPathComponent("dvrescue.xml"), expectedSource: receipt.sourceSnapshot)
  #expect(external.listedFrameCount == 3)
  var scenes = try await DVSceneSegmentation.analyze(map: reader, source: original)
  for i in scenes.boundaries.indices { scenes.boundaries[i].decision = .rejected }
  #expect(scenes.segments.count == 3) // Format boundaries remain independent of recording/cut decisions.
  let exported = try await DVSceneSegmentation.publish(plan: scenes, map: reader, source: original,
    destination: root.appendingPathComponent("scenes"), exportDV: true)
  #expect(exported.outputs.count == 3 && exported.concatenatedSHA256 == epochHash(bytes))
}

@Test func epochUnknownTailRemainsExplicitAndExcludedOnlyByReviewedRange() async throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let first = epochFrame(false, marker: 3), incomplete = epochFrame(true, marker: 4).prefix(72000)
  let bytes = first + incomplete, source = root.appendingPathComponent("master.dv")
  try bytes.write(to: source)
  #expect(throws: Error.self) { try DVReviewedRangeExporter.inspect(source: source) }
  let snapshot = try DVReviewedRangeExporter.inspect(source: source, preserveUnknownRegions: true)
  #expect(snapshot.frameCount == 1 && !snapshot.isComplete)
  #expect(snapshot.unknownRegions?.first?.byteOffset == 120_000)
  #expect(snapshot.unknownRegions?.first?.byteEndExclusive == 192_000)
  #expect(snapshot.unknownRegions?.first?.frameCount == nil)
  let map = try DVTapeEvidenceMapExporter.create(source: source, destination: root.appendingPathComponent("map"))
  #expect(map.uncoveredSourceByteCount == 72_000)
  _ = try DVTapeEvidenceLedgerReader(mapDirectory: root.appendingPathComponent("map"))
  let receipt = try DVReviewedRangeExporter.export(source: source, snapshot: snapshot, first: 0, endExclusive: 1,
    destination: root.appendingPathComponent("range"))
  #expect(receipt.sourceSnapshot?.unknownRegions == snapshot.unknownRegions)
  #expect(try Data(contentsOf: root.appendingPathComponent("range/reviewed-range.dv")) == first)
  #expect(try Data(contentsOf: source) == bytes)
}

@Test func epochImportedCoordinatesRejectOverlapOverflowAndWrongCadence() throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("source.dv")
  try (epochFrame(false, marker: 1) + epochFrame(true, marker: 2)).write(to: source)
  let snapshot = try DVReviewedRangeExporter.inspect(source: source)
  let data = try JSONEncoder().encode(snapshot)
  for (key, value) in [("byteOffset", UInt64(1)), ("endFrameExclusive", UInt64.max), ("cadenceNumerator", UInt64(30))] {
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var epochs = try #require(json["epochs"] as? [[String: Any]])
    epochs[1][key] = value; json["epochs"] = epochs
    let changed = try JSONDecoder().decode(DVReviewedRangeExporter.Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: Error.self) { try changed.validate() }
    #expect(throws: Error.self) { try DVVerifiedFrameSource(url: source, snapshot: changed) }
  }
}

@Test func epochFilmstripAndContactSheetUseSamePhysicalSamples() throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("source.dv")
  var bytes = Data()
  for i in 0..<18 { bytes.append(epochFrame((5..<13).contains(i), marker: UInt8(i))) }
  try bytes.write(to: source)
  let snapshot = try DVReviewedRangeExporter.inspect(source: source)
  let plan = try DVArchiveSamplePlan.make(source: snapshot, first: 2, endExclusive: 16, maximumSamples: 8)
  #expect(Set(plan.frames.map(\.ordinal)).isSuperset(of: [2, 4, 5, 12, 13, 15]))
  #expect(plan.frames.count <= 8 && plan.omittedTransitionEndpoints == 0)
  #expect(plan.frames.first(where: { $0.ordinal == 5 })?.byteOffset == 600_000)
  #expect(plan.frames.first(where: { $0.ordinal == 13 })?.byteOffset == 1_752_000)
  #expect(plan.frames.map(\.ordinal) == plan.frames.map(\.ordinal).sorted())
  #expect(try JSONDecoder().decode(DVArchiveSamplePlan.self, from: JSONEncoder().encode(plan)) == plan)
}

@Test func epochEntirelyUnknownSourceRetainsAllBytesWithoutInventingFrames() async throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("unknown.dv"), bytes = Data(repeating: 0x55, count: 1000)
  try bytes.write(to: source)
  let mapURL = root.appendingPathComponent("map")
  let map = try DVTapeEvidenceMapExporter.create(source: source, destination: mapURL)
  #expect(map.sourceSnapshot.frameCount == 0 && map.sourceSnapshot.recordingEpochs.isEmpty)
  #expect(map.uncoveredSourceByteCount == 1000 && map.sourceSnapshot.sourceSHA256 == epochHash(bytes))
  let reader = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
  #expect(reader.binding.pageCount == 0)
  #expect(throws: Error.self) { try map.sourceSnapshot.frame(0) }
  #expect(throws: Error.self) { try DVArchiveSamplePlan.make(source: map.sourceSnapshot, first: 0, endExclusive: 1) }
  #expect(try Data(contentsOf: source) == bytes)
}

@Test func epochImportedInterpretationProvenanceCannotBeOmitted() throws {
  let root = try epochRoot(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("mixed.dv")
  try (epochFrame(false, marker: 0) + epochFrame(true, marker: 1)).write(to: source)
  var snapshot = try DVReviewedRangeExporter.inspect(source: source)
  snapshot.interpretationVersion = nil
  #expect(throws: Error.self) { try snapshot.validate() }
}

@Test func epochEmptyImportedSourceRejectsBeforeConsumers() throws {
  let data = Data("""
  {"schema_version":2,"source_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","source_byte_count":0,"frame_count":0,"epochs":[],"unknown_regions":[],"interpretation_version":4}
  """.utf8)
  let snapshot = try JSONDecoder().decode(DVReviewedRangeExporter.Snapshot.self, from: data)
  #expect(throws: Error.self) { try snapshot.validate() }
}
