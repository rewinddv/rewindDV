// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline only: actual model/delegate with synthetic receipts. No bridge method,
// driver discovery, receive operation, tape command or original media is used.
import AppKit
import Foundation

@MainActor private func syntheticMotion(_ command: DeckCommand = .rewind,
  uncertain: Bool = false) -> ControlAttemptReport {
  .init(disposition: uncertain ? .uncertainLockedOut : .protocolAcceptedMotionUnverified,
    command: command, result: nil,
    receiptURL: URL(fileURLWithPath: "/offline-quit-fixture/\(UUID()).json"),
    message: "Synthetic receipt; no tape command was sent", requiresSupervisedStop: true,
    firstError: uncertain ? "Synthetic uncertain response" : nil, cleanupErrors: [])
}

@main struct QuitSupervisionRegression {
  @MainActor static func main() {
    let app = NSApplication.shared
    precondition(RewindDVRuntimeOptions.hardwareDisabled, "Require --ui-automation-no-driver")
    if CommandLine.arguments.contains("--interactive") {
      let fixture = QuitFixtureWindow()
      withExtendedLifetime(fixture) { app.run() }
      return
    }
    let model = RewindDVModel()
    let live = LiveMonitorModel(muteAudio: true)
    let delegate = WholeTapeAppDelegate()
    delegate.bind(model: model, live: live)
    var failures = 0, assertions = 0, alerts = 0
    func require(_ condition: Bool, _ message: String) {
      assertions += 1
      print("\(condition ? "PASS" : "FAIL"): \(message)")
      if !condition { failures += 1 }
    }
    func reset() {
      model.isBusy = false; model.controlLockedOut = false; model.controlReport = nil
      WholeTapeAppDelegate.active = false; WholeTapeAppDelegate.receiveActive = false
      alerts = 0
      delegate.presentQuitAlert = { _ in alerts += 1; return .alertFirstButtonReturn }
    }
    func reply() -> NSApplication.TerminateReply { delegate.applicationShouldTerminate(app) }

    reset()
    require(reply() == .terminateNow && alerts == 0, "idle quit is immediate without warning")
    for command in [DeckCommand.rewind, .fastForward] {
      reset(); model.controlReport = syntheticMotion(command)
      require(model.requiresSupervisedStop, "actual model retains \(command) STOP obligation")
      require(reply() == .terminateCancel && alerts == 1, "quit protects pending \(command) without receive")
      require(model.requiresSupervisedStop, "cancelling quit cannot clear motion evidence")
    }
    reset(); model.controlReport = syntheticMotion(uncertain: true); model.controlLockedOut = true
    require(reply() == .terminateCancel && alerts == 1, "uncertain locked-out motion still needs physical STOP")
    require(model.controlLockedOut && model.requiresSupervisedStop, "quit guard preserves lockout and receipt")

    reset(); model.isBusy = true
    require(reply() == .terminateCancel && alerts == 1, "admitted request blocks quit before a receipt exists")
    model.isBusy = false
    require(reply() == .terminateNow, "completed idle request releases quit")
    reset(); model.controlReport = syntheticMotion(); model.wholeTapeStopObserved()
    require(!model.requiresSupervisedStop && reply() == .terminateNow && alerts == 0,
      "observed STOP for current receipt permits quit")
    model.controlReport = syntheticMotion()
    require(reply() == .terminateCancel, "older STOP receipt cannot release new motion")

    reset(); WholeTapeAppDelegate.active = true
    require(reply() == .terminateCancel && alerts == 1, "active whole-tape owner remains protected")
    reset(); WholeTapeAppDelegate.receiveActive = true
    require(reply() == .terminateCancel && alerts == 1, "active receive owner remains protected")

    reset(); model.controlReport = syntheticMotion(uncertain: true); model.controlLockedOut = true
    var choices: [String] = []
    delegate.presentQuitAlert = { alert in
      alerts += 1; choices = alert.buttons.map(\.title); return .alertSecondButtonReturn
    }
    require(reply() == .terminateNow && alerts == 1 && choices.count == 2
      && choices[1].contains("physically stopped"), "idle motion has explicit physical-STOP quit escape")
    require(model.requiresSupervisedStop && model.controlLockedOut,
      "physical quit attestation does not fabricate a STOP receipt or clear lockout")

    for activity in ["job", "request", "receive"] {
      reset(); model.controlReport = syntheticMotion()
      delegate.presentQuitAlert = { _ in
        if activity == "job" { WholeTapeAppDelegate.active = true }
        if activity == "request" { model.isBusy = true }
        if activity == "receive" { WholeTapeAppDelegate.receiveActive = true }
        return .alertSecondButtonReturn
      }
      require(reply() == .terminateCancel, "new \(activity) activity during modal cannot bypass protection")
    }
    reset(); model.controlReport = syntheticMotion()
    delegate.presentQuitAlert = { _ in
      model.controlReport = syntheticMotion(); return .alertSecondButtonReturn
    }
    require(reply() == .terminateCancel, "replacement motion receipt invalidates earlier quit confirmation")
    reset(); model.controlReport = syntheticMotion()
    delegate.presentQuitAlert = { _ in model.wholeTapeStopObserved(); return .alertSecondButtonReturn }
    require(reply() == .terminateNow, "fresh STOP observation during confirmation permits quit")
    reset(); model.controlReport = syntheticMotion()
    for _ in 0..<3 { require(reply() == .terminateCancel, "repeated cancelled quit keeps obligation") }
    require(alerts == 3 && model.requiresSupervisedStop, "three quit attempts retain exact pending receipt")
    reset()
    print("QUIT_SUPERVISION_\(failures == 0 ? "PASS" : "FAIL") assertions=\(assertions) failures=\(failures); no hardware or tape commands")
    exit(failures == 0 ? 0 : 1)
  }
}

/// Interactive fixture for exercising the real NSAlert and quit delegate.
@MainActor private final class QuitFixtureWindow: NSObject {
  let model = RewindDVModel()
  let live = LiveMonitorModel(muteAudio: true)
  let delegate = WholeTapeAppDelegate()
  let window = NSWindow(contentRect: .init(x: 160, y: 160, width: 620, height: 230),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  let status = NSTextField(labelWithString: "")

  override init() {
    super.init()
    delegate.bind(model: model, live: live)
    NSApp.delegate = delegate
    NSApp.setActivationPolicy(.regular)
    let stack = NSStackView()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
    stack.edgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
    stack.addArrangedSubview(NSTextField(labelWithString: "OFFLINE FIXTURE — no driver, media, or physical tape operations"))
    stack.addArrangedSubview(status)
    for (title, action) in [("Simulate pending rewind", #selector(pending)),
      ("Simulate observed STOP", #selector(stopped)),
      ("Toggle request in progress", #selector(busy)), ("Quit", #selector(quit))] {
      stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
    }
    window.contentView = stack
    window.title = "Offline quit supervision regression"
    pending()
    window.center(); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc func pending() { model.controlReport = syntheticMotion(); update() }
  @objc func stopped() { model.wholeTapeStopObserved(); update() }
  @objc func busy() { model.isBusy.toggle(); update() }
  @objc func quit() { NSApp.terminate(nil) }
  private func update() {
    status.stringValue = "Synthetic STOP obligation: \(model.requiresSupervisedStop); request in progress: \(model.isBusy)"
  }
}
