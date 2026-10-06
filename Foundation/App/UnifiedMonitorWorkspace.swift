import AVFoundation
// RewindDV b3063ff workspace layout and meter presentation selectively adapted.
// No historical driver, capture helper, or duration policy is imported.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if canImport(RewindDVMonitorCore)
  import RewindDVMonitorCore
#endif

/// In-view hover help avoids the system tooltip delay. It never takes focus,
/// participates in layout, or intercepts a click intended for the control.
private struct TechnicalSpecificationRows: View {
  let sections: [DVTechnicalSpecifications.Section]
  let coverage: String
  var metadata: DVPackSemanticReport? = nil
  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(DVMetadataPresentation.summarySections(sections)) { section in
          VStack(alignment: .leading, spacing: 9) {
            Text(section.title).font(.headline)
            ForEach(section.rows) { row in
              VStack(alignment: .leading, spacing: 2) {
                Text(DVMetadataPresentation.inspectorLabel(row.label, section: section.title).uppercased())
                  .font(.caption2.bold()).foregroundStyle(.yellow)
                Text(row.value).font(.callout)
                  .foregroundStyle(row.isWarning ? Color.red : Color.primary)
                  .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                  .lineLimit(row.label == "Recorded date & time" ? 3 : nil)
                  .frame(height: row.label == "Recorded date & time" ? 66 : nil, alignment: .topLeading)
              }.frame(maxWidth: .infinity, alignment: .leading)
                .help(row.evidence).accessibilityElement(children: .combine)
                .accessibilityIdentifier("spec-" + section.title + "-" + row.label)
            }
          }
          Divider()
        }
        if let metadata { DVMetadataInspector(report: metadata) }
        Text(coverage).font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 5)
    }.frame(height: 510)
  }
}

private struct LiveTechnicalSpecificationsPanel: View {
  @ObservedObject var live: LiveMonitorModel
  @ObservedObject var metadata: LiveDVMetadata

  private func progress() -> [DVTechnicalSpecifications.Row] {
    var rows: [DVTechnicalSpecifications.Row] = []
    func add(_ label: String, _ value: String, _ evidence: String) {
      rows.append(.init(label: label, value: value, evidence: evidence))
    }
    add("Capture status", live.ingestRequested ? live.ingestDetail : "Monitoring only — no archival capture", "Capture state, separate from sampled source metadata.")
    if live.ingestRequested {
      add("Destination", live.verifiedCaptureURL?.path ?? live.flightURL?.path ?? "Preparing…", "Current capture destination, not a recorded tape property.")
      if let result = live.verification {
        add("Final DV file size", String(format: "%.2f MiB (%llu bytes)", Double(result.dvBytes) / 1_048_576, result.dvBytes), "Reconstructed native DV bytes from completed verification report; raw evidence is separate.")
        add("Final complete frames", String(result.completeDVFrames), "Completed reconstruction; not an exact lost-frame count.")
        let size: Int? = live.captureElapsed.conflictingSystems ? nil : live.captureElapsed.system.map { $0 == .pal625_50 ? 144_000 : 120_000 }
        add("Final DV duration", DVTechnicalSpecifications.completedDuration(bytes: result.dvBytes, frames: result.completeDVFrames, frameSize: size), "Calculated only after reconstruction, using complete frame count and a matching total byte count. Excludes gaps with no saved frames; distinct from PLAY elapsed.")
      } else {
        add(live.active ? "Raw evidence size so far" : "Last observed raw evidence size", metadata.rawFileBytes.map { String(format: "%.2f MiB", Double($0) / 1_048_576) } ?? "Unavailable — awaiting size observation", "Background filesystem length observation; includes packet-record headers. Not native DV file size or a durability guarantee. Last observed size after reception stops.")
        add("Complete frames received", String(live.completeFrames), "Receive assembly counter; final native DV file and totals await reconstruction and verification.")
      }
    }
    let elapsed = live.captureElapsed.display(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    add("PLAY elapsed", elapsed ?? "Awaiting PLAY status", "Monotonic observed PLAY-to-STOP interval, including gaps. Not the duration of saved DV media.")
    return rows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        if live.mediaFormats.requiresHDVExport {
          TechnicalSpecificationRows(sections: [
            .init(title: "HDV transport", rows: [
              .init(label: "Format", value: live.mediaFormats.isMixed ? "Mixed DV / HDV — raw evidence retained" : "MPEG-2 transport stream (HDV CIP)", evidence: "Source-bound CIP observations, not a camera-model assumption or decoder qualification."),
              .init(label: "HDV payload records", value: live.mediaFormats.hdvPayloadRecords.formatted(), evidence: "Received isochronous records containing supported MPEG CIP payload geometry; not video frames or 188-byte TS packets."),
              .init(label: "Capture", value: live.ingestDetail, evidence: "Raw preservation is independent of picture/audio decoding."),
              .init(label: "Preview", value: "HDV picture/audio preview not yet qualified", evidence: "DV preview tools and DIF metadata do not apply to HDV. The original transport stream is retained without transcoding.")
            ])
          ], coverage: "Experimental HDV ingest. Real 50 Hz and 60 Hz tape qualification is pending. No DV metadata is inferred from MPEG packets.")
        } else {
        Text(metadata.presentationStatus).font(.caption)
          .foregroundStyle(metadata.staleNow || metadata.report == nil ? .orange : .secondary)
          .accessibilityIdentifier("live-metadata-freshness")
        let progress = progress()
        let report = metadata.report?.liveReport(progress: progress)
        TechnicalSpecificationRows(sections: (report?.inspectorSections(apple: live.preview.appleGeometry,
          preview: (live.preview.displayAspect == .standard ? "4:3" : "16:9")
            + (live.preview.aspect == .source ? " — source-following preview" : " — user override"),
          appleScope: "Apple decoder output before preview overrides; frame \(live.preview.appleGeometryOrdinal.map(String.init) ?? "unknown"). Separate from the DV-pack sampling instant. \(live.preview.appleGeometryStatus).") ?? [
          .init(title: "General", rows: progress),
          .init(title: "Video", rows: [.init(label: "Metadata", value: "Unavailable — waiting for complete DV frame", evidence: "No values synthesized from the deck name.")]),
          .init(title: "Audio", rows: [.init(label: "Metadata", value: "Unavailable — waiting for complete DV frame", evidence: "No values synthesized from decoded monitor settings.")])
        ]) + DVTechnicalSpecifications.recordedMotionSections(report?.semanticReport), coverage: report?.coverage ?? "Metadata inspection never controls or blocks capture.", metadata: report?.semanticReport)
        .accessibilityIdentifier("capture-technical-specifications")
        }
      }
    }
  }
}


private struct PlaybackTechnicalSpecificationsPanel: View {
  @ObservedObject var playback: OfflineDVPlaybackModel
  @ObservedObject var metadata: PlaybackDVMetadata
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        // The status varies from a short paused message to a wrapped playback
        // observation. Reserve its full height so seeks cannot move the file
        // facts, Inspector card, or Reviewed export below the monitor row.
        Text(metadata.presentationStatus).font(.caption)
          .lineLimit(4).frame(height: 80, alignment: .topLeading)
          .accessibilityLabel(metadata.presentationStatus)
          .accessibilityIdentifier("playback-metadata-position")
      }
      if let specs = playback.technicalSpecifications {
        let current = specs.playbackReport(sampledFrame: metadata.specifications, timeline: playback.sourceTimeline)
        Text("Source values follow the identified frame").font(.caption)
        TechnicalSpecificationRows(sections: current.inspectorSections(apple: metadata.geometry,
          preview: playback.displayAspect == .standard ? "4:3" : "16:9",
          appleScope: "Apple decoder output for playback frame \(metadata.report?.frameOrdinal.description ?? "unknown"); not whole-file uniformity.")
            + (playback.sourceFileAudit?.sections ?? [.init(title: "Source error summary", rows: [.init(label: "Source audit", value: playback.sourceFileAuditStatus, evidence: "Background read-only assessment; never blocks playback.")])]),
          coverage: current.coverage, metadata: metadata.report)
          .accessibilityIdentifier("playback-technical-specifications")
      } else { Text(playback.technicalSpecificationsStatus).font(.caption) }
    }
  }
}

