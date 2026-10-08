// Offline native renderer geometry oracle. No driver or tape access.
import AppKit
import AVFoundation
import SwiftUI

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}

private struct Fixture: View {
  @ObservedObject var preview: LiveDVPreview
  var body: some View {
    ZStack {
      Color.black
      MonitorVideoSurface(displayLayer: preview.displayLayer, overrideDisplayAspect: true)
        .aspectRatio(preview.displayAspectRatio, contentMode: .fit).padding(2)
    }.frame(width: 720, height: 480)
  }
}

@main struct LiveAspectGeometryRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
    let bytes = try file.read(upToCount: 120_000)!
    try file.close()
    let preview = LiveDVPreview(muteAudio: true)
    let host = NSHostingView(rootView: Fixture(preview: preview))
    host.frame = CGRect(x: 0, y: 0, width: 720, height: 480)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    await preview.begin()
    for (index, aspect) in [DVDisplayAspect.standard, .widescreen, .standard, .widescreen].enumerated() {
      preview.setDisplayAspect(aspect)
      for frame in 0..<12 {
        preview.offerPreservedFrame(bytes, ordinal: UInt64(index * 12 + frame), sourceTimecode: nil)
        try await Task.sleep(for: .milliseconds(34))
        host.layoutSubtreeIfNeeded()
      }
      let layer = preview.displayLayer
      precondition(preview.isReceiving && preview.error == nil)
      // latestSubmittedOrdinal follows the delayed A/V presentation clock;
      // use decodedFrames to prove new input reached this geometry check.
      precondition(preview.decodedFrames == UInt64((index + 1) * 12),
        "Geometry must be checked against newly decoded frames, not stale metadata")
      print("ASPECT=\(aspect.rawValue) host=\(layer.frame) sampleAspect=\(preview.presentedAspectRatio ?? 0) gravity=\(layer.videoGravity.rawValue)")
      precondition(abs(layer.bounds.width / layer.bounds.height - CGFloat(aspect.ratio)) < 0.01)
      precondition(layer.videoGravity == .resize)
      precondition(abs((preview.presentedAspectRatio ?? 0) - 1.5) < 0.001,
        "Incoming sample metadata must stay square-pixel regardless of viewport aspect")
    }
    await preview.end()
    withExtendedLifetime(window) {}
    print("LIVE_ASPECT_GEOMETRY_PASS")
  }
}
