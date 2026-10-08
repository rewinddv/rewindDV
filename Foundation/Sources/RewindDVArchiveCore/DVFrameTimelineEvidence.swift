// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Recorded labels/format transitions, never missing-frame counts or edit/merge
/// authority. Unknown values break comparison rather than being carried forward.
public struct DVFrameTimelineEvidence: Codable, Equatable, Sendable {
  public struct Point: Codable, Equatable, Sendable {
    public let timecodeFrame: Int?
    public let dropFrame: Bool?
    public let timecodeLabel: String?
    public let recordedDate: String?
    public let formatFingerprint: [String]
    public var timecodeInterpretation: String? = nil
  }
  public let point: Point
  public let changes: [DVTapeEvidenceMapExporter.IssueCode]
  public static func inspect(_ inventory: DVMetadataInventory, report: DVPackSemanticReport) -> Point {
    let film = DVFilmFrameEvidence.inspect(inventory, semanticReport: report)
    let knownFormat = report.format == "IEC 61834 consumer DV" || report.format == "SMPTE ST 314M-2005 DV"
    let tc = knownFormat ? film.timecodeFrame : nil
    var label: String?
    if tc != nil, let pack = report.packs.first(where: { $0.typeHex == "0x13" && $0.id.hasPrefix("subcode-frame:") }) {
      let p = pack.rawHex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
      if p.count == 5 {
        label = String(format: "%02X:%02X:%02X%@%02X", p[4] & 0x3f, p[3] & 0x7f, p[2] & 0x7f,
          film.timecodeDropFrame == true ? ";" : ":", p[1] & 0x3f)
      }
    }
    let dates = report.packs.filter { $0.typeHex == "0x62" && $0.id.hasPrefix("vaux-frame:") }
    let values = dates.compactMap { pack -> String? in
      let fields = ["REC_YEAR", "REC_MONTH", "REC_DAY"].compactMap { id in pack.fields.first { $0.id == id && $0.status == "interpreted" } }
      guard fields.count == 3 else { return nil }
      return fields.map { String(format: "%02X", $0.rawValue) }.joined(separator: "-")
    }
    let date = !values.isEmpty && values.count == dates.count && Set(values).count == 1 ? values.first : nil
    let formatFields = report.packs.filter { ["0x50", "0x60", "0x61"].contains($0.typeHex) }.flatMap { pack in
      pack.fields.filter { ["SMP", "QU", "CHN", "STYPE", "DISP", "BCS"].contains($0.id) }.map { field in
        "\(pack.id.split(separator: ":").first ?? "unknown")/\(field.id)/\(field.status)/\(field.rawValue)"
      }
    }
    return Point(timecodeFrame: tc, dropFrame: tc == nil ? nil : film.timecodeDropFrame, timecodeLabel: label,
      recordedDate: date, formatFingerprint: [report.format] + Set(formatFields).sorted(), timecodeInterpretation:film.timecodeInterpretation)
  }
  public static func changes(from previous: Point?, to current: Point) -> [DVTapeEvidenceMapExporter.IssueCode] {
    guard let previous else { return [] }
    var changes: [DVTapeEvidenceMapExporter.IssueCode] = []
    if let a = previous.timecodeFrame, let b = current.timecodeFrame {
      if a == Int.max || b != a + 1 || previous.dropFrame != current.dropFrame { changes.append(.timecodeTransition) }
    } else if (previous.timecodeFrame == nil) != (current.timecodeFrame == nil) { changes.append(.timecodeTransition) }
    if previous.recordedDate != current.recordedDate { changes.append(.recordedDateTransition) }
    if previous.formatFingerprint != current.formatFingerprint { changes.append(.formatTransition) }
    return changes
  }
}
