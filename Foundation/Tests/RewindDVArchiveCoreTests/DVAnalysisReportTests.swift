import CryptoKit
import Foundation
import Testing
@testable import RewindDVArchiveCore

private let reportFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/DVRescue")
private func withReportFiles(_ body: (URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewindDV-ReportTest-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}
private func reportFrame(pal: Bool) -> Data {
  var data = semanticFrame(pal: pal, audio: [0x50, pal ? 24 : 20, 0, pal ? 0xa0 : 0x80, 0xc0])
  data[7 * 80 + 3] = 0xe8
  data[6 * 80 + 8] = 0x80; data[6 * 80 + 9] = 0 // one active sample, not a full block
  return data
}
private func validateXSD(_ xml: URL) throws {
  let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
  process.arguments = ["--nonet", "--noout", "--schema", reportFixtures.appendingPathComponent("dvrescue.xsd").path, xml.path]
  let pipe = Pipe(); process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
  try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
  #expect(process.terminationStatus == 0, "Pinned DVRescue XSD rejected output: \(String(decoding: output, as: UTF8.self))")
}

@Test(arguments: [false, true]) func portableReportsRoundTripAndValidateOfficialSchema(pal: Bool) async throws {
  try await withReportFiles { root in
    let source = root.appendingPathComponent("private & <source>.dv"), mapURL = root.appendingPathComponent("map"), out = root.appendingPathComponent("reports")
    let data = reportFrame(pal: pal) + reportFrame(pal: pal)
    try data.write(to: source)
    let mapReceipt = try DVTapeEvidenceMapExporter.create(source: source, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let original = try DVVerifiedFrameSource(url: source, snapshot: mapReceipt.sourceSnapshot)
    let result = try await DVAnalysisReportExporter.export(map: map, source: original, destination: out)
    #expect(result.frameCount == 2 && result.cueCount == 2 && result.artifacts.count == 4)
    for file in result.artifacts {
      let content = try Data(contentsOf: out.appendingPathComponent(file.name))
      #expect(UInt64(content.count) == file.bytes)
      #expect(DVAnalysisReportExporter.hex(SHA256.hash(data: content)) == file.sha256)
      #expect(!String(decoding: content, as: UTF8.self).contains(source.path))
    }
    struct JSONReport: Decodable { let schemaVersion: Int; let frames: [DVAnalysisReportExporter.Frame] }
    let json = try JSONDecoder().decode(JSONReport.self, from: Data(contentsOf: out.appendingPathComponent("analysis.json")))
    #expect(json.frames.count == 2 && json.frames[0].videoStatusBlocks.count == 1)
    #expect(json.frames[0].audioErrorSamples.count == 1)
    #expect(json.frames[0].audioErrorSamples[0].byteOffsets == [488, 489])
    #expect(json.frames[1].presentationNumerator == (pal ? 1 : 1001))
    let csv = try String(contentsOf: out.appendingPathComponent("frames.csv"), encoding: .utf8)
    #expect(csv.components(separatedBy: "\r\n").count == 4)
    #expect(csv.contains("active_audio_error_samples"))
    let vtt = try String(contentsOf: out.appendingPathComponent("review.vtt"), encoding: .utf8)
    #expect(vtt.hasPrefix("WEBVTT\n\nNOTE Source SHA-256:"))
    #expect(vtt.contains(pal ? "00:00:00.000 --> 00:00:00.040" : "00:00:00.000 --> 00:00:00.033"))
    #expect(vtt.contains(pal ? "00:00:00.040 --> 00:00:00.080" : "00:00:00.033 --> 00:00:00.067"))
    let xml = out.appendingPathComponent("dvrescue.xml")
    try validateXSD(xml)
    let xmlText = try String(contentsOf: xml, encoding: .utf8)
    #expect(xmlText.contains("<program>rewindDV</program>"))
    #expect(!xmlText.contains("<aud")) // sample count must never masquerade as a block count
    let external = try DVExternalReportReader.read(xml, expectedSource: mapReceipt.sourceSnapshot)
    #expect(external.listedFrameCount == 2 && external.declaredFrameCount == 2)
    #expect(external.videoSTAObservations == 2 && external.audioBlockObservations == nil)
    #expect(external.claimedSourceBinding.hasPrefix("external_report_claims_matching"))
    #expect(try Data(contentsOf: source) == data)
    await #expect(throws: Error.self) { try await DVAnalysisReportExporter.export(map: map, source: original, destination: out) }
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("report.json").path))
  }
}

