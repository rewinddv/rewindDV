// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif

/// Shared by Capture, current Playback and Archives. All interpretation and
/// grouping live in the core layers; this view only renders immutable evidence.
struct DVMetadataInspector: View {
  let report: DVPackSemanticReport
  var ordinalIsEstimated = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ordinalIsEstimated ? "Selected frame pack metadata" : "Frame pack metadata · frame \(report.frameOrdinal)").font(.headline)
      if ordinalIsEstimated {
        Text("Source byte offsets identify this frame. Frame numbers are preview estimates; the whole-file timeline has not been assessed.").font(.caption)
      }
      Text(report.format).font(.caption).textSelection(.enabled)
      Text("Every observed pack is listed by ID and name. Known fields have labels; unknown or unqualified payloads retain labelled raw bytes. Packs absent from this sampled frame are not invented.")
        .font(.caption).foregroundStyle(.secondary)
      if !DVMetadataPresentation.unresolvedVAUX61(report).isEmpty {
        DisclosureGroup("Unresolved VAUX 0x61 interpretation") {
          Text("Recorded PC2 fixed-bit values disagree with current checks. The cause remains unresolved. This alone does not establish media damage or host loss. Original bytes, check statuses and every location are retained below.")
            .font(.caption)
          ForEach(DVMetadataPresentation.unresolvedVAUX61(report), id: \.id) { pack in
            Text("\(pack.rawHex) · \(pack.observationCount) observations in this frame · \(pack.id)")
              .font(.caption.monospaced())
          }
        }.accessibilityIdentifier("metadata-vaux61-unresolved")
      }
      ForEach(DVMetadataPresentation.groups(report)) { group in
        VStack(alignment: .leading, spacing: 8) {
          Text(group.title).font(.headline)
          ForEach(group.packs, id: \.id) { pack in
            DisclosureGroup(DVMetadataPresentation.packFieldLabel(pack.name, packID: pack.typeHex)) {
              ForEach(pack.fields, id: \.id) { field in fieldRow(field, source: pack.typeHex) }
              packEvidence(pack)
            }.accessibilityIdentifier("metadata-pack-" + pack.id)
          }
        }
      }
      DisclosureGroup("Subcode & Tape Structure · DIF observations") {
        ForEach(report.structuralMetadata ?? []) { item in
          DisclosureGroup("[DIF STRUCTURE] — " + item.name) {
            ForEach(item.fields, id: \.id) { field in fieldRow(field, source: "DIF STRUCTURE") }
            Text(item.rawHex).font(.caption.monospaced()).textSelection(.enabled)
            Text(item.locations.map(DVMetadataPresentation.location).joined(separator: "\n"))
              .font(.caption).textSelection(.enabled)
          }
        }
      }.accessibilityIdentifier("metadata-structure")
      DisclosureGroup("Pack Evidence · every observed pack (\(report.packs.reduce(0) { $0 + $1.observationCount }))") {
        Text("Exact repetitions share a row; every location remains listed. MIC data was not acquired. Missing packs do not prove missing tape content.").font(.caption)
        ForEach(report.packs, id: \.id) { pack in
          DisclosureGroup("[\(pack.typeHex)] — \(pack.name) · \(pack.observationCount) observations") { packEvidence(pack) }
        }
        Text("Frame SHA-256: " + report.frameSHA256).font(.caption.monospaced()).textSelection(.enabled)
        Text(report.formatEvidence).font(.caption)
      }.accessibilityIdentifier("metadata-all-pack-evidence")
    }.textSelection(.enabled)
  }
  private func color(_ field: DVPackSemanticReport.Field) -> Color {
    if field.status == "invalid" || field.status == "conflicting" || field.confidence == .conflictingEvidence { return .red }
    if field.status == "unavailable" { return .secondary }
    if field.confidence == .mostLikely || field.confidence == .provisional { return .orange }
    return .primary
  }
  private func fieldRow(_ field: DVPackSemanticReport.Field, source: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(DVMetadataPresentation.packFieldLabel(field.name, packID: source)).font(.caption.bold())
      Text(field.meaning).foregroundStyle(color(field))
      Text(DVMetadataPresentation.fieldCaption(field))
        .font(.caption).foregroundStyle(color(field))
      Text(field.reference).font(.caption2).foregroundStyle(.secondary)
      if let qualifier = field.qualifier { Text(qualifier).font(.caption2).foregroundStyle(.secondary) }
    }.padding(.vertical, 3).accessibilityElement(children: .combine)
  }
  private func packEvidence(_ pack: DVPackSemanticReport.Pack) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(pack.rawHex).font(.callout.monospaced())
      Text(pack.status).font(.caption)
      if let evidence = pack.catalogEvidence { Text(evidence).font(.caption) }
      ForEach(DVMetadataPresentation.rawPayloadFields(pack), id: \.id) { field in fieldRow(field, source: pack.typeHex) }
      MetadataLocations(locations: pack.locations ?? [])
    }.textSelection(.enabled)
  }
}

/// Bounded text expansion even for a pack repeated throughout a PAL frame.
private struct MetadataLocations: View {
  let locations: [DVMetadataLocation]
  @State private var page = 0
  private let pageSize = 20
  var body: some View {
    let pages = max(1, (locations.count + pageSize - 1) / pageSize)
    let selected = min(page, pages - 1)
    VStack(alignment: .leading) {
      Text(locations.dropFirst(selected * pageSize).prefix(pageSize)
        .map(DVMetadataPresentation.location).joined(separator: "\n"))
        .font(.caption.monospaced())
      if pages > 1 {
        HStack {
          Button("Previous locations") { page = max(0, selected - 1) }.disabled(selected == 0)
          Text("\(selected + 1) / \(pages)").font(.caption)
          Button("Next locations") { page = min(pages - 1, selected + 1) }.disabled(selected == pages - 1)
        }
      }
    }
  }
}
