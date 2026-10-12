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
  var searchQuery: Binding<String>? = nil
  @State private var localQuery = ""
  @State private var expandedPacks = Set<String>()
  @State private var collapsedPacks = Set<String>()
  @State private var showAllFields = true
  init(report:DVPackSemanticReport,ordinalIsEstimated:Bool=false,searchQuery:Binding<String>?=nil,expandsFieldsByDefault:Bool=true) {
    self.report=report;self.ordinalIsEstimated=ordinalIsEstimated;self.searchQuery=searchQuery
    _showAllFields=State(initialValue:expandsFieldsByDefault)
  }
  private var query: Binding<String> { searchQuery ?? $localQuery }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ordinalIsEstimated ? "Selected frame pack metadata" : "Frame pack metadata · frame \(report.frameOrdinal)").font(.headline)
      if ordinalIsEstimated {
        Text("Source byte offsets identify this frame. Frame numbers are preview estimates; the whole-file timeline has not been assessed.").font(.caption)
      }
      Text(report.format).font(.caption).textSelection(.enabled)
      Text("Every observed pack is listed by ID and name. Recorded settings are spelled out below. Expand field details for source codes and qualifications; unknown payloads remain explicit. Packs absent from this sampled frame are not invented.")
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
      TextField("Find a pack ID, name or field", text: query)
        .textFieldStyle(.roundedBorder).accessibilityIdentifier("metadata-search")
      Toggle("Show all recorded fields", isOn: $showAllFields)
        .accessibilityIdentifier("metadata-show-all-fields")
      ForEach(DVMetadataPresentation.groups(report).filter { $0.packs.contains { DVMetadataPresentation.matches($0, query: query.wrappedValue) } }) { group in
        VStack(alignment: .leading, spacing: 8) {
          Text(group.title).font(.headline)
          ForEach(group.packs.filter { DVMetadataPresentation.matches($0, query: query.wrappedValue) }, id: \.id) { pack in
            DisclosureGroup(DVMetadataPresentation.packFieldLabel(pack.name, packID: pack.typeHex), isExpanded: Binding(
              get: { !query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expandedPacks.contains(pack.id) || (showAllFields && !collapsedPacks.contains(pack.id)) },
              set: { if $0 { expandedPacks.insert(pack.id); collapsedPacks.remove(pack.id) } else { expandedPacks.remove(pack.id); collapsedPacks.insert(pack.id) } })) {
              ForEach(pack.fields.filter { !DVMetadataPresentation.isFormatDetail($0) }, id: \.id) { field in fieldRow(field, source: pack.typeHex) }
              if pack.fields.isEmpty { Text(pack.status).font(.caption) }
              DisclosureGroup("Raw bytes, format checks & source locations") {
                ForEach(pack.fields.filter(DVMetadataPresentation.isFormatDetail), id: \.id) { field in fieldRow(field, source: pack.typeHex) }
                packEvidence(pack)
              }
            }.accessibilityIdentifier("metadata-pack-" + pack.id)
          }
        }
      }
      if let sequences = report.sequences, !sequences.isEmpty {
        DisclosureGroup("Text, teletext & line sequences (\(sequences.count))") {
          ForEach(Array(sequences.enumerated()), id: \.offset) { index, sequence in
            sequenceEvidence(sequence, index: index)
          }
        }.accessibilityIdentifier("metadata-sequences")
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
      DisclosureGroup("Coverage & interpretation") {
        Text("Schema \(report.schemaVersion) · interpretation \(report.interpretationVersion.map(String.init) ?? "unknown")")
        Text("Frame source byte: \(report.frameByteOffset.map(String.init) ?? "unknown")")
        Text("Absolute source offsets: \(report.absoluteOffsetsKnown.map { $0 ? "known" : "unknown" } ?? "unspecified")")
        Text("Principal packs not observed in this sampled frame: " + (report.missingPrincipalPacks.isEmpty ? "none" : report.missingPrincipalPacks.joined(separator: ", ")))
        Text("A pack ID in the catalog does not establish that it was recorded. Unavailable, conflicting and context-dependent meanings remain qualified. MIC data was not acquired.")
      }.font(.caption).accessibilityIdentifier("metadata-coverage")
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
      Text(DVMetadataPresentation.fieldValue(field)).foregroundStyle(color(field)).fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("Field details") {
      Text(DVMetadataPresentation.fieldCaption(field))
        .font(.caption).foregroundStyle(color(field))
      Text(field.reference).font(.caption2).foregroundStyle(.secondary)
      if let qualifier = field.qualifier { Text(qualifier).font(.caption2).foregroundStyle(.secondary) }
      }
    }.padding(.vertical, 3).accessibilityElement(children: .contain)
  }
  private func packEvidence(_ pack: DVPackSemanticReport.Pack) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(pack.rawHex).font(.callout.monospaced())
      Text(pack.status).font(.caption)
      if let evidence = pack.catalogEvidence { Text(evidence).font(.caption) }
      ForEach(DVMetadataPresentation.rawPayloadFields(pack), id: \.id) { field in fieldRow(field, source: pack.typeHex) }
      if let layout = pack.normativeLayout, !layout.isEmpty {
        DisclosureGroup("Documented bit layout (\(layout.count) fields)") {
          Text("Slices are listed least-significant fragment first. Layout definitions describe the decoder's interpretation; check each field's status and reference.").font(.caption)
          ForEach(Array(layout.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 3) {
              Text("[\(pack.typeHex)] — \(field.id)").font(.caption.bold())
              Text(DVMetadataPresentation.layoutCaption(field)).font(.caption.monospaced())
              Text(field.reference).font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 3)
          }
        }
      }
      if let locations = pack.locations, !locations.isEmpty {
        MetadataLocations(locations: locations)
      } else {
        MetadataEvidenceLines(lines: pack.sourceByteOffsets.map { "Source byte \($0) · legacy offset; detailed location unavailable" })
      }
    }.textSelection(.enabled)
  }
  private func sequenceEvidence(_ sequence: DVIECSequences.Sequence, index: Int) -> some View {
    DisclosureGroup("\(sequence.kind.capitalized) sequence \(index + 1) · \(sequence.status)") {
      Text("Expected \(sequence.expectedCount) \(sequence.countUnit) · \(sequence.payload.count) payload bytes · \(sequence.observations.count) observed packs").font(.caption)
      Text(sequence.reference).font(.caption2)
      if let text=sequence.decodedText { Text("Recorded text: "+text).textSelection(.enabled) }
      if let status=sequence.textInterpretation { Text(status).font(.caption) }
      if let first=sequence.firstTeletextID {
        Text("First teletext identifier: system \(first.system), \(first.secondField ? "second":"first") field, line \(first.lineNumber.map(String.init) ?? "unresolved") · \(first.status)").font(.caption)
      }
      ForEach(sequence.teletextInformation ?? [],id:\.id) { field in fieldRow(field,source:"0x0C") }
      if let sets = sequence.characterSets {
        ForEach(sets.keys.sorted(), id: \.self) { key in
          Text("Character set \(key): \(DVIEC61834.characterSetName(sets[key]!)) · \(String(format: "0x%02X", sets[key]!))").font(.caption)
        }
      }
      DisclosureGroup("Payload bytes") { MetadataByteEvidence(bytes: sequence.payload) }
      ForEach(Array((sequence.components ?? []).enumerated()), id: \.offset) { _, component in
        DisclosureGroup("[\(String(format: "0x%02X", component.header))] — \(component.status)") {
          Text("Expected samples: \(component.expectedSamples.map(String.init) ?? "unknown") · observed \(component.samples.count)").font(.caption)
          Text("Unpacked sample values · hexadecimal").font(.caption)
          MetadataByteEvidence(bytes: component.samples)
          DisclosureGroup("Padding sample values (\(component.padding.count))") { MetadataByteEvidence(bytes: component.padding) }
        }
      }
      DisclosureGroup("Sequence observations") {
        MetadataEvidenceLines(lines: sequence.observations.map {
          $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            + ($0.qualified ? " · qualified · " : " · unqualified · ")
            + ($0.location.map(DVMetadataPresentation.location) ?? "location unavailable")
        })
      }
      Text("Byte sequences do not prove readable text or intact content. No glyphs or missing context are inferred.").font(.caption)
    }
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

/// Paging preserves access to every byte without expanding unbounded text.
private struct MetadataByteEvidence: View {
  let bytes: [UInt8]
  var body: some View {
    MetadataEvidenceLines(lines: stride(from: 0, to: bytes.count, by: 16).map { offset in
      "\(offset): " + bytes.dropFirst(offset).prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
    })
  }
}
private struct MetadataEvidenceLines: View {
  let lines: [String]
  @State private var page = 0
  var body: some View {
    let pages = max(1, (lines.count + 19) / 20)
    let selected = min(page, pages - 1)
    VStack(alignment: .leading, spacing: 6) {
      Text(lines.isEmpty ? "None observed" : lines.dropFirst(selected * 20).prefix(20).joined(separator: "\n"))
        .font(.caption.monospaced()).textSelection(.enabled)
      if pages > 1 {
        HStack {
          Button("Previous") { page = max(0, selected - 1) }.disabled(selected == 0)
          Text("\(selected + 1) / \(pages)").font(.caption)
          Button("Next") { page = min(pages - 1, selected + 1) }.disabled(selected == pages - 1)
        }
      }
    }
  }
}