private struct ImmediatePreviewHelp: ViewModifier {
  let text: String
  @State private var hovering = false
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .overlay(alignment: .topLeading) {
        if hovering {
          Text(text).font(.callout).foregroundStyle(.primary)
            .frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            // Explicit alpha-one sRGB fill: never a vibrancy/material surface.
            .padding(12).background(
              colorScheme == .dark
                ? Color(.sRGB, white: 0.13, opacity: 1)
                : Color(.sRGB, white: 0.98, opacity: 1),
              in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.3)))
            .shadow(radius: 5, y: 2).offset(y: 46)
            .allowsHitTesting(false).accessibilityHidden(true)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
      }
      .accessibilityHint(text)
      .zIndex(hovering ? 10 : 0)
      .onDisappear { hovering = false }
  }
}

// Keep per-frame observation local. The driver/ingest workspace need not be
// rebuilt whenever its video clock advances or an audio meter changes.
private struct WholeTapePhysicalStopConfirmation: View {
  @ObservedObject var wholeTape: WholeTapeCaptureModel
  @State private var confirming = false

  var body: some View {
    Button("Already stopped with the deck’s physical STOP? Finish receiving…") { confirming = true }
      .accessibilityIdentifier("whole-tape-physical-stop")
      .confirmationDialog("Is the tape physically stopped?", isPresented: $confirming) {
        Button("Tape is physically stopped — save and verify") { wholeTape.finishAfterPhysicalStop() }
      } message: {
        Text("Use this only after the deck has physically stopped. It ends reception and saves remaining data without sending another tape command.")
      }
  }
}

private struct LiveSourceTimecode: View {
  @ObservedObject var preview: LiveDVPreview
  var body: some View { Text(preview.sourceTimecode ?? "--:--:--:--") }
}

private struct PlaybackPresentationView<Content: View>: View {
  @ObservedObject var updates: OfflineDVPlaybackPresentation
  @ViewBuilder var content: () -> Content
  var body: some View { content() }
}

// Drag position belongs to this small subtree, not the entire workspace.
// Decoder publication advances the timecode separately; the handle follows
// the pointer immediately and keeps its final target until decoding catches up.
private struct PlaybackTimeline: View {
  let playback: OfflineDVPlaybackModel
  @ObservedObject var updates: OfflineDVPlaybackPresentation
  let enabled: Bool
  @State private var scrubPosition: Double?
  @State private var isScrubbing = false

  var body: some View {
    HStack(spacing: 8) {
      Text(MonitorCounter.elapsed(seconds: playback.currentTimeSeconds))
      InstantPlaybackScrubber(
        value: Binding(
          get: { scrubPosition ?? playback.currentTimeSeconds },
          set: { scrubPosition = $0; playback.seek(to: $0) }),
        duration: max(0.001, playback.durationSeconds),
        onEditingChanged: { editing in
          isScrubbing = editing
          if !editing { releaseCompletedTarget() }
        })
        .accessibilityLabel("Playback position").disabled(!enabled)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
      Text(MonitorCounter.elapsed(seconds: playback.durationSeconds))
    }
    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    .onChange(of: playback.currentTimeSeconds) { _, _ in
      if !isScrubbing { releaseCompletedTarget() }
    }
    .onChange(of: playback.sourceURL) { _, _ in
      scrubPosition = nil; isScrubbing = false
    }
  }

  private func releaseCompletedTarget() {
    if let target = scrubPosition, abs(playback.currentTimeSeconds - target) < 0.05 {
      scrubPosition = nil
    }
  }
}

private struct LivePreviewPresentationView<Content: View>: View {
  @ObservedObject var preview: LiveDVPreview
  @ViewBuilder var content: () -> Content
  var body: some View { content() }
}

private struct CaptureElapsedDisplay: View {
  @ObservedObject var live: LiveMonitorModel
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !live.captureElapsedRunning)) { context in
      HStack(spacing: 5) {
        if live.captureElapsedRecordingActive {
          Circle().fill(.red).frame(width: 6, height: 6)
            .opacity(0.6 + 0.4 * (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi) + 1) / 2)
            .accessibilityLabel("Recording")
        }
        Text("Time elapsed " + (live.captureElapsed.display(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) ?? "00:00:00:00"))
      }
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("capture-elapsed-time")
    .help("Approximate elapsed tape-play time. Starts on observed PLAY and holds after observed STOP. Red indicator means packet capture is active.")
  }
}

private struct LivePictureSurface: View {
  @ObservedObject var preview: LiveDVPreview
  var body: some View {
    MonitorVideoSurface(displayLayer: preview.displayLayer,
      inspectionMode: preview.viewingMode != .standard || preview.extremeZebras,
      overrideDisplayAspect: true, zoom: preview.zoom, center: preview.zoomCenter)
      .accessibilityHidden(true)
      .aspectRatio(preview.displayAspectRatio, contentMode: .fit).padding(2)
      .overlay {
        if let message = preview.signalState.message {
          VStack(spacing: 8) {
            Image(systemName: "waveform.path").font(.title2)
            Text(message).font(.headline)
            Text("Monitoring remains active and resumes automatically.\nSignal status does not establish tape motion.")
              .font(.callout).multilineTextAlignment(.center)
            if preview.hasImage { Text("Last received picture held").font(.caption) }
          }
          .foregroundStyle(.white).padding(20)
          .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
          .padding(16).allowsHitTesting(false)
        }
      }
  }
}

// AppKit gives both segments equal, explicit hit areas. SwiftUI's segmented
// Picker otherwise keeps its small intrinsic control centered in a wider frame.
private struct WorkspaceModeSelector: NSViewRepresentable {
  @Binding var selection: MonitorSource
  var isEnabled: Bool

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: MonitorSource.allCases.map(\.rawValue), trackingMode: .selectOne,
      target: context.coordinator, action: #selector(Coordinator.selectMode(_:)))
    control.segmentStyle = .rounded
    control.segmentDistribution = .fill
    control.controlSize = .large
    control.font = .systemFont(ofSize: 16, weight: .semibold)
    for index in MonitorSource.allCases.indices { control.setWidth(128, forSegment: index) }
    control.setAccessibilityLabel("Workspace mode")
    control.setAccessibilityIdentifier("monitor-source")
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.selection = $selection
    control.selectedSegment = MonitorSource.allCases.firstIndex(of: selection) ?? 0
    control.isEnabled = isEnabled
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
    CGSize(width: 390, height: 36)
  }

  @MainActor final class Coordinator: NSObject {
    var selection: Binding<MonitorSource>
    init(selection: Binding<MonitorSource>) { self.selection = selection }
    @objc func selectMode(_ control: NSSegmentedControl) {
      guard control.isEnabled, MonitorSource.allCases.indices.contains(control.selectedSegment) else { return }
      selection.wrappedValue = MonitorSource.allCases[control.selectedSegment]
    }
  }
}

struct UnifiedMonitorWorkspace: View {
  @ObservedObject var model: RewindDVModel
  @ObservedObject var installer: SystemExtensionInstaller
  @ObservedObject var playback: OfflineDVPlaybackModel
  @ObservedObject var live: LiveMonitorModel
  @ObservedObject var wholeTape: WholeTapeCaptureModel
  @State private var showCounter = false
  @State private var liveRasterHeight = 480
  @State private var viewingMode: DVViewingMode = .standard
  @State private var confirmPhysicalStop = false
  @State private var playbackOpenPanel: NSOpenPanel?
  @StateObject private var rangeReview = ReviewedRangeModel()
  @ObservedObject var surgery: SurgeryModel

