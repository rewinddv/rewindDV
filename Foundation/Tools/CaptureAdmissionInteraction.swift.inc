// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
@MainActor final class AdmissionInteractionFixture {
  let window: NSWindow
  let model = RewindDVModel()
  let live = LiveMonitorModel(muteAudio: true)
  var boundary: Barrier?
  init(deck: DiscoveredDeck, route: FoundationRoute) {
    model.selectedDeck = deck; model.selectedRoute = route
    window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 780, height: 360),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Capture admission — OFFLINE fixture"
    window.contentView = NSHostingView(rootView: AdmissionFixtureView(fixture: self, deck: deck, route: route))
    window.makeKeyAndOrderFront(nil)
    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
  }
  func waitStart(deck: DiscoveredDeck, route: FoundationRoute) {
    guard !live.busy else { return }
    let gate = Barrier(); boundary = gate; model.joinBoundary = gate
    model.startIngest(live: live, deck: deck, route: route,
      destination: URL(fileURLWithPath: "/offline-no-files-created"))
  }
  func completeQuery() { Task { await boundary?.release() } }
  func reject(deck: DiscoveredDeck, route: FoundationRoute) {
    guard !live.busy else { return }
    Task {
      await model.bridge.configure(command: true)
      live.start(bridge: model.bridge, deck: deck,
        ingestParent: URL(fileURLWithPath: "/offline-no-files-created"), expectedRoute: route)
    }
  }
}
struct AdmissionFixtureView: View {
  let fixture: AdmissionInteractionFixture
  let deck: DiscoveredDeck, route: FoundationRoute
  @ObservedObject var live: LiveMonitorModel
  init(fixture: AdmissionInteractionFixture, deck: DiscoveredDeck, route: FoundationRoute) {
    self.fixture = fixture; self.deck = deck; self.route = route; live = fixture.live
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Offline capture-start interaction").font(.title2)
      Text("Synthetic queries only. No driver, physical commands or capture files.")
      HStack {
        Button("Start waiting capture") { fixture.waitStart(deck: deck, route: route) }
        Button("Complete query") { fixture.completeQuery() }
        Button("Reject capture") { fixture.reject(deck: deck, route: route) }
      }
      CaptureStartAdmissionNotice(live: live)
      Text("Receive active: \(live.active) · STOP warning: \(live.tapeStopNeedsAttention) · Frames: \(live.completeFrames)")
      Text("Flight: \(live.flightURL == nil ? "none" : "synthetic")")
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
