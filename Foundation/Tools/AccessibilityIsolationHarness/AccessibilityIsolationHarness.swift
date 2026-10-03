// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import AVFoundation
import SwiftUI

/// A driver-free executable used to reduce native accessibility failures to a
/// single SwiftUI/AppKit surface. The bundle identifier suffix selects a mode,
/// so every surface can be inspected as an independent process.
private enum IsolationMode: String {
  case staticContent = "static"
  case navigation = "navigation"
  case canvas = "canvas"
  case timeline = "timeline"
  case video = "video"
  case scrollText = "scrolltext"
  case scrollButtons = "scrollbuttons"
  case scrollPicker = "scrollpicker"
  case scrollGroup = "scrollgroup"
  case scrollSpacer = "scrollspacer"
  case fixedScroll = "fixedscroll"
  case scroll = "scroll"
  case horizontalSplit = "hsplit"
  case navigationScroll = "navscroll"
  case navigationTimeline = "navtimeline"
  case navigationVideo = "navvideo"
  case combinedStatic = "combinedstatic"
  case combined = "combined"

  static var current: Self {
    let suffix = Bundle.main.bundleIdentifier?.split(separator: ".").last.map(String.init)
    return Self(rawValue: suffix ?? "") ?? .staticContent
  }
}

@main
private struct AccessibilityIsolationHarness: App {
  var body: some Scene {
    Window("RewindDV Accessibility Isolation", id: "isolation") {
      IsolationRoot(mode: .current)
        .frame(minWidth: 760, minHeight: 560)
    }
    .defaultSize(width: 960, height: 680)
  }
}

private struct IsolationRoot: View {
  let mode: IsolationMode

  var body: some View {
    switch mode {
    case .staticContent:
      StaticContent()
    case .navigation:
      NavigationContent(detail: StaticContent())
    case .canvas:
      MeterContent(animated: false)
    case .timeline:
      MeterContent(animated: true)
    case .video:
      VideoContent()
    case .scrollText:
      ScrollView { Text("Scrollable text") }
    case .scrollButtons:
      ScrollView {
        VStack { Button("One") {}; Button("Two") {}; Button("Three") {} }
      }
    case .scrollPicker:
      ScrollView {
        Picker("Deck", selection: .constant(0)) { Text("Test deck").tag(0) }
      }
    case .scrollGroup:
      ScrollView {
        GroupBox("Status") { Text("Connected") }.padding()
      }
    case .scrollSpacer:
      ScrollView {
        VStack { Text("Before spacer"); Spacer(); Text("After spacer") }.padding()
      }
    case .fixedScroll:
      ScrollView {
        IsolationSection("Driver connection") {
          HStack {
            Label("Connected", systemImage: "cable.connector")
            Picker("Deck", selection: .constant(0)) { Text("Test deck").tag(0) }
            Button("Refresh") {}
          }
        }
        .padding()
      }
    case .scroll:
      ScrollView { StaticContent() }
    case .horizontalSplit:
      HorizontalSplitContent(detail: ScrollView { StaticContent() })
    case .navigationScroll:
      NavigationContent(detail: ScrollView { StaticContent() })
    case .navigationTimeline:
      NavigationContent(detail: MeterContent(animated: true))
    case .navigationVideo:
      NavigationContent(detail: VideoContent())
    case .combinedStatic:
      NavigationContent(detail: CombinedContent(animated: false))
    case .combined:
      NavigationContent(detail: CombinedContent(animated: true))
    }
  }
}

private struct IsolationSection<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline).accessibilityAddTraits(.isHeader)
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct HorizontalSplitContent<Detail: View>: View {
  let detail: Detail
  @State private var selected = "Workspace"

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 0) {
        Text("RewindDV").font(.title2.bold()).padding()
        List(["Workspace", "Archives", "Device Inspector", "Diagnostics"], id: \.self,
          selection: $selected) { value in
          Text(value).tag(value)
        }
      }
      .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
      detail.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct StaticContent: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("RewindDV accessibility isolation").font(.largeTitle.bold())
      Text("Static native controls only").foregroundStyle(.secondary)
      GroupBox("Driver connection") {
        HStack {
          Label("Connected", systemImage: "cable.connector")
          Picker("Deck", selection: .constant(0)) {
            Text("Test deck").tag(0)
          }
          Button("Refresh") {}
        }.padding(.vertical, 6)
      }
      HStack {
        Button("Rewind", systemImage: "backward.fill") {}
        Button("Play", systemImage: "play.fill") {}
        Button("Stop", systemImage: "stop.fill") {}
        Button("Fast-forward", systemImage: "forward.fill") {}
      }
      Spacer()
    }
    .padding(24)
  }
}

