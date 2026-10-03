import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RewindDVArchiveCore

private func reviewedFrame(pal: Bool, marker: UInt8 = 0) -> Data {
  let sequenceCount = pal ? 12 : 10
  var frame = Data()
  frame.reserveCapacity(sequenceCount * 12_000)
  for sequence in 0..<sequenceCount {
    func append(section: Int, block: Int) {
      var bytes = Data(repeating: 0xff, count: 80)
      bytes[0] = UInt8(section << 5)
      bytes[1] = UInt8(sequence << 4)
      bytes[2] = UInt8(block)
      if section == 0 {
        bytes[3] = pal ? 0x80 : 0
        for index in 4...7 { bytes[index] = 0 }
      } else if section == 2 {
        bytes.replaceSubrange(3..<8, with: [0x60, 0xff, marker, 0, 0xff])
      } else if section == 3 {
        bytes.replaceSubrange(3..<8, with: [0x50, 0, 0, 0, 0])
      } else if section == 4 {
        bytes[3] = 0
        bytes[79] = marker
      }
      frame.append(bytes)
    }
    append(section: 0, block: 0)
    for block in 0..<2 { append(section: 1, block: block) }
    for block in 0..<3 { append(section: 2, block: block) }
    for group in 0..<9 {
      append(section: 3, block: group)
      for block in group * 15..<(group + 1) * 15 {
        append(section: 4, block: block)
      }
    }
  }
  return frame
}

private func withReviewedTemporaryDirectory(
  _ body: (URL) throws -> Void
) throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("RewindDVReviewedRangeTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func reviewedSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test(arguments: [false, true])
func reviewedRangeInspectionValidatesUniformNativeDV(pal: Bool) throws {
  try withReviewedTemporaryDirectory { root in
    let frames = [
      reviewedFrame(pal: pal, marker: 1),
      reviewedFrame(pal: pal, marker: 2),
      reviewedFrame(pal: pal, marker: 3),
    ]
    let source = root.appendingPathComponent("source.dv")
    let bytes = frames.reduce(into: Data()) { $0.append($1) }
    try bytes.write(to: source)

    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.sourceSHA256 == reviewedSHA256(bytes))
    #expect(snapshot.frameCount == 3)
    #expect(snapshot.frameByteCount == (pal ? 144_000 : 120_000))
    #expect(snapshot.sourceByteCount == UInt64(bytes.count))
    #expect(snapshot.videoSystem == (pal ? .pal625_50 : .ntsc525_60))
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(DVReviewedRangeExporter.Snapshot.self, from: encoded) == snapshot)
  }
}

@Test func reviewedRangeExportsExactOneFrameWithExplicitProvenance() throws {
  try withReviewedTemporaryDirectory { root in
    let frames = [
      reviewedFrame(pal: false, marker: 1),
      reviewedFrame(pal: false, marker: 2),
      reviewedFrame(pal: false, marker: 3),
    ]
    let sourceBytes = frames.reduce(into: Data()) { $0.append($1) }
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    let destination = root.appendingPathComponent("range", isDirectory: true)

    let receipt = try DVReviewedRangeExporter.export(
      source: source, snapshot: snapshot, first: 1, endExclusive: 2,
      destination: destination)
    let outputURL = destination.appendingPathComponent(DVReviewedRangeExporter.outputFileName)
    let output = try Data(contentsOf: outputURL)
    #expect(output == frames[1])
    #expect(receipt.outputSHA256 == reviewedSHA256(frames[1]))
    #expect(receipt.sourceSHA256 == reviewedSHA256(sourceBytes))
    #expect(receipt.firstSourceFrameOrdinal == 1)
    #expect(receipt.endSourceFrameOrdinalExclusive == 2)
    #expect(receipt.exportedFrameCount == 1)
    #expect(receipt.sourceByteOffset == 120_000)
    #expect(receipt.sourceByteEndExclusive == 240_000)
    #expect(receipt.omittedLeadingFrameCount == 1)
    #expect(receipt.omittedTrailingFrameCount == 1)
    #expect(receipt.derivativeClassification.contains("not_unmodified_master"))
    #expect(receipt.captureQuality.contains("unknown"))
    #expect(receipt.acquisitionLoss.contains("unknown"))
    #expect(receipt.bytesReencoded == false)
    #expect(receipt.audioResampled == false)
    #expect(receipt.timecodeRewritten == false)

    let marker = try Data(contentsOf:
      destination.appendingPathComponent(DVReviewedRangeExporter.completionMarkerName))
    #expect(marker.last == 10)
    #expect(try JSONDecoder().decode(
      DVReviewedRangeExporter.Receipt.self, from: marker.dropLast()) == receipt)
    #expect(FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(DVReviewedRangeExporter.intentFileName).path))
    #expect(!FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(DVReviewedRangeExporter.outputFileName + ".partial").path))
  }
}

