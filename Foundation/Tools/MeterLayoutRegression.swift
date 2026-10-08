// Native offscreen layout only. No driver, media, user window, or audio.
import SwiftUI
import AppKit

@MainActor private final class GeometryProbe { var frames: [Int: CGRect] = [:] }
@main struct MeterLayoutRegression {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let probe = GeometryProbe()
    let host = NSHostingView(rootView: MeterBank(presentation: .silence,
      observeRailFrame: { probe.frames[$0] = $1 }))
    host.frame = CGRect(x: 0, y: 0, width: 214, height: 400)
    var reference: [Int: CGRect]?
    for state in 0..<5 {
      let channel = OfflineDVMonitorMeter.PresentedChannel(active: state != 0,
        peakDBFS: state == 2 ? -96 : state == 4 ? 0 : -12.3,
        rmsDBFS: state == 2 ? -96 : -22.7, heldPeakDBFS: -3, isClipping: state == 4)
      let presentation = OfflineDVMonitorMeter.Presentation(channels:
        state == 0 ? [] : Array(repeating: channel, count: state == 3 ? 2 : 4))
      host.rootView = MeterBank(presentation: presentation,
        observeRailFrame: { probe.frames[$0] = $1 })
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      guard probe.frames.count == 4 else { throw Failure("No offscreen rail geometry") }
      if let reference, reference != probe.frames { throw Failure("Meter rails moved in state \(state)") }
      reference = probe.frames
      guard probe.frames.values.allSatisfy({ $0.width == 24 && $0.height == 244 }) else {
        throw Failure("Incorrect rail dimensions")
      }
      print("METER_LAYOUT_STATE_\(state)_PASS rail_centers=\((0..<4).map { probe.frames[$0]!.midX })")
    }
    withExtendedLifetime(host) {}
  }
  struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
