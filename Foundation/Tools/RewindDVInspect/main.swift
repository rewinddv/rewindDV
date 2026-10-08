// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline only: this executable has no IOKit, DriverKit, or deck-control code.
import Foundation
import CryptoKit
import RewindDVArchiveCore

struct MetadataSummary: Encodable {
  let sourcePath: String
  let sourceBytes: UInt64
  let sourceSHA256: String
  let completeFrames: UInt64
  let audioEpochs: [DVAudioSampleRateEpoch]
  let unclassifiedExtents: Int
  let derivedAudioTrackPolicy: String
}

do {
  if CommandLine.arguments == [CommandLine.arguments[0], "iec-field-inventory"] {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(IECInventory.make()) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "whole-tape-job" {
    let summary = try WholeTapeJobJournal.readSummary(from: URL(fileURLWithPath: CommandLine.arguments[2]))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(summary) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "export-hdv-closed-flight" {
    let receipt = try HDVIngestExporter.exportClosedFlight(at: URL(fileURLWithPath: CommandLine.arguments[2]))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(receipt) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "forensic-prefix" {
    let receipt = try DVForensicPrefix.export(source: URL(fileURLWithPath: CommandLine.arguments[2]),
      destination: URL(fileURLWithPath: CommandLine.arguments[3]))
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(receipt) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "reports" {
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: URL(fileURLWithPath: CommandLine.arguments[3]))
    let source = try DVVerifiedFrameSource(url: URL(fileURLWithPath: CommandLine.arguments[2]), snapshot: reader.binding.mapReceipt.sourceSnapshot)
    let receipt = try await DVAnalysisReportExporter.export(map: reader, source: source,
      destination: URL(fileURLWithPath: CommandLine.arguments[4]))
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(receipt) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "external-xml" {
    let result = try DVExternalReportReader.read(URL(fileURLWithPath: CommandLine.arguments[2]))
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result) + Data([10])); exit(0)
  }
  if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "tape-map" {
    let source = URL(fileURLWithPath: CommandLine.arguments[2])
    let destination = URL(fileURLWithPath: CommandLine.arguments[3])
    let receipt = try DVTapeEvidenceMapExporter.create(source: source, destination: destination)
    let reader = try DVTapeEvidenceLedgerReader(mapDirectory: destination)
    let original = try DVVerifiedFrameSource(url: source, snapshot: receipt.sourceSnapshot)
    guard reader.binding.pageCount > 0, let first = try await reader.page(0).records.first else {
      throw DVIngestError.invalidEvidence("tape map has no complete frames to inspect")
    }
    _ = try await original.frame(first)
    guard let last = try await reader.page(reader.binding.pageCount - 1).records.last else {
      throw DVIngestError.invalidEvidence("tape map final page has no frames")
    }
    _ = try await original.frame(last)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(receipt) + Data([10]))
    exit(0)
  }
  guard CommandLine.arguments.count == 3,
    ["metadata", "inventory", "semantics", "cadence", "positions", "export-closed-flight", "export-legacy-closed-flight", "resume-publication"].contains(CommandLine.arguments[1]) else {
    throw NSError(
      domain: "RewindDVInspect", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Usage: RewindDVInspect metadata|inventory|semantics|cadence|positions /absolute/path/to/capture.dv (read-only), export-closed-flight /absolute/path/to/closed-flight, export-legacy-closed-flight /absolute/path/to/RevB-flight (explicitly allows unknown final ACK), or resume-publication /absolute/path/to/verified-partials. Inventory/semantics/cadence/positions stream provenance as JSON lines with a final source hash; export/resume create final names without replacing existing files."
      ])
  }
  let url = URL(fileURLWithPath: CommandLine.arguments[2])
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  if CommandLine.arguments[1] == "cadence" {
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let report = try DVFilmScan.scan(url: url) { observation in
      try FileHandle.standardOutput.write(contentsOf: encoder.encode(observation) + Data([10]))
    }
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(report) + Data([10]))
    exit(0)
  }
  if ["inventory", "semantics", "positions"].contains(CommandLine.arguments[1]) {
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var ordinal: UInt64 = 0, offset: UInt64 = 0
    var hash = SHA256()
    var continuity = DVPositionContinuity()
    while let header = try input.read(upToCount: 80), !header.isEmpty {
      guard header.count == 80 else { throw DVIngestError.invalidEvidence("inventory partial header at \(offset)") }
      let size = header[3] & 0x80 == 0 ? 120_000 : 144_000
      guard let tail = try input.read(upToCount: size - 80), tail.count == size - 80 else {
        throw DVIngestError.invalidEvidence("inventory incomplete frame at \(offset); original bytes remain authoritative")
      }
      let frame = header + tail
      let inventory = try DVMetadataInventory.inspect(frame: frame, ordinal: ordinal, byteOffset: offset)
      hash.update(data: frame)
      if CommandLine.arguments[1] == "positions" {
        struct PositionRecord: Encodable {
          let position: DVPositionEvidence
          let continuity: DVPositionContinuity.Observation
        }
        let position = DVPositionEvidence.inspect(inventory)
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(
          PositionRecord(position: position, continuity: continuity.observe(position))) + Data([10]))
      } else if CommandLine.arguments[1] == "semantics" {
        try FileHandle.standardOutput.write(contentsOf:
          encoder.encode(DVPackSemanticReport.inspect(inventory)) + Data([10]))
      } else {
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(inventory) + Data([10]))
      }
      offset += UInt64(frame.count); ordinal += 1
    }
    guard ordinal > 0 else { throw DVIngestError.invalidEvidence("inventory has no complete frames") }
    let summary: [String: Any] = ["event": "\(CommandLine.arguments[1])_complete", "schemaVersion": 1,
      "sourceBytes": offset, "completeFrames": ordinal,
      "sourceSHA256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
      "scope": "DV25 metadata-bearing extents; no complete semantic interpretation or tape-position authority"]
    try FileHandle.standardOutput.write(contentsOf:
      JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) + Data([10]))
    exit(0)
  }
  if CommandLine.arguments[1] != "metadata" {
    let verification = CommandLine.arguments[1] == "resume-publication"
      ? try DVIngestExporter.resumeVerifiedPublication(at: url)
      : try DVIngestExporter.exportClosedFlight(at: url,
          allowLegacyStoppedSnapshot: CommandLine.arguments[1] == "export-legacy-closed-flight")
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(verification) + Data([10]))
    exit(0)
  }
  let manifest = try DVCaptureMetadataEpochAnalyzer.analyze(url: url)
  let summary = MetadataSummary(
    sourcePath: url.path, sourceBytes: manifest.sourceByteCount,
    sourceSHA256: manifest.sourceSHA256, completeFrames: manifest.completeFrameCount,
    audioEpochs: manifest.audioSampleRateEpochs,
    unclassifiedExtents: manifest.unclassifiedExtents.count,
    derivedAudioTrackPolicy: manifest.derivedAudioTrackPolicy)
  try FileHandle.standardOutput.write(contentsOf: encoder.encode(summary) + Data([0x0a]))
} catch {
  try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
