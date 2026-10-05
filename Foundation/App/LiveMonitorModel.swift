// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation

struct LivePreservedFrame: Sendable {
  let bytes: Data
  let ordinal: UInt64
  let timecode: String?
}
struct LiveReceiveBatch: Sendable {
  let status: LiveReceiveStatus
  let frames: [LivePreservedFrame]
  let drained: Bool
  let rejectedPackets: UInt64
  let assembledFrames: UInt64
  let discontinuities: UInt64
  let incompleteFrames: UInt64
  var finalDiagnosticMessage: String {
    "snapshot_phase=post_terminal_drain; complete_frames=\(assembledFrames); incomplete_frames=\(incompleteFrames); continuity_breaks=\(discontinuities); rejected_packets=\(rejectedPackets); packets_seen=\(status.packetsSeen); known_dropped_packets=\(status.dropped); oversized_packets=\(status.oversized); hardware_continuity=unknown"
  }
  func replacingFrames(_ frames: [LivePreservedFrame]) -> Self {
    Self(status: status, frames: frames, drained: drained, rejectedPackets: rejectedPackets,
      assembledFrames: assembledFrames, discontinuities: discontinuities, incompleteFrames: incompleteFrames)
  }
}

@MainActor final class LiveMonitorModel: ObservableObject {
  let preview: LiveDVPreview
  @Published private(set) var busResetObserved = false
  private(set) var resetSegmentClosed = false
  var canReconnectAfterBusReset: Bool { resetSegmentClosed && !active && !busy && !lockedOut }
  @Published private(set) var active = false
  @Published private(set) var waitingForAdmission = false
  @Published private(set) var hasReceiveSession = false
  @Published private(set) var hasCurrentPreview = false
  @Published private(set) var startRejection: ReceiveStartDiagnostic?
  @Published private(set) var busy = false
  @Published private(set) var lockedOut = false
  @Published private(set) var detail = "Live monitor is stopped. No tape command is sent when monitoring starts."
  @Published private(set) var flightURL: URL?
  private(set) var ingestDestinationURL: URL?
  var sourceTimecode: String? { preview.sourceTimecode }
  @Published private(set) var packetsSeen: UInt64 = 0
  @Published private(set) var mediaFormats = ReceiveMediaFormatEvidence()
  @Published private(set) var knownDroppedPackets: UInt64 = 0
  @Published private(set) var oversizedPackets: UInt64 = 0
  @Published private(set) var completeFrames: UInt64 = 0
  @Published private(set) var incompleteFrames: UInt64 = 0
  @Published private(set) var continuityBreaks: UInt64 = 0
  @Published private(set) var rejectedPackets: UInt64 = 0
  @Published private(set) var deliverySkips: UInt64 = 0
  @Published private(set) var ingestRequested = false
  @Published private(set) var verification: DVIngestVerification?
  @Published private(set) var hdvVerification: HDVIngestVerification?
  @Published private(set) var hdvVerificationProgress: HDVIngestProgress?
  @Published private(set) var verificationProgress: DVIngestProgress?
  @Published private(set) var verificationETASeconds: TimeInterval?
  @Published private(set) var verificationElapsedSeconds: TimeInterval = 0
  @Published private(set) var ingestDestinationVolumeName: String?
  @Published private(set) var verifiedCaptureURL: URL?
  @Published private(set) var ingestDetail = "No ingest in progress"
  @Published private(set) var diagnosticWarning: String?
  @Published private(set) var awaitingTapeStop = false
  @Published private(set) var tapeStopNeedsAttention = false
  @Published private(set) var tapeStopFeedback = ""
  @Published private(set) var pendingDurabilityRecords = 0
  @Published private(set) var durableRecords: UInt64 = 0
  @Published private(set) var writerUnderPressure = false
  @Published private(set) var receiverFailedWithoutTapeStopProof = false
  private var task: Task<Void, Never>?
  private let tapePlayObserver = ForwardPlayObserver()
  private var playObservationSetup: Task<Void, Never>?
  private var playObservationToken = UUID()
  private let tapeStopObserver = WindStopObserver()
  private var sessionID = UUID()
  private var startingReceive = false
  private var receiverStopObligationRoute: FoundationRoute?
  private var tapeStopObservationAllowed = false
  private var tapeStopObservationRoute: FoundationRoute?
  private var pendingIngestPlay = false
  private var verificationProgressStartedAt: Date?
  @Published private(set) var receiverReady = false
  @Published private(set) var captureElapsed = CaptureElapsedState()
  @Published private(set) var captureElapsedAwaitingPlay = false