@Test func reportTimestampsAreRationalAcrossHourAndDropFrameLabels() throws {
  #expect(try DVAnalysisReportExporter.timestamp(frame: 107_892, pal: false, precision: 6) == "00:59:59.996400")
  #expect(try DVAnalysisReportExporter.timestamp(frame: 107_892, pal: false, precision: 3) == "00:59:59.996")
  #expect(try DVAnalysisReportExporter.timestamp(frame: 90_000, pal: true, precision: 3) == "01:00:00.000")
  #expect(try DVAnalysisReportExporter.timestamp(frame: 30_000, pal: false, precision: 6) == "00:16:41.000000")
  #expect(throws: Error.self) { try DVAnalysisReportExporter.timestamp(frame: UInt64.max, pal: false, precision: 3) }
}

@Test func reportEscapingPreservesStringsWithoutSpreadsheetFormulaExecution() {
  #expect(DVAnalysisReportExporter.csvRow(["a,b", "a\"b", "a\r\nb", " =CMD()", "+1", "@x"]) == "\"a,b\",\"a\"\"b\",\"a\r\nb\",\"' =CMD()\",\"'+1\",\"'@x\"\r\n")
  #expect(DVAnalysisReportExporter.xmlEscape("<&\"'>") == "&lt;&amp;&quot;&apos;&gt;")
}

private func externalXML(_ body: String, media: String = "", creator: String = "dvrescue") -> Data {
  Data("<dvrescue xmlns=\"https://mediaarea.net/dvrescue\" version=\"1.2.1\"><creator><program>\(creator)</program><version>test</version></creator><media \(media)>\(body)</media></dvrescue>".utf8)
}

