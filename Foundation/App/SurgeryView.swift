// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif

struct SurgeryThumbnail: View {
  @ObservedObject var model: SurgeryModel
  let frame: Int
  @State private var image: CGImage?
  @State private var finished = false
  var body: some View {
    ZStack {
      Color.black
      if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
      else {
        VStack(spacing: 6) {
          Image(systemName: "film").font(.title3)
          Text(finished ? "Preview unavailable" : "Loading preview…").font(.caption2)
        }.foregroundStyle(.white.opacity(0.6))
      }
    }
    .task(id: "\(model.epoch)-\(frame)") {
      image = nil; finished = false
      let result = await model.thumbnail(frame)
      guard !Task.isCancelled else { return }
      image = result; finished = true
    }
    .accessibilityLabel("Source frame \(frame + 1) thumbnail")
  }
}

struct SurgeryView: View {
  @ObservedObject var model: SurgeryModel
  var playbackURL: URL?
  private let accent = Color.teal
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Label("SURGERY", systemImage: "scissors").font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
          Text("Precision cuts. Original quality.").font(.system(size: 28, weight: .semibold, design: .rounded))
          Text("Find the breaks. Cut a range or join selected segments. Keep the original quality.")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open clip…", systemImage: "folder") { model.choose() }
          .controlSize(.large).buttonStyle(.borderedProminent).tint(accent).disabled(model.busy || model.choosing)
          .accessibilityIdentifier("surgery-open")
      }
      if let clip = model.clip {
        editor(clip)
      } else {
        VStack(spacing: 18) {
          Image(systemName: "timeline.selection").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(accent)
          Text(model.busy ? "Mapping your clip" : "A clean cut starts here.").font(.title2.weight(.semibold))
          Text("Open a .dv file to see its format sections and recording breaks.\nNo sidecar files required.")
            .multilineTextAlignment(.center).foregroundStyle(.secondary)
          if let playbackURL, !model.busy {
            Button("Use Playback clip", systemImage: "arrow.turn.down.right") { model.open(playbackURL) }.controlSize(.large)
          }
          Text("DV25 · NTSC & PAL · Mixed-format clips").font(.caption.monospaced()).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 70)
          .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
      }
      if model.busy {
        HStack { ProgressView(value: model.progress).tint(accent); Button("Cancel") { model.cancel() } }
      }
      HStack {
        Label(model.status, systemImage: model.exportedURL == nil ? "info.circle" : "checkmark.seal.fill")
          .foregroundStyle(model.exportedURL == nil ? Color.secondary : accent)
        Spacer()
        if let url = model.exportedURL { Button("Show exports in Finder", systemImage: "folder") { NSWorkspace.shared.open(url) } }
      }.font(.callout).accessibilityIdentifier("surgery-status")
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
          .textSelection(.enabled).accessibilityIdentifier("surgery-error")
      }
      Text("Frame-aligned DV25 exports. HDV and multichannel DVCPRO editing are not available here yet. Recording breaks are suggestions from metadata, not visual scene detection.")
        .font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: 1400, alignment: .leading).padding(.top, 22)
  }

  private func editor(_ clip: DVSurgeryClip) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "film.stack").font(.title2).foregroundStyle(accent)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.sourceURL?.lastPathComponent ?? "Clip").font(.headline).lineLimit(1).truncationMode(.middle)
          Text("\(model.time(clip.timeline.durationSeconds))  ·  \(clip.timeline.frameCount.formatted()) frames  ·  \(ByteCountFormatter.string(fromByteCount: Int64(clip.timeline.byteCount), countStyle: .file))")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer()
        Label("LOSSLESS", systemImage: "checkmark.shield").font(.caption.bold()).foregroundStyle(accent)
          .padding(8).background(accent.opacity(0.1), in: Capsule())
      }
      HStack(alignment: .top, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          SurgeryThumbnail(model: model, frame: model.first).frame(height: 245).clipShape(RoundedRectangle(cornerRadius: 12))
          HStack {
            Text("IN · FRAME \(model.first + 1)")
            Spacer()
            Text(model.time(clip.seconds(model.first)))
          }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 14) {
          Text("RANGE EXPORT").font(.caption.bold()).tracking(1.5).foregroundStyle(.secondary)
          HStack(spacing: 12) {
            timeField("Start", text: $model.startText, id: "surgery-start")
            timeField("End", text: $model.endText, id: "surgery-end")
          }
          HStack {
            Button("Apply times") { model.applyTimes() }.accessibilityIdentifier("surgery-apply")
            Button("Entire clip") { model.select(first: 0, end: clip.timeline.frameCount) }
            Spacer()
          }
          Text("Times snap to the nearest complete frame. The end is exclusive.").font(.caption).foregroundStyle(.secondary)
          Divider()
          Toggle("Split at recording breaks", isOn: $model.splitScenes).toggleStyle(.checkbox)
            .accessibilityIdentifier("surgery-split-scenes")
          Text("Format changes always create separate files.").font(.caption).foregroundStyle(.secondary)
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("\(model.ranges.count) \(model.ranges.count == 1 ? "export" : "exports") · \((model.end - model.first).formatted()) frames").font(.headline)
              Text(model.time(clip.seconds(model.end) - clip.seconds(model.first)) + " selected").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export losslessly…", systemImage: "square.and.arrow.up") { model.chooseExport() }
              .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
              .disabled(model.ranges.isEmpty || model.hasUnappliedTimes).accessibilityIdentifier("surgery-export")
          }
        }.frame(maxWidth: .infinity)
      }.disabled(model.busy || model.choosing)
      SurgeryTimeline(model: model, clip: clip).zIndex(10).disabled(model.busy || model.choosing)
      HStack {
        Text("SEGMENTS").font(.caption.bold()).tracking(1.5)
        Text("\(clip.segments.count)").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(.primary.opacity(0.06), in: Capsule())
        Spacer()
        Text("Hover to preview · Click to set a range · Check to merge").font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Image(systemName: "rectangle.stack.badge.plus").font(.title2).foregroundStyle(accent)
          VStack(alignment: .leading, spacing: 4) {
            Text("\(model.selectedSegments.count) segments checked for merge").font(.headline)
            Text(model.mergeRanges.isEmpty ? "Check any segment cards below, including ones apart from each other." : "\(model.time(model.mergeRanges.reduce(0) { $0 + $1.endSeconds - $1.startSeconds })) · One file · Original timeline order")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
        HStack(spacing: 12) {
          Button("Select all") { model.selectAllSegments(true) }.accessibilityIdentifier("surgery-check-all")
          Button("Clear") { model.selectAllSegments(false) }.disabled(model.selectedSegments.isEmpty)
            .accessibilityIdentifier("surgery-check-clear")
          Spacer()
          Button("Merge selected…", systemImage: "arrow.triangle.merge") { model.chooseExport(merged: true) }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .disabled(model.mergeIssue != nil).accessibilityIdentifier("surgery-merge")
        }
        Text(model.mergeIssue ?? "Original picture, audio and recording metadata stay unchanged. Timecode may jump at joins.")
          .font(.caption).foregroundStyle(model.mergeIssue != nil && !model.selectedSegments.isEmpty ? Color.orange : .secondary)
      }.padding(16).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.busy || model.choosing)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 310), spacing: 14)], spacing: 14) {
        ForEach(Array(clip.segments.enumerated()), id: \.element.id) { index, segment in
          segmentCard(segment, index: index, clip: clip)
        }
      }.disabled(model.busy || model.choosing)
    }
  }
  private func timeField(_ title: String, text: Binding<String>, id: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
      TextField("HH:MM:SS.mmm", text: text).font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
        .onSubmit { model.applyTimes() }.accessibilityLabel(title + " time").accessibilityIdentifier(id)
    }
  }
  private func segmentCard(_ segment: DVSurgeryClip.Segment, index: Int, clip: DVSurgeryClip) -> some View {
    let selected = model.first == segment.first && model.end == segment.end
    return VStack(alignment: .leading, spacing: 0) {
      Button { model.select(first: segment.first, end: segment.end) } label: {
      VStack(alignment: .leading, spacing: 9) {
        SurgeryThumbnail(model: model, frame: segment.first).frame(height: 120).clipped()
          .overlay(alignment: .topLeading) {
            Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit().bold()).padding(6)
              .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white).padding(8)
          }
        VStack(alignment: .leading, spacing: 5) {
          Text(segment.format).font(.callout.weight(.semibold)).foregroundStyle(segment.format.contains("PAL") ? Color.teal : Color.indigo)
          Text(model.time(clip.seconds(segment.first)) + " – " + model.time(clip.seconds(segment.end)))
            .font(.caption.monospacedDigit()).foregroundStyle(.primary)
          Text(segment.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
        }.padding(.horizontal, 12).padding(.bottom, 12)
      }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("Segment \(index + 1), \(segment.format), \(segment.reason)")
        .accessibilityIdentifier("surgery-segment-\(index + 1)")
      Divider().padding(.horizontal, 12)
      Toggle("Include in merge", isOn: Binding(get: { model.selectedSegments.contains(segment.id) }, set: { _ in model.toggleSegment(segment.id) }))
        .toggleStyle(.checkbox).font(.caption.weight(.medium)).padding(12)
        .accessibilityLabel("Include segment \(index + 1) in merge")
        .accessibilityIdentifier("surgery-check-\(index + 1)")
    }.background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedSegments.contains(segment.id) ? accent : selected ? .primary.opacity(0.5) : .primary.opacity(0.1), lineWidth: model.selectedSegments.contains(segment.id) ? 2 : 1))
  }
}

