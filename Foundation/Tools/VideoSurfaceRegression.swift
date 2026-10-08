import AVFoundation
// Native offscreen layout regression. No driver, media audio, or user-window control.
import AppKit
import SwiftUI

@MainActor private final class Probe {
  var hosts: [NSView] = []
}

private struct LegacySurface: NSViewRepresentable {
  let display: AVSampleBufferDisplayLayer
  let probe: Probe
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer = display
    probe.hosts.append(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
}

private struct FixedFixture: View {
  let display: AVSampleBufferDisplayLayer
  let wide: Bool
  var body: some View {
    let layout = wide ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
    layout {
      MonitorVideoSurface(displayLayer: display).frame(
        width: wide ? 640 : 480, height: wide ? 480 : 360)
      Text("Inspector")
    }
  }
}

@main struct VideoSurfaceRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let display = AVSampleBufferDisplayLayer()
    let probe = Probe()
    let monitor = ZStack {
      RoundedRectangle(cornerRadius: 12).fill(.black)
      LegacySurface(display: display, probe: probe)
        .aspectRatio(4.0 / 3.0, contentMode: .fit).padding(2)
    }.frame(minHeight: 325).aspectRatio(4.0 / 3.0, contentMode: .fit)
    let host = NSHostingView(
      rootView:
        ScrollView {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
              monitor.frame(minWidth: 480, maxWidth: .infinity)
              Text("Meter").frame(width: 214)
              Text("Inspector").frame(width: 240)
            }
            VStack(spacing: 18) {
              monitor
              HStack(alignment: .top, spacing: 18) {
                Text("Meter").frame(width: 214)
                Text("Inspector").frame(maxWidth: .infinity)
              }
            }
          }
        })
    host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    print("LEGACY_HOST_COUNT=\(probe.hosts.count)")
    print("LEGACY_DISPLAY_BOUNDS=\(display.bounds)")
    for (index, view) in probe.hosts.enumerated() {
      print(
        "LEGACY_HOST_\(index) frame=\(view.frame) hidden=\(view.isHiddenOrHasHiddenAncestor) root=\(view.layer === display) superlayer=\(String(describing: display.superlayer))"
      )
    }
    withExtendedLifetime(host) {}
    let fixedDisplay = AVSampleBufferDisplayLayer()
    let fixed = NSHostingView(rootView: FixedFixture(display: fixedDisplay, wide: true))
    fixed.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    func surfaces(in view: NSView) -> [MonitorVideoHostView] {
      if let surface = view as? MonitorVideoHostView { return [surface] }
      return view.subviews.flatMap { surfaces(in: $0) }
    }
    var identity: ObjectIdentifier?
    for wide in [true, false, true, false, true] {
      fixed.rootView = FixedFixture(display: fixedDisplay, wide: wide)
      fixed.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      fixed.layoutSubtreeIfNeeded()
      let hosts = surfaces(in: fixed)
      precondition(hosts.count == 1, "Exactly one video host must exist")
      let surface = hosts[0]
      if let identity {
        precondition(
          identity == ObjectIdentifier(surface), "Layout must preserve video host identity")
      }
      identity = ObjectIdentifier(surface)
      precondition(fixedDisplay.superlayer === surface.layer, "Video must be attached to its host")
      precondition(
        fixedDisplay.frame == surface.bounds && fixedDisplay.bounds.width > 0
          && fixedDisplay.bounds.height > 0)
      print(
        "PASS_FIXED_LAYOUT wide=\(wide) bounds=\(fixedDisplay.bounds) attached=true singleHost=true"
      )
    }
    let replacement = MonitorVideoHostView(displayLayer: fixedDisplay)
    replacement.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    // An unattached offscreen view has no window-driven layout pass. Lay out
    // its resized bounds before testing a no-op 1x setting.
    replacement.layoutSubtreeIfNeeded()
    for zoom: CGFloat in [1, 2, 4, 8] {
      replacement.setZoom(zoom, center: CGPoint(x: 0.5, y: 0.5))
      precondition(fixedDisplay.frame.width == 640 * zoom)
      precondition(fixedDisplay.frame.height == 480 * zoom)
      precondition(fixedDisplay.frame.midX == 320 && fixedDisplay.frame.midY == 240)
      replacement.setZoom(zoom, center: .zero)
      precondition(fixedDisplay.frame.minX == 0)
      precondition(fixedDisplay.frame.maxY == 480, "Top-left navigator maps to top-left picture")
      replacement.setZoom(zoom, center: CGPoint(x: 1, y: 1))
      precondition(fixedDisplay.frame.maxX == 640 && fixedDisplay.frame.minY == 0)
    }
    replacement.setZoom(1, center: .zero)
    precondition(fixedDisplay.frame == replacement.bounds, "1x restores full picture")
    print("PASS_ZOOM_CENTER_CORNERS_AND_RESET")
    for overridden in [true, false, true, false] {
      replacement.overrideDisplayAspect = overridden
      precondition(fixedDisplay.videoGravity == (overridden ? .resize : .resizeAspect))
      precondition(fixedDisplay.frame == replacement.bounds)
      precondition(fixedDisplay.superlayer === replacement.layer)
      precondition(fixedDisplay.animationKeys()?.isEmpty ?? true,
        "Display aspect changes must not install implicit animations")
    }
    print("PASS_DISPLAY_ASPECT_OVERRIDE_NO_REHOST_OR_ANIMATION")
    surfaces(in: fixed)[0].detach()
    precondition(
      fixedDisplay.superlayer === replacement.layer, "Old teardown cannot detach replacement")
    replacement.detach()
    precondition(fixedDisplay.superlayer == nil)
    print("PASS_SAFE_DETACH")
    if CommandLine.arguments.count == 2 {
      let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
      let track = try await asset.loadTracks(withMediaType: .video)[0]
      let synchronizer = AVSampleBufferRenderSynchronizer()
      synchronizer.addRenderer(display.sampleBufferRenderer)
      for surfaceBacked in [false, true] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
          start: CMTime(seconds: 19, preferredTimescale: 60000),
          duration: CMTime(seconds: 1, preferredTimescale: 60000))
        var settings: [String: Any] = [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if surfaceBacked {
          settings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
          let pixel = CMSampleBufferGetImageBuffer(sample)
        else { fatalError("No decoded video") }
        print(
          "EXPLICIT_SURFACE=\(surfaceBacked) IOSURFACE_PRESENT=\(CVPixelBufferGetIOSurface(pixel) != nil) DIMENSIONS=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))"
        )
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        var minimum = 255
        var maximum = 0
        var alphaMin = 255
        var alphaMax = 0
        for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(pixel), by: 4) {
          for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(pixel), by: 4) {
            for c in 0..<3 {
              minimum = min(minimum, Int(base[y * stride + x * 4 + c]))
              maximum = max(maximum, Int(base[y * stride + x * 4 + c]))
            }
            alphaMin = min(alphaMin, Int(base[y * stride + x * 4 + 3]))
            alphaMax = max(alphaMax, Int(base[y * stride + x * 4 + 3]))
          }
        }
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        print("RGB_RANGE=\(minimum)...\(maximum) ALPHA_RANGE=\(alphaMin)...\(alphaMax)")
        synchronizer.setRate(0, time: CMSampleBufferGetPresentationTimeStamp(sample))
        display.sampleBufferRenderer.enqueue(sample)
        try await Task.sleep(for: .milliseconds(300))
        print(
          "RENDERER_STATUS=\(display.sampleBufferRenderer.status.rawValue) READY=\(display.isReadyForDisplay) DISPLAYED_PIXEL=\(display.sampleBufferRenderer.displayedPixelBuffer() != nil)"
        )
        reader.cancelReading()
      }
    }
  }
}