@Test func externalXMLRejectsEntitiesTruncationOverflowAndDuplicateFrames() throws {
  let bad: [Data] = [
    Data("<!DOCTYPE x [<!ENTITY steal SYSTEM 'file:///etc/passwd'>]><x>&steal;</x>".utf8),
    Data("<!DOCTYPE x [<!ENTITY a 'lol'>]><x>&a;</x>".utf8),
    Data("<dvrescue xmlns='https://wrong.example'/>".utf8),
    Data("<dvrescue".utf8),
    externalXML("<frames count='18446744073709551615'/>"),
    externalXML("<frames count='2'><frame n='0'/><frame n='0'/></frames>"),
    externalXML("<frames count='0'><frame n='0'/></frames>"),
    externalXML("<frames count='1'><frame n='-1'/></frames>"),
    externalXML("<frames><frame n='0' pos='18446744073709551615'/></frames>"),
    externalXML("<frames><frame n='0'><sta t='16' n='1'/></frame></frames>"),
    externalXML("<frames><frame n='0'><sta t='1' n='1' n_even='2'/></frame></frames>"),
    externalXML("<frames><frame n='0'><aud n='109'/></frame></frames>"),
    externalXML("<frames><frame n='0'><dseq n='12'/></frame></frames>"),
    externalXML("<frames/>", creator: String(repeating: "a", count: 4097)),
    externalXML("<frames/>", media: "unknown='\(String(repeating: "a", count: 16385))'"),
    Data([0xff, 0xfe, 0, 60, 0, 120])
  ]
  for data in bad { #expect(throws: Error.self) { try DVExternalReportReader.parse(data) } }
}

@Test func externalXMLPreservesUnknownAttributesAndDoesNotTrustFilenames() throws {
  let result = try DVExternalReportReader.parse(externalXML("<frames count='1'><frame n='0' pos='0' future='&lt;&amp;&quot;'/></frames>", media: "ref='/private/same.dv' size='120000'"))
  #expect(result.preview.last?.attributes["future"] == "<&\"")
  #expect(result.claimedSourceBinding.hasPrefix("unbound_external_claims"))
  #expect(result.authority.contains("no motion"))
}

@Test func syntheticDVRescueFixtureParsesWithoutInventingSourceIdentity() throws {
  // Replaces the identifying upstream report with newly authored structural data.
  let xml = reportFixtures.appendingPathComponent("synthetic-many-attributes.xml")
  try validateXSD(xml)
  let result = try DVExternalReportReader.read(xml)
  #expect(result.creator == "rewindDV synthetic fixture")
  #expect(result.creatorVersion == "1")
  #expect(result.listedFrameCount == 4)
  #expect(result.declaredFrameCount == 7) // sparse listed frames across groups
  #expect(result.videoSTAObservations == 19)
  #expect(result.audioBlockObservations == 12)
  #expect(result.claimedSourceBinding.hasPrefix("unbound"))
  #expect(result.media["ref"] == "synthetic.dv")
  #expect(!result.previewTruncated)
  let frames = result.preview.filter { $0.path == "dvrescue/media/frames/frame" }
  #expect(frames.count == 4)
  let first = try #require(frames.first)
  #expect(first.attributes["no_pack_aud"] == "true")
  #expect(first.attributes["full_conceal_vid"] == "true")
  #expect(first.attributes["rdt_nc"] == "3")
  #expect(first.attributes["tc_nc"] == "2")
  #expect(first.attributes["tc_r"] == "true")
  #expect(first.attributes["arb_nc"] == "true")
  #expect(first.attributes["arb_r"] == "true")
  #expect(result.preview.contains { $0.path == "dvrescue/media/frames/frame/dseq/sta" && $0.attributes["n_even"] == "2" })
  // Frame aggregates dominate supplied DIF detail; detail-only frames still count.
  #expect(result.preview.contains { $0.path == "dvrescue/media/frames/frame/sta" && $0.attributes["n"] == "10" })
}

@Test func externalReportPreservationAndHashMismatchAreFailClosed() async throws {
  try await withReportFiles { root in
    let source = root.appendingPathComponent("source.dv"), xml = root.appendingPathComponent("external.xml")
    try reportFrame(pal: false).write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    try externalXML("<frames count='1'><frame n='0'/></frames>", media: "ref='urn:sha256:wrong' size='120000'").write(to: xml)
    #expect(throws: Error.self) { try DVExternalReportReader.read(xml, expectedSource: snapshot) }
    let data = externalXML("<frames count='1'><frame n='0' future='retained'/></frames>")
    try data.write(to: xml)
    let out = root.appendingPathComponent("external")
    let result = try DVExternalReportReader.preserve(xml, destination: out, expectedSource: snapshot)
    #expect(try Data(contentsOf: out.appendingPathComponent("external.xml")) == data)
    #expect(result.reportSHA256 == DVAnalysisReportExporter.hex(SHA256.hash(data: data)))
    #expect(throws: Error.self) { try DVExternalReportReader.preserve(xml, destination: out) }
    let link = root.appendingPathComponent("linked.xml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: xml)
    #expect(throws: Error.self) { try DVExternalReportReader.read(link) }
  }
}

@Test func reportSourceMutationCannotPublishCompletion() async throws {
  try await withReportFiles { root in
    let source = root.appendingPathComponent("source.dv"), mapURL = root.appendingPathComponent("map"), out = root.appendingPathComponent("reports")
    try reportFrame(pal: false).write(to: source)
    let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let original = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    await #expect(throws: Error.self) {
      try await DVAnalysisReportExporter.export(map: map, source: original, destination: out) { _, _ in
        if let handle = try? FileHandle(forWritingTo: source) {
          try? handle.seek(toOffset: 1000); try? handle.write(contentsOf: Data([0])); try? handle.close()
        }
      }
    }
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("report.json").path))
  }
}

