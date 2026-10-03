// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

@MainActor final class GentleRecoveryModel: ObservableObject {
  @Published private(set) var snapshot: DVGentleRecovery.Snapshot?
  @Published private(set) var busy = false
  @Published private(set) var message = "No recovery plan open. Budgets belong to the physical tape you identify, not to a deck or filename."
  private(set) var journal: DVGentleRecoveryJournal?
  private var access: URL?
  func open(directory: URL, plan: DVGentleRecovery.Plan?, source: DVReviewedRangeExporter.Snapshot, mapSHA: String, accessRoot: URL) {
    guard !busy else { return }
    busy = true; journal = nil; snapshot = nil
    if let access { access.stopAccessingSecurityScopedResource() }; access = nil
    let granted = accessRoot.startAccessingSecurityScopedResource()
    Task {
      defer { busy = false }
      do {
        let loaded = try await Task.detached(priority: .utility) {
          try DVGentleRecoveryJournal(directory: directory, creating: plan, expectedSource: source, expectedMapSHA256: mapSHA)
        }.value
        journal = loaded; snapshot = try await loaded.snapshot()
        access = granted ? accessRoot : nil
        message = "Plan open. Position manually, stop the deck, confirm the physical tape and approve one pass. No automatic seeking or retries."
      } catch {
        if granted { accessRoot.stopAccessingSecurityScopedResource() }
        message = "Plan unavailable: \(error.localizedDescription)"
      }
    }
  }
  func refresh() {
    guard !busy, let journal else { return }
    busy = true
    Task {
      defer { busy = false }
      do { snapshot = try await journal.snapshot() }
      catch { snapshot = nil; message = "Plan verification failed: \(error.localizedDescription)" }
    }
  }
  func reconcile() {
    guard !busy, let journal else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await journal.reconcileInterrupted(operatorConfirmedStopped: true,
          note: "Operator explicitly confirmed the physical deck is stopped after interruption.")
        snapshot = try await journal.snapshot()
        message = "Interruption acknowledged. Unknown motion duration holds this plan; no new pass or automatic restart."
      } catch { message = "Reconciliation failed: \(error.localizedDescription)" }
    }
  }
}