  private var source: MonitorSource { model.monitorSource }

  private var busy: Bool { model.isBusy || model.wholeTapeActive || installer.isInFlight }
  private var sourceChangeLocked: Bool {
    busy || rangeReview.isBusy || surgery.busy || surgery.choosing || live.active || live.busy || live.lockedOut || model.controlLockedOut || model.requiresSupervisedStop
  }
  private var policy: WorkspaceCapabilities {
    WorkspaceCapabilities(
      source: source, fileReady: playback.canPlay || playback.canPause,
      filePlaying: playback.canPause, deckSelected: model.selectedDeck != nil,
      busy: busy || (source == .file && (playback.isLoading || rangeReview.isBusy || rangeReview.isEditingFields)),
      lockedOut: model.controlLockedOut || live.lockedOut, requiresSupervisedStop: model.requiresSupervisedStop,
      fastForwardSupported: model.fastForwardAvailable,
      liveMonitoring: live.active && !live.busy, ingestActive: live.ingestRequested && (live.active || live.busy),
      shuttleForwardSupported: model.capabilityReport?.permits(.shuttleForward, on: model.selectedRoute) == true,
      shuttleReverseSupported: model.capabilityReport?.permits(.shuttleReverse, on: model.selectedRoute) == true)
  }

  var body: some View {
    GeometryReader { viewport in
    let workspaceWidth = viewport.size.width
    ScrollViewReader { scroll in
    ScrollView([.horizontal, .vertical]) {
      VStack(alignment: .leading, spacing: 10) {
        header
        if source == .surgery {
          SurgeryView(model: surgery, playbackURL: playback.sourceURL)
        } else {
        // Identical reserved height in both modules; options never move the
        // preview or meters when toggled, and sidebar expansion is independent.
        viewingControls.frame(width: 720, height: 82, alignment: .topLeading).zIndex(2)
        HStack(alignment: .top, spacing: 18) {
          monitor.frame(width: 720)
          HStack(alignment: .top, spacing: 18) {
            meters.frame(width: 214)
            // A permanent peer of Audio levels in both modules. Keep the
            // section's own info-circle heading; no duplicate disclosure row.
            inspector.frame(width: 240)
              .accessibilityIdentifier("workspace-inspector")
          }
        }
        if source == .deck {
          CollapsibleWorkspaceSection(title: "Ingest and verification", identifier: "ingest-details") {
            ingestStatus
          }
        } else if playback.hasLoadedFile {
          ReviewedRangeView(review: rangeReview, playback: playback)
        }
        // Routine status/evidence lives on Diagnostics. Actionable warnings and
        // the receive-only escape hatch must remain reachable during capture,
        // when sidebar navigation is intentionally locked.
        statusNotice
        HStack(spacing: 8) {
          Image(systemName: "lock.shield")
          Text("The source tape is never modified. Tape record and erase are never available.")
          Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(width: max(source == .surgery ? 720 : 1210, workspaceWidth - 44), alignment: .leading)
      .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 22)
      .fixedSize(horizontal: false, vertical: true)
      // A short Capture page and a taller Playback page share one origin.
      // Otherwise the two-axis scroll view can center the shorter content.
      .frame(minHeight: viewport.size.height, alignment: .topLeading)
      .id("workspace-origin")
    }
    .defaultScrollAnchor(.topLeading)
    .onChange(of: source) { _, _ in
      // Never carry a lower-page scroll offset into the other module, or
      // animate its monitor/meter row into place as the content height changes.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        scroll.scrollTo("workspace-origin", anchor: .topLeading)
      }
    }
    }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("workspace-page")
    .onAppear { viewingMode = playback.viewingMode }
    .onReceive(live.preview.$rasterHeight) { liveRasterHeight = $0 }
    .onChange(of: source) { _, _ in
      // Source switches change presentation only; never dispatch deck commands.
      playback.pause()
      if source == .file && playback.consumeInitialFilePickerRequest() {
        // Present after the new module's view/state bindings have been installed.
        DispatchQueue.main.async { chooseFile() }
      }
    }
    .onChange(of: playback.sourceURL) { _, _ in rangeReview.reset() }
    .onDisappear {
      rangeReview.reset()
      playback.pause()
      // Navigation/layout disappearance is not operator STOP or a receive fault.
      // The session owner, not the view lifetime, ends live monitoring/ingest.
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      moduleSelector
      HStack {
        if source == .deck {
          deckConnection
        } else if source == .file {
          Button("Open DV…", systemImage: "folder") { chooseFile() }
            .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
            .fixedSize(horizontal: true, vertical: true)
            .disabled(busy || playback.isLoading || rangeReview.isBusy)
            .accessibilityIdentifier("open-dv")
          if playback.hasLoadedFile {
            Button("Close file", systemImage: "xmark") { playback.close() }
              .labelStyle(.iconOnly).disabled(busy || rangeReview.isBusy)
              .accessibilityIdentifier("close-dv")
          }
        }
        Spacer()
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: 44)
  }

  private var moduleSelector: some View {
      WorkspaceModeSelector(selection: Binding(
        get: { model.monitorSource },
        set: { selection in
          guard !sourceChangeLocked, selection != source else { return }
          model.monitorSource = selection
        }), isEnabled: !sourceChangeLocked)
      .frame(width: 390, height: 36, alignment: .leading)
  }

  private var viewingControls: some View {
    LivePreviewPresentationView(preview: live.preview) {
    VStack(alignment: .center, spacing: 0) {
      Spacer(minLength: 0)
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("VIDEO VIEW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          Picker("", selection: $viewingMode) {
            ForEach(DVViewingMode.allCases) {
              Text($0.rawValue).tag($0).help($0.explanation)
            }
          }.pickerStyle(.menu).labelsHidden().frame(width: 230, alignment: .leading)
            .accessibilityLabel("Video view")
            .accessibilityIdentifier("video-view-mode")
        }.frame(width: 230, alignment: .leading)
          .modifier(ImmediatePreviewHelp(text: viewingMode.explanation))
        Group {
          VStack(alignment: .leading, spacing: 4) {
            Text("ZOOM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Zoom", selection: Binding(get: { previewZoom }, set: {
              if source == .file { playback.setZoom($0) } else { live.preview.setZoom($0) }
            })) {
              ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag(CGFloat($0)) }
            }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("playback-zoom")
          }.frame(width: 160, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            Text("ASPECT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Display aspect", selection: Binding(
              get: { source == .file ? playback.displayAspect : live.preview.displayAspect }, set: {
                if source == .file { playback.setDisplayAspect($0) } else { live.preview.setDisplayAspect($0) }
              })) {
                ForEach(DVDisplayAspect.allCases) { Text($0.rawValue).tag($0) }
              }.labelsHidden().pickerStyle(.segmented)
              .accessibilityIdentifier("playback-display-aspect")
          }.frame(width: 100, alignment: .leading)
            .modifier(ImmediatePreviewHelp(text: "View as 4:3 or 16:9. Starts from reported source flags; overriding it never changes captured or exported DV."))
          VStack(alignment: .leading, spacing: 4) {
            Text("HIGHLIGHT/SHADOW CLIP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Highlight/shadow clip", isOn: Binding(
              get: { source == .file ? playback.extremeZebras : live.preview.extremeZebras }, set: {
                if source == .file { playback.setExtremeZebras($0) } else { live.preview.setExtremeZebras($0) }
              }))
              .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("playback-extreme-zebras")
          }.frame(width: 170, alignment: .leading)
            .modifier(ImmediatePreviewHelp(text: "Suspected clipping only: solid bright red covers decoded luma 255; solid bright purple covers 0. Superwhite/subblack detail is unmarked. This is not proof of unrecoverable detail. Display only; original DV is unchanged."))
        }
      }.controlSize(.small).frame(maxWidth: .infinity, alignment: .center)
        .disabled(source == .deck && live.mediaFormats.requiresHDVExport)
        // A child's zIndex only orders its siblings inside this row. Raise
        // the row too, so the later preview notice cannot paint over its help.
        .zIndex(1)
      Spacer(minLength: 0)
      Text(source == .deck && live.mediaFormats.requiresHDVExport
        ? "PREVIEW ONLY - ORIGINAL CAPTURE IS UNCHANGED"
        : "PREVIEW ONLY - ORIGINAL DV FILE IS UNCHANGED")
        .font(.caption2).foregroundStyle(.secondary).frame(height: 14)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("preview-only-notice")
    }
    }
    .onChange(of: viewingMode) { _, mode in
      playback.setViewingMode(mode)
      live.preview.viewingMode = mode
      Task { await live.preview.refreshHeldGeometry() }
    }
  }

