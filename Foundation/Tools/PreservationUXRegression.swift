// OFFLINE ONLY. Native preservation UI with a marked, derived local fixture.
// No driver, deck commands, source overwrite or replacement-media output.
import AppKit
import CryptoKit
import Foundation
import SwiftUI

@main struct PreservationUXRegression {
  @MainActor static func main() async throws {
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let original = try Data(contentsOf: source)
    precondition(original.count >= 260 * 120_000)
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-Preservation-UX-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    var synthetic = Data(original.prefix(260 * 120_000))
    // Remove source-rate packs in the FIRST DERIVED frame only. This exercises
    // missing-metadata review, never modifies or diagnoses the user's fixture.
    for block in stride(from: 0, to: 120_000, by: 80) {
      if synthetic[block] & 0xe0 == 0x60, synthetic[block + 3] == 0x50 {
        synthetic[block + 3] = 0xff
      }
    }
    let fixture = parent.appendingPathComponent("SYNTHETIC-metadata-absence.dv")
    try synthetic.write(to: fixture, options: .withoutOverwriting)
    let model = TapeEvidenceMapModel()
    model.create(source: fixture, parent: parent)
    try await wait(model)
    precondition(model.receipt?.frameLedgerRecordCount == 260 && model.summaries.count == 2)
    let mapURL = model.directory!
    let record = model.page!.records[0]
    precondition(record.issues.contains { $0.code == .audioRateAbsent })
    model.select(record)
    let frameSHA = model.selection!.frameSHA256
    let reviewURL = parent.appendingPathComponent("review")
    model.connectReview(at: reviewURL, create: true, access: parent)
    try await wait(model)
    model.addSelectedForReview(note: "SYNTHETIC UI TEST — missing AAUX metadata is not packet loss")
    try await wait(model)
    precondition(model.reviewRevision == 1 && model.reviewItemCount == 1)
    model.updateReview(model.reviewEvents[0].item, state: .deferred, note: "Review later; no tape reread")
    try await wait(model)
    precondition(model.reviewRevision == 2 && model.reviewEvents.count == 1 && model.reviewEvents[0].state == .deferred)
    model.loadPage(1); try await wait(model)
    precondition(model.page?.records.count == 4)
    model.open(mapURL); try await wait(model)
    model.select(model.page!.records[0])
    precondition(model.selection?.frameSHA256 == frameSHA)
    model.connectReview(at: reviewURL, create: false, access: parent); try await wait(model)
    precondition(model.reviewRevision == 2 && model.reviewEvents[0].state == .deferred)
    let originalAfter = try Data(contentsOf: source)
    let fixtureAfter = try Data(contentsOf: fixture)
    precondition(originalAfter == original && fixtureAfter == synthetic)
    _ = NSApplication.shared
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    let view = NSHostingView(rootView: TapeEvidenceMapView(map: model).padding(20).frame(width: 1200).environment(\.colorScheme, .dark))
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 2000)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    try await Task.sleep(for: .milliseconds(100))
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: parent.appendingPathComponent("preservation-ui.png"))
    }
    print("PRESERVATION_NATIVE_UI_PASS 260 frames; paging; source/frame provenance; queue create/defer/reopen; unchanged source and derived fixture")
    print("LOCAL_ONLY_ARTIFACTS=\(parent.path)")
  }
  @MainActor static func wait(_ model: TapeEvidenceMapModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    precondition(!model.busy, "UI operation did not finish: \(model.message) \(model.reviewMessage)")
  }
}