struct GentleRecoveryView: View {
  @ObservedObject var recovery: GentleRecoveryModel
  @ObservedObject var map: TapeEvidenceMapModel
  let executionAvailable: Bool
  let start: (DVGentleRecoveryJournal, String, Int) -> Void
  @State private var tape = ""
  @State private var first = "0"
  @State private var end = "1"
  @State private var maximumAttempts = 3
  @State private var perTarget = 2
  @State private var passSeconds = 20
  @State private var totalSeconds = 300
  @State private var cooldown = 60
  @State private var positioningSeconds = 0
  @State private var selectedTarget = ""
  @State private var sameTape = false
  @State private var positioned = false
  @State private var attend = false
  @State private var formError = ""
  var body: some View {
    ArchiveSection("Gentle recovery planner — supervised passes") {
      VStack(alignment: .leading, spacing: 10) {
        Text(recovery.message).textSelection(.enabled)
        Text("A plan is a wear allowance, not a repair guarantee. Reuse the same plan for this tape: starting a new plan does not erase physical wear. Repositioning is manual and must be included in the charged seconds. Captures remain separate; no master replacement or merge.")
          .font(.caption).foregroundStyle(.secondary)
        ArchiveDisclosure("Create a source-bound recovery plan") {
          TextField("Physical tape label / inventory ID (required)", text: $tape)
          HStack {
            TextField("First file frame", text: $first)
            TextField("End frame (exclusive)", text: $end)
            Button("Use selected frame ±150") {
              if let frame = map.selection?.frameOrdinal, let count = map.receipt?.sourceSnapshot.frameCount {
                first = String(frame > 150 ? frame - 150 : 0); end = String(min(count, frame + 151))
              }
            }.disabled(map.selection == nil)
          }
          Text("File-frame ranges are review targets, NOT physical tape positions. Preview the area and position the tape yourself before starting.").font(.caption).foregroundStyle(.orange)
          HStack {
            Stepper("Total attempts: \(maximumAttempts)", value: $maximumAttempts, in: 1...20)
            Stepper("Per target: \(perTarget)", value: $perTarget, in: 1...20)
          }
          HStack {
            Stepper("PLAY limit: \(passSeconds)s", value: $passSeconds, in: 1...300)
            Stepper("Total motion allowance: \(totalSeconds)s", value: $totalSeconds, in: 30...7200, step: 30)
          }
          Stepper("Cooldown between attempts: \(cooldown)s", value: $cooldown, in: 10...3600, step: 10)
          Text("Each attempt charges reported positioning + PLAY limit + 10s STOP allowance before PLAY. Failed/cancelled attempts are not refunded. An overrun or unknown interrupted motion holds the plan.").font(.caption)
          HStack {
            Button("Create plan for this range…") { create(fromQueue: false) }
            Button("Create plan from visible review queue…") { create(fromQueue: true) }.disabled(map.reviewEvents.isEmpty)
          }.disabled(!map.canExportReports || recovery.busy)
        }
        HStack {
          Button("Open existing recovery plan…") { open() }.disabled(map.receipt == nil || recovery.busy)
          Button("Refresh attempts") { recovery.refresh() }.disabled(recovery.journal == nil || recovery.busy)
          if let journal = recovery.journal {
            Button("Show plan / attempts") { NSWorkspace.shared.activateFileViewerSelecting([journal.directory]) }
          }
        }
        if !formError.isEmpty { Text(formError).foregroundStyle(.red) }
        if let snapshot = recovery.snapshot {
          ArchiveHeading("Tape: \(snapshot.plan.tapeLabel)")
          Text("\(snapshot.attempts.count)/\(snapshot.plan.budget.maximumAttempts) attempts · \(snapshot.chargedSeconds)/\(snapshot.plan.budget.totalReservedSeconds)s charged · \(snapshot.plan.budget.passSeconds)s PLAY limit + \(snapshot.plan.budget.stopAllowanceSeconds)s stop allowance")
          if snapshot.plan.source != map.receipt?.sourceSnapshot || snapshot.plan.mapSHA256 != map.reader?.binding.mapReceiptSHA256 {
            Text("This plan does not match the currently open tape map. Execution is disabled.").foregroundStyle(.red)
          }
          Picker("Recovery target", selection: $selectedTarget) {
            Text("Select a target").tag("")
            ForEach(snapshot.plan.targets) { target in
              Text("Frames \(target.first)..<\(target.endExclusive) — \(target.reason)").tag(target.id)
            }
          }.onChange(of: selectedTarget) { _, _ in clearConfirmations() }
          Button("Inspect target in original tape map") {
            if let target = snapshot.plan.targets.first(where: { $0.id == selectedTarget }) { map.jump(to: target.first) }
          }.disabled(selectedTarget.isEmpty || map.busy || snapshot.plan.source != map.receipt?.sourceSnapshot)
          Stepper("Manual positioning/winding since last attempt: \(positioningSeconds)s", value: $positioningSeconds, in: 0...3600, step: 5)
          Toggle("I verified this physical tape matches the plan label", isOn: $sameTape)
          Toggle("I positioned the tape before the target and it is physically STOPPED", isOn: $positioned)
          Toggle("I will remain present and can press physical STOP immediately", isOn: $attend)
          if let reason = snapshot.refusal(target: selectedTarget, positioningSeconds: positioningSeconds) {
            Text(reason).font(.callout).foregroundStyle(.orange)
          }
          Text("After cooldown, click Refresh attempts to recheck availability. Reopen and verify the original DV if execution is unavailable.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Approve ONE bounded recovery pass…", systemImage: "record.circle") {
            guard let journal = recovery.journal else { return }
            start(journal, selectedTarget, positioningSeconds); clearConfirmations()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("recovery-approve-one-pass")
          .disabled(!executionAvailable || recovery.busy || !sameTape || !positioned || !attend ||
            snapshot.plan.source != map.receipt?.sourceSnapshot || snapshot.plan.mapSHA256 != map.reader?.binding.mapReceiptSHA256 ||
            snapshot.refusal(target: selectedTarget, positioningSeconds: positioningSeconds) != nil)
          if snapshot.unresolved != nil {
            Button("Acknowledge interrupted attempt — deck is physically stopped…") { reconcile() }
              .accessibilityIdentifier("recovery-confirm-physical-stop")
              .disabled(!executionAvailable || recovery.busy)
          }
          ArchiveDisclosure("Persistent attempts and evidence") {
            ForEach(snapshot.attempts) { attempt in
              VStack(alignment: .leading, spacing: 3) {
                ArchiveHeading("\(attempt.target) · \(attempt.phase.rawValue) · \(attempt.chargedSeconds)s charged")
                Text("\(attempt.id) · route \(attempt.route)").font(.caption.monospaced()).textSelection(.enabled)
                if let result = attempt.result {
                  Text("\(result.outcome) · \(result.completeFrames) frames; alignment/improvement unproved").font(.caption)
                  Text(result.note).font(.caption).textSelection(.enabled)
                  if let path = result.verificationPath { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                }
              }.padding(.vertical, 4)
            }
          }
        }
      }.padding(8)
      .onChange(of: map.directory) { _, _ in clearConfirmations() }
    }
  }
  private func clearConfirmations() { sameTape = false; positioned = false; attend = false }
  private func create(fromQueue: Bool) {
    guard let receipt = map.receipt, let binding = map.reader?.binding else { return }
    do {
      var targets: [DVGentleRecovery.Target] = []
      if fromQueue {
        for event in map.reviewEvents.sorted(by: { $0.item.firstFrameOrdinal < $1.item.firstFrameOrdinal }) {
          guard event.item.sourceSHA256 == receipt.sourceSnapshot.sourceSHA256 else { throw DVGentleRecovery.failure("queue source mismatch") }
          let first = event.item.firstFrameOrdinal, end = event.item.endFrameOrdinalExclusive
          if let previous = targets.last, first <= previous.endExclusive {
            targets.removeLast(); targets.append(.init(first: previous.first, endExclusive: max(previous.endExclusive, end), reason: "Coalesced visible review-queue observations"))
          } else { targets.append(.init(first: first, endExclusive: end, reason: event.item.summary)) }
        }
      } else {
        guard let first = UInt64(first), let end = UInt64(end) else { throw DVGentleRecovery.failure("enter valid file frame ordinals") }
        targets = [.init(first: first, endExclusive: end, reason: "Operator-selected file-frame review region")]
      }
      let plan = try DVGentleRecovery.Plan(source: receipt.sourceSnapshot, mapSHA256: binding.mapReceiptSHA256, tapeLabel: tape,
        budget: .init(maximumAttempts: maximumAttempts, attemptsPerTarget: perTarget, passSeconds: passSeconds,
          totalReservedSeconds: totalSeconds, cooldownSeconds: cooldown), targets: targets)
      let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
      panel.message = "Choose a persistent plan location. Reuse this plan for this tape; budgets cannot be reset in place."
      guard panel.runModal() == .OK, let parent = panel.url else { return }
      if let mapDirectory = map.directory,
        DVGentleRecovery.isWithin(parent, directory: mapDirectory) {
        throw DVGentleRecovery.failure("store the recovery plan outside the immutable tape map")
      }
      if let journal = recovery.journal, DVGentleRecovery.isWithin(parent, directory: journal.directory) {
        throw DVGentleRecovery.failure("do not nest a new plan inside an existing plan")
      }
      let output = parent.appendingPathComponent("rewindDV-Recovery-\(plan.id)")
      recovery.open(directory: output, plan: plan, source: receipt.sourceSnapshot, mapSHA: binding.mapReceiptSHA256, accessRoot: parent)
      clearConfirmations(); selectedTarget = ""; formError = ""
    } catch { formError = error.localizedDescription }
  }
  private func open() {
    guard let receipt = map.receipt, let binding = map.reader?.binding else { return }
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    panel.message = "Choose the original recovery plan folder for this source/map. Interrupted attempts never resume automatically."
    if panel.runModal() == .OK, let directory = panel.url {
      recovery.open(directory: directory, plan: nil, source: receipt.sourceSnapshot, mapSHA: binding.mapReceiptSHA256, accessRoot: directory)
      clearConfirmations(); selectedTarget = ""; formError = ""
    }
  }
  private func reconcile() {
    let alert = NSAlert(); alert.messageText = "Confirm physical STOP after interruption"
    alert.informativeText = "This does not send a command. Confirm the tape is physically stopped. The prior reservation stays charged; unknown motion duration holds the plan. No automatic resume."
    alert.addButton(withTitle: "Deck is physically stopped"); alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { recovery.reconcile() }
  }
}