  var captureElapsedRunning: Bool { captureElapsed.isRunning }
  var captureElapsedRecordingActive: Bool {
    captureElapsed.isRunning && ingestRequested && active
  }
  var captureElapsedPlaybackActive: Bool {
    captureElapsed.isRunning && !ingestRequested && active
  }
  var captureElapsedSystemDescription: String {
    if captureElapsed.conflictingSystems { return "conflicting DV systems; frame field withheld" }
    switch captureElapsed.system {
    case .ntsc525_60: return "NTSC 30-count"
    case .pal625_50: return "PAL 25-count"
    case nil: return "awaiting native DV system"
    }
  }

  func markCaptureTransportPlaying(
    atUptimeNanoseconds instant: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    var next = captureElapsed
    next.begin(atUptimeNanoseconds: instant)
    captureElapsedAwaitingPlay = false
    if next != captureElapsed { captureElapsed = next }
  }

  func prepareCaptureTransportPlay() {
    var next = captureElapsed
    next.resetInterval()
    captureElapsedAwaitingPlay = true
    if next != captureElapsed { captureElapsed = next }
  }

  func observeCaptureTransportPlaying(bridge: DriverBridge, deck: DiscoveredDeck,
                                      route: FoundationRoute) {
    prepareCaptureTransportPlay()
    let id = sessionID
    let token = UUID(); playObservationToken = token
    let previousSetup = playObservationSetup
    previousSetup?.cancel()
    playObservationSetup = Task { [weak self] in
      guard let self else { return }
      await previousSetup?.value
      guard !Task.isCancelled, self.playObservationToken == token else { return }
      await self.tapePlayObserver.stopAndJoin()
      while self.startingReceive, self.sessionID == id, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard !Task.isCancelled, self.playObservationToken == token,
        self.sessionID == id, self.task != nil, !self.lockedOut else { return }
      self.tapePlayObserver.start(route: route, sample: {
        try await bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route)
      }, observed: { [weak self] _ in
        guard let self, self.sessionID == id, self.captureElapsedAwaitingPlay else { return }
        self.markCaptureTransportPlaying()
      }, failed: { [weak self] reason in
        guard let self, self.sessionID == id, self.captureElapsedAwaitingPlay else { return }
        self.diagnosticWarning = "Tape-motion elapsed time is awaiting qualified PLAY evidence: \(reason)"
      })
    }
  }

  func markCaptureTransportStopped(
    atUptimeNanoseconds instant: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    var next = captureElapsed
    next.stop(atUptimeNanoseconds: instant)
    captureElapsedAwaitingPlay = false
    if next != captureElapsed { captureElapsed = next }
  }

  /// A new STOP intent revokes startup PLAY immediately, before its AV/C reply.
  func cancelPendingIngestPlay() { pendingIngestPlay = false }

  /// Revoke setup before joining its pending STATUS. Never cancel an admitted
  /// hardware query or submit STOP until that query has returned terminally.
  func prepareForOperatorStop() async {
    cancelPendingIngestPlay()
    revokePlayObservationSetup()
    let setup = playObservationSetup
    await setup?.value
    playObservationSetup = nil
    await tapePlayObserver.stopAndJoin()
  }

  private func revokePlayObservationSetup() {
    playObservationToken = UUID()
    playObservationSetup?.cancel()
  }

  // Per-frame picture/timecode views observe preview directly. Forwarding every
  // preview/audio change through this model invalidates the entire workspace.
  init(muteAudio: Bool = false) { preview = LiveDVPreview(muteAudio: muteAudio) }

  func start(bridge: DriverBridge, deck: DiscoveredDeck, ingestParent: URL? = nil,
             captureFolderKind: CaptureDirectory.Kind = .manual,
             expectedRoute: FoundationRoute? = nil,
             existingStopObligation: Bool? = nil,
             beforeAdmission: (@MainActor () async throws -> Void)? = nil,
             admissionFinished: (@MainActor () -> Void)? = nil,
             onReceiving: (@MainActor () -> Void)? = nil) {
    guard !active, !busy, !lockedOut else { admissionFinished?(); return }
    busy = true
    busResetObserved = false; resetSegmentClosed = false
    // Revoke prior connection metadata immediately, before receive preparation.
    preview.metadata.begin(automatic: false)
    startingReceive = true
    receiverReady = false
    diagnosticWarning = nil
    // Existing STOP uncertainty belongs to its original operation. A new
    // admission attempt cannot erase it, even when that attempt is rejected.
    pendingIngestPlay = onReceiving != nil
    sessionID = UUID()
    tapeStopObservationAllowed = false
    pendingDurabilityRecords = 0; durableRecords = 0; writerUnderPressure = false
    ingestRequested = ingestParent != nil
    captureElapsed = CaptureElapsedState()
    captureElapsedAwaitingPlay = false
    ingestDestinationURL = ingestParent
    if let ingestParent {
      ingestDestinationVolumeName =
        (try? ingestParent.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    } else { ingestDestinationVolumeName = nil }
    verification = nil
    hdvVerification = nil
    hdvVerificationProgress = nil
    verificationProgress = nil
    verificationETASeconds = nil
    verificationElapsedSeconds = 0
    verificationProgressStartedAt = nil
    verifiedCaptureURL = nil
    flightURL = nil
    hasReceiveSession = false
    hasCurrentPreview = false
    startRejection = nil
    waitingForAdmission = true
    detail = beforeAdmission == nil ? "Preparing receive admission…" : "Waiting for the current device query to finish…"
    ingestDetail = detail
    packetsSeen = 0; knownDroppedPackets = 0; oversizedPackets = 0; completeFrames = 0
    mediaFormats = ReceiveMediaFormatEvidence()
    incompleteFrames = 0; continuityBreaks = 0; rejectedPackets = 0; deliverySkips = 0
    task = Task {
      var failed = false
      var ownsReceive = false
      var pump: LiveReceivePump?
      var readinessDelivered = false
      var reportedPreviewError: String?
      // Managed receive may allocate channel/bandwidth and establish CMP before
      // it can receive. This is a startup deadline, never a capture-duration cap.
      var readinessDeadline: ContinuousClock.Instant?
      let securityAccess = ingestParent?.startAccessingSecurityScopedResource() == true
      defer { if securityAccess { ingestParent?.stopAccessingSecurityScopedResource() } }
      do {
        do {
          defer { waitingForAdmission = false; admissionFinished?() }
          try Task.checkCancellation()
          try await beforeAdmission?()
          try Task.checkCancellation()
          readinessDeadline = ContinuousClock.now.advanced(by: .seconds(30))
          flightURL = try await bridge.beginLiveReceive(deck, destinationParent: ingestParent,
            captureFolderKind: captureFolderKind, expectedRoute: expectedRoute,
            existingStopObligation: (awaitingTapeStop || receiverFailedWithoutTapeStopProof || tapeStopNeedsAttention)
              ? true : existingStopObligation)
          ownsReceive = true
          hasReceiveSession = true
        }
        try Task.checkCancellation()
        ingestDetail = ingestRequested ? "Receiving raw evidence; native media export verifies after Stop" : "Monitor-only evidence"
        await preview.begin()
        hasCurrentPreview = true
        preview.metadata.setRawURL(ingestRequested ? flightURL?.appendingPathComponent("receive.records.raw") : nil)
        try Task.checkCancellation()
        active = true
        startingReceive = false
        busy = awaitingTapeStop
        let receiver = LiveReceivePump(bridge: bridge)
        pump = receiver
        var diagnosticTime = Date.distantPast
        var uiUpdateTime = ContinuousClock.now.advanced(by: .seconds(-1))
        var priorUIState: UInt32?
        for await _ in receiver.notifications {
          if Task.isCancelled { break }
          guard let event = receiver.take() else { continue }
          let batch: LiveReceiveBatch
          switch event {
          case .batch(let value): batch = value
          case .failure(let message): throw LiveMonitorError.failed(message)
          }
          if !readinessDelivered, batch.status.state == 1 {
            readinessDelivered = true
            receiverReady = true
            if pendingIngestPlay {
              pendingIngestPlay = false
              guard let readinessDeadline, ContinuousClock.now <= readinessDeadline else {
                throw LiveMonitorError.failed("Receive preparation expired; no PLAY was sent")
              }
              onReceiving?()
            }
          }
          if !readinessDelivered, let readinessDeadline, ContinuousClock.now > readinessDeadline {
            throw LiveMonitorError.failed("Receive did not become ready; no PLAY was sent")
          }
          preview.observeReceivePackets(batch.status.packetsSeen)
          for frame in batch.frames {
            var next = captureElapsed
            next.observeCompleteDVFrame(byteCount: frame.bytes.count)
            if next != captureElapsed { captureElapsed = next }
            preview.offerPreservedFrame(frame.bytes, ordinal: frame.ordinal, sourceTimecode: frame.timecode)
          }
          let now = ContinuousClock.now
          if now - uiUpdateTime >= .milliseconds(250) || batch.status.state != priorUIState {
            uiUpdateTime = now; priorUIState = batch.status.state
            let state = ["Preparing", "Receiving", "Stopped", "Bus reset", "Receive failed", "Quarantined", "Releasing connection"][Int(batch.status.state)]
            detail = "\(state) · status \(String(format: "0x%08X", UInt32(bitPattern: batch.status.lastStatus))) · \(batch.assembledFrames) complete frames · known dropped packets \(batch.status.dropped) (includes \(batch.status.oversized) oversized) · rejected packets \(batch.rejectedPackets). Hardware continuity unknown."
            packetsSeen = batch.status.packetsSeen; knownDroppedPackets = batch.status.dropped
            oversizedPackets = batch.status.oversized; completeFrames = batch.assembledFrames
            incompleteFrames = batch.incompleteFrames; continuityBreaks = batch.discontinuities
            rejectedPackets = batch.rejectedPackets; deliverySkips = receiver.skippedDeliveryFrames
            mediaFormats = await bridge.receivedMediaFormats()
            let persistence = await bridge.livePersistenceHealth()
            pendingDurabilityRecords = persistence.pendingRecords
            durableRecords = persistence.durableThrough
            writerUnderPressure = persistence.writerPressure
            if let failure = persistence.diagnosticFailure {
              diagnosticWarning = "Diagnostic evidence is incomplete; raw reception continues: \(failure)"
            }
          }
          if Date().timeIntervalSince(diagnosticTime) >= 1 {
            diagnosticTime = Date()
            preview.requestNativeVideoMetrics()
            do { try await bridge.recordMonitorDiagnostics(diagnostics + (hasCurrentPreview ? "; " + preview.timingDiagnostics : "")) }
            catch { diagnosticWarning = "Preview diagnostics could not be saved; raw receive continues: \(error.localizedDescription)" }
          }
          if batch.status.state == 3 { busResetObserved = true }
          if batch.status.state >= 2 {
            // A terminal bus reset or receive failure can have successful
            // resource cleanup. Neither proves that the tape has stopped.
            if batch.status.state == 3 || batch.status.state == 4 { failed = true }
            break
          }
          // Display/decoder failure is NOT receive failure. In particular, bad
          // frames or missing timecode must not terminate archival intake.
          if let error = preview.error, reportedPreviewError != error {
            reportedPreviewError = error
            do { try await bridge.recordMonitorDiagnostics("preview_failure_receive_continues=\(error)") }
            catch { diagnosticWarning = "Preview diagnostics unavailable; raw receive continues" }
          }
        }
      } catch is CancellationError {
        // Cancellation ends only this attempt's receive; never a tape command.
        if !ownsReceive { detail = "Capture start cancelled. No receive or tape command was submitted." }
      } catch {
        if let rejection = error as? ReceiveStartFailure {
          startRejection = rejection.diagnostic
          lockedOut = lockedOut || rejection.diagnostic.blockers.contains("permanentlyLockedOut")
          ownsReceive = rejection.diagnostic.acquiredOwnership
          hasReceiveSession = ownsReceive
          flightURL = rejection.flightURL
        }
        failed = true
        detail = ownsReceive ? "Live monitor failed: \(error.localizedDescription)" :
          "Capture did not start: \(error.localizedDescription)"
      }
      if !ownsReceive {
        // No cleanup selectors, final statistics, or diagnostics may touch a
        // different receive owner. Preview counters still belong to the prior
        // session and are withheld from this attempt's UI and alpha snapshot.
        ingestDetail = detail
        if startRejection?.flightCreationAttempted == true {
          ingestDetail += " Destination preparation may have left incomplete files; no receive was submitted."
        } else { ingestDetail += " No new capture was created." }
        startingReceive = false; receiverReady = false; pendingIngestPlay = false
        // STOP may have been submitted independently while receive was preparing.
        // Join this model's observers without touching a bridge receive owner.
        tapeStopObservationAllowed = false
        await prepareForOperatorStop()
        await tapeStopObserver.stopAndJoin()
        if awaitingTapeStop {
          tapeStopNeedsAttention = true
          tapeStopFeedback = "Capture did not start. The existing STOP request still needs confirmation."
        }
        awaitingTapeStop = false
        busy = false; task = nil
        return
      }
      busy = true
      startingReceive = false
      receiverReady = false
      pendingIngestPlay = false
      revokePlayObservationSetup()
      await pump?.cancelAndJoin()
      // A receive stop must not abandon an already-submitted FCP STATUS. This
      // joins only the observation owner; it sends no tape command.
      tapeStopObservationAllowed = false
      await prepareForOperatorStop()
      await tapeStopObserver.stopAndJoin()
      awaitingTapeStop = false
      if let pump { deliverySkips = pump.skippedDeliveryFrames }
      try? await bridge.recordMonitorDiagnostics("snapshot_phase=pre_terminal_drain; " + diagnostics + (hasCurrentPreview ? "; " + preview.timingDiagnostics : ""))
      var finalFrame: LivePreservedFrame?
      do {
        finalFrame = try await bridge.endLiveReceive()
        mediaFormats = await bridge.receivedMediaFormats()
        pendingDurabilityRecords = 0; writerUnderPressure = false
        if let final = await bridge.completedReceiveStatistics() {
          packetsSeen = final.status.packetsSeen; knownDroppedPackets = final.status.dropped
          oversizedPackets = final.status.oversized; completeFrames = final.assembledFrames
          incompleteFrames = final.incompleteFrames; continuityBreaks = final.discontinuities
          rejectedPackets = final.rejectedPackets
          busResetObserved = busResetObserved || final.status.state == 3
          resetSegmentClosed = final.status.state == 3 && final.status.lastStatus == 0
            && final.status.writeSequence == final.status.acknowledged
          let terminalFailed = final.status.state == 3 || final.status.state == 4
          if terminalFailed { failed = true }
          if !failed || terminalFailed {
            detail = "Receive \(terminalFailed ? "failed" : "ended") (state \(final.status.state), status \(String(format: "0x%08X", UInt32(bitPattern: final.status.lastStatus)))); final post-drain count \(final.assembledFrames) complete frames · known dropped packets \(final.status.dropped) · CIP discontinuities \(final.discontinuities) · incomplete frames \(final.incompleteFrames) · rejected packets \(final.rejectedPackets). Hardware continuity unknown; final picture retained."
          }
        }
      }
      catch {
        lockedOut = true
        detail += " Cleanup failed; session locked: \(error.localizedDescription)"
      }
      let bridgeLockedOut = await bridge.receiveRequiresLockout()
      lockedOut = lockedOut || bridgeLockedOut
      if failed || lockedOut {
        // Receiver shutdown is not AV/C transport STOP. Never use an uncertain
        // owner or stale route to hide this distinction with a retry.
        // Multiple/unknown routes cannot be resolved by a STOP from just the
        // latest selected device. Explicit physical attestation remains valid.
        if !receiverFailedWithoutTapeStopProof { receiverStopObligationRoute = expectedRoute }
        else if receiverStopObligationRoute != expectedRoute { receiverStopObligationRoute = nil }
        receiverFailedWithoutTapeStopProof = true
        tapeStopNeedsAttention = true
        tapeStopFeedback = "MANUAL STOP REQUIRED if the tape is moving. Receive failed or persistence is uncertain; receiver shutdown does not stop the tape. Use the deck's physical STOP. Preserve the raw flight for interrupted-flight recovery in Archives."
      }
      await preview.end(retainingImage: true, finalFrame: finalFrame)
      active = false
      if ingestRequested, !lockedOut, !failed, let flightURL {
        ingestDetail = "Verifying raw records and exporting complete DV frames…"
        do {
          guard !mediaFormats.isMixed else {
            throw LiveMonitorError.failed("Both DV and HDV payloads were observed. All raw records are retained; mixed-format native export is not yet supported. No single-format success is claimed.")
          }
          if mediaFormats.requiresHDVExport {
            try await verifyHDVFlight(flightURL)
          } else {
          verificationProgressStartedAt = Date()
          observeVerificationProgress(DVIngestProgress(
            phase: .validatingEvidence, completedBytes: 0, totalBytes: 0,
            overallCompletedBytes: 0, overallTotalBytes: 0))
          let id = sessionID
          let channel = AsyncStream<DVIngestProgress>.makeStream(bufferingPolicy: .bufferingNewest(8))
          let export = Task.detached(priority: .utility) {
            defer { channel.continuation.finish() }
            return try DVIngestExporter.exportClosedFlight(at: flightURL) { update in
              channel.continuation.yield(update)
            }
          }
          // The exporter can finish a very short capture between two SwiftUI
          // display passes. Keep its truthful validation state on screen long
          // enough to render while the detached work proceeds concurrently.
          try? await Task.sleep(for: .milliseconds(350))
          for await update in channel.stream where sessionID == id {
            observeVerificationProgress(update)
          }
          let result = try await export.value
          verification = result
          verifiedCaptureURL = result.captureFile.map { flightURL.appendingPathComponent($0) }
          ingestDetail = "Verification finished — inspect the loss and source-quality report"
          // The completed verification now drives a persistent summary panel.
          verificationProgress = nil
          verificationETASeconds = nil
          }
        } catch {
          verificationProgress = nil
          hdvVerificationProgress = nil
          verificationETASeconds = nil
          ingestDetail = "Ingest incomplete: \(error.localizedDescription). Raw evidence retained."
        }
      } else if ingestRequested { ingestDetail = "Ingest incomplete — receive failure; raw evidence retained" }
      busy = false
      task = nil
    }
  }

  private func verifyHDVFlight(_ flightURL: URL) async throws {
    ingestDetail = "Reconstructing and independently rereading the original HDV transport stream…"
    let started = Date()
    let channel = AsyncStream<HDVIngestProgress>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let export = Task.detached(priority: .utility) {
      defer { channel.continuation.finish() }
      return try HDVIngestExporter.exportClosedFlight(at: flightURL) {
        channel.continuation.yield($0)
      }
    }
    for await update in channel.stream {
      hdvVerificationProgress = update
      let elapsed = max(0, Date().timeIntervalSince(started))
      verificationElapsedSeconds = elapsed
      if let fraction = update.fractionCompleted, fraction >= 0.005, fraction < 1,
        update.phase != .publishingVerifiedFiles {
        verificationETASeconds = min(24 * 60 * 60, elapsed * (1 - fraction) / fraction)
      } else { verificationETASeconds = nil }
    }
    let result = try await export.value
    hdvVerification = result
    verifiedCaptureURL = result.captureFile.map { flightURL.appendingPathComponent($0) }
    hdvVerificationProgress = nil
    verificationETASeconds = nil
    ingestDetail = "HDV saved-byte verification finished — review the transport-quality report. Hardware qualification is pending."
  }

  private func observeVerificationProgress(_ update: DVIngestProgress) {
    verificationProgress = update
    let elapsed = max(0, Date().timeIntervalSince(verificationProgressStartedAt ?? Date()))
    verificationElapsedSeconds = elapsed
    guard update.phase != .publishingVerifiedFiles, update.phase != .complete,
      let fraction = update.fractionCompleted, fraction >= 0.005, fraction < 1 else {
      verificationETASeconds = nil
      return
    }
    verificationETASeconds = min(24 * 60 * 60, elapsed * (1 - fraction) / fraction)
  }

  private var diagnostics: String {
    guard hasCurrentPreview else { return "preview_scope=not_started_for_this_attempt" }
    return "diagnostics_version=2; audio_scope=preview_offered_frames; delivery_skips=\(deliverySkips); media_queue_skips=\(preview.queueSkippedFrames); renderer_skips=\(preview.rendererSkippedFrames); audio_skips=\(preview.audio.skippedAudioFrames); audio_delivery_gaps=\(preview.audio.deliveryGapFrames); audio_offered_frames=\(preview.audio.frameAccounting.offeredFrames); audio_unknown_format_frames=\(preview.audio.frameAccounting.unknownFormatFrames); audio_unavailable_pcm_frames=\(preview.audio.frameAccounting.unavailablePCMFrames); audio_renderer_failure_frames=\(preview.audio.rendererFailureFrames); audio_sample_construction_failures=\(preview.audio.sampleConstructionFailures); preview_input_interruptions=\(preview.audio.inputInterruptions); audio_resyncs=\(preview.audio.resynchronizations); video_timeline_resets=\(preview.videoTimelineResets); discarded_presentation_schedules=\(preview.discardedPresentationSchedules); last_resync=\(preview.audio.lastResynchronization); complete_frames=\(completeFrames); incomplete_frames=\(incompleteFrames); continuity_breaks=\(continuityBreaks); rejected_packets=\(rejectedPackets)" + "; " + preview.metadata.diagnostics
  }

  func stop() {
    if waitingForAdmission {
      detail = "Capture start cancelled; waiting for the current device query to finish. No capture will follow."
      ingestDetail = detail
    }
    pendingIngestPlay = false
    revokePlayObservationSetup()
    guard task != nil else { return }
    busy = true
    task?.cancel()
  }

  /// Join a reset shutdown without cancelling reception or manufacturing a STOP.
  func waitForReceiveEnd() async { await task?.value }

  func carryStopObligationAcrossReset(from old: FoundationRoute, to fresh: FoundationRoute) {
    guard canReconnectAfterBusReset, old.guid == fresh.guid,
      old.driverInstanceID == fresh.driverInstanceID, old != fresh else { return }
    if receiverStopObligationRoute == old { receiverStopObligationRoute = fresh }
    tapeStopFeedback = "Reconnecting after a bus reset. Tape STOP is still unconfirmed; any missing footage remains unknown."
  }

  /// Joins raw drain AND offline export. The job never cancels a pending FCP
  /// request to get here; its status observer has already returned terminally.
  func stopAndWait() async {
    let pending = task
    stop()
    await pending?.value
  }

  func stopAfterTapeResponse(bridge: DriverBridge, deck: DiscoveredDeck,
                            route: FoundationRoute, onConfirmed: @escaping @MainActor () -> Void) {
    // STOP may be accepted while beginLiveReceive is still preparing. Attach
    // confirmation to the owned task, not only to its eventual active state.
    guard task != nil, !awaitingTapeStop else { return }
    awaitingTapeStop = true; tapeStopNeedsAttention = false; busy = true
    tapeStopObservationAllowed = true
    tapeStopObservationRoute = route
    tapeStopFeedback = "STOP accepted; waiting for two fresh stopped observations. Receive continues."
    let id = sessionID
    Task { [weak self] in
      guard let self else { return }
      await self.prepareForOperatorStop()
      guard self.sessionID == id, self.awaitingTapeStop, self.tapeStopObservationAllowed else { return }
      self.tapeStopObserver.start(route: route, interval: .milliseconds(100), sampleImmediately: true,
        sample: { [weak self] in
          guard await self?.mayObserveAfterStartup() == true else { throw CancellationError() }
          return try await bridge.inspectDevice(deck, transportOnly: true, expectedRoute: route)
        }, update: { [weak self] report, stopped in
          guard let self, self.sessionID == id, self.awaitingTapeStop else { return }
          // The elapsed display ends at the first fresh device-reported STOP.
          // Receive remains open until the second independent STOP below.
          if report.validatedTransportState == [0x0c, 0x20, 0xc4, 0x60] {
            self.markCaptureTransportStopped()
          }
          guard stopped else { return }
          self.confirmReceiverTapeStopped(on: route)
          onConfirmed()
          self.tapeStopFeedback = "Deck reports stopped. Draining and saving all final received bytes…"
          // Run outside the observer callback: shutdown joins the callback's task.
          Task { [weak self] in
            guard let self, self.sessionID == id else { return }
            await self.stopAndWait()
          }
        }, failed: { [weak self] reason in
          guard let self, self.sessionID == id, self.awaitingTapeStop else { return }
          self.tapeStopNeedsAttention = true
          self.tapeStopFeedback = "STOP could not be confirmed: \(reason). Receive remains active. Use physical STOP, then confirm below."
        })
    }
  }

  private func mayObserveAfterStartup() async -> Bool {
    while startingReceive && tapeStopObservationAllowed { try? await Task.sleep(for: .milliseconds(20)) }
    return tapeStopObservationAllowed
  }

  /// Explicit operator attestation, never inferred from absent packets/timecode.
  func finishAfterPhysicalStop() async {
    guard awaitingTapeStop else { return }
    await prepareForOperatorStop()
    markCaptureTransportStopped()
    tapeStopObservationAllowed = false
    await tapeStopObserver.stopAndJoin()
    let confirmedRoute = tapeStopObservationRoute
    await stopAndWait()
    // Attestation resolves this route after drain; it cannot release an older
    // unknown/different device's STOP obligation.
    if let confirmedRoute { confirmReceiverTapeStopped(on: confirmedRoute) }
    if !receiverFailedWithoutTapeStopProof {
      tapeStopNeedsAttention = false
      tapeStopFeedback = "Operator confirmed the tape is physically stopped."
    }
  }

  func confirmReceiverTapeStopped(on route: FoundationRoute) {
    guard receiverFailedWithoutTapeStopProof, receiverStopObligationRoute == route else { return }
    receiverFailedWithoutTapeStopProof = false
    receiverStopObligationRoute = nil
    tapeStopNeedsAttention = false
    tapeStopFeedback = "Deck reports stopped on the route with the outstanding STOP obligation."
  }
}
private enum LiveMonitorError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self { case .failed(let message): message }
  }
}
