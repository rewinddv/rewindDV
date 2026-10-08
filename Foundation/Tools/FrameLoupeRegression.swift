// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline regression: actual UI model, SwiftUI view and VideoToolbox/Metal still.
// No DriverBridge, IOKit user client, transport or capture implementation linked.
import AppKit
import SwiftUI

@main struct FrameLoupeRegression {
  @MainActor static func main() async throws {
    guard [4, 5].contains(CommandLine.arguments.count) else { fatalError("Usage: FrameLoupeRegression source.dv map-directory new-screenshot.png [report-parent]") }
    _ = NSApplication.shared
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let screenshot = URL(fileURLWithPath: CommandLine.arguments[3])
    guard !FileManager.default.fileExists(atPath: screenshot.path) else { fatalError("Refuse screenshot overwrite") }
    let model = TapeEvidenceMapModel()
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      guard condition() else { throw NSError(domain: "FrameLoupeRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
      print("PASS: \(message)")
    }
    func settled() async throws {
      let deadline = Date().addingTimeInterval(120)
      while model.busy || model.detailBusy {
        guard Date() < deadline else { throw NSError(domain: "FrameLoupeRegression", code: 2) }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    model.open(directory); try await settled()
    try require(model.receipt != nil && model.page != nil, "actual UI model opens the verified map")
    model.connectSource(source); try await settled()
    try require(model.originalFrame != nil && model.frameImage != nil, "original bytes and native decoded still are available")
    model.findIssue(forward: true, code: .nonzeroVideoSTA); try await settled()
    try require(model.selection?.issues.contains { $0.code == .nonzeroVideoSTA } == true, "tape-wide warning navigation reaches a video-status observation")
    guard let frame = model.originalFrame, let selected = model.selection else { fatalError(model.sourceMessage) }
    // Host the actual view offscreen: ImageRenderer cannot draw native pickers,
    // text fields and checkboxes, and substitutes misleading placeholders.
    let host = NSHostingView(rootView: DVFrameForensicsView(frame: frame, image: model.frameImage, identity: selected)
      .frame(width: 1220).environment(\.colorScheme, .dark).padding(16).background(Color.black))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1252, height: 1600),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No rendered loupe") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    window.close()
    try png.write(to: screenshot, options: .withoutOverwriting)
    print("RENDERED: \(screenshot.path)")
    if let page = model.page {
      for record in page.records.prefix(20) { model.select(record) }
      try await settled()
      let last = page.records.prefix(20).last!.boundaryEvidence.frameOrdinal
      try require(model.selection?.frameOrdinal == last && model.originalFrame?.evidence.semantics.frameOrdinal == last,
        "rapid frame selection never publishes stale bytes or provenance")
    }
    model.open(directory); model.cancel(); try await settled()
    try require(model.originalFrame == nil && model.frameImage == nil, "cancel/reopen clears previous source pixels and bytes")
    model.open(directory); try await settled()
    model.connectSource(source); try await settled()
    try require(model.frameImage != nil, "reopen and source verification recover normally")
    if CommandLine.arguments.count == 5 {
      let parent = URL(fileURLWithPath: CommandLine.arguments[4])
      model.analyzeScenes(); try await settled()
      guard let scenes = model.scenePlan else { fatalError(model.sceneMessage) }
      try require(scenes.source.frameCount == model.receipt?.sourceSnapshot.frameCount,
        "scene proposals cover the verified source")
      for cut in scenes.boundaries {
        model.decideScene(cut.frame, decision: .accepted, note: "Offline regression acceptance; not operator take qualification")
      }
      model.publishScenes(parent: parent, exportDV: true); try await settled()
      guard let sceneOutput = model.sceneDirectory else { fatalError(model.sceneMessage) }
      print("SCENE_DIRECTORY: \(sceneOutput.path)")
      try require(FileManager.default.fileExists(atPath: sceneOutput.appendingPathComponent("scenes.json").path),
        "UI exports a verified, complete raw-DV scene partition")
      model.analyzeScenes(); try await settled()
      model.restoreScenes(sceneOutput.appendingPathComponent("review.json")); try await settled()
      try require(model.scenePlan?.pendingCount == 0, "scene review decisions restore against verified evidence")
      let sceneImage = screenshot.deletingLastPathComponent().appendingPathComponent(screenshot.deletingPathExtension().lastPathComponent + "-scenes.png")
      let sceneHost = NSHostingView(rootView: DVSceneReviewView(map: model)
        .frame(width: 1300).environment(\.colorScheme, .dark).padding(16).background(Color.black))
      let sceneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1332, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
      sceneWindow.isReleasedWhenClosed = false; sceneWindow.appearance = NSAppearance(named: .darkAqua)
      sceneWindow.contentView = sceneHost; sceneWindow.setContentSize(sceneHost.fittingSize); sceneHost.layoutSubtreeIfNeeded()
      guard let sceneBitmap = sceneHost.bitmapImageRepForCachingDisplay(in: sceneHost.bounds) else { fatalError("Scene UI bitmap unavailable") }
      sceneHost.cacheDisplay(in: sceneHost.bounds, to: sceneBitmap)
      guard let scenePNG = sceneBitmap.representation(using: .png, properties: [:]) else { fatalError("Scene PNG unavailable") }
      try scenePNG.write(to: sceneImage, options: .withoutOverwriting); sceneWindow.close()
      print("SCENE_UI_RENDERED: \(sceneImage.path)")
      model.exportReports(parent: parent); try await settled()
      guard let reports = model.reportDirectory else { fatalError(model.reportMessage) }
      for name in ["analysis.json", "frames.csv", "review.vtt", "dvrescue.xml", "report.json"] {
        try require(FileManager.default.fileExists(atPath: reports.appendingPathComponent(name).path), "UI model exported \(name)")
      }
      print("REPORT_DIRECTORY: \(reports.path)")
      model.importExternalReport(reports.appendingPathComponent("dvrescue.xml"), parent: parent); try await settled()
      try require(model.externalReport?.claimedSourceBinding.hasPrefix("external_report_claims_matching") == true,
        "UI imports exported XML into a separate external-claims namespace")
      let reportImage = screenshot.deletingLastPathComponent().appendingPathComponent(screenshot.deletingPathExtension().lastPathComponent + "-reports.png")
      let reportHost = NSHostingView(rootView: TapeEvidenceMapView(map: model)
        .frame(width: 1400, height: 1000, alignment: .topLeading).clipped()
        .environment(\.colorScheme, .dark).padding(16).background(Color.black))
      let reportWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1432, height: 1032), styleMask: .borderless, backing: .buffered, defer: false)
      reportWindow.isReleasedWhenClosed = false; reportWindow.appearance = NSAppearance(named: .darkAqua)
      reportWindow.contentView = reportHost; reportWindow.setContentSize(reportHost.fittingSize); reportHost.layoutSubtreeIfNeeded()
      guard let bitmap = reportHost.bitmapImageRepForCachingDisplay(in: reportHost.bounds) else { fatalError("Report UI bitmap unavailable") }
      reportHost.cacheDisplay(in: reportHost.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Report UI PNG unavailable") }
      try png.write(to: reportImage, options: .withoutOverwriting); reportWindow.close()
      print("REPORT_UI_RENDERED: \(reportImage.path)")
      model.open(directory); try await settled()
      try require(model.externalReport == nil && model.reportDirectory == nil, "changing maps clears prior external-report context")
      try require(model.scenePlan == nil && model.sceneDirectory == nil, "changing maps clears scene review authority")
      print("OFFLINE_REPORT_UI_PASS")
      // A clearly named synthetic derivative exercises actual cut controls;
      // no metadata is written to the user's original file.
      let fixture = parent.appendingPathComponent("synthetic-scene-markers.dv")
      let fixtureMap = parent.appendingPathComponent("synthetic-scene-map")
      guard let frameOffset = frame.evidence.semantics.frameByteOffset else { fatalError("Source frame offset unavailable") }
      var fixtureBytes = Data()
      for ordinal in 0..<4 {
        var sample = frame.bytes
        for pack in frame.evidence.semantics.packs where ["0x51", "0x61"].contains(pack.typeHex) {
          for offset in pack.sourceByteOffsets {
            let local = Int(offset - frameOffset) + 2
            sample[local] = ordinal < 2 ? (sample[local] | 0x80) : (sample[local] & 0x7f)
            if pack.typeHex == "0x51" { sample[local] |= 0x40 }
          }
        }
        fixtureBytes.append(sample)
      }
      try fixtureBytes.write(to: fixture, options: .withoutOverwriting)
      _ = try DVTapeEvidenceMapExporter.create(source: fixture, destination: fixtureMap)
      model.open(fixtureMap); try await settled(); model.connectSource(fixture); try await settled()
      model.analyzeScenes(); try await settled()
      try require(model.scenePlan?.boundaries.map(\.frame) == [2], "synthetic recorded marker creates exactly one reviewable cut")
      model.loadPage(0, selecting: 1); try await settled()
      try require(model.frameImage != nil && model.selection?.frameOrdinal == 1, "before-cut preview decodes verified original frame")
      model.loadPage(0, selecting: 2); try await settled()
      try require(model.frameImage != nil && model.selection?.frameOrdinal == 2, "after-cut preview decodes verified original frame")
      model.decideScene(2, decision: .accepted, note: "Synthetic fixture only")
      let cutHost = NSHostingView(rootView: DVSceneReviewView(map: model, initialFrame: 2)
        .frame(width: 1300).environment(\.colorScheme, .dark).padding(16).background(Color.black))
      let cutWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1332, height: 1100), styleMask: .borderless, backing: .buffered, defer: false)
      cutWindow.isReleasedWhenClosed = false; cutWindow.appearance = NSAppearance(named: .darkAqua)
      cutWindow.contentView = cutHost; cutWindow.setContentSize(cutHost.fittingSize); cutHost.layoutSubtreeIfNeeded()
      guard let bitmap = cutHost.bitmapImageRepForCachingDisplay(in: cutHost.bounds) else { fatalError("Cut UI unavailable") }
      cutHost.cacheDisplay(in: cutHost.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cut PNG unavailable") }
      let cutImage = screenshot.deletingLastPathComponent().appendingPathComponent(screenshot.deletingPathExtension().lastPathComponent + "-synthetic-cut.png")
      try png.write(to: cutImage, options: .withoutOverwriting); cutWindow.close()
      model.publishScenes(parent: parent, exportDV: true); try await settled()
      guard let splitOutput = model.sceneDirectory else { fatalError(model.sceneMessage) }
      let receipt = try JSONDecoder().decode(DVSceneSegmentation.Receipt.self, from: Data(contentsOf: splitOutput.appendingPathComponent("scenes.json")))
      var restored = Data()
      for output in receipt.outputs { restored.append(try Data(contentsOf: splitOutput.appendingPathComponent(output.file))) }
      try require(receipt.outputs.count == 2 && restored == fixtureBytes, "actual UI exports two scene copies that reassemble bit-for-bit")
      print("SYNTHETIC_SCENE_DIRECTORY: \(splitOutput.path)")
      print("SYNTHETIC_SCENE_UI_RENDERED: \(cutImage.path)")
      print("OFFLINE_SCENE_UI_PASS")
      // The actual recovery UI/model, still without any driver or transport.
      model.open(directory); try await settled(); model.connectSource(source); try await settled()
      let target = DVGentleRecovery.Target(first: 10, endExclusive: 40, reason: "Offline UI qualification only")
      let plan = try DVGentleRecovery.Plan(source: model.receipt!.sourceSnapshot,
        mapSHA256: model.reader!.binding.mapReceiptSHA256, tapeLabel: "OFFLINE UI TEST — NOT A PHYSICAL TAPE",
        budget: .init(), targets: [target])
      try await model.validateRecoveryTarget(target, plan: plan)
      let recovery = GentleRecoveryModel(), planDirectory = parent.appendingPathComponent("recovery-ui-plan")
      recovery.open(directory: planDirectory, plan: plan, source: plan.source, mapSHA: plan.mapSHA256, accessRoot: parent)
      while recovery.busy { try await Task.sleep(for: .milliseconds(20)) }
      try require(recovery.snapshot?.plan == plan, "recovery UI creates and rereads source-bound plan")
      guard let journal = recovery.journal else { fatalError(recovery.message) }
      let attempt = try await journal.reserve(target: target.id, route: "SYNTHETIC — NO HARDWARE", positioningSeconds: 10, confirmedTapeAndPosition: true)
      try await journal.recordPlayIntent(attempt.id, route: attempt.route)
      try await journal.finish(attempt.id, result: .init(outcome: "synthetic_UI_test_not_capture", observedSeconds: 5, note: "NO REAL DECK OR CAPTURE"), physicalStopConfirmed: true)
      recovery.refresh(); while recovery.busy { try await Task.sleep(for: .milliseconds(20)) }
      try require(recovery.snapshot?.chargedSeconds == 40 && recovery.snapshot?.attempts.count == 1,
        "recovery UI shows persistent charged attempt without refund")
      let recoveryHost = NSHostingView(rootView: GentleRecoveryView(recovery: recovery, map: model, executionAvailable: false,
        start: { _,_,_ in fatalError("Offline UI must never execute") })
        .frame(width: 1220).environment(\.colorScheme, .dark).padding(16).background(Color.black))
      let recoveryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1252, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
      recoveryWindow.isReleasedWhenClosed = false; recoveryWindow.appearance = NSAppearance(named: .darkAqua)
      recoveryWindow.contentView = recoveryHost; recoveryWindow.setContentSize(recoveryHost.fittingSize); recoveryHost.layoutSubtreeIfNeeded()
      guard let bitmap = recoveryHost.bitmapImageRepForCachingDisplay(in: recoveryHost.bounds) else { fatalError("Recovery UI unavailable") }
      recoveryHost.cacheDisplay(in: recoveryHost.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Recovery PNG unavailable") }
      let recoveryImage = screenshot.deletingLastPathComponent().appendingPathComponent("recovery-ui.png")
      try png.write(to: recoveryImage, options: .withoutOverwriting); recoveryWindow.close()
      print("RECOVERY_UI_RENDERED: \(recoveryImage.path)")
      print("OFFLINE_RECOVERY_UI_PASS")
      try await MultiPassUIRegression.run(parent: parent)
    }
    print("OFFLINE_FRAME_LOUPE_PASS")
  }
}
