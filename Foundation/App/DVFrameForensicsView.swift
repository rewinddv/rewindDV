// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Offline, selected-frame-only inspection. No driver, capture, or tape APIs.
struct DVFrameForensicsView: View {
  let frame: DVVerifiedFrameSource.Frame
  let image: NSImage?
  let identity: DVTapeDefectInspector.Model
  @State private var selectedBlock = 0
  @State private var selectedSequence = 0
  @State private var showStatus = true
  @State private var blockEntry = "0"
  @State private var highlightedOffsets: Set<UInt64> = []
  @State private var metadataWarningsOnly = false
  private var evidence: DVFrameForensics { frame.evidence }
  private var block: DVFrameForensics.Block { evidence.blocks[selectedBlock] }
  private var pal: Bool { frame.bytes.count == 144_000 }
  private var geometryAvailable: Bool { evidence.videoLayout != nil }
  private var blockBytes: Data {
    let index = Int(block.sourceByteOffset - identity.sourceByteOffset)
    return frame.bytes.subdata(in: index..<(index + 80))
  }

  var body: some View {
    ArchiveSection("Original frame loupe · \(identity.frameOrdinal)") {
      VStack(alignment: .leading, spacing: 12) {
        fact("Verified source", "Whole-file SHA-256 and this frame's SHA-256 match. No original bytes are changed.")
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            picture
            Toggle("Show nonzero video STA locations", isOn: $showStatus).toggleStyle(.checkbox)
              .disabled(!geometryAvailable)
            if !geometryAvailable { Text("Spatial overlay unassessed for this application/system. Exact DIF bytes remain available.").font(.caption).foregroundStyle(.orange) }
            Text("Both decoded fields retained. Rectangles locate nominal video macroblocks—not the complete damage footprint. A decoder can conceal defects; borrowed segment data may affect other blocks.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }.frame(width: 540)
          VStack(alignment: .leading, spacing: 8) {
            fact("Audio coverage", evidence.summary.audioCoverage)
            fact("Active samples examined", "\(evidence.summary.audioSamplesExamined)")
            fact("Audio error codes", "\(evidence.audioErrors.count)")
            fact("Application", evidence.semantics.format)
            fact("Recorded position", evidence.position.classification.rawValue)
            fact("Recorded ATN candidates", evidence.position.normalizedFrameTrackCandidates.map(String.init).joined(separator: ", "))
            Text("Recorded ATN is not physical tape position, BOT/EOT, or alignment/merge authority. ETN is not inferred.")
              .font(.caption).foregroundStyle(.secondary)
            Button("Copy frame provenance") { copyProvenance() }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("DIF BLOCK MAP — columns are physical block order within each sequence, not picture pixels. Red: nonzero STA; purple: audio error code; yellow outline: selection.")
          .font(.caption).foregroundStyle(.secondary)
        blockMap
        HStack {
          Picker("Sequence", selection: $selectedSequence) {
            ForEach(0..<(pal ? 12 : 10), id: \.self) { Text(String($0)).tag($0) }
          }.frame(width: 150)
          TextField("DIF ordinal", text: $blockEntry).frame(width: 120).onSubmit { jumpToBlock() }
          Button("Inspect DIF block") { jumpToBlock() }
            .disabled(Int(blockEntry).map { evidence.blocks.indices.contains($0) } != true)
        }
        HStack {
          Button("Previous block") { chooseBlock(max(0, selectedBlock - 1)) }.disabled(selectedBlock == 0)
          Button("Next block") { chooseBlock(min(evidence.blocks.count - 1, selectedBlock + 1)) }
            .disabled(selectedBlock + 1 == evidence.blocks.count)
          Button("Previous flagged block") { if let item = flaggedBlocks.last(where: { $0.id < selectedBlock }) { chooseBlock(item.id) } }
            .disabled(!flaggedBlocks.contains { $0.id < selectedBlock })
          Button("Next flagged block") { if let item = flaggedBlocks.first(where: { $0.id > selectedBlock }) { chooseBlock(item.id) } }
            .disabled(!flaggedBlocks.contains { $0.id > selectedBlock })
        }
        ScrollView(.horizontal) {
          HStack(spacing: 3) {
            ForEach(evidence.blocks.filter { $0.sequence == selectedSequence }) { item in
              Button { chooseBlock(item.id) } label: {
                Text("\(item.name.prefix(1))\(item.number)").font(.system(size: 10, design: .monospaced))
                  .padding(5).background(color(item).opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
              }.buttonStyle(.plain).accessibilityLabel("Sequence \(item.sequence), \(item.name) block \(item.number), source byte \(item.sourceByteOffset)")
            }
          }
        }
        fact("Selected DIF block", "\(block.id) · sequence \(block.sequence) · \(block.name) \(block.number)")
        fact("Original byte range (decimal)", "\(block.sourceByteOffset)..<\(block.sourceByteOffset + 80)")
        if let sta = block.videoSTA {
          fact("Raw STA / QNO", String(format: "0x%X / 0x%X", sta, blockBytes[3] & 15))
        }
        hexView
        Button("Copy original 80-byte hex with offsets") {
          copy("Original DV SHA-256: \(identity.sourceSHA256)\nFrame \(identity.frameOrdinal) SHA-256: \(identity.frameSHA256)\nDIF \(block.id): sequence \(block.sequence), \(block.name) \(block.number)\nOffsets below are hexadecimal. Source bytes unchanged.\n"
            + DVFrameForensics.hexDump(blockBytes, sourceOffset: block.sourceByteOffset))
        }
        ArchiveDisclosure("Exact audio error samples (\(evidence.audioErrors.count))") {
          ScrollView {
            LazyVStack(alignment: .leading) {
              ForEach(Array(evidence.audioErrors.enumerated()), id: \.offset) { _, error in
                Button {
                  if let item = evidence.blocks.first(where: { $0.section == 3 && $0.sequence == error.sequence && $0.number == error.block }) {
                    chooseBlock(item.id); highlightedOffsets = Set(error.byteOffsets)
                  }
                } label: {
                  Text("Channel \(error.channel + 1) · frame sample \(error.sample) · code \(String(format: "0x%X", error.code)) · bytes \(error.byteOffsets.map(String.init).joined(separator: ", ")) · masks \(error.bitMasks.map { String(format: "%02X", $0) }.joined(separator: ", "))")
                    .font(.caption.monospaced()).foregroundStyle(.white)
                }.buttonStyle(.plain)
              }
            }
          }.frame(maxHeight: 180)
          Text("Sample indices are zero based within this frame. Masks identify contributing bits for packed 12-bit samples. This is not an audible-defect duration or packet-loss count.").font(.caption).foregroundStyle(.secondary)
        }
        ArchiveDisclosure("All source-bound metadata packs and interpretations") {
          if !DVMetadataPresentation.unresolvedVAUX61(evidence.semantics).isEmpty {
            Text("Unresolved VAUX 0x61 interpretation: recorded PC2 fixed-bit values disagree with current checks. This alone does not establish media damage or host loss. Every raw observation and check remains below.").font(.caption)
          }
          Toggle("Invalid or conflicting metadata only", isOn: $metadataWarningsOnly).toggleStyle(.checkbox)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(evidence.semantics.packs.filter { pack in
                !metadataWarningsOnly || pack.status.hasPrefix("Conflicting field values") || pack.fields.contains { $0.status == "invalid" }
              }, id: \.id) { pack in
                ArchiveDisclosure("\(pack.name) · \(pack.typeHex) · \(pack.status)") {
                  fact("Raw five-byte pack", pack.rawHex)
                  ForEach(pack.fields.sorted { ($0.status == "uninterpreted" ? 1 : 0) < ($1.status == "uninterpreted" ? 1 : 0) }, id: \.id) { field in
                    HStack(alignment: .firstTextBaseline) {
                      Text(field.name.uppercased()).font(.caption.bold()).foregroundStyle(.yellow)
                      Text(field.meaning).font(.caption)
                        .foregroundStyle(["uninterpreted", "invalid"].contains(field.status) ? .red : .white)
                        .textSelection(.enabled)
                    }.help(field.reference)
                  }
                  ScrollView(.horizontal) {
                    HStack {
                      ForEach(pack.sourceByteOffsets, id: \.self) { offset in
                        Button("Byte \(offset)") {
                          if let block = evidence.block(containingSourceByte: offset) { chooseBlock(block.id) }
                          highlightedOffsets = Set(offset..<(offset + 5))
                        }.font(.caption.monospaced())
                      }
                    }
                  }
                }
              }
            }
          }.frame(maxHeight: 360)
        }
      }.padding(8).onAppear { if let first = flaggedBlocks.first { chooseBlock(first.id) } }
    }
  }
  private var picture: some View {
    ZStack {
      Color.black
      if let image {
        Image(nsImage: image).resizable().interpolation(.none)
      } else { Text("Decoded picture unavailable. Original bytes remain inspectable.").font(.caption).padding() }
      if geometryAvailable {
        Canvas { context, size in
          for item in evidence.blocks where item.section == 4 && (item.id == selectedBlock || (showStatus && item.videoSTA != 0)) {
            guard let layout = evidence.videoLayout, let region = DVVideoBlockGeometry.region(sequence: item.sequence, block: item.number, layout: layout) else { continue }
            let rect = CGRect(x: CGFloat(region.x) / 720 * size.width, y: CGFloat(region.y) / CGFloat(pal ? 576 : 480) * size.height,
              width: CGFloat(region.width) / 720 * size.width, height: CGFloat(region.height) / CGFloat(pal ? 576 : 480) * size.height)
            context.stroke(Path(rect), with: .color(item.id == selectedBlock ? .yellow : .red), lineWidth: 1)
          }
        }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
          let x = Int(tap.location.x / 540 * 720), y = Int(tap.location.y / 540 * 720)
          if let hit = evidence.block(atRasterX: x, y: y) { chooseBlock(hit.id) }
        })
      }
    }.frame(width: 540, height: CGFloat(pal ? 576 : 480) * 0.75)
      .accessibilityLabel(image == nil
        ? "Picture unavailable for verified frame \(identity.frameOrdinal). Original DIF bytes remain inspectable."
        : "Decoded frame \(identity.frameOrdinal), raw raster proportions. Use DIF block controls for keyboard inspection.")
  }
  private var blockMap: some View {
    GeometryReader { geometry in
      Canvas { context, size in
        for item in evidence.blocks {
          let rect = CGRect(x: CGFloat(item.id % 150) / 150 * size.width,
            y: CGFloat(item.id / 150) * 14, width: size.width / 150, height: 12)
          context.fill(Path(rect), with: .color(color(item)))
          if item.id == selectedBlock { context.stroke(Path(rect), with: .color(.yellow), lineWidth: 2) }
        }
      }.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
        let row = min((pal ? 12 : 10) - 1, max(0, Int(tap.location.y / 14)))
        let column = min(149, max(0, Int(tap.location.x / max(1, geometry.size.width) * 150)))
        chooseBlock(row * 150 + column)
      })
    }.frame(height: CGFloat(pal ? 12 : 10) * 14)
      .accessibilityLabel("Original DIF layout. Use sequence selector and block buttons for keyboard access.")
  }
  private var hexView: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("HEX OFFSET        ORIGINAL BYTES (yellow: selected evidence)").font(.caption).foregroundStyle(.secondary)
      ForEach(0..<5, id: \.self) { row in
        HStack(spacing: 6) {
          Text(String(format: "%012llX", block.sourceByteOffset + UInt64(row * 16)))
          ForEach(0..<16, id: \.self) { column in
            let index = row * 16 + column
            Text(String(format: "%02X", blockBytes[index]))
              .foregroundStyle(highlightedOffsets.contains(block.sourceByteOffset + UInt64(index)) ? .yellow : .white)
          }
        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
      }
    }.padding(10).background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
  }
  private func color(_ item: DVFrameForensics.Block) -> Color {
    if let sta = item.videoSTA, sta != 0 { return .red }
    if item.audioErrorCount > 0 { return .purple }
    return [Color.gray, .cyan, .yellow.opacity(0.6), .green.opacity(0.5), .blue.opacity(0.4)][item.section]
  }
  private var flaggedBlocks: [DVFrameForensics.Block] {
    evidence.blocks.filter { ($0.videoSTA.map { $0 != 0 } ?? false) || $0.audioErrorCount > 0 }
  }
  private func chooseBlock(_ id: Int) {
    guard evidence.blocks.indices.contains(id) else { return }
    selectedBlock = id; selectedSequence = evidence.blocks[id].sequence; blockEntry = String(id)
    highlightedOffsets = evidence.blocks[id].section == 4 ? [evidence.blocks[id].sourceByteOffset + 3] : []
  }
  private func jumpToBlock() { if let id = Int(blockEntry) { chooseBlock(id) } }
  private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
  private func copyProvenance() {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(identity), let text = String(data: data, encoding: .utf8) { copy(text) }
  }
  private func fact(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.yellow)
      Text(value.isEmpty ? "Unavailable" : value).font(.caption).foregroundStyle(.white).textSelection(.enabled)
    }
  }
}