@Test func reviewedRangeSupportsFullAndLastFrameEdges() throws {
  try withReviewedTemporaryDirectory { root in
    let frames = [
      reviewedFrame(pal: true, marker: 7),
      reviewedFrame(pal: true, marker: 8),
    ]
    let sourceBytes = frames.reduce(into: Data()) { $0.append($1) }
    let source = root.appendingPathComponent("source.dv")
    try sourceBytes.write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)

    let full = root.appendingPathComponent("full", isDirectory: true)
    let fullReceipt = try DVReviewedRangeExporter.export(
      source: source, snapshot: snapshot, first: 0, endExclusive: 2, destination: full)
    #expect(try Data(contentsOf:
      full.appendingPathComponent(DVReviewedRangeExporter.outputFileName)) == sourceBytes)
    #expect(fullReceipt.omittedLeadingFrameCount == 0)
    #expect(fullReceipt.omittedTrailingFrameCount == 0)

    let last = root.appendingPathComponent("last", isDirectory: true)
    let lastReceipt = try DVReviewedRangeExporter.export(
      source: source, snapshot: snapshot, first: 1, endExclusive: 2, destination: last)
    #expect(try Data(contentsOf:
      last.appendingPathComponent(DVReviewedRangeExporter.outputFileName)) == frames[1])
    #expect(lastReceipt.exportedFrameCount == 1)
  }
}

@Test func reviewedRangeRejectsEmptyAndOutOfBoundsRangesBeforeCreatingDestination() throws {
  try withReviewedTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try reviewedFrame(pal: false).write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    let invalidRanges: [(UInt64, UInt64)] = [(0, 0), (1, 1), (0, 2), (2, 3)]
    for (index, range) in invalidRanges.enumerated() {
      let destination = root.appendingPathComponent("invalid-\(index)", isDirectory: true)
      #expect(throws: (any Error).self) {
        try DVReviewedRangeExporter.export(
          source: source, snapshot: snapshot, first: range.0,
          endExclusive: range.1, destination: destination)
      }
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
  }
}

@Test func reviewedRangeRefusesChangedSourceAndLeavesNoCompletionMarker() throws {
  try withReviewedTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try reviewedFrame(pal: false, marker: 1).write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    try reviewedFrame(pal: false, marker: 2).write(to: source)
    let destination = root.appendingPathComponent("changed", isDirectory: true)

    #expect(throws: (any Error).self) {
      try DVReviewedRangeExporter.export(
        source: source, snapshot: snapshot, first: 0, endExclusive: 1,
        destination: destination)
    }
    #expect(FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(DVReviewedRangeExporter.intentFileName).path))
    #expect(FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(DVReviewedRangeExporter.outputFileName + ".partial").path))
    #expect(!FileManager.default.fileExists(atPath:
      destination.appendingPathComponent(DVReviewedRangeExporter.completionMarkerName).path))
  }
}

@Test func reviewedRangeNeverOverwritesExistingDestination() throws {
  try withReviewedTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try reviewedFrame(pal: false).write(to: source)
    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    let destination = root.appendingPathComponent("existing", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)

    #expect(throws: DVIngestError.self) {
      try DVReviewedRangeExporter.export(
        source: source, snapshot: snapshot, first: 0, endExclusive: 1,
        destination: destination)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["sentinel"])
  }
}

@Test func reviewedRangeRejectsMalformedIncompleteAndMixedSystemSources() throws {
  try withReviewedTemporaryDirectory { root in
    let valid = reviewedFrame(pal: false)
    var conflicting = valid
    conflicting.append(valid)
    conflicting[valid.count + 3] = 0x80
    var duplicate = valid
    duplicate.replaceSubrange(160..<240, with: valid[80..<160])
    var outOfOrder = valid
    let firstSubcode = Data(valid[80..<160])
    let secondSubcode = Data(valid[160..<240])
    outOfOrder.replaceSubrange(80..<160, with: secondSubcode)
    outOfOrder.replaceSubrange(160..<240, with: firstSubcode)
    let malformed = [Data(), Data(valid.dropLast()), duplicate, outOfOrder, conflicting]
    for (index, bytes) in malformed.enumerated() {
      let source = root.appendingPathComponent("malformed-\(index).dv")
      try bytes.write(to: source)
      #expect(throws: (any Error).self) {
        try DVReviewedRangeExporter.inspect(source: source)
      }
    }
  }
}

@Test func reviewedRangeRejectsFIFOWithoutBlocking() throws {
  try withReviewedTemporaryDirectory { root in
    let fifo = root.appendingPathComponent("source.fifo")
    #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) {
      try DVReviewedRangeExporter.inspect(source: fifo)
    }
  }
}

@Test func reviewedRangeRejectsSymbolicLinkSourcesAndDestinations() throws {
  try withReviewedTemporaryDirectory { root in
    let source = root.appendingPathComponent("source.dv")
    try reviewedFrame(pal: false).write(to: source)
    let sourceLink = root.appendingPathComponent("source-link.dv")
    try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
    #expect(throws: (any Error).self) {
      try DVReviewedRangeExporter.inspect(source: sourceLink)
    }

    let snapshot = try DVReviewedRangeExporter.inspect(source: source)
    let realDestination = root.appendingPathComponent("real-destination", isDirectory: true)
    try FileManager.default.createDirectory(at: realDestination, withIntermediateDirectories: false)
    let destinationLink = root.appendingPathComponent("destination-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: destinationLink, withDestinationURL: realDestination)
    #expect(throws: (any Error).self) {
      try DVReviewedRangeExporter.export(
        source: source, snapshot: snapshot, first: 0, endExclusive: 1,
        destination: destinationLink)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: realDestination.path).isEmpty)
  }
}