  private var monitor: some View {
    VStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(.black)
        if source == .file && playback.hasLoadedFile {
          MonitorVideoSurface(displayLayer: playback.displayLayer,
            inspectionMode: viewingMode != .standard || playback.extremeZebras,
            overrideDisplayAspect: true,
            zoom: playback.zoom, center: playback.zoomCenter)
            .accessibilityHidden(true)
            .aspectRatio(playback.displayAspectRatio, contentMode: .fit)
            .padding(2)
            .overlay(alignment: .topTrailing) {
              if playback.zoom > 1 { zoomNavigator.padding(10) }
            }
        } else if source == .deck && live.mediaFormats.requiresHDVExport {
          VStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 34))
            Text("HDV / MPEG-2 transport detected").font(.headline)
            Text(live.active ? "Raw reception continues. HDV picture and audio preview are not yet available in this candidate." : "Reception ended. Review the HDV verification result below.")
              .multilineTextAlignment(.center)
            Text("Preview availability never controls capture.").font(.caption)
          }.foregroundStyle(.white).padding(24)
        } else if source == .deck && (live.active || live.preview.hasImage) {
          LivePictureSurface(preview: live.preview)
            .overlay(alignment: .topTrailing) {
              LivePreviewPresentationView(preview: live.preview) {
                if live.preview.zoom > 1 { zoomNavigator.padding(10) }
              }
            }
        } else {
          VStack(spacing: 12) {
            Image(systemName: source == .deck ? "video.slash" : "film")
              .font(.system(size: 34, weight: .light))
            Text(source == .deck ? "Press Play to monitor the deck" : "Open a recorded DV file")
              .font(.headline)
            Text(
              source == .deck
                ? "Select the deck and press Play. Live picture, source timecode and audio follow automatically."
                : "Native playback, source metadata and four-channel metering."
            )
            .font(.callout).multilineTextAlignment(.center)
          }
          .foregroundStyle(.white.opacity(0.72)).padding(24)
        }
        if source == .file && playback.isLoading { ProgressView().controlSize(.large).tint(.white) }
      }
      // A source-system change affects decoded pixels, never the playback layout.
      .frame(width: 720, height: source == .file ? 576 : (liveRasterHeight == 576 ? 576 : 480))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
      .onTapGesture {
        if source == .file && !playback.hasLoadedFile { chooseFile() }
      }
      .accessibilityAction(named: "Open recorded DV") {
        if source == .file && !playback.hasLoadedFile { chooseFile() }
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard !sourceChangeLocked, !playback.isLoading, urls.count == 1,
          let url = urls.first, url.isFileURL,
          url.pathExtension.lowercased() == "dv" else { return false }
        model.monitorSource = .file
        playback.open(url: url)
        return true
      }
      HStack(spacing: 22) {
        transport.frame(width: 345)
        if source == .file { playbackTimeDisplay } else { timeDisplay }
      }.frame(maxWidth: .infinity, alignment: .center)
      if source == .deck {
        captureActions
        transportNotices
        if live.receiverFailedWithoutTapeStopProof {
          notice("Check the deck — physical STOP may be required", live.tapeStopFeedback, .red)
            .accessibilityIdentifier("receive-fault-physical-stop-warning")
        }
        if let hdv = live.hdvVerification {
          VStack(alignment: .leading, spacing: 10) {
            Label("HDV capture complete — saved bytes verified",
              systemImage: hdv.needsLossReview ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.headline)
            Text("Original MPEG-2 transport stream saved without transcoding. Review the HDV verification report for continuity, packet errors and incomplete fragments.").font(.callout)
            Text("\(hdv.transportPacketCount.formatted()) TS packets · \(hdv.transportBytes.formatted()) bytes · \(hdv.knownDroppedPackets.formatted()) known dropped isochronous packets").font(.callout)
            Text("Saved-byte verification does not establish pristine tape content or HDV hardware qualification.").font(.caption).foregroundStyle(.secondary)
            if let url = live.verifiedCaptureURL {
              Button("Show HDV file in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              }.buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.55), lineWidth: 2))
            .accessibilityIdentifier("hdv-ingest-completion-summary")
        } else if let progress = live.hdvVerificationProgress {
          VStack(alignment: .leading, spacing: 10) {
            Label("DO NOT QUIT OR DISCONNECT THE CAPTURE DRIVE", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
            Text("Reconstructing, synchronizing and independently rereading the native HDV transport stream and its evidence.")
            if let fraction = progress.fractionCompleted {
              ProgressView(value: fraction).tint(.orange)
            } else { ProgressView().controlSize(.small) }
            if let eta = live.verificationETASeconds {
              Text("Estimated remaining: \(Int(eta.rounded())) seconds").font(.caption)
            } else { Text("Estimating time remaining…").font(.caption) }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("hdv-ingest-verification-progress")
        } else if let result = live.verification {
          VStack(alignment: .leading, spacing: 10) {
            Label(result.completionHeadline,
              systemImage: result.needsLossReview ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.headline)
            Text("\(result.completeDVFrames.formatted()) complete frames saved · \(result.knownDroppedPackets) known dropped packets · \(result.incompleteFrames) incomplete frames · \(result.CIPDiscontinuities) continuity events")
              .font(.callout)
            Text("Saved bytes verified. Exact missing-frame count and source recording quality remain unknown.")
              .font(.caption).foregroundStyle(.secondary)
            Text(result.completionContext)
              .font(.caption).foregroundStyle(.secondary)
            if let captureURL = live.verifiedCaptureURL {
              Button("Open in Playback", systemImage: "play.rectangle.fill") {
                openVerifiedCapture(captureURL)
              }
              .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
              .disabled(live.busy || wholeTape.active)
              .accessibilityIdentifier("open-verified-capture")
            }
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.55), lineWidth: 2))
          .accessibilityIdentifier("ingest-completion-summary")
        } else if let progress = live.verificationProgress {
          VerificationProgressBanner(
            progress: progress, etaSeconds: live.verificationETASeconds,
            elapsedSeconds: live.verificationElapsedSeconds,
            volumeName: live.ingestDestinationVolumeName)
        } else if live.ingestRequested && !live.active && !live.busy {
          notice("Capture needs attention", live.ingestDetail, .orange)
        }
      }
      if source == .file && playback.hasLoadedFile {
        PlaybackTimeline(playback: playback, updates: playback.presentation,
          enabled: policy.allows(.beginning))
      }
    }
  }

  private var zoomNavigator: some View {
    let width: CGFloat = 160
    let height = width / (source == .file ? playback.displayAspectRatio : live.preview.displayAspectRatio)
    return ZStack(alignment: .topLeading) {
      MonitorVideoSurface(displayLayer: source == .file ? playback.navigatorLayer : live.preview.navigatorLayer,
        overrideDisplayAspect: true)
        .allowsHitTesting(false).accessibilityHidden(true)
      Rectangle().stroke(.red, lineWidth: 1)
        .frame(width: width / previewZoom, height: height / previewZoom)
        .offset(x: (previewZoomCenter.x - 0.5 / previewZoom) * width,
          y: (previewZoomCenter.y - 0.5 / previewZoom) * height)
        .allowsHitTesting(false)
    }
    .frame(width: width, height: height)
    .background(.black).clipShape(Rectangle())
    .overlay(Rectangle().stroke(.white.opacity(0.65), lineWidth: 1))
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0).onChanged { event in
      setPreviewZoomCenter(CGPoint(x: event.location.x / width, y: event.location.y / height))
    })
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Zoom navigator")
    .accessibilityValue("\(Int(previewZoom)) times zoom")
    .accessibilityIdentifier("playback-zoom-navigator")
    .accessibilityAction(named: "Pan left") { panZoom(dx: -0.1, dy: 0) }
    .accessibilityAction(named: "Pan right") { panZoom(dx: 0.1, dy: 0) }
    .accessibilityAction(named: "Pan up") { panZoom(dx: 0, dy: -0.1) }
    .accessibilityAction(named: "Pan down") { panZoom(dx: 0, dy: 0.1) }
    .accessibilityAction(named: "Center") { setPreviewZoomCenter(CGPoint(x: 0.5, y: 0.5)) }
  }

  private var previewZoom: CGFloat { source == .file ? playback.zoom : live.preview.zoom }
  private var previewZoomCenter: CGPoint { source == .file ? playback.zoomCenter : live.preview.zoomCenter }
  private func setPreviewZoomCenter(_ point: CGPoint) {
    if source == .file { playback.setZoomCenter(point) } else { live.preview.setZoomCenter(point) }
  }

  private func panZoom(dx: CGFloat, dy: CGFloat) {
    setPreviewZoomCenter(CGPoint(x: previewZoomCenter.x + dx, y: previewZoomCenter.y + dy))
  }

  private var playbackTimeDisplay: some View {
    PlaybackPresentationView(updates: playback.presentation) {
      VStack(spacing: 3) {
        Button { showCounter.toggle() } label: {
          HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
              Text(showCounter ? "CLIP" : "SOURCE")
              Text(showCounter ? "COUNTER" : "TIMECODE")
            }.font(.system(size: 9, weight: .semibold, design: .monospaced))
              .foregroundStyle(.secondary).fixedSize().frame(width: 55, alignment: .trailing)
              .offset(x: 8)
            Text(showCounter ? MonitorCounter.elapsed(seconds: playback.currentTimeSeconds)
              : playback.sourceTimecodeText ?? "--:--:--:--")
              .font(.system(size: 25, weight: .medium, design: .monospaced)).monospacedDigit()
              .fixedSize().frame(width: 200)
          }
        }.buttonStyle(.plain).accessibilityIdentifier("monitor-time-display")
          .help("Switch between recorded source timecode and elapsed clip counter. Unknown timecode is never synthesized.")
        HStack(spacing: 10) {
          Color.clear.frame(width: 55, height: 1).accessibilityHidden(true)
          Text(playback.hasLoadedFile ? playback.frameCounterDescription : "No file selected")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 200)
        }
      }.frame(width: 275)
    }
  }

  private var timeDisplay: some View {
    VStack(spacing: 3) {
      HStack(spacing: 10) {
        VStack(alignment: .trailing, spacing: 1) {
          Text(live.active || live.busy ? "SOURCE" : "DECK")
          Text("TIMECODE")
        }.font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary).fixedSize().frame(width: 55, alignment: .trailing).offset(x: 8)
        Group {
          if live.active || live.busy {
            LiveSourceTimecode(preview: live.preview)
          } else {
            Text(model.deckTimecode.text ?? "--:--:--:--")
          }
        }
          .font(.system(size: 25, weight: .medium, design: .monospaced)).monospacedDigit()
          .fixedSize().frame(width: 200)
      }.accessibilityIdentifier("monitor-time-display")
      HStack(spacing: 10) {
        Color.clear.frame(width: 55, height: 1).accessibilityHidden(true)
        VStack(spacing: 1) {
          CaptureElapsedDisplay(live: live)
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(live.active || live.busy ? "Video-frame timecode" :
              model.deckTimecode.label(at: DispatchTime.now().uptimeNanoseconds))
              .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
              .help(live.active || live.busy ? "Timecode from received DV frames" :
                model.deckTimecode.label(at: DispatchTime.now().uptimeNanoseconds)
                  + ". Read-only sampled position; frame rate/drop-frame flag not reported.")
          }
        }.frame(width: 200)
      }
    }.frame(width: 275)
  }

  private var transport: some View {
    VStack(spacing: 10) {
      HStack(spacing: 9) {
        if source == .file {
          transportButton("Beginning", "backward.end.fill", .beginning) { playback.seek(to: 0) }
          transportButton("Previous frame", "backward.frame.fill", .stepBackward) {
            playback.stepFrames(-1)
          }
          .keyboardShortcut(.leftArrow, modifiers: [])
          .help("Previous frame (←)")
        } else if live.active {
          transportButton("Reverse picture search", "backward.fill", .shuttleReverse) {
            model.send(.shuttleReverse, duringLiveMonitoring: true)
          }.disabled(live.busy || live.ingestRequested)
        } else {
          transportButton("Rewind tape", "backward.fill", .rewind) { model.send(.rewind) }
            .disabled(live.active || live.busy)
        }
        if source == .file && playback.canPause {
          transportButton("Pause playback", "pause.fill", .pause) { playback.pause() }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play/Pause (Space)")
        } else if source == .file {
          transportButton("Play file", "play.fill", .play) { playback.play() }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play/Pause (Space)")
        } else {
          transportButton("Play tape", "play.fill", .play) {
            guard !live.busy, !live.lockedOut, let deck = model.selectedDeck,
              let route = model.selectedRoute else { return }
            if live.active {
              guard !live.ingestRequested else { return }
              model.send(.play, duringLiveMonitoring: true,
                onAccepted: {
                  live.observeCaptureTransportPlaying(bridge: model.bridge, deck: deck, route: route)
                })
            } else {
              // Swift 6 forward-matches an unlabeled closure to beforeSubmission.
              // Receiver startup must follow the consumed, accepted PLAY result.
              model.send(.play, onAccepted: {
                live.start(bridge: model.bridge, deck: deck, expectedRoute: route)
                live.observeCaptureTransportPlaying(bridge: model.bridge, deck: deck, route: route)
              })
            }
          }
          .disabled(live.busy || (live.active && live.ingestRequested))
        }
        if source == .deck {
          if wholeTape.active {
            // The job owns FCP. Request cancellation through it, never through
            // the ordinary busy-gated transport or a concurrent bridge call.
            Button { wholeTape.requestStop() } label: {
              Label("Stop automated capture", systemImage: "stop.fill")
                .labelStyle(.iconOnly).frame(width: 34, height: 24)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .accessibilityLabel("Stop automated capture")
            .accessibilityIdentifier("transport-stop")
            .help("Stop this job, confirm the tape has stopped, then save and verify the captured data.")
            .disabled(!wholeTape.canRequestStop)
          } else {
            transportButton("Stop tape", "stop.fill", .stop) {
              live.cancelPendingIngestPlay()
              guard let deck = model.selectedDeck, let route = model.selectedRoute else { return }
              model.send(.stop, beforeSubmission: { await live.prepareForOperatorStop() }, onAccepted: {
                live.stopAfterTapeResponse(bridge: model.bridge, deck: deck, route: route) {
                  model.wholeTapeStopObserved()
                }
              })
            }.disabled(live.awaitingTapeStop)
          }
          if live.active {
            transportButton("Forward picture search", "forward.fill", .shuttleForward) {
              model.send(.shuttleForward, duringLiveMonitoring: true)
            }.disabled(live.busy || live.ingestRequested)
          } else {
            transportButton("Fast-forward tape", "forward.fill", .fastForward) { model.send(.fastForward) }
              .disabled(live.active || live.busy)
          }
        }
        if source == .file {
          transportButton("Next frame", "forward.frame.fill", .stepForward) {
            playback.stepFrames(1)
          }
          .keyboardShortcut(.rightArrow, modifiers: [])
          .help("Next frame (→)")
          transportButton("End", "forward.end.fill", .end) {
            playback.seek(to: playback.durationSeconds)
          }
        }
      }
      .controlSize(.large)
    }
  }

  private var captureActions: some View {
    HStack(spacing: 12) {
        if source == .deck {
          Button { chooseWholeTapeDestination() } label: {
            Text("Automated Whole Tape Capture").font(.callout.weight(.semibold)).frame(height: 24)
          }
          .buttonStyle(.borderedProminent).tint(.blue)
          .disabled(!policy.allows(.play) || live.active || live.busy || live.lockedOut || wholeTape.active)
          .accessibilityIdentifier("capture-whole-tape")
          .help("Rewinds toward tape beginning, captures through missing data, and finishes after the deck reports stopped. Boundaries are inferred; physical STOP can look the same as tape end.")
          Button { chooseIngestDestination() } label: {
            Text("Manual Capture").font(.callout.weight(.semibold)).frame(height: 24)
          }
          .buttonStyle(.borderedProminent).tint(.blue)
          .disabled(!policy.allows(.play) || live.active || live.busy || live.lockedOut)
          .accessibilityIdentifier("start-ingest")
          .help("Manually capture from the current tape position. Choose a destination to begin, then press Stop to finish capture.")
        }

    }.controlSize(.large).frame(maxWidth: .infinity, alignment: .center)
  }

  private var transportNotices: some View {
    VStack(spacing: 10) {
      if source == .deck {
        CaptureStartAdmissionNotice(live: live)
        if wholeTape.active {
          VStack(alignment: .leading, spacing: 8) {
            Text(wholeTape.status).font(.callout.weight(.semibold))
              .accessibilityIdentifier("whole-tape-active-status")
            if wholeTape.canConfirmPhysicalStop {
              WholeTapePhysicalStopConfirmation(wholeTape: wholeTape)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
          .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        Text("One command per click. No queued commands or automatic retries.")
          .font(.caption).foregroundStyle(.secondary)
        if live.active {
          Text(live.ingestRequested ? "Picture search is unavailable during archival ingest." :
            "During monitoring, the arrow buttons search the picture; Play returns to normal playback. Availability follows the deck’s capability replies.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func transportButton(
    _ title: String, _ symbol: String, _ action: MonitorAction,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: {
      guard policy.allows(action) else { return }
      perform()
    }) {
      Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 34, height: 24)
    }
    .buttonStyle(.bordered).tint(action == .stop ? .red : .accentColor)
    .help(title).accessibilityLabel(title)
    .accessibilityIdentifier("transport-\(action.accessibilityID)")
    .disabled(!policy.allows(action))
  }

  private var meters: some View {
    RewindDVSection {
      VStack(alignment: .leading, spacing: 12) {
        Text("Sample peak · RMS · peak hold").font(.caption2).foregroundStyle(.secondary)
        TimelineView(
          .animation(minimumInterval: 1.0 / 30.0, paused: source == .file ? !playback.canPause : !live.active)
        ) { _ in
          MeterBank(presentation: source == .file ? playback.meterPresentation : live.preview.audio.presentation)
        }
        Text(source == .file ? playback.audioDescription : live.preview.audio.detail)
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Monitor measurements only—not source verification or true-peak measurements.")
          .font(.caption2).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    } label: {
      Label("Audio levels", systemImage: "waveform")
    }
  }

  private var inspector: some View {
    RewindDVSection {
      VStack(alignment: .leading, spacing: 12) {
        if source == .deck {
          LiveTechnicalSpecificationsPanel(live: live, metadata: live.preview.metadata)
        } else {
          PlaybackTechnicalSpecificationsPanel(playback: playback, metadata: playback.metadata)
        }
        Divider()
        Text("Source facts, decoder output and operator observations remain separate.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    } label: {
      Label("Inspector", systemImage: "info.circle")
    }
  }

  private var deckConnection: some View {
      HStack(spacing: 14) {
        let connected = model.selectedDeck != nil && model.selectedRoute != nil && !model.refreshFailed
        Label(connected ? "CONNECTED" : "NO CONNECTION", systemImage: "cable.connector")
          .font(.callout.bold()).foregroundStyle(connected ? Color.green : Color.red)
          .accessibilityIdentifier("deck-connection-status")
        Picker("Deck", selection: $model.selectedDeckID) {
          Text("No deck selected").tag(UInt64?.none)
          ForEach(model.driverSnapshot?.decks ?? []) { deck in
            Text("\(deck.name) · \(deck.guidText)").tag(UInt64?.some(deck.guid))
          }
        }.disabled(sourceChangeLocked).accessibilityIdentifier("deck-selector")
      }.padding(.vertical, 6)
  }

  private var ingestStatus: some View {
    RewindDVSection("Ingest and verification") {
      VStack(alignment: .leading, spacing: 8) {
        Text(wholeTape.status).foregroundStyle(wholeTape.needsAttention ? .orange : .primary)
        if !wholeTape.active {
          Toggle("Notify on this Mac when finished or attention is needed", isOn: $wholeTape.notifyWhenFinished)
        }
        if !wholeTape.notificationStatus.isEmpty { Text(wholeTape.notificationStatus).foregroundStyle(.secondary) }
        if let url = wholeTape.evidenceURL {
          Button("Show tape job and evidence", systemImage: "folder") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Text(live.ingestDetail).font(.callout)
        if live.awaitingTapeStop {
          Text(live.tapeStopFeedback).foregroundStyle(live.tapeStopNeedsAttention ? .orange : .secondary)
          if live.tapeStopNeedsAttention {
            Button("I confirm the tape is physically stopped — finish receiving") {
              confirmPhysicalStop = true
            }
            .confirmationDialog("Is the tape physically stopped?", isPresented: $confirmPhysicalStop) {
              Button("Tape is stopped — drain and finish") {
                Task { await live.finishAfterPhysicalStop(); model.wholeTapeStopObserved() }
              }
            } message: {
              Text("Use the deck's physical STOP first if needed. This ends reception after saving the remaining bytes; it does not send another deck command.")
            }
          }
        }
        if live.hasCurrentPreview, let error = live.preview.error {
          Text("Last preview issue: \(error). Automatic recovery remains active; raw receive is independent.").foregroundStyle(.orange)
        }
        if let warning = live.diagnosticWarning { Text(warning).foregroundStyle(.orange) }
        if live.mediaFormats.requiresHDVExport {
          Text("Received \(live.packetsSeen) isochronous packets · \(live.mediaFormats.hdvPayloadRecords) HDV payload records. TS packet totals are verified after Stop.")
          Text("Known dropped isochronous packets \(live.knownDroppedPackets) · oversized subset \(live.oversizedPackets)")
          if let hdv = live.hdvVerification {
            Text("Final: \(hdv.transportPacketCount) TS packets · \(hdv.transportBytes) bytes · independently reread and SHA-256 verified")
            Text("CIP continuity observations \(hdv.transportSummary.CIPDBCDiscontinuities) · TS continuity observations \(hdv.transportSummary.continuityCounterObservations) · TEI packets \(hdv.transportSummary.transportErrorIndicatorPackets) · incomplete source fragments \(hdv.transportSummary.discardedSourceFragments)")
          }
        } else {
          Text("Received \(live.packetsSeen) packets · \(live.completeFrames) complete DV frames")
        }
        if live.active || live.busy {
          Text("Durably saved records \(live.durableRecords) · waiting for disk confirmation \(live.pendingDurabilityRecords). Live preview is not archive verification.")
            .foregroundStyle(live.writerUnderPressure ? .orange : .secondary)
          if live.writerUnderPressure {
            Text("Storage is under pressure. Reception is bounded; any known loss is counted and retained in the verification report.")
              .foregroundStyle(.orange)
          }
        }
        if !live.mediaFormats.requiresHDVExport {
        Text("Known dropped packets \(live.knownDroppedPackets) · oversized subset \(live.oversizedPackets) · incomplete frames \(live.incompleteFrames) · continuity events \(live.continuityBreaks) · rejected packets \(live.rejectedPackets)")
          .foregroundStyle(live.knownDroppedPackets + live.incompleteFrames + live.continuityBreaks + live.rejectedPackets > 0 ? .orange : .secondary)
        if live.hasCurrentPreview {
        Text("Preview only: delivery skips \(live.deliverySkips) · media queue skips \(live.preview.queueSkippedFrames) · renderer skips \(live.preview.rendererSkippedFrames) · audio backpressure skips \(live.preview.audio.skippedAudioFrames) · audio resyncs \(live.preview.audio.resynchronizations). Delivery/queue/renderer skips omit monitor A/V, never saved raw bytes.")
        Text("Presentation clock resets \(live.preview.videoTimelineResets) · retired video/timecode schedules \(live.preview.discardedPresentationSchedules)")
        Text("Failed video preview frames \(live.preview.failedVideoFrames) — later frames remain eligible; not a raw packet-loss count")
        Text("Preview audio: \(live.preview.audio.frameAccounting.offeredFrames) frames examined · omitted before audio stage \(live.preview.audio.deliveryGapFrames) · unknown format \(live.preview.audio.frameAccounting.unknownFormatFrames) · unusable PCM \(live.preview.audio.frameAccounting.unavailablePCMFrames). These are not raw packet-loss counts or a whole-capture audio audit.")
        Text("Preview input interruptions \(live.preview.audio.inputInterruptions) · native audio failures \(live.preview.audio.rendererFailureFrames) · sample construction failures \(live.preview.audio.sampleConstructionFailures). Source gaps preserve earlier queued good audio.")
        }
        if let result = live.verification {
          Text("Final: \(result.completeDVFrames) DV frames · \(result.dvBytes) bytes · raw SHA-256 verified: \(result.integritySHA256Verified ? "yes" : "no") · DV reread verified: \(result.nativeDVRereadVerified ? "yes" : "no DV file")")
          Text("Final receive observations: host ring drops \(result.hostRingDrops) · oversized \(result.oversizedPackets) · CIP discontinuities \(result.CIPDiscontinuities) · incomplete frames \(result.incompleteFrames) · rejected packets \(result.rejectedPackets)")
          if let afterEmpty = result.dbcDiscontinuitiesAfterEmptyPackets,
            let discarded = result.dbcDiscontinuitiesDiscardingPartialFrames,
            let terminal = result.terminalPartialFrames {
            Text("Continuity context: \(afterEmpty) DBC changes after empty packets · \(discarded) DBC changes discarded a partial frame · \(terminal) partial frames at receive end. These can overlap and do not prove that loss was harmless or absent.")
          }
          if result.captureFile == nil { Text("No complete DV frames: no .dv file was created.").foregroundStyle(.orange) }
        }
        }
        Text("Integrity checks prove saved-byte consistency, not pristine tape content. Exact missing-frame count and source concealment remain unknown. No fabricated frames, padding or silent repair; valid source black/grey is preserved.")
          .foregroundStyle(.secondary)
        if let url = live.flightURL {
          Text(url.path).textSelection(.enabled)
        }
      }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
  }

  private func chooseWholeTapeDestination() {
    guard source == .deck, policy.allows(.play), !live.active, !live.busy, !wholeTape.active,
      let deck = model.selectedDeck, let route = model.selectedRoute else { return }
    let panel = NSOpenPanel()
    panel.title = "Capture the whole tape"
    // AppKit can size this message as one unwrapped line. Keep instructions
    // compact instead of forcing the system picker wider than the screen.
    panel.message = """
      Choose a destination folder.
      Rewind → prepare receive → PLAY → observed stop → verify.
      Missing timecode or DV signal never ends capture.
      Tape boundaries are inferred, not guaranteed.
      Keep the deck, Mac and destination connected and powered on.
      """
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    guard runCaptureDestinationPanel(panel) == .OK, let url = panel.url,
      model.selectedDeck?.id == deck.id, model.selectedRoute == route else { return }
    wholeTape.start(model: model, live: live, destination: url)
  }

  private func openVerifiedCapture(_ url: URL) {
    guard !live.busy, FileManager.default.isReadableFile(atPath: url.path) else { return }
    model.monitorSource = .file
    playback.open(url: url)
  }

  private func chooseIngestDestination() {
    guard source == .deck, policy.allows(.play), !live.active, !live.busy,
      !live.lockedOut, let deck = model.selectedDeck, let route = model.selectedRoute else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose ingest destination"
    panel.message = """
      Creates a new capture folder without overwriting files.
      Prepares receive, then sends one PLAY. Press STOP to finish.
      Raw evidence and complete native DV frames are retained.
      No capture duration limit.
      """
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    guard runCaptureDestinationPanel(panel) == .OK, let url = panel.url,
      policy.allows(.play), !live.active, !live.busy,
      model.selectedDeck?.id == deck.id, model.selectedRoute == route else { return }
    model.startIngest(live: live, deck: deck, route: route, destination: url)
  }

  private func runCaptureDestinationPanel(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
    let owner = NSApp.keyWindow ?? NSApp.mainWindow
    // NSSavePanel restores shared window geometry on presentation, including
    // the oversized frame created by the former single-line instructions.
    // Apply a conventional picker size after that restoration, without
    // changing Finder preferences or constraining subsequent user resizing.
    panel.setContentSize(NSSize(width: 720, height: 500))
    DispatchQueue.main.async {
      guard panel.isVisible else { return }
      panel.setContentSize(NSSize(width: 720, height: 500))
      if let owner {
        let visible = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let x = min(max(owner.frame.midX - panel.frame.width / 2, visible.minX),
                    max(visible.minX, visible.maxX - panel.frame.width))
        let y = min(max(owner.frame.midY - panel.frame.height / 2, visible.minY),
                    max(visible.minY, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
      } else { panel.center() }
    }
    return panel.runModal()
  }

  @ViewBuilder private var statusNotice: some View {
    if model.controlLockedOut || (live.lockedOut && model.requiresSupervisedStop) {
      notice("Manual STOP required if the tape may still be moving", model.detail, .red)
      notice("Receive status", live.detail, .red)
    } else if source == .deck {
      if live.lockedOut {
        notice("Receive needs attention", live.detail, .red)
      }
      if model.requiresSupervisedStop {
        notice(
          "Supervised STOP pending",
          "STOP remains available. After winding, two fresh stopped-state observations can release controls without another motion command. If software cannot stop the tape, use physical STOP.",
          .orange)
      }
    } else if let detail = playback.state.detail {
      notice("Playback needs attention", detail, .orange)
    }
    if source == .deck && !wholeTape.active && (live.active || live.busy) {
      Menu("Recovery", systemImage: "ellipsis.circle") {
        Button("End monitoring only — no tape command") { live.stop() }
      }
      .help("Receive-only escape hatch after physical STOP or a control failure; does not change tape motion.")
    }
  }

  private func notice(_ title: String, _ detail: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.callout.weight(.semibold)).foregroundStyle(color)
      Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
  }

  private func chooseFile() {
    guard source == .file, !sourceChangeLocked, !playback.isLoading, playbackOpenPanel == nil else { return }
    let owner = NSApp.mainWindow ?? NSApp.keyWindow
    let panel = NSOpenPanel()
    playbackOpenPanel = panel
    panel.title = "Open recorded DV"
    panel.message = "The original file is opened read-only and is never rewritten."
    if let type = UTType(filenameExtension: "dv") { panel.allowedContentTypes = [type] }
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.setContentSize(NSSize(width: 720, height: 500))
    panel.begin { response in
      playbackOpenPanel = nil
      if response == .OK, let url = panel.url, source == .file, !sourceChangeLocked {
        playback.open(url: url)
      }
    }
    // AppKit restores shared panel geometry during presentation. Position after
    // that restoration, not before it, and keep the chooser on the owner's screen.
    DispatchQueue.main.async {
      guard panel.isVisible else { return }
      panel.setContentSize(NSSize(width: 720, height: 500))
      if let owner {
        let visible = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let x = min(max(owner.frame.midX - panel.frame.width / 2, visible.minX),
                    max(visible.minX, visible.maxX - panel.frame.width))
        let y = min(max(owner.frame.midY - panel.frame.height / 2, visible.minY),
                    max(visible.minY, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
      } else { panel.center() }
    }
  }
}

/// Read-only presentation of both modules; navigation does not trigger queries
/// or tape operations, and the same session models retain their evidence.
/// Direct pointer mapping avoids the native slider's animated click-to-position behavior.
private struct InstantPlaybackScrubber: View {
  @Binding var value: Double
  let duration: Double
  let onEditingChanged: (Bool) -> Void
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - 16)
      let fraction = min(1, max(0, value / duration))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4)
        Capsule().fill(Color.accentColor).frame(width: width * fraction + 8, height: 4)
        Circle().fill(.white).frame(width: 16, height: 16).offset(x: width * fraction)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { event in
        guard enabled else { return }
        onEditingChanged(true)
        value = min(1, max(0, (event.location.x - 8) / width)) * duration
      }.onEnded { _ in onEditingChanged(false) })
    }
    .frame(height: 24)
    .opacity(enabled ? 1 : 0.5)
    .accessibilityElement()
    .accessibilityValue(MonitorCounter.elapsed(seconds: value))
    .accessibilityAdjustableAction { direction in
      guard enabled else { return }
      switch direction {
      case .increment: value = min(duration, value + 1)
      case .decrement: value = max(0, value - 1)
      @unknown default: break
      }
      onEditingChanged(false)
    }
  }
}

/// Ordinary native buttons keep expansion available to keyboard and AX clients.
/// Local state intentionally starts collapsed on each fresh workspace launch.
private struct CollapsibleWorkspaceSection<Content: View>: View {
  let title: String
  let identifier: String
  @ViewBuilder var content: () -> Content
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button { expanded.toggle() } label: {
        HStack {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .accessibilityHidden(true)
          Text(title).font(.headline)
          Spacer(minLength: 0)
        }.contentShape(Rectangle()).padding(10)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Expand or collapse section")
      .accessibilityIdentifier("toggle-\(identifier)")
      if expanded { content() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct VerificationProgressBanner: View {
  let progress: DVIngestProgress
  let etaSeconds: TimeInterval?
  let elapsedSeconds: TimeInterval
  let volumeName: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: progress.phase == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.title2).foregroundStyle(accent)
        VStack(alignment: .leading, spacing: 3) {
          Text(headline)
            .font(.headline.weight(.bold)).foregroundStyle(accent)
          Text(stageTitle).font(.callout.weight(.semibold))
          Text(stageExplanation).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      if let fraction = progress.fractionCompleted {
        ProgressView(value: fraction, total: 1).progressViewStyle(.linear)
          .tint(accent).accessibilityLabel("Native DV reconstruction and verification")
          .accessibilityValue("\(Int(fraction * 100)) percent")
        HStack {
          Text("\(Int(fraction * 100))% · \(bytes(progress.overallCompletedBytes)) of \(bytes(progress.overallTotalBytes)) processed")
          Spacer()
          Text(etaText)
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      } else {
        ProgressView().progressViewStyle(.linear).tint(accent)
        Text("Validating closed receive evidence before reconstruction begins…")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.55), lineWidth: 2))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("ingest-verification-progress")
  }

  private var destination: String {
    guard let volumeName, !volumeName.isEmpty else { return "THE DESTINATION DRIVE" }
    return "“\(volumeName)”"
  }

  private var accent: Color { progress.phase == .complete ? .green : .orange }

  private var headline: String {
    progress.phase == .complete
      ? "VERIFICATION COMPLETE — FILES ARE DURABLE"
      : "DO NOT QUIT REWINDDV OR DISCONNECT \(destination.uppercased())"
  }

  private var stageTitle: String {
    switch progress.phase {
    case .validatingEvidence: "Validating the closed raw receive"
    case .reconstructingNativeDV: "Reconstructing the native DV file"
    case .rereadingNativeDV: "Rereading every byte of the reconstructed DV file"
    case .rereadingRawEvidence: "Rereading and hashing the original receive evidence"
    case .rereadingFrameManifest: "Rereading and verifying the frame manifest"
    case .publishingVerifiedFiles: "Making verified files durable on the destination"
    case .complete: "Verification complete"
    }
  }

  private var stageExplanation: String {
    switch progress.phase {
    case .reconstructingNativeDV:
      "capture.dv.partial is still growing. Closing the app or disconnecting storage can interrupt reconstruction."
    case .publishingVerifiedFiles:
      "Final names and directory records are being synchronized. Keep the destination connected until this notice disappears."
    case .complete:
      "The native DV file and its verification evidence were reread and published successfully."
    default:
      "rewindDV is still processing the capture. Keep the app open and the destination connected until verification finishes."
    }
  }

  private var etaText: String {
    guard let etaSeconds, etaSeconds.isFinite else {
      return progress.phase == .publishingVerifiedFiles ? "Final durable sync…" : "Estimating time remaining…"
    }
    return "ETA \(duration(etaSeconds)) · \(duration(elapsedSeconds)) elapsed"
  }

  private func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600, minutes = total % 3600 / 60, remainder = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }

  private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
  }
}

private extension MonitorAction {
  var accessibilityID: String {
    switch self {
    case .play: "play"
    case .pause: "pause"
    case .stop: "stop"
    case .rewind: "rewind"
    case .fastForward: "fast-forward"
    case .shuttleForward: "shuttle-forward"
    case .shuttleReverse: "shuttle-reverse"
    case .stepBackward: "step-backward"
    case .stepForward: "step-forward"
    case .beginning: "beginning"
    case .end: "end"
    case .capture: "capture"
    }
  }
}

/// Shared with the offline interaction fixture; reflects only this start attempt.
struct CaptureStartAdmissionNotice: View {
  @ObservedObject var live: LiveMonitorModel
  var body: some View {
    if live.waitingForAdmission || (live.ingestRequested && !live.hasReceiveSession && !live.busy) {
      VStack(alignment: .leading, spacing: 8) {
        Text(live.ingestDetail).accessibilityIdentifier("capture-admission-status")
        if live.waitingForAdmission {
          Button("Cancel capture start") { live.stop() }
            .accessibilityIdentifier("cancel-capture-start")
        }
      }
      .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