@Test func reportCancellationNeverPublishesAndExternalPreviewIsBounded() async throws {
  let data = externalXML("<frames count='300'>" + (0..<300).map { "<frame n='\($0)'/>" }.joined() + "</frames>")
  let result = try DVExternalReportReader.parse(data)
  #expect(result.preview.count == 256 && result.previewTruncated && result.listedFrameCount == 300)
  let task = Task { () throws -> DVExternalReportReader.Result in
    withUnsafeCurrentTask { $0?.cancel() }; return try DVExternalReportReader.parse(data)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func reportMidExportCancellationAndMismatchedSourceRefuseCompletion() async throws {
  try await withReportFiles { root in
    let source = root.appendingPathComponent("source.dv"), mapURL = root.appendingPathComponent("map")
    let out = root.appendingPathComponent("cancelled")
    try reportFrame(pal: false).write(to: source)
    let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let original = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    let task = Task {
      try await DVAnalysisReportExporter.export(map: map, source: original, destination: out) { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("report.json").path))
    let wrong = root.appendingPathComponent("different.dv")
    try reportFrame(pal: true).write(to: wrong)
    let mismatch = try DVVerifiedFrameSource(url: wrong, snapshot: DVReviewedRangeExporter.inspect(source: wrong))
    await #expect(throws: Error.self) { try await DVAnalysisReportExporter.export(map: map, source: mismatch, destination: root.appendingPathComponent("wrong")) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wrong").path))
  }
}

@Test func externalXMLDistinguishesMissingCountersAndReconcilesDIFDetail() throws {
  let empty = try DVExternalReportReader.parse(externalXML("<frames count='1'><frame n='0'/></frames>"))
  #expect(empty.videoSTAObservations == nil && empty.audioBlockObservations == nil)
  #expect(try DVExternalReportReader.parse(externalXML("<frames><frame n='0'/></frames>")).declaredFrameCount == nil)
  let detail = try DVExternalReportReader.parse(externalXML("<frames count='1'><frame n='0'><dseq n='0'><sta t='14' n='2'/><aud n='1'/></dseq></frame></frames>"))
  #expect(detail.videoSTAObservations == 2 && detail.audioBlockObservations == 1)
  #expect(throws: Error.self) {
    try DVExternalReportReader.parse(externalXML("<frames count='1'><frame n='0'><dseq n='0'><sta t='14' n='2'/></dseq><sta t='14' n='1'/></frame></frames>"))
  }
}

@Test(arguments: ["report", "scene-review", "scene-dv"], [false, true])
func derivativeOutputsRefuseEvidenceMapDestinationsBeforeWriting(kind: String, viaAlias: Bool) async throws {
  try await withReportFiles { root in
    let sourceURL = root.appendingPathComponent("source.dv")
    let bytes = reportFrame(pal: false)
    try bytes.write(to: sourceURL)
    let mapURL = root.appendingPathComponent("map")
    let receipt = try DVTapeEvidenceMapExporter.create(source: sourceURL, destination: mapURL)
    let alias = root.appendingPathComponent("map-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mapURL)
    let map = try DVTapeEvidenceLedgerReader(mapDirectory: mapURL)
    let source = try DVVerifiedFrameSource(url: sourceURL, snapshot: receipt.sourceSnapshot)
    let destination = (viaAlias ? alias : mapURL).appendingPathComponent("derived")
    let namesBefore = try FileManager.default.contentsOfDirectory(atPath: mapURL.path).sorted()
    await #expect(throws: DVIngestError.self) {
      if kind == "report" {
        _ = try await DVAnalysisReportExporter.export(map: map, source: source, destination: destination)
      } else {
        let plan = try await DVSceneSegmentation.analyze(map: map, source: source)
        _ = try await DVSceneSegmentation.publish(plan: plan, map: map, source: source,
          destination: destination, exportDV: kind == "scene-dv")
      }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: mapURL.path).sorted() == namesBefore)
    #expect(try await map.page(0).records.count == 1)
    #expect(try Data(contentsOf: sourceURL) == bytes)
  }
}
