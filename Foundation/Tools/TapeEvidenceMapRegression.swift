// Real-file offline regression. Never opens a driver or changes a source capture.
import Foundation
import CryptoKit

@main struct TapeEvidenceMapRegression {
  @MainActor static func main() async throws {
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let before = try Data(contentsOf: source)
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-TapeMap-Regression-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let model = TapeEvidenceMapModel()
    model.create(source: source, parent: parent)
    let deadline = Date().addingTimeInterval(60)
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard !model.busy, let result = model.receipt, let directory = model.directory else { throw Failure(model.message) }
    let ledger = try Data(contentsOf: directory.appendingPathComponent(DVTapeEvidenceMapExporter.frameLedgerFileName))
    guard SHA256.hash(data: ledger).map({ String(format: "%02x", $0) }).joined() == result.frameLedgerSHA256,
      ledger.split(separator:10).count == 230, result.frameLedgerRecordCount == 230,
      result.sourceSnapshot.sourceSHA256 == "c659cf7e597dcad085919d259272c00ae789ea7ec1b07df42376a1cfc48cb685",
      try Data(contentsOf: source) == before else { throw Failure("Map or original-source identity mismatch") }
    print("TAPE_MAP_MODEL_PASS 230 frames; source and ledger independently verified; source unchanged")
    let bound = try DVTapeEvidenceMapExporter.create(source: source,
      archiveVerification: source.deletingLastPathComponent().appendingPathComponent("verification.json"),
      destination: parent.appendingPathComponent("report-bound-map"))
    guard bound.archiveReportProvenance?.CIPDiscontinuities == 1,
      bound.acquisitionReport == .verificationReportObservesKnownDefects else { throw Failure("Report defects were lost") }
    print("TAPE_MAP_REPORT_BINDING_PASS one CIP discontinuity remains report evidence, not exact loss")
    model.create(source:source,parent:parent); model.cancel()
    while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard !model.busy, model.receipt == nil else { throw Failure("Cancelled map published success") }
    print("TAPE_MAP_CANCELLATION_PASS; artifacts=\(parent.path)")
  }
  struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
