// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Untrusted external XML stays in a separate namespace. No pathname is followed,
/// no entities or network are resolved, and no imported claim becomes native proof.
public enum DVExternalReportReader {
  public static let maximumBytes = 128 * 1024 * 1024
  public struct Element: Codable, Equatable, Sendable {
    public let path: String
    public let attributes: [String: String]
  }
  public struct Result: Codable, Sendable {
    public let schemaVersion: Int
    public let namespace: String
    public let reportSHA256: String
    public let reportBytes: Int
    public let creator: String
    public let creatorVersion: String
    public let media: [String: String]
    public let elementCount: Int
    public let listedFrameCount: UInt64
    public let declaredFrameCount: UInt64?
    public let videoSTAObservations: UInt64?
    public let audioBlockObservations: UInt64?
    public let claimedSourceBinding: String
    public let preview: [Element]
    public let previewTruncated: Bool
    public let authority: String
  }

  public static func read(_ url: URL, expectedSource: DVReviewedRangeExporter.Snapshot? = nil) throws -> Result {
    try parse(readBounded(url), expectedSource: expectedSource)
  }
  /// Optionally preserve the exact imported document and interpretation receipt.
  /// Exclusive separate directory; does not update the native map or review queue.
  public static func preserve(_ url: URL, destination: URL,
    expectedSource: DVReviewedRangeExporter.Snapshot? = nil) throws -> Result {
    let data = try readBounded(url), result = try parse(data, expectedSource: expectedSource)
    let dir = try DVTapeEvidenceMapExporter.EvidenceDirectory.create(destination)
    defer { dir.close() }
    try dir.writeExclusive(named: "external.xml.partial", data: data, synchronize: true)
    let check = try dir.hashRegularFile(named: "external.xml.partial")
    guard check.sha256 == result.reportSHA256, check.bytes == UInt64(data.count) else {
      throw DVIngestError.invalidEvidence("external report reread mismatch")
    }
    try Task.checkCancellation(); try dir.requireCurrentDestinationPath()
    try dir.promoteExclusive(from: "external.xml.partial", to: "external.xml", expectedBytes: check.bytes, expectedSHA256: check.sha256)
    let receipt = try DVAnalysisReportExporter.encode(result)
    try dir.writeExclusive(named: "external-report.json.partial", data: receipt, synchronize: true)
    try dir.synchronize(); try Task.checkCancellation(); try dir.requireCurrentDestinationPath()
    try dir.promoteExclusive(from: "external-report.json.partial", to: "external-report.json",
      expectedBytes: UInt64(receipt.count), expectedSHA256: DVAnalysisReportExporter.hex(SHA256.hash(data: receipt)))
    do { try dir.synchronize() }
    catch { dir.withdrawCompletionMarkerBestEffort(from: "external-report.json", to: "external-report.json.partial"); throw error }
    return result
  }
  static func parse(_ data: Data, expectedSource: DVReviewedRangeExporter.Snapshot? = nil) throws -> Result {
    try Task.checkCancellation()
    guard data.count <= maximumBytes, let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") else {
      throw DVIngestError.invalidEvidence("XML must be bounded UTF-8, not UTF-16/32 or a binary document")
    }
    // Reject declarations before XMLParser can expand even an internal entity.
    guard !utf8.contains("<!DOCTYPE"), !utf8.contains("<!ENTITY") else {
      throw DVIngestError.invalidEvidence("DTD and entity declarations are not permitted")
    }
    let delegate = Reader(expected: expectedSource)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    let parsed = parser.parse()
    if let failure = delegate.failure { throw failure }
    try Task.checkCancellation()
    guard parsed, delegate.finished, delegate.mediaCount == 1, delegate.programCount == 1,
      delegate.versionCount == 1, !delegate.program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DVIngestError.invalidEvidence("incomplete or unsupported DVRescue XML structure")
    }
    var binding = "unbound_external_claims; filename and size are not source identity"
    if let expectedSource, let reference = delegate.media["ref"], reference.hasPrefix("urn:sha256:") {
      guard reference == "urn:sha256:" + expectedSource.sourceSHA256,
        delegate.media["size"].flatMap(UInt64.init) == expectedSource.sourceByteCount else {
        throw DVIngestError.invalidEvidence("XML claimed source hash/size mismatch")
      }
      binding = "external_report_claims_matching_source_hash_and_size; findings_not_independently_verified"
    }
    return Result(schemaVersion: 1, namespace: "external_dvrescue_xml", reportSHA256: DVAnalysisReportExporter.hex(SHA256.hash(data: data)),
      reportBytes: data.count, creator: delegate.program, creatorVersion: delegate.version,
      media: delegate.media, elementCount: delegate.elements, listedFrameCount: delegate.frames,
      declaredFrameCount: delegate.groupCount > 0 && delegate.allGroupCountsKnown ? delegate.declared : nil,
      videoSTAObservations: delegate.sawSTA ? delegate.sta : nil,
      audioBlockObservations: delegate.sawAudio ? delegate.aud : nil,
      claimedSourceBinding: binding, preview: delegate.preview, previewTruncated: delegate.elements > delegate.preview.count,
      authority: "external claims only; bounded structural parsing, not full XSD certification; unknown attributes preserved in exact external.xml and bounded preview; no motion, deletion, replacement, recovery or merge authority")
  }

  private static func readBounded(_ url: URL) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open external report", errno) }
    defer { Darwin.close(fd) }
    var initial = stat()
    guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
      initial.st_size > 0, initial.st_size <= maximumBytes else { throw DVIngestError.invalidEvidence("external report type or size limit") }
    var data = Data(count: Int(initial.st_size)), done = 0
    while done < data.count {
      try Task.checkCancellation()
      let requested = min(1_048_576, data.count - done)
      let amount = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: done), requested) }
      if amount < 0 && errno == EINTR { continue }
      guard amount > 0 else { throw DVIngestError.invalidEvidence("external XML read truncated") }; done += amount
    }
    var final = stat(), path = stat()
    guard fstat(fd, &final) == 0, lstat(url.path, &path) == 0,
      final.st_size == initial.st_size, final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
      path.st_dev == initial.st_dev, path.st_ino == initial.st_ino, path.st_mode & S_IFMT == S_IFREG else {
      throw DVIngestError.invalidEvidence("external XML changed while reading")
    }
    return data
  }

  private final class Reader: NSObject, XMLParserDelegate {
    let expected: DVReviewedRangeExporter.Snapshot?
    var stack: [String] = [], elements = 0, mediaCount = 0, programCount = 0, versionCount = 0
    var frames: UInt64 = 0, declared: UInt64 = 0, sta: UInt64 = 0, aud: UInt64 = 0
    var sawSTA = false, sawAudio = false
    var groupCount = 0, allGroupCountsKnown = true
    var frameSTA: UInt64 = 0, frameAudio: UInt64 = 0, sequenceSTA: UInt64 = 0, sequenceAudio: UInt64 = 0
    var hasFrameSTA = false, hasFrameAudio = false
    var program = "", version = "", media: [String: String] = [:], preview: [Element] = []
    var finished = false, failure: Error?, lastFrame: UInt64?, groupFrames: UInt64 = 0, groupDeclared: UInt64?
    init(expected: DVReviewedRangeExporter.Snapshot?) { self.expected = expected }
    func fail(_ parser: XMLParser, _ text: String) { failure = DVIngestError.invalidEvidence(text); parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
      if Task.isCancelled { failure = CancellationError(); parser.abortParsing(); return }
      elements += 1
      guard elements <= 2_000_000, stack.count < 12, attributes.count <= 128,
        attributes.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 }) else { fail(parser, "XML structural budget exceeded"); return }
      guard namespaceURI == DVAnalysisReportExporter.xmlNamespace else { fail(parser, "unsupported XML namespace"); return }
      let parent = stack.last
      let allowed: [String: Set<String>] = ["dvrescue": ["creator", "media"], "creator": ["program", "version", "library"],
        "media": ["stop", "source", "frames"], "frames": ["frame"], "frame": ["dseq", "sta", "aud", "signalstats"], "dseq": ["sta", "aud"]]
      guard parent.map({ allowed[$0]?.contains(name) == true }) ?? (name == "dvrescue" && elements == 1) else { fail(parser, "unsupported XML element placement"); return }
      stack.append(name)
      if preview.count < 256 { preview.append(Element(path: stack.joined(separator: "/"), attributes: attributes)) }
      switch name {
      case "media": mediaCount += 1; media = attributes
      case "program": programCount += 1
      case "version": versionCount += 1
      case "frames":
        groupCount += 1
        groupFrames = 0; groupDeclared = nil
        if let raw = attributes["count"] {
          guard let n = UInt64(raw), n <= 10_000_000, declared <= 10_000_000 - n else { fail(parser, "XML frame range exceeds budget"); return }
          groupDeclared = n; declared += n
        } else { allGroupCountsKnown = false }
      case "frame":
        frameSTA = 0; frameAudio = 0; sequenceSTA = 0; sequenceAudio = 0
        hasFrameSTA = false; hasFrameAudio = false
        guard let raw = attributes["n"], let n = UInt64(raw), n < 10_000_000,
          lastFrame.map({ n > $0 }) ?? true else { fail(parser, "invalid, duplicate or unordered external frame ordinal"); return }
        if let raw = attributes["pos"] {
          guard let pos = UInt64(raw), pos <= UInt64(Int64.max) else { fail(parser, "invalid external byte offset"); return }
          if let expected, media["ref"] == "urn:sha256:" + expected.sourceSHA256,
            (n >= expected.frameCount || pos != (try? expected.frame(n).byteOffset)) {
            fail(parser, "external frame coordinates disagree with claimed source"); return
          }
        }
        if let expected, media["ref"] == "urn:sha256:" + expected.sourceSHA256, n >= expected.frameCount {
          fail(parser, "external frame outside claimed source"); return
        }
        lastFrame = n; frames += 1; groupFrames += 1
      case "dseq":
        guard let n = attributes["n"].flatMap(UInt64.init), n < 12 else { fail(parser, "external DIF sequence outside DV25"); return }
      case "sta", "aud":
        guard let n = attributes["n"].flatMap(UInt64.init), n <= (name == "sta" ? 1620 : 108) else { fail(parser, "external defect count outside DV25"); return }
        if name == "sta", let type = attributes["t"] { guard let t = UInt64(type), t <= 15 else { fail(parser, "STA code outside nibble"); return } }
        if let raw = attributes["n_even"] { guard let even = UInt64(raw), even <= n else { fail(parser, "external even count exceeds total"); return } }
        // Do not double-count per-DIF detail and frame-level aggregates.
        if name == "sta" {
          sawSTA = true
          if parent == "frame" { hasFrameSTA = true; frameSTA += n } else { sequenceSTA += n }
        } else {
          sawAudio = true
          if parent == "frame" { hasFrameAudio = true; frameAudio += n } else { sequenceAudio += n }
        }
        guard frameSTA <= 1620, sequenceSTA <= 1620, frameAudio <= 108, sequenceAudio <= 108 else {
          fail(parser, "combined external counts exceed DV25 frame capacity"); return
        }
      default: break
      }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
      if stack.last == "program" { program += text }
      if stack.last == "version" { version += text }
      if program.utf8.count > 4096 || version.utf8.count > 4096 { fail(parser, "external creator text budget exceeded") }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      if name == "frame" {
        // Some external tools only include a subset of DIF detail; never require
        // equality, but aggregates cannot be smaller than supplied detail.
        if (hasFrameSTA && frameSTA < sequenceSTA) || (hasFrameAudio && frameAudio < sequenceAudio) {
          fail(parser, "external aggregate smaller than supplied DIF detail"); return
        }
        sta += hasFrameSTA ? frameSTA : sequenceSTA
        aud += hasFrameAudio ? frameAudio : sequenceAudio
      }
      if name == "frames", let n = groupDeclared, groupFrames > n { fail(parser, "listed frame count exceeds declared group"); return }
      if name == "dvrescue" { finished = true }
      _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(parser, "external entities prohibited"); return nil }
  }
}
