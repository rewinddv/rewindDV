// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline app-model regression. No driver, IOKit, tape, or audible playback.
import Foundation
import CryptoKit

@main struct ReviewedRangeModelRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw Failure("Provide the 230-frame local capture") }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let before = try Data(contentsOf: source)
    guard before.count == 230 * 120_000 else { throw Failure("Expected exact local regression fixture") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-Range-Model-Regression-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let model = ReviewedRangeModel()
    func require(_ condition: Bool, _ description: String) throws {
      guard condition else { throw Failure(description) }
      print("PASS \(description)")
    }
    func wait() async throws {
      let deadline = Date().addingTimeInterval(60)
      while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      try require(!model.isBusy, "operation completed within deadline")
    }
    model.prepare(source); try await wait()
    try require(model.snapshot?.frameCount == 230 && !model.canExport, "actual source scanned; approval required")
    model.firstFrameText = "6"; model.lastFrameText = "230"
    try require(model.range?.first == 5 && model.range?.end == 230, "inclusive GUI endpoints map to [5,230)")
    model.confirmed = true
    try require(model.canExport, "explicit range approval enables export")
    model.lastFrameText = "229"
    try require(!model.confirmed && !model.canExport, "changing endpoint revokes approval")
    for invalid in ["0", "231", "-1", "1.5", "18446744073709551616"] {
      model.firstFrameText = invalid
      try require(model.range == nil && !model.canExport, "invalid first frame rejected: \(invalid)")
    }
    model.firstFrameText = "6"; model.lastFrameText = "230"; model.confirmed = true
    model.export(toParent: root); try await wait()
    guard let output = model.exportedDirectory else { throw Failure(model.message) }
    let actual = try Data(contentsOf: output.appendingPathComponent(DVReviewedRangeExporter.outputFileName))
    try require(actual == before.subdata(in: (5 * 120_000)..<before.count), "225 output frames exactly equal selected source bytes")
    let receipt = try JSONDecoder().decode(DVReviewedRangeExporter.Receipt.self,
      from: Data(contentsOf: output.appendingPathComponent(DVReviewedRangeExporter.completionMarkerName)))
    try require(receipt.omittedLeadingFrameCount == 5 && receipt.omittedTrailingFrameCount == 0,
      "provenance retains all omissions")
    try require(!model.confirmed && !model.canExport, "completed export requires renewed approval before another export")
    model.prepare(source); model.reset()
    try await Task.sleep(for: .milliseconds(100))
    try require(model.snapshot == nil && model.source == nil && !model.isBusy, "source reset fences cancelled scan")
    model.prepare(source); model.cancel(); try await wait()
    try require(model.snapshot == nil, "cancelled scan does not publish a snapshot")
    let copy = root.appendingPathComponent("changed-source.dv")
    try before.write(to: copy, options: .withoutOverwriting)
    model.prepare(copy); try await wait()
    model.confirmed = true
    var changed = before; changed[119_999] ^= 1
    try changed.write(to: copy)
    model.export(toParent: root); try await wait()
    try require(model.failed && model.exportedDirectory == nil, "source mutation refuses successful export")
    try require(try Data(contentsOf: source) == before, "original source remains byte-identical")
    print("REVIEWED_RANGE_MODEL_PASS; generated test derivatives only; not operator or hardware qualification; artifacts=\(root.path)")
  }
  struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
