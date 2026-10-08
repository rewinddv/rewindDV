// Native offscreen SwiftUI lifecycle regression; no driver or hardware access.
import AppKit
import SwiftUI

@MainActor private final class Probe {
  var phases: [ScenePhase] = []
}

private struct PhaseView: View {
  @Environment(\.scenePhase) var phase
  let keyed: Bool
  let probe: Probe
  var body: some View {
    if keyed {
      Color.clear.task(id: phase) { await observe() }
    } else {
      Color.clear.task { await observe() }
    }
  }
  @MainActor func observe() async {
    while !Task.isCancelled {
      probe.phases.append(phase)
      do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
    }
  }
}

@main struct DriverDiscoveryLifecycleRegression {
  struct Failure: Error { let message: String }
  @MainActor static func main() async throws {
    let source = try String(contentsOfFile: "Foundation/App/RewindDVApp.swift", encoding: .utf8)
    guard source.contains(".task(id: scenePhase)"),
      source.contains("DriverRefreshPolicy.mayCheck(sceneActive: scenePhase == .active") else {
      throw Failure(message: "Shipping discovery must bind its task lifetime to scene phase and retain idle admission")
    }
    _ = NSApplication.shared
    for keyed in [false, true] {
      let probe = Probe()
      let host = NSHostingView(rootView: PhaseView(keyed: keyed, probe: probe)
        .environment(\.scenePhase, .inactive))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [], backing: .buffered, defer: false)
      window.contentView = host // Never shown or activated.
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      guard !probe.phases.isEmpty else { throw Failure(message: "Initial task did not run") }
      host.rootView = PhaseView(keyed: keyed, probe: probe).environment(\.scenePhase, .active)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      if keyed {
        guard probe.phases.contains(.active) else { throw Failure(message: "Activation never reached task") }
        host.rootView = PhaseView(keyed: keyed, probe: probe).environment(\.scenePhase, .inactive)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        guard probe.phases.suffix(3).allSatisfy({ $0 == .inactive }) else {
          throw Failure(message: "Task kept active phase after deactivation")
        }
        host.rootView = PhaseView(keyed: keyed, probe: probe).environment(\.scenePhase, .active)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        guard probe.phases.suffix(3).allSatisfy({ $0 == .active }) else {
          throw Failure(message: "Task did not resume after reactivation")
        }
        print("PASS: keyed task observes cold-launch activation, deactivation and reactivation")
      } else {
        guard probe.phases.allSatisfy({ $0 == .inactive }) else {
          throw Failure(message: "Old unkeyed-task failure was not reproduced")
        }
        print("REPRODUCED: unkeyed task retains initial inactive phase after activation")
      }
      withExtendedLifetime(window) {}
    }
  }
}