private struct NavigationContent<Detail: View>: View {
  let detail: Detail
  @State private var selected = "Workspace"

  var body: some View {
    NavigationSplitView {
      List(["Workspace", "Archives", "Device Inspector", "Diagnostics"], id: \.self,
        selection: $selected) { value in
        Text(value).tag(value)
      }
      .navigationTitle("RewindDV")
    } detail: {
      detail
    }
  }
}

private struct MeterContent: View {
  let animated: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(animated ? "Animated audio meters" : "Static audio meters")
        .font(.title.bold())
      if animated {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          IsolationMeter(phase: context.date.timeIntervalSinceReferenceDate)
        }
      } else {
        IsolationMeter(phase: 0.4)
      }
      Spacer()
    }
    .padding(24)
  }
}

private struct IsolationMeter: View {
  let phase: Double

  var body: some View {
    HStack(alignment: .bottom, spacing: 16) {
      ForEach(0..<4, id: \.self) { channel in
        VStack {
          Text("\(channel + 1)")
          Canvas { context, size in
            let fraction = 0.2 + 0.7 * abs(sin(phase + Double(channel)))
            context.fill(
              Path(CGRect(x: 3, y: size.height * (1 - fraction), width: size.width - 6,
                height: size.height * fraction)),
              with: .color(.mint))
          }
          .frame(width: 28, height: 260)
          .accessibilityHidden(true)
          Text(String(format: "%.1f dBFS", -60 + 60 * abs(sin(phase + Double(channel)))))
        }
        .frame(width: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio channel \(channel + 1)")
        .accessibilityValue("Meter test value")
      }
    }
  }
}

private struct VideoContent: View {
  private let layer = AVSampleBufferDisplayLayer()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Video-host bridge").font(.title.bold())
      IsolationVideoSurface(displayLayer: layer)
        .accessibilityHidden(true)
        .frame(width: 640, height: 480)
        .background(.black)
      Text("No video frame is loaded")
        .accessibilityIdentifier("isolation-video-status")
      Spacer()
    }
    .padding(24)
  }
}

private struct CombinedContent: View {
  let animated: Bool
  private let layer = AVSampleBufferDisplayLayer()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Combined RewindDV workspace").font(.largeTitle.bold())
        HStack(alignment: .top, spacing: 18) {
          VStack {
            IsolationVideoSurface(displayLayer: layer)
              .accessibilityHidden(true)
              .frame(width: 520, height: 390)
              .background(.black)
            HStack {
              Button("Rewind", systemImage: "backward.fill") {}
              Button("Play", systemImage: "play.fill") {}
              Button("Stop", systemImage: "stop.fill") {}
              Button("Fast-forward", systemImage: "forward.fill") {}
            }
          }
          MeterContent(animated: animated).frame(width: 360)
        }
        StaticContent().frame(height: 280)
      }
      .padding(22)
    }
  }
}

private struct IsolationVideoSurface: NSViewRepresentable {
  let displayLayer: AVSampleBufferDisplayLayer

  func makeNSView(context: Context) -> IsolationVideoHostView {
    IsolationVideoHostView(displayLayer: displayLayer)
  }

  func updateNSView(_ view: IsolationVideoHostView, context: Context) {
    view.install(displayLayer)
  }
}

@MainActor
private final class IsolationVideoHostView: NSView {
  private var videoLayer: AVSampleBufferDisplayLayer?

  init(displayLayer: AVSampleBufferDisplayLayer) {
    super.init(frame: .zero)
    wantsLayer = true
    install(displayLayer)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Programmatic video host only") }

  func install(_ displayLayer: AVSampleBufferDisplayLayer) {
    if videoLayer !== displayLayer {
      videoLayer?.removeFromSuperlayer()
      videoLayer = displayLayer
    }
    if displayLayer.superlayer !== layer { layer?.addSublayer(displayLayer) }
    displayLayer.videoGravity = .resizeAspect
    displayLayer.frame = bounds
  }

  override func layout() {
    super.layout()
    videoLayer?.frame = bounds
  }
}