private struct SurgeryTimeline: View {
  @ObservedObject var model: SurgeryModel
  let clip: DVSurgeryClip
  @State private var hover: Int?
  @State private var pointerX: CGFloat = 0
  private func fraction(_ frame: Int) -> Double { clip.seconds(frame) / clip.timeline.durationSeconds }
  private func segment(at x: CGFloat, width: CGFloat) -> Int {
    let time = min(1, max(0, x / max(1, width))) * clip.timeline.durationSeconds
    return clip.segments.lastIndex { clip.seconds($0.first) <= time } ?? 0
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("CLIP MAP").font(.caption.bold()).tracking(1.5)
        Spacer()
        Label("PAL", systemImage: "circle.fill").foregroundStyle(.teal)
        Label("NTSC", systemImage: "circle.fill").foregroundStyle(.indigo)
      }.font(.caption)
      GeometryReader { geometry in
        let width = geometry.size.width
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.04))
          ForEach(Array(clip.segments.enumerated()), id: \.element.id) { index, item in
            let left = fraction(item.first) * width, span = (fraction(item.end) - fraction(item.first)) * width
            let color = item.format.contains("PAL") ? Color.teal : Color.indigo
            Rectangle().fill(color.opacity(index % 2 == 0 ? 0.8 : 0.6))
              .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.6)).frame(width: 1) }
              .overlay {
                if span > 65 { Text("\(index + 1) · \(item.format.contains("PAL") ? "PAL" : "NTSC")").font(.caption.bold()).foregroundStyle(.white).lineLimit(1) }
              }
              .frame(width: max(1, span), height: 56).offset(x: left)
          }
          Rectangle().fill(.black.opacity(0.3)).frame(width: fraction(model.first) * width, height: 56).allowsHitTesting(false)
          Rectangle().fill(.black.opacity(0.3)).frame(width: (1 - fraction(model.end)) * width, height: 56).offset(x: fraction(model.end) * width).allowsHitTesting(false)
          ForEach(clip.segments.filter { model.selectedSegments.contains($0.id) }) { item in
            Rectangle().fill(.white).frame(width: max(2, (fraction(item.end) - fraction(item.first)) * width), height: 4)
              .offset(x: fraction(item.first) * width, y: 23).allowsHitTesting(false)
          }
          RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2)
            .frame(width: max(2, (fraction(model.end) - fraction(model.first)) * width), height: 60)
            .offset(x: fraction(model.first) * width).allowsHitTesting(false)
          .onChange(of: geometry.size) { _, _ in hover = nil }
      }.frame(height: 60).contentShape(Rectangle())
          .overlay {
            SurgeryTimelineTracking(onMove: { point in
              if let point { pointerX = point.x; hover = segment(at: point.x, width: width) }
              else { hover = nil }
            }, onSelect: { point in
              let s = clip.segments[segment(at: point.x, width: width)]
              model.select(first: s.first, end: s.end)
            })
          }
          .overlay(alignment: .topLeading) {
            if let hover {
              let s = clip.segments[hover]
              VStack(alignment: .leading, spacing: 7) {
                SurgeryThumbnail(model: model, frame: s.first).frame(width: 216, height: 130).clipShape(RoundedRectangle(cornerRadius: 7))
                Text("Segment \(hover + 1) · \(s.format)").font(.caption.bold())
                Text(model.time(clip.seconds(s.first)) + " – " + model.time(clip.seconds(s.end))).font(.caption2.monospacedDigit())
                Text(s.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
              }.padding(10).frame(width: 236, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.14)))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
                .offset(x: min(max(0, pointerX - 118), max(0, width - 236)), y: -228)
                .allowsHitTesting(false).accessibilityIdentifier("surgery-hover-preview")
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Clip map, \(clip.segments.count) segments. Use the segment buttons below to select a range.")
          .accessibilityIdentifier("surgery-timeline")
        .onChange(of: geometry.size) { _, _ in hover = nil }
      }.frame(height: 60)
      HStack { Text("00:00:00.000"); Spacer(); Text(model.time(clip.timeline.durationSeconds)) }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      HStack(spacing: 16) {
        boundarySlider("In", value: model.first, maximum: clip.timeline.frameCount - 1) { model.select(first: min($0, model.end - 1), end: model.end) }
        boundarySlider("Out", value: model.end, maximum: clip.timeline.frameCount) { model.select(first: model.first, end: max(model.first + 1, $0)) }
      }
    }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
      .onChange(of: model.epoch) { _, _ in hover = nil }
      .onDisappear { hover = nil }
  }
  private func boundarySlider(_ title: String, value: Int, maximum: Int, change: @escaping (Int) -> Void) -> some View {
    HStack {
      Text(title).font(.caption.bold()).frame(width: 26)
      Slider(value: Binding(get: { Double(value) }, set: { change(Int($0.rounded())) }), in: 0...Double(max(1, maximum)))
        .tint(.teal).accessibilityLabel(title + " frame boundary").accessibilityIdentifier("surgery-\(title.lowercased())-slider")
    }
  }
}

/// Native tracking retains immediate previews during mouse movement and drags,
/// including when SwiftUI reconciles a rapidly changing range selection.
private struct SurgeryTimelineTracking: NSViewRepresentable {
  var onMove: (CGPoint?) -> Void
  var onSelect: (CGPoint) -> Void
  func makeNSView(context: Context) -> TrackingView { TrackingView() }
  func updateNSView(_ view: TrackingView, context: Context) {
    view.onMove = onMove; view.onSelect = onSelect
  }
  final class TrackingView: NSView {
    var onMove: (CGPoint?) -> Void = { _ in }
    var onSelect: (CGPoint) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
      addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMove(nil) }
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      onMove(point); onSelect(point)
    }
  }
}
