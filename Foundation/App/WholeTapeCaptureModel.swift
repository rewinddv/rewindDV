// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import UserNotifications

/// Durable intent/state writes are outside the UI and receive-owner executors.
/// Observations are linear-sized sidecars; stage checkpoints do not grow once
/// per packet or once per poll. Recovery never executes any recorded intent.
private actor WholeTapeEvidence {
  let directory: URL
  private let receipts: URL
  private let journal: WholeTapeJobJournal
  private let route: String
  private var ordinal = 0
  private var captureURL: URL?
  private var captureBinding: WholeTapeJobEvidence.Capture?

  private func update() -> WholeTapeJobEvidence.Update {
    .init(jobID: journal.job.jobID, routeIdentity: route)
  }
  func bindCapture(_ source: URL?) throws {
    guard let source else { return }
    let url = source.standardizedFileURL
    guard url.deletingLastPathComponent() == directory.standardizedFileURL else {
      throw DVIngestError.invalidEvidence("Job capture directory mismatch")
    }
    if let captureURL {
      guard captureURL == url else { throw DVIngestError.invalidEvidence("Job capture was replaced") }
      return
    }
    let binding = WholeTapeJobEvidence.Capture(relativeDirectory: url.lastPathComponent)
    var value = update(); value.bindCapture = binding
    try journal.account(value)
    captureURL = url; captureBinding = binding
  }
  func stopEvidence(_ kind: WholeTapeJobEvidence.Stop.Kind, receipts: [String]) throws {
    var value = update(); value.stop = .init(kind, receipts: receipts)
    try journal.account(value)
  }
  func finalEvidence(capture url: URL?, dv: DVIngestVerification?, hdv: HDVIngestVerification?,
                     receiveClosed: Bool) throws {
    guard let binding = captureBinding else {
      // A cancelled preflight must never borrow a previous LiveMonitor result.
      guard url == nil, dv == nil, hdv == nil else { throw DVIngestError.invalidEvidence("Final capture has no job binding") }
      return
    }
    guard url?.standardizedFileURL == captureURL, !(dv != nil && hdv != nil) else {
      throw DVIngestError.invalidEvidence("Final capture/session mismatch")
    }
    var value = update(); value.captureID = binding.id; value.receiveClosed = receiveClosed
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if let dv {
      let report = captureURL!.appendingPathComponent(dv.verificationFile)
      let bytes = try Data(contentsOf: report)
      guard try encoder.encode(JSONDecoder().decode(DVIngestVerification.self, from: bytes)) == encoder.encode(dv) else {
        throw DVIngestError.invalidEvidence("DV verifier/report mismatch")
      }
      let reportHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      if journal.job.accounting?.verification?.reportSHA256 != reportHash {
        _ = try evidence("Final DV verifier report; automation outcome unchanged", source: report)
      }
      let passed = dv.finalAcknowledgementConfirmed && dv.integritySHA256Verified
        && (dv.completeDVFrames == 0 || dv.nativeDVRereadVerified)
      value.verification = .init(format: .dv, passed: passed,
        reportSHA256: reportHash,
        completeDVFrames: passed ? dv.completeDVFrames : nil, needsLossReview: dv.needsLossReview)
    } else if let hdv {
      let report = captureURL!.appendingPathComponent(hdv.verificationFile)
      let bytes = try Data(contentsOf: report)
      guard try encoder.encode(JSONDecoder().decode(HDVIngestVerification.self, from: bytes)) == encoder.encode(hdv) else {
        throw DVIngestError.invalidEvidence("HDV verifier/report mismatch")
      }
      let reportHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      if journal.job.accounting?.verification?.reportSHA256 != reportHash {
        _ = try evidence("Final HDV verifier report; no DV-frame count claimed", source: report)
      }
      let passed = hdv.finalAcknowledgementConfirmed && hdv.integritySHA256Verified
        && (hdv.transportPacketCount == 0 || hdv.nativeTSRereadVerified)
      value.verification = .init(format: .hdv, passed: passed,
        reportSHA256: reportHash,
        transportPackets: passed ? hdv.transportPacketCount : nil,
        transportBytes: passed ? hdv.transportBytes : nil, needsLossReview: hdv.needsLossReview)
    }
    try journal.account(value)
  }
  func summary() throws -> WholeTapeJobSummary {
    // UI/report use the same replay-checked reader as reopened jobs.
    try WholeTapeJobJournal.readSummary(from: journal.directory)
  }

  init(parent: URL, route: String) throws {
    self.route = route
    directory = try CaptureDirectory.create(parent: parent, kind: .wholeTape)
    receipts = directory.appendingPathComponent("receipts", isDirectory: true)
    let checkpoints = directory.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false)
    journal = try WholeTapeJobJournal(parentDirectory: checkpoints, routeIdentity: route)
    for parent in [directory, parent] {
      let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard fd >= 0 else { throw DVIngestError.invalidEvidence("Tape job parent unavailable") }
      defer { Darwin.close(fd) }
      guard Darwin.fsync(fd) == 0 else { throw DVIngestError.invalidEvidence("Tape job parent sync failed") }
    }
  }

  func evidence(_ message: String, source: URL? = nil) throws -> String {
    struct Receipt: Encodable {
      let version: Int, sequence: Int
      let route: String, message: String
      let uptimeNanoseconds: UInt64
      let originalPath: String?
      let originalBytes: Data?
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(Receipt(version: 1, sequence: ordinal, route: route,
      message: message, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
      originalPath: source?.path, originalBytes: try source.map { try Data(contentsOf: $0) }))
    let file = receipts.appendingPathComponent(String(format: "%08d.json", ordinal))
    let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw DVIngestError.invalidEvidence("Whole-tape receipt creation failed") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
    let directoryFD = Darwin.open(receipts.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw DVIngestError.invalidEvidence("Whole-tape receipt directory unavailable") }
    defer { Darwin.close(directoryFD) }
    guard Darwin.fsync(directoryFD) == 0 else { throw DVIngestError.invalidEvidence("Whole-tape receipt sync failed") }
    ordinal += 1
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  func record(_ event: WholeTapeJob.Event, digest: String, frames: UInt64 = 0) throws {
    try journal.record(.init(event: event, evidenceSHA256: digest, routeIdentity: route, completeFrames: frames))
  }
  func interrupt(_ message: String, operatorRequested: Bool, budgetExpired: Bool = false) throws {
    guard !journal.job.isTerminal else { return }
    let digest = try evidence(message)
    try record(budgetExpired ? .watchdogExpired : operatorRequested ? .cancel : .failure, digest: digest)
  }
}

/// The app must not exit normally while a request, job or receiver owns work.
/// Forced termination remains an interrupted journal, never automatic resume.
@MainActor final class WholeTapeAppDelegate: NSObject, NSApplicationDelegate {
  static var active = false
  static var receiveActive = false
  private weak var model: RewindDVModel?
  private weak var live: LiveMonitorModel?
  var presentQuitAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

  func bind(model: RewindDVModel, live: LiveMonitorModel) {
    self.model = model
    self.live = live
  }

  private var workActive: Bool {
    Self.active || Self.receiveActive || model?.wholeTapeActive == true
      || model?.isBusy == true || live?.active == true || live?.busy == true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Read the owners directly: SwiftUI's receive onChange can lag admission.
    if workActive {
      let alert = NSAlert()
      alert.messageText = "A tape request, reception or verification is still active"
      alert.informativeText = "Wait for the request to finish, or stop the job and wait for verification before quitting. If software cannot stop the tape, use physical STOP, then finish receiving."
      alert.addButton(withTitle: "Keep Open")
      _ = presentQuitAlert(alert)
      return .terminateCancel
    }
    guard model?.requiresSupervisedStop == true || live?.awaitingTapeStop == true
      || live?.receiverFailedWithoutTapeStopProof == true else { return .terminateNow }

    let receipt = model?.controlReport?.receiptURL
    let alert = NSAlert()
    alert.messageText = "The tape may still be moving"
    alert.informativeText = "Use the deck's physical STOP and confirm the tape has stopped before quitting. Quitting does not send a tape command."
    alert.addButton(withTitle: "Keep Open")
    alert.addButton(withTitle: "I have physically stopped the tape — Quit")
    let choice = presentQuitAlert(alert)
    // A modal alert runs a nested event loop. New work or a replacement motion
    // receipt cannot be released by a confirmation about the earlier state.
    guard choice == .alertSecondButtonReturn, !workActive,
      model?.controlReport?.receiptURL == receipt else { return .terminateCancel }
    return .terminateNow
  }
}

@MainActor final class WholeTapeCaptureModel: ObservableObject {
  struct RecoveryRequest {
    let journal: DVGentleRecoveryJournal
    let target: String
    let positioningSeconds: Int
    let confirmedTapeAndPosition: Bool
  }
  @Published private(set) var active = false
  @Published private(set) var status = "Rewind → receive before PLAY → capture through gaps → observed stop → verify."
  @Published private(set) var evidenceURL: URL?
  @Published private(set) var needsAttention = false
  @Published private(set) var notificationStatus = ""
  @Published var notifyWhenFinished = true
  private var task: Task<Void, Never>?
  @Published private(set) var stopRequested = false
  private var stopRequestedUptime: UInt64?
  @Published private(set) var finalizing = false
  var canRequestStop: Bool { active && !stopRequested && !finalizing }
  var canConfirmPhysicalStop: Bool { active && !finalizing }
  private var physicalStopConfirmed = false
  private var receiverPrepared = false
  private var motionMayPersist = false
  private var accountingFailure: String?
  private var recoveryDeadline: Task<Void, Never>?
  private var recoveryForcePhysicalStop = false
  private var recoveryStarted: ContinuousClock.Instant?
  private var recoveryStopped: ContinuousClock.Instant?
  @Published private(set) var recoveryBudgetStop = false
  private let sampleInterval: Duration
  private let notificationPreparationOverride: (@MainActor @Sendable () async -> Void)?
  private let notificationDeliveryOverride: (@MainActor @Sendable (String, String) async -> Void)?

  init(sampleInterval: Duration = .seconds(1),
       notificationPreparationOverride: (@MainActor @Sendable () async -> Void)? = nil,
       notificationDeliveryOverride: (@MainActor @Sendable (String, String) async -> Void)? = nil) {
    self.sampleInterval = sampleInterval
    self.notificationPreparationOverride = notificationPreparationOverride
    self.notificationDeliveryOverride = notificationDeliveryOverride
  }

  /// No Task.cancel(): a dispatched STATUS must reach its terminal result before
  /// STOP can use the FCP owner. Cancellation only revokes future job actions.
  func requestStop() {
    guard canRequestStop else { return }
    stopRequested = true
    stopRequestedUptime = DispatchTime.now().uptimeNanoseconds
    status = "STOP requested — waiting for the current deck request, then confirming mechanical stop. Reception continues until stopped."
  }
  func finishAfterPhysicalStop() {
    guard canConfirmPhysicalStop else { return }
    physicalStopConfirmed = true; stopRequested = true
  }

  func start(model: RewindDVModel, live: LiveMonitorModel, destination: URL, recovery: RecoveryRequest? = nil) {
    guard !active, !live.active, !live.busy, !live.lockedOut,
      let deck = model.selectedDeck, let route = model.selectedRoute,
      model.acquireWholeTapeOwnership() else {
      if recovery != nil { status = "Recovery not started: idle deck/receiver and exclusive transport ownership are required. No command or attempt was issued." }
      return
    }
    active = true; needsAttention = false; stopRequested = false; finalizing = false
    stopRequestedUptime = nil
    physicalStopConfirmed = false; receiverPrepared = false; evidenceURL = nil
    motionMayPersist = false
    accountingFailure = nil
    recoveryForcePhysicalStop = false; recoveryStarted = nil; recoveryStopped = nil; recoveryBudgetStop = false
    WholeTapeAppDelegate.active = true
    let routeID = "\(route.guid):\(route.driverInstanceID):\(route.deviceIncarnation):\(route.routeEpoch):\(route.generation):\(route.nodeID)"
    // Retain the active job until its existing finalization path releases it.
    // Explicit ownership avoids Swift 6.4's nested weak-capture ambiguity.
    task = Task { [self] in
      let access = destination.startAccessingSecurityScopedResource()
      let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Preserving a moving tape without interrupting FireWire reception")
      defer {
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        if access { destination.stopAccessingSecurityScopedResource() }
        ProcessInfo.processInfo.endActivity(activity)
        active = false; WholeTapeAppDelegate.active = false
        model.releaseWholeTapeOwnership(); task = nil
      }
      var recorder: WholeTapeEvidence?
      var recoveryAttempt: DVGentleRecovery.Attempt?
      do {
        // Join the passive physical-control observer before taking exclusive
        // whole-tape ownership of FCP and receive resources.
        await model.pauseExternalTransportObservation()
        let evidence = try WholeTapeEvidence(parent: destination, route: routeID)
        recorder = evidence; evidenceURL = evidence.directory
        // Notification consent is optional UI work. It must never delay deck
        // preflight, REWIND, receive preparation or PLAY.
        Task { [weak self] in await self?.prepareNotification() }
        status = "Checking the selected deck without moving tape…"
        let preflight = try await model.bridge.inspectDevice(deck, tapeStateOnly: true, expectedRoute: route)
        let digest = try await save(preflight, to: evidence)
        guard !preflight.controlLockedOut,
          preflight.validatedTransportState == [0x0c, 0x20, 0xc4, 0x60],
          preflight.entries.contains(where: { entry in
            guard entry.query == .tapeMediumInfo else { return false }
            if case .dvCassette = AVCTapeStatusDecoder.medium(entry.response) { return true }
            return false
          }) else { throw JobError.attention("Preflight could not confirm a stopped deck with a DV cassette. No rewind or PLAY was sent.") }
        try await evidence.record(.preflightPassed, digest: digest)
        if stopRequested { throw JobError.cancelled }
        if let recovery {
          let stoppedAgain = try await model.bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route)
          _ = try await save(stoppedAgain, to: evidence)
          guard !stoppedAgain.controlLockedOut, stoppedAgain.route == route,
            stoppedAgain.validatedTransportState == [0x0c,0x20,0xc4,0x60] else {
            throw JobError.attention("Recovery requires a second fresh stopped observation on the same route. No PLAY sent.")
          }
          // Reservation is fsync/reread-confirmed before receiving or motion.
          // The operator positioned the tape; no rewind or seek is performed.
          recoveryAttempt = try await recovery.journal.reserve(target: recovery.target, route: routeID,
            positioningSeconds: recovery.positioningSeconds, confirmedTapeAndPosition: recovery.confirmedTapeAndPosition)
          let positioned = try await evidence.evidence("Supervised recovery; operator confirms physical tape and position. File frame targets are advisory, not seek authority. Plan \(recovery.journal.plan.id), attempt \(recoveryAttempt!.id)")
          try await evidence.record(.operatorPositionedRecoveryStart, digest: positioned)
        } else {
        status = "Rewinding to the starting boundary…"
        try await command(.rewind, event: .rewindIntent, model: model, deck: deck, route: route, evidence: evidence)
        var rewind = TapeMotionEvidence(routeIdentity: routeID, direction: .rewind)
        let startReceipt = try await waitForNaturalStop(gate: &rewind, model: model, live: live,
          deck: deck, route: route, evidence: evidence, receiving: false)
        live.confirmReceiverTapeStopped(on: route)
        model.wholeTapeStopObserved()
        motionMayPersist = false
        try await evidence.record(.windStopped, digest: startReceipt)
        try await evidence.record(.inferredStart, digest: startReceipt)
        }
        if stopRequested { throw JobError.cancelled }
        status = "Starting raw receive before PLAY…"
        live.start(bridge: model.bridge, deck: deck, ingestParent: evidence.directory,
          captureFolderKind: .wholeTapePayload, expectedRoute: route)
        receiverPrepared = true
        while !live.receiverReady {
          if stopRequested { throw JobError.cancelled }
          guard live.active || live.busy else { throw JobError.attention("Receive could not start. No PLAY was sent. " + live.detail) }
          try await Task.sleep(for: .milliseconds(100))
        }
        let ready = try await evidence.evidence("Receiver ready before PLAY; raw flight: \(live.flightURL?.path ?? "missing")")
        try await evidence.bindCapture(live.flightURL)
        try await evidence.record(.receiverReady, digest: ready)
        if stopRequested { throw JobError.cancelled }
        if let recovery, let attempt = recoveryAttempt {
          try await recovery.journal.recordPlayIntent(attempt.id, route: routeID)
          recoveryStarted = ContinuousClock.now
          let budget = recovery.journal.plan.budget
          recoveryDeadline = Task { [weak self] in
            do {
              try await Task.sleep(for: .seconds(budget.passSeconds))
              guard let self, self.active, !self.finalizing, self.recoveryStopped == nil else { return }
              self.recoveryBudgetStop = true; self.requestStop()
              self.status = "Recovery pass limit reached. Requesting STOP once; raw reception continues through the stop tail."
              try await Task.sleep(for: .seconds(budget.stopAllowanceSeconds))
              guard self.active, self.recoveryStopped == nil, !self.finalizing else { return }
              self.recoveryForcePhysicalStop = true; self.needsAttention = true
              self.status = "STOP allowance exceeded. Use physical STOP now, then Finish receiving. No command retry; receive remains armed."
              await self.notify(title: "Recovery needs physical STOP", body: self.status)
            } catch { /* Finished jobs cancel only their local deadline, never FCP. */ }
          }
        }
        try await command(.play, event: .playIntent, model: model, deck: deck, route: route, evidence: evidence)
        live.prepareCaptureTransportPlay()
        status = "Capturing the tape. Missing timecode, metadata or DV signal does not stop receive."
        var playback = TapeMotionEvidence(routeIdentity: routeID, direction: .forwardPlayback)
        let endReceipt = try await waitForNaturalStop(gate: &playback, model: model, live: live,
          deck: deck, route: route, evidence: evidence, receiving: true)
        live.confirmReceiverTapeStopped(on: route)
        model.wholeTapeStopObserved()
        motionMayPersist = false
        recoveryStopped = ContinuousClock.now
        finalizing = true
        try await evidence.record(.transportStopped, digest: endReceipt)
        try await evidence.record(recovery == nil ? .inferredEnd : .supervisedRecoveryEnd, digest: endReceipt)
        status = "The deck reports stopped. Draining the final packets and verifying saved data…"
        // The receiver joins durable writes and drains its quiesced final ring.
        // There is no fixed sleep standing in for mechanical or DMA completion.
        await live.stopAndWait()
        try await evidence.finalEvidence(capture: live.flightURL, dv: live.verification,
          hdv: live.hdvVerification, receiveClosed: !live.active && !live.busy && !live.lockedOut)
        if let hdv = live.hdvVerification {
          guard recovery == nil, !live.lockedOut, hdv.integritySHA256Verified,
            hdv.finalAcknowledgementConfirmed, hdv.nativeTSRereadVerified,
            hdv.transportPacketCount > 0, hdv.captureFile != nil,
            let flight = live.flightURL else {
            throw JobError.attention("HDV verification is incomplete or this was a DV-only recovery pass. Raw evidence is retained.")
          }
          let verified = try await evidence.evidence("HDV transport-stream saved bytes independently verified; zero DV frames are claimed. Absolute BOT/EOT and exact missing-picture count remain unknown.",
            source: flight.appendingPathComponent(hdv.verificationFile))
          try await evidence.record(.receiveDrained, digest: verified, frames: 0)
          try await evidence.record(.verificationPassed, digest: verified, frames: 0)
          needsAttention = hdv.needsLossReview
          status = "HDV capture ended at an observed stop; original transport-stream bytes verified. "
            + (needsAttention ? "Transport warnings need review. " : "Review the transport-quality report. ")
            + "Tape boundaries are inferred, not absolute BOT/EOT proof. HDV hardware qualification is pending."
          await notify(title: needsAttention ? "HDV capture finished — review needed" : "HDV capture finished", body: status)
        } else {
        guard !live.lockedOut, let result = live.verification,
          result.integritySHA256Verified, result.finalAcknowledgementConfirmed,
          result.completeDVFrames == 0 || result.nativeDVRereadVerified,
          let flight = live.flightURL else {
          throw JobError.attention("Capture ended but verification did not complete. Raw evidence is retained. " + live.ingestDetail)
        }
        let verified = try await evidence.evidence("Final saved-byte verification; absolute BOT/EOT and exact missing-frame count remain unknown",
          source: flight.appendingPathComponent(result.verificationFile))
        try await evidence.record(.receiveDrained, digest: verified, frames: result.completeDVFrames)
        try await evidence.record(.verificationPassed, digest: verified, frames: result.completeDVFrames)
        let defects = result.needsLossReview
        needsAttention = defects || result.completeDVFrames == 0
        status = "Capture ended at an observed stop: \(result.completeDVFrames) DV frames; saved bytes verified. "
          + (defects ? "Quality warnings need review. " : "Review the source-quality report. ")
          + "Start/end boundaries inferred from observed tape motion and stop, not absolute position proof. A physical STOP can look the same as reaching tape end."
        if result.completeDVFrames == 0 { status += " No complete DV frames arrived; no DV file was created. Inspect the deck/output configuration before concluding the tape was blank." }
        if recovery == nil {
          await notify(title: needsAttention ? "Tape capture finished — review needed" : "Tape capture finished", body: status)
        } else {
          status = "Supervised recovery stopped naturally. No BOT/EOT or target coverage is inferred."
        }
        }
      } catch {
        if let recorder {
          do {
            if receiverPrepared { try await recorder.bindCapture(live.flightURL) }
            try await recorder.interrupt("Job interrupted: \(error.localizedDescription)",
              operatorRequested: stopRequested && !recoveryBudgetStop, budgetExpired: recoveryBudgetStop)
          } catch { noteAccountingFailure(error) }
        }
        if recovery != nil, recoveryStarted != nil { requestStop() }
        if stopRequested {
          await stopJob(model: model, live: live, deck: deck, route: route, recorder: recorder)
        } else {
          needsAttention = true
          status = "Needs attention: \(error.localizedDescription)"
          await notify(title: "Tape capture needs attention", body: status)
          // An automation/status/journal problem must not discard ongoing raw
          // reception. Leave it running until an explicit operator finish/STOP.
          if live.active || live.busy || motionMayPersist || model.requiresSupervisedStop {
            finalizing = false
            status += " Raw receive stays armed if available. Use the red STOP button, or physical STOP then Finish receiving."
            while !stopRequested { try? await Task.sleep(for: .milliseconds(250)) }
            await stopJob(model: model, live: live, deck: deck, route: route, recorder: recorder)
          }
        }
      }
      if let recovery, let attempt = recoveryAttempt {
        // Completion here proves only saved bytes and stopped transport. It
        // cannot establish target coverage, alignment or improved tape content.
        do {
          let seconds: Int? = recoveryStarted.map { start in
            let duration = start.duration(to: recoveryStopped ?? ContinuousClock.now).components
            return Int(duration.seconds) + (duration.attoseconds > 0 ? 1 : 0)
          }
          let result = receiverPrepared ? live.verification : nil
          let verified = result.map { $0.integritySHA256Verified && $0.finalAcknowledgementConfirmed && ($0.completeDVFrames == 0 || $0.nativeDVRereadVerified) } ?? false
          let verificationURL = result.flatMap { value in live.flightURL?.appendingPathComponent(value.verificationFile) }
          let verificationHash = try verificationURL.map { try Data(contentsOf: $0) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
          try await recovery.journal.finish(attempt.id, result: .init(
            outcome: verified ? (result?.completeDVFrames == 0 ? "verified_raw_capture_no_complete_DV" : "capture_bytes_verified_alignment_unproved") : "capture_incomplete_or_not_started",
            observedSeconds: seconds ?? 0, verificationPath: verificationURL?.path, verificationSHA256: verificationHash,
            nativeDVSHA256: result?.nativeDVSHA256, completeFrames: result?.completeDVFrames ?? 0,
            note: "\(status) No recovery/merge success inferred."), physicalStopConfirmed: !motionMayPersist)
          status = "Recovery pass ended; allowance remains charged. " + (verified ? "Saved bytes verified. " : "Capture requires inspection. ")
            + "Target coverage and improvement require comparison; no master was changed."
          if result?.completeDVFrames == 0 { status += " No complete DV frames arrived." }
          if let accountingFailure {
            status += " Job summary could not be persisted/verified: \(accountingFailure). Preserved capture evidence remains separate."
          }
          await notify(title: "Recovery pass ended — review required", body: status)
        } catch {
          needsAttention = true
          status = "Recovery attempt could not be closed durably: \(error.localizedDescription). Do not retry; inspect the plan and retained capture."
        }
      }
    }
  }

  private func waitForNaturalStop(gate: inout TapeMotionEvidence, model: RewindDVModel,
    live: LiveMonitorModel, deck: DiscoveredDeck, route: FoundationRoute,
    evidence: WholeTapeEvidence, receiving: Bool) async throws -> String {
    var recordedDV = false
    var elapsedStarted = false
    while !stopRequested {
      if receiving, !live.active || live.lockedOut {
        throw JobError.attention("Raw receiver ended unexpectedly; this is not end-of-tape proof. " + live.detail)
      }
      let report: DeviceInspectionReport
      do { report = try await model.bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route) }
      catch { if recoveryStarted != nil { recoveryForcePhysicalStop = true }; throw error }
      let digest = try await save(report, to: evidence)
      if stopRequested { throw JobError.cancelled }
      guard !report.controlLockedOut, report.route == route else {
        if recoveryStarted != nil { recoveryForcePhysicalStop = true }
        throw JobError.attention("Transport observation lost authority. Capture is not declared complete.")
      }
      if receiving, !recordedDV, live.completeFrames > 0 {
        let progress = try await evidence.evidence("Raw receiver reports \(live.completeFrames) complete frames; metadata is not a progress prerequisite")
        try await evidence.record(.receivedDV, digest: progress, frames: live.completeFrames)
        recordedDV = true
      }
      let observedAt = DispatchTime.now().uptimeNanoseconds
      let decision = gate.observe(response: report.validatedTransportState, route: gate.routeIdentity,
        receipt: report.receiptURL.path, uptimeNanoseconds: observedAt)
      if receiving, gate.sawExpectedMotion, !elapsedStarted {
        // The timer begins on the first fresh route-bound STATUS report of
        // forward PLAY. Later status polls prove continued motion but are not
        // new PLAY triggers and therefore must not reset the elapsed interval.
        elapsedStarted = true
        live.markCaptureTransportPlaying(atUptimeNanoseconds: observedAt)
      }
      switch decision {
      case .naturalStop:
        if receiving { live.markCaptureTransportStopped(atUptimeNanoseconds: observedAt) }
        return digest
      case .transportFault:
        throw JobError.attention("The deck reports ejection or an emergency/dew stop, not a successful tape boundary.")
      case .stoppedWithoutObservedMotion:
        // A tape already at BOT may stop REWIND before the first poll. Obtain a
        // fresh idle-only ATN observation, not a cached preflight value. ATN zero
        // plus completed rewind is an explicit inference, not absolute proof.
        if !receiving, gate.direction == .rewind {
          let position = try await model.bridge.inspectDevice(deck, tapeStateOnly: true, expectedRoute: route)
          let positionDigest = try await save(position, to: evidence)
          if !position.controlLockedOut, position.route == route,
            position.validatedTransportState == [0x0c,0x20,0xc4,0x60],
            position.entries.contains(where: {
              $0.query == .tapeAbsoluteTrackNumber && AVCTapeStatusDecoder.dvTrack($0.response)?.number == 0
            }) {
            return try await evidence.evidence("Starting boundary inferred: REWIND accepted, two fresh stopped observations, then fresh stopped DV ATN zero; motion not sampled; position receipt \(positionDigest)")
          }
        }
        throw JobError.attention("The deck reports stopped, but the requested motion was not observed and a starting boundary could not be corroborated. No command is replayed.")
      case .keepReceiving:
        if report.validatedTransportState == nil {
          needsAttention = true
          status = "Transport status unavailable; raw reception continues. Missing data is never treated as end of tape."
        }
      }
      if !receiving, !stopRequested {
        await model.sampleDeckTimecode(deck: deck, route: route,
          transport: report.validatedTransportState, receiving: false,
          stopping: stopRequested, wholeTapeOwner: true)
      }
      // Fresh independent STATUS samples; no retransmission of a prior command.
      // Faster display-only winding observation; capture keeps its unchanged
      // cadence. Neither is a timeout on data, timecode or capture length.
      let interval = receiving ? sampleInterval : min(sampleInterval, .milliseconds(200))
      for _ in 0..<20 {
        if stopRequested { throw JobError.cancelled }
        try await Task.sleep(for: interval / 20)
      }
    }
    throw JobError.cancelled
  }

  private func save(_ report: DeviceInspectionReport, to evidence: WholeTapeEvidence) async throws -> String {
    try await evidence.evidence(report.completion, source: report.receiptURL.appendingPathComponent("flight.ndjson"))
  }

  private func command(_ command: DeckCommand, event: WholeTapeJob.Event, model: RewindDVModel,
    deck: DiscoveredDeck, route: FoundationRoute, evidence: WholeTapeEvidence) async throws {
    let intent = try await evidence.evidence("User-started whole-tape job: one \(command.title) intent; no replay")
    try await evidence.record(event, digest: intent)
    if stopRequested { throw JobError.cancelled }
    // Keep a conservative STOP obligation even if perform throws after dispatch
    // but before it can return a report to the model.
    motionMayPersist = true
    let report: ControlAttemptReport
    do { report = try await model.bridge.perform(command, selectedDeck: deck, explicitlyArmed: true, expectedRoute: route) }
    catch { if recoveryStarted != nil { recoveryForcePhysicalStop = true }; throw error }
    model.wholeTapeControlCompleted(report)
    _ = try await evidence.evidence(report.message, source: report.receiptURL.appendingPathComponent("flight.ndjson"))
    guard report.disposition == .protocolAcceptedMotionUnverified else {
      if recoveryStarted != nil { recoveryForcePhysicalStop = true }
      throw JobError.attention("Control result is uncertain; use physical STOP. No command will be replayed.")
    }
  }

  private func stopJob(model: RewindDVModel, live: LiveMonitorModel, deck: DiscoveredDeck,
    route: FoundationRoute, recorder: WholeTapeEvidence?) async {
    if !physicalStopConfirmed && (motionMayPersist || model.requiresSupervisedStop) {
      do {
        if recoveryForcePhysicalStop { throw JobError.attention("Recovery motion authority uncertain; physical STOP required") }
        // perform revalidates the COMPLETE pinned route. No stale-route STOP.
        let dispatchUptime = DispatchTime.now().uptimeNanoseconds
        let report = try await model.bridge.perform(.stop, selectedDeck: deck, explicitlyArmed: true, expectedRoute: route)
        model.wholeTapeControlCompleted(report)
        if let recorder { _ = try? await recorder.evidence("STOP timing: requested_uptime_ns=\(stopRequestedUptime.map(String.init) ?? "unknown"); dispatch_boundary_uptime_ns=\(dispatchUptime); returned_uptime_ns=\(DispatchTime.now().uptimeNanoseconds)") }
        if let recorder {
          do {
            let receipt = try await recorder.evidence(report.message, source: report.receiptURL.appendingPathComponent("flight.ndjson"))
            if report.disposition == .protocolAcceptedMotionUnverified {
              try await recorder.stopEvidence(.accepted, receipts: [receipt])
            }
          } catch { noteAccountingFailure(error) }
        }
        guard report.disposition == .protocolAcceptedMotionUnverified else { throw JobError.attention("STOP result uncertain") }
        // ACCEPTED does not establish mechanical stop. Keep intake until two
        // fresh stable STOP observations or explicit physical confirmation.
        var stopped = TapeMotionEvidence(routeIdentity: "stop-confirmation", direction: .forwardPlayback)
        var stopObservations = 0
        var firstStableStopRecorded = false
        var stableStopReceipts: [String] = []
        while !physicalStopConfirmed {
          if recoveryForcePhysicalStop { throw JobError.attention("Recovery stop allowance exceeded") }
          let observation = try await model.bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route)
          var observationReceipt: String?
          if let recorder {
            do { observationReceipt = try await save(observation, to: recorder) }
            catch { noteAccountingFailure(error) }
          }
          guard !observation.controlLockedOut, observation.route == route else {
            throw JobError.attention("STOP observation uncertain")
          }
          let decision = stopped.observe(response: observation.validatedTransportState,
            route: "stop-confirmation", receipt: observation.receiptURL.path,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
          stopObservations += 1
          if observation.validatedTransportState == [0x0c,0x20,0xc4,0x60], !firstStableStopRecorded {
            firstStableStopRecorded = true
            if let recorder { _ = try? await recorder.evidence("First stable STOP observed; receive retained until second independent stable STOP") }
          }
          if decision == .naturalStop || decision == .stoppedWithoutObservedMotion {
            live.markCaptureTransportStopped()
            live.confirmReceiverTapeStopped(on: route)
            model.wholeTapeStopObserved()
            if let receipt = observationReceipt { stableStopReceipts.append(receipt) }
            if let recorder {
              do { try await recorder.stopEvidence(.deviceObserved, receipts: Array(stableStopReceipts.suffix(2))) }
              catch { noteAccountingFailure(error) }
            }
            break
          }
          if observation.validatedTransportState == [0x0c,0x20,0xc4,0x60], let receipt = observationReceipt {
            stableStopReceipts.append(receipt)
          } else { stableStopReceipts.removeAll() }
          if decision == .transportFault { throw JobError.attention("Deck reports transport fault") }
          status = "Waiting for confirmed mechanical stop; raw reception continues…"
          try await Task.sleep(for: TapeStopPollingPolicy.interval(afterObservation: stopObservations))
        }
      } catch {
        needsAttention = true
        status = "Software STOP could not be confirmed. Use physical STOP, then click Finish receiving. Raw receive remains armed if available."
        while !physicalStopConfirmed { try? await Task.sleep(for: .milliseconds(250)) }
      }
    }
    if physicalStopConfirmed {
      live.markCaptureTransportStopped()
      live.confirmReceiverTapeStopped(on: route)
      model.wholeTapeStopObserved()
      if let recorder {
        do {
          let receipt = try await recorder.evidence("Operator explicitly confirmed physical STOP; not a device observation")
          try await recorder.stopEvidence(.operatorConfirmed, receipts: [receipt])
        } catch { noteAccountingFailure(error) }
      }
    }
    motionMayPersist = false
    // Account for the request after the existing STOP owner has finished. A
    // summary write must not delay dispatch of the operator's STOP command.
    if let recorder {
      do {
        let receipt = try await recorder.evidence("Operator requested job stop; requested_uptime_ns=\(stopRequestedUptime.map(String.init) ?? "unknown"); request alone is not stopped evidence")
        try await recorder.stopEvidence(.requested, receipts: [receipt])
      } catch { noteAccountingFailure(error) }
    }
    recoveryStopped = ContinuousClock.now
    recoveryDeadline?.cancel(); recoveryDeadline = nil
    if receiverPrepared {
      finalizing = true
      status = "Tape stopped. Saving the remaining packets and verifying the interrupted capture — do not quit or disconnect the destination."
      await live.stopAndWait()
    }
    status = (recoveryBudgetStop ? "Recovery PLAY allowance reached; STOP confirmed. " : "Job stopped by operator — not a whole-tape completion. ")
      + (receiverPrepared ? live.ingestDetail : "No capture was started.")
    if let recorder {
      do {
        try await recorder.finalEvidence(capture: receiverPrepared ? live.flightURL : nil,
          dv: receiverPrepared ? live.verification : nil, hdv: receiverPrepared ? live.hdvVerification : nil,
          receiveClosed: receiverPrepared && !live.active && !live.busy && !live.lockedOut)
        let summary = try await recorder.summary()
        status = summary.text
        if summary.evidence?.verification?.passed != true && receiverPrepared { needsAttention = true }
        if summary.evidence?.verification?.needsLossReview == true { needsAttention = true }
      } catch { noteAccountingFailure(error) }
    }
    if let accountingFailure {
      status += " Job summary could not be persisted/verified: \(accountingFailure). Preserved capture evidence remains separate."
    }
    await notify(title: "Tape job stopped", body: status)
  }

  private func noteAccountingFailure(_ error: Error) {
    needsAttention = true
    if accountingFailure == nil { accountingFailure = error.localizedDescription }
  }

  private func prepareNotification() async {
    guard notifyWhenFinished else { return }
    if let notificationPreparationOverride {
      await notificationPreparationOverride()
      return
    }
    do {
      let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      notificationStatus = allowed ? "Mac notifications enabled" : "Notifications declined; completion remains visible here"
    } catch { notificationStatus = "Notifications unavailable; capture is unaffected" }
  }
  private func notify(title: String, body: String) async {
    guard notifyWhenFinished else { return }
    if let notificationDeliveryOverride {
      await notificationDeliveryOverride(title, body)
      return
    }
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .authorized else { return }
    let content = UNMutableNotificationContent()
    content.title = title; content.body = body; content.sound = .default
    do { try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
    catch { notificationStatus = "Notification delivery failed; see the job result here" }
  }
}

private enum JobError: Error, LocalizedError {
  case cancelled, attention(String)
  var errorDescription: String? {
    switch self { case .cancelled: "Stopped at operator request"; case .attention(let reason): reason }
  }
}
