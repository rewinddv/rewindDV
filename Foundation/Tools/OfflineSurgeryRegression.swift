// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline local-file regression. No driver or transport command code is linked.
import Foundation
import CryptoKit
import AppKit

@main struct OfflineSurgeryRegression {
  struct Failure: LocalizedError { let errorDescription: String? }
  @MainActor static func main() async throws {
    guard (3...4).contains(CommandLine.arguments.count) else { fatalError("Provide a local DV source and a new output directory") }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let destination = URL(fileURLWithPath: CommandLine.arguments[2])
    let clip = try DVSurgeryClip.read(source)
    print("frames=\(clip.timeline.frameCount) segments=\(clip.segments.count) sourceSHA256=\(clip.sha256)")
    if CommandLine.arguments.last == "--merge" {
      guard clip.segments.count >= 5, clip.segments[2].format == clip.segments[4].format else {
        throw Failure(errorDescription: "Merge fixture needs compatible segments 3 and 5")
      }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
      let model = SurgeryModel(); model.open(source)
      while model.busy { try await Task.sleep(for: .milliseconds(20)) }
      guard model.clip != nil else { throw Failure(errorDescription: model.error ?? "Scan failed") }
      model.toggleSegment(clip.segments[4].id); model.toggleSegment(clip.segments[2].id)
      let ranges = model.mergeRanges
      guard ranges.map(\.firstFrame) == [clip.segments[2].first, clip.segments[4].first], model.mergeIssue == nil else {
        throw Failure(errorDescription: "Selection order or compatibility failed")
      }
      model.select(first: 0, end: 1)
      guard model.mergeRanges == ranges else { throw Failure(errorDescription: "Range navigation changed checked segments") }
      model.export(to: destination, merged: true)
      while model.busy { try await Task.sleep(for: .milliseconds(20)) }
      guard let output = model.exportedURL else { throw Failure(errorDescription: model.error ?? "Merge failed") }
      let saved = try Data(contentsOf: output.appendingPathComponent("merged.dv"))
      let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
      var expected = Data()
      for r in ranges {
        try input.seek(toOffset: r.byteOffset)
        expected.append(try input.read(upToCount: Int(r.byteCount))!)
      }
      guard saved == expected else { throw Failure(errorDescription: "Merged bytes differ") }
      let merged = try DVSurgeryClip.read(output.appendingPathComponent("merged.dv"))
      guard merged.timeline.frameCount == ranges.reduce(0, { $0 + $1.endFrameExclusive - $1.firstFrame }) else { throw Failure(errorDescription: "Merged frame count mismatch") }
      let decoder = SurgeryThumbnailDecoder()
      let join = ranges[0].endFrameExclusive - ranges[0].firstFrame
      for frame in [0, join - 1, join, merged.timeline.frameCount - 1] {
        _ = try await decoder.image(url: output.appendingPathComponent("merged.dv"), clip: merged, frame: frame)
      }
      model.selectAllSegments(true)
      if Set(clip.segments.map(\.format)).count > 1, model.mergeIssue == nil { throw Failure(errorDescription: "Mixed formats allowed") }
      model.selectAllSegments(false)
      guard model.mergeRanges.isEmpty, model.mergeIssue != nil else { throw Failure(errorDescription: "Clear selection failed") }
      model.toggleSegment(clip.segments[2].id); model.open(source)
      while model.busy { try await Task.sleep(for: .milliseconds(20)) }
      guard model.selectedSegments.isEmpty else { throw Failure(errorDescription: "Reopen retained stale selection") }
      print("PASS disjoint model selection, range independence, merged original bytes, \(merged.timeline.frameCount) frames, join previews, mixed-format guard, clear and source reset; output=\(output.path)")
      return
    }
    let decoder = SurgeryThumbnailDecoder()
    for (i, segment) in clip.segments.enumerated() {
      let image = try await decoder.image(url: source, clip: clip, frame: segment.first)
      guard image.width == 320, image.height == 240 || image.height == 180 else { throw Failure(errorDescription: "Invalid thumbnail size") }
      print("segment=\(i+1) frames=\(segment.first)..<\(segment.end) format=\(segment.format) reason=\(segment.reason) thumbnail=\(image.width)x\(image.height)")
    }
    // Exercise the same UI model used for rapid in/out changes and source reopen.
    let model = SurgeryModel(); model.open(source)
    while model.busy { try await Task.sleep(for: .milliseconds(20)) }
    guard model.clip?.sha256 == clip.sha256 else { throw Failure(errorDescription: model.error ?? "Model scan mismatch") }
    for i in 0..<140 {
      let first = i % clip.timeline.frameCount
      model.select(first: first, end: min(first + 10, clip.timeline.frameCount))
      guard await model.thumbnail(first) != nil else { throw Failure(errorDescription: "Missing preview after range change") }
    }
    model.select(first: 0, end: clip.timeline.frameCount)
    model.startText = "not a time"
    guard !model.applyTimes(), model.hasUnappliedTimes else { throw Failure(errorDescription: "Invalid time accepted") }
    model.startText = "0"; model.endText = model.time(clip.timeline.durationSeconds)
    guard model.applyTimes() else { throw Failure(errorDescription: "Full range rejected") }
    // Full partition, then independently reread every published file.
    let ranges = try clip.ranges(first: 0, end: clip.timeline.frameCount, splitScenes: true)
    let receipt = try DVSurgeryByteExporter.export(source: source, expectedSHA256: clip.sha256, ranges: ranges, destination: destination)
    var combined = SHA256()
    for output in receipt.outputs {
      let input = try FileHandle(forReadingFrom: destination.appendingPathComponent(output.file))
      while let chunk = try input.read(upToCount: 1048576), !chunk.isEmpty { combined.update(data: chunk) }
      try input.close()
    }
    guard combined.finalize().map({ String(format: "%02x", $0) }).joined() == clip.sha256 else { throw Failure(errorDescription: "Partition differs from original") }
    print("PASS all thumbnails, 140 repeated range changes, time validation, lossless full partition and independent combined hash")
  }
}
