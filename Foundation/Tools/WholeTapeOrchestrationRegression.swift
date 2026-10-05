// OFFLINE ONLY. Compile with WholeTapeCaptureModel and archive/wire sources,
// NEVER with real DriverBridge/LiveMonitorModel/RewindDVApp. All replies and
// verification results below are synthetic; this is not hardware/byte proof.
import AppKit
import Combine
import CryptoKit
import Foundation

struct FixtureMediaFormats { var requiresHDVExport = false; var isMixed = false }

private extension FoundationRoute {
  var raw: Data {
    var data = Data(repeating: 0, count: 48)
    func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    put(UInt32(1),0); put(UInt32(48),4); put(guid,8); put(driverInstanceID,16)
    put(deviceIncarnation,24); put(routeEpoch,32); put(generation,40); put(nodeID,44)
    return data
  }
}

enum ControlAttemptDisposition { case protocolAcceptedMotionUnverified, uncertainLockedOut }
struct ControlAttemptReport {
  let disposition: ControlAttemptDisposition
  let command: DeckCommand
  let receiptURL: URL
  let message = "SYNTHETIC CONTROL — NO HARDWARE"
}

@MainActor final class DriverBridge {
  enum Scenario { case busResetResume, busResetTwice, busResetDuringRearm, busResetStopWaiting, busResetUnsafe, blankTape, operatorStop, lostStatus, alreadyBOT, uncorroboratedBOT, stoppedBeforePlayObserved,
    hdvTape, hdvFailedVerification, hdvZeroPackets,
    operatorZero, operatorOther, operatorFailedVerification, operatorMissingVerification, operatorHDV, journalWriteFailure,
    preflightStop, rewindStop, pendingStatusStop, finalizationStop,
    recoveryBounded, recoveryStatusGap, recoveryUncertainPlay, recoveryRouteLoss,
    recoveryStopFailure, recoveryEarlyStop, recoveryNaturalStop, recoveryNoAdmission, recoveryJournalWriteFailure }
  let scenario: Scenario, parent: URL
  var route: FoundationRoute
  var reconnectQueries = 0
  var routeAdvanced = false
  var commands: [DeckCommand] = []
  var phase: DeckCommand?
  var phaseQueries = 0
  var statusPending = false
  var stableStops = 0
  var live: LiveMonitorModel?
  init(_ scenario: Scenario, route: FoundationRoute, parent: URL) {
    self.scenario = scenario; self.route = route; self.parent = parent
  }
  func rediscoverAfterBusReset(previous: FoundationRoute) throws -> (DiscoveredDeck, FoundationRoute)? {
    precondition(live?.canReconnectAfterBusReset == true && !statusPending)
    reconnectQueries += 1
    if scenario == .busResetStopWaiting { return nil }
    if !routeAdvanced {
      var bytes = previous.raw
      func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
      }
      put(previous.routeEpoch + 1, 32); put(previous.generation + 1, 40)
      route = try FoundationRoute(data: bytes); routeAdvanced = true
    }
    return (DiscoveredDeck(guid: 1, generation: route.generation, node: 1, state: 1,
      vendor: "Synthetic", model: "No hardware"), route)
  }
  func receipt() throws -> URL {
    let url = parent.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try Data("SYNTHETIC TEST RECEIPT; NO FCP OR DRIVER ACCESS".utf8).write(to: url.appendingPathComponent("flight.ndjson"))
    return url
  }
  func inspectDevice(_ deck: DiscoveredDeck, tapeStateOnly: Bool = false,
    transportOnly: Bool = false, expectedRoute: FoundationRoute? = nil) async throws -> DeviceInspectionReport {
    precondition(expectedRoute == route && !statusPending)
    statusPending = true
    defer { statusPending = false }
    try await Task.sleep(for: .milliseconds(20))
    phaseQueries += 1
    var response: [UInt8]? = [0x0c, 0x20, 0xc4, 0x60]
    if phase == .rewind, phaseQueries == 1, scenario != .alreadyBOT, scenario != .uncorroboratedBOT {
      response = [0x0c,0x20,0xc4,0x65]
    }
    if phase == .play {
      precondition(live?.active == true, "Content/status gap must never terminate receiver")
      switch scenario {
      case .busResetResume, .busResetTwice, .busResetDuringRearm, .busResetStopWaiting, .busResetUnsafe:
        let resetLimit = scenario == .busResetTwice ? 2 : 1
        if phaseQueries == 2, live!.receiveStarts <= resetLimit {
          try live!.emitReset(unsafe: scenario == .busResetUnsafe)
          routeAdvanced = false
        }
        response = phaseQueries >= 7 ? [0x0c,0x20,0xc4,0x60] : [0x0c,0x20,0xc3,0x75]
      case .blankTape, .alreadyBOT, .finalizationStop, .recoveryNaturalStop,
           .hdvTape, .hdvFailedVerification, .hdvZeroPackets:
        response = phaseQueries >= 7 ? [0x0c,0x20,0xc4,0x60] : phaseQueries == 2 || phaseQueries == 3 ? nil : [0x0c,0x20,0xc3,0x75]
      case .operatorStop, .pendingStatusStop, .operatorZero, .operatorOther, .operatorFailedVerification, .operatorMissingVerification, .operatorHDV, .journalWriteFailure:
        live?.completeFrames = 6
        response = [0x0c,0x20,0xc3,0x75]
      case .lostStatus: response = nil
      case .stoppedBeforePlayObserved: response = [0x0c,0x20,0xc4,0x60]
      case .uncorroboratedBOT, .preflightStop, .rewindStop: preconditionFailure("This scenario must never issue PLAY")
      case .recoveryBounded, .recoveryUncertainPlay, .recoveryRouteLoss, .recoveryStopFailure, .recoveryEarlyStop, .recoveryJournalWriteFailure:
        response = [0x0c,0x20,0xc3,0x75]
      case .recoveryStatusGap: response = nil
      case .recoveryNoAdmission: preconditionFailure("Refused reservation cannot PLAY")
      }
    }
    if phase == .stop, phaseQueries <= 2 || scenario == .recoveryStopFailure {
      if let live { precondition(live.active, "STOP accepted is not mechanical stop") }
      response = [0x0c,0x20,0xc3,0x75]
    }
    if response == [0x0c,0x20,0xc4,0x60] { stableStops += 1 } else { stableStops = 0 }
    var entries: [DeviceInspectionEntry] = tapeStateOnly
      ? [.init(query: .tapeMediumInfo, disposition: "synthetic", facts: [], response: [0x0c,0x20,0xda,0x32,0x31])] : []
    if tapeStateOnly, scenario == .alreadyBOT {
      entries.append(.init(query: .tapeAbsoluteTrackNumber, disposition: "synthetic", facts: [],
        response: [0x0c,0x20,0x52,0x71,0,0,0,0xff]))
    }
    return DeviceInspectionReport(deck: deck, observedAt: Date(), receiptURL: try receipt(), entries: entries,
      completion: "SYNTHETIC OBSERVATION", controlLockedOut: scenario == .recoveryRouteLoss && phase == .play,
      route: route, validatedTransportState: response)
  }
  func perform(_ command: DeckCommand, selectedDeck: DiscoveredDeck, explicitlyArmed: Bool,
    expectedRoute: FoundationRoute? = nil) async throws -> ControlAttemptReport {
    precondition(!statusPending, "STOP must join pending STATUS; no concurrent FCP")
    precondition(expectedRoute == route && explicitlyArmed)
    commands.append(command); phase = command; phaseQueries = 0; stableStops = 0
    return .init(disposition: scenario == .recoveryUncertainPlay && command == .play ? .uncertainLockedOut : .protocolAcceptedMotionUnverified,
      command: command, receiptURL: try receipt())
  }
}

@MainActor final class RewindDVModel {
  let bridge: DriverBridge, selectedDeck: DiscoveredDeck?, selectedRoute: FoundationRoute?
  var requiresSupervisedStop = false
  var isBusy = false
  var wholeTapeActive: Bool { owned }
  var controlReport: ControlAttemptReport?
  private var owned = false
  init(_ bridge: DriverBridge) {
    self.bridge = bridge; selectedRoute = bridge.route
    selectedDeck = DiscoveredDeck(guid: 1, generation: 1, node: 1, state: 1, vendor: "Synthetic", model: "No hardware")
  }
  func acquireWholeTapeOwnership() -> Bool { if owned { return false }; owned = true; return true }
  func releaseWholeTapeOwnership() { owned = false }
  func wholeTapeControlCompleted(_ report: ControlAttemptReport) { requiresSupervisedStop = report.command != .stop }
  func wholeTapeStopObserved() { requiresSupervisedStop = false }
  func pauseExternalTransportObservation() async {}
  var optionalTimecodeSamples = 0
  func sampleDeckTimecode(deck: DiscoveredDeck, route: FoundationRoute,
    transport: [UInt8]?, receiving: Bool, stopping: Bool, wholeTapeOwner: Bool = false) async {
    precondition(!receiving && !stopping && wholeTapeOwner && owned)
    precondition(bridge.phase == .rewind, "Timecode must not compete with capture or STOP")
    optionalTimecodeSamples += 1
  }
}

@MainActor final class LiveMonitorModel {
  var active = false, busy = false, lockedOut = false, receiverReady = false
  var busResetObserved = false, hasReceiveSession = false
  var canReconnectAfterBusReset: Bool { busResetObserved && !active && !busy && !lockedOut }
  var mediaFormats = FixtureMediaFormats()
  var receiveStarts = 0
  func waitForReceiveEnd() async {}
  func carryStopObligationAcrossReset(from old: FoundationRoute, to fresh: FoundationRoute) {
    precondition(canReconnectAfterBusReset && old.guid == fresh.guid && old.driverInstanceID == fresh.driverInstanceID)
  }
  func emitReset(unsafe: Bool = false) throws {
    busResetObserved = true; active = false; busy = false; receiverReady = false; lockedOut = unsafe
    var status = Data(repeating: 0, count: 128)
    func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
      var value = value.littleEndian
      withUnsafeBytes(of: &value) { status.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    put(UInt32(0x58524452), 0); put(UInt16(1), 4); put(UInt16(256), 6)
    put(UInt32(4160), 8); put(UInt32(8192), 12); put(UInt64(receiveStarts), 16)
    status.replaceSubrange(24..<72, with: bridge!.route.raw)
    put(UInt32(3), 80)
    let hash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    func event(_ name: String, _ wire: Data) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "event": name,
        "wireBase64": wire.base64EncodedString(), "recordBytes": 0, "recordSHA256": hash], options: [.sortedKeys]) + Data([10])
    }
    try Data("RDRXLOG1".utf8).write(to: flightURL!.appendingPathComponent("receive.records.raw"))
    var journal = try event("receive_start_intent", bridge!.route.raw)
    journal.append(try event("receive_final_status", status)); journal.append(try event("receive_closed", Data()))
    try journal.write(to: flightURL!.appendingPathComponent("flight.ndjson"))
  }
  var awaitingTapeStop = false, receiverFailedWithoutTapeStopProof = false
  var detail = "Synthetic receive", ingestDetail = "Synthetic export"
  var completeFrames: UInt64 = 0
  var flightURL: URL?, verification: DVIngestVerification?
  var hdvVerification: HDVIngestVerification?
  var physicalStop = false
  var bridge: DriverBridge?
  var onFinalize: (() -> Void)?
  var finalizationCount = 0
  func prepareCaptureTransportPlay() {}
  func markCaptureTransportPlaying(atUptimeNanoseconds: UInt64? = nil) {}
  func confirmReceiverTapeStopped(on route: FoundationRoute) {}
  func markCaptureTransportStopped(atUptimeNanoseconds: UInt64? = nil) {
    if bridge?.phase == .stop {
      precondition(physicalStop || (bridge?.stableStops ?? 0) >= 2,
        "Elapsed clock must not claim STOP from one transient observation")
    }
  }
  func start(bridge: DriverBridge, deck: DiscoveredDeck, ingestParent: URL? = nil,
             captureFolderKind: CaptureDirectory.Kind = .manual,
    expectedRoute: FoundationRoute? = nil) {
    self.bridge = bridge; bridge.live = self
    precondition((bridge.stableStops >= 2 || receiveStarts > 0) && expectedRoute == bridge.route)
    receiveStarts += 1; busResetObserved = false; hasReceiveSession = true; verification = nil
    flightURL = try! CaptureDirectory.create(parent: ingestParent!, kind: .wholeTapePayload)
    active = true; receiverReady = true
    if receiveStarts > 1 { bridge.phaseQueries = 0 }
    if bridge.scenario == .busResetDuringRearm && receiveStarts == 2 {
      try! emitReset(); bridge.routeAdvanced = false
    }
  }
  func stopAndWait() async {
    precondition(physicalStop || (bridge?.stableStops ?? 0) >= 2)
    finalizationCount += 1
    onFinalize?()
    try? await Task.sleep(for: .milliseconds(20))
    active = false; receiverReady = false
    if busResetObserved { return }
    if let scenario = bridge?.scenario,
      [.hdvTape, .hdvFailedVerification, .hdvZeroPackets, .operatorHDV].contains(scenario) {
      let packets: UInt64 = scenario == .hdvZeroPackets ? 0 : 1
      hdvVerification = HDVIngestVerification(schemaVersion: 1,
        transportPacketCount: packets, transportBytes: packets * 188,
        rawRecordCount: 1, rawRecordBytes: 272, rawRecordSHA256: "SYNTHETIC",
        nativeTSSHA256: "SYNTHETIC", journalSHA256: "SYNTHETIC",
        packetManifestSHA256: "SYNTHETIC", packetManifestBytes: 1,
        hostRingDrops: 0, oversizedPackets: 0, knownDroppedPackets: 0,
        rawTransportGapEvents: 0, transportSummary: .init(), diagnosticSample: [],
        diagnosticSampleTruncated: false, finalAcknowledgementConfirmed: true,
        integritySHA256Verified: scenario != .hdvFailedVerification,
        nativeTSRereadVerified: true, hardwareContinuity: "SYNTHETIC",
        exactLostTransportPacketCount: nil, sourceMediaDamage: "SYNTHETIC",
        captureFile: "synthetic-not-created.m2t", packetManifestFile: "none",
        verificationFile: "synthetic-hdv-verification.json", finalStatusWireBase64: "")
      try! JSONEncoder().encode(hdvVerification!).write(to: flightURL!.appendingPathComponent("synthetic-hdv-verification.json"))
      return
    }
    // Stub verifier covers controller transitions only; real verifier has its
    // own byte/hash/journal tests. No fabricated DV file is emitted here.
    if bridge?.scenario == .operatorMissingVerification { return }
    let finalFrames: UInt64 = bridge?.scenario == .operatorStop ? 1_899 : bridge?.scenario == .operatorOther ? 42 : 0
    verification = DVIngestVerification(schemaVersion: 1, completeDVFrames: finalFrames, dvBytes: finalFrames * 120_000,
      rawRecordCount: 0, rawRecordBytes: 0, rawRecordSHA256: "synthetic", nativeDVSHA256: nil,
      journalSHA256: "synthetic", frameManifestSHA256: "synthetic", frameManifestBytes: 0,
      hostRingDrops: 0, oversizedPackets: 0, knownDroppedPackets: 0, CIPDiscontinuities: 0,
      rejectedPackets: 0, incompleteFrames: 0, finalAcknowledgementConfirmed: true,
      legacyStoppedSnapshotUsed: false, rawTransportGapEvents: 0, integritySHA256Verified: bridge?.scenario != .operatorFailedVerification,
      nativeDVRereadVerified: finalFrames > 0, hardwareContinuity: "SYNTHETIC", exactLostFrameCount: nil,
      sourceMediaDamage: "SYNTHETIC", captureFile: nil, frameManifestFile: "none",
      verificationFile: "synthetic-verification.json", finalStatusWireBase64: "")
    try! JSONEncoder().encode(verification!).write(to: flightURL!.appendingPathComponent("synthetic-verification.json"))
  }
}

@main struct WholeTapeOrchestrationRegression {
  @MainActor static func main() async throws {
    var priorVerification: DVIngestVerification?
    var priorFlight: URL?
    for scenario in [DriverBridge.Scenario.busResetResume, .busResetTwice, .busResetDuringRearm, .busResetStopWaiting, .busResetUnsafe, .blankTape, .operatorStop, .lostStatus, .alreadyBOT,
                     .uncorroboratedBOT, .stoppedBeforePlayObserved, .preflightStop, .rewindStop,
                     .pendingStatusStop, .finalizationStop,
                     .hdvTape, .hdvFailedVerification, .hdvZeroPackets, .operatorZero, .operatorOther,
                     .operatorFailedVerification, .operatorMissingVerification, .operatorHDV, .journalWriteFailure] {
      let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-offline-job-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      var bytes = Data(repeating: 0, count: 48)
      func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
      }
      put(UInt32(1),0); put(UInt32(48),4)
      for offset in [8,16,24,32] { put(UInt64(1),offset) }
      put(UInt32(1),40); put(UInt16(1),44)
      let bridge = DriverBridge(scenario, route: try FoundationRoute(data: bytes), parent: parent)
      let model = RewindDVModel(bridge), live = LiveMonitorModel()
      if scenario == .preflightStop {
        precondition(priorVerification != nil)
        live.verification = priorVerification; live.flightURL = priorFlight
      }
      // Hold notification preparation far beyond the entire synthetic job in
      // one scenario. Transport/receive must still finish without waiting for
      // optional notification authorization.
      let holdNotification = scenario == .blankTape
      let suspendedNotification: @MainActor @Sendable () async -> Void = {
        _ = try? await Task.sleep(for: .seconds(60))
      }
      let notificationOverride: (@MainActor @Sendable () async -> Void)? =
        holdNotification ? suspendedNotification : nil
      let ignoredDelivery: @MainActor @Sendable (String, String) async -> Void = { _, _ in }
      let deliveryOverride: (@MainActor @Sendable (String, String) async -> Void)? =
        holdNotification ? ignoredDelivery : nil
      let job = WholeTapeCaptureModel(sampleInterval: .milliseconds(20),
        notificationPreparationOverride: notificationOverride,
        notificationDeliveryOverride: deliveryOverride)
      job.notifyWhenFinished = holdNotification
      precondition(!job.canRequestStop && !job.canConfirmPhysicalStop)
      job.requestStop(); job.finishAfterPhysicalStop()
      precondition(!job.stopRequested, "Idle cancellation must do nothing")
      live.onFinalize = {
        precondition(job.finalizing && !job.canRequestStop && !job.canConfirmPhysicalStop)
        let wasRequested = job.stopRequested
        let status = job.status
        job.requestStop(); job.finishAfterPhysicalStop()
        precondition(job.stopRequested == wasRequested && job.status == status,
          "STOP must not interrupt or relabel final verification")
      }
      if scenario == .journalWriteFailure {
        live.onFinalize = {
          let parent = job.evidenceURL!.appendingPathComponent("journal")
          let directory = try! FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)[0]
          let count = try! FileManager.default.contentsOfDirectory(atPath: directory.path).count
          // Obstruct only the next new checkpoint; preserve all existing records.
          try! FileManager.default.createDirectory(at: directory.appendingPathComponent(String(format: "%08d.json", count)), withIntermediateDirectories: false)
        }
      }
      job.start(model: model, live: live, destination: parent)
      precondition(job.canRequestStop)
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      var requested = false
      while job.active && ContinuousClock.now < deadline {
        if !requested && ((scenario == .busResetStopWaiting && bridge.reconnectQueries >= 1)
          || (scenario == .busResetUnsafe && job.status.contains("Reset recovery refused"))) {
          live.physicalStop = true; job.finishAfterPhysicalStop(); requested = true
        }
        if !requested && bridge.statusPending &&
          ((scenario == .preflightStop && bridge.phase == nil) ||
           (scenario == .rewindStop && bridge.phase == .rewind) ||
           (scenario == .pendingStatusStop && bridge.phase == .play)) {
          job.requestStop(); requested = true
          let status = job.status
          job.requestStop()
          precondition(!job.canRequestStop && job.status == status, "Repeated STOP is idempotent")
        }
        if job.needsAttention, !requested,
          scenario == .uncorroboratedBOT || scenario == .stoppedBeforePlayObserved {
          job.requestStop(); requested = true
        }
        if bridge.phase == .play, bridge.phaseQueries >= 3, !requested {
          if [.operatorStop, .operatorZero, .operatorOther, .operatorFailedVerification, .operatorMissingVerification, .operatorHDV, .journalWriteFailure].contains(scenario) { job.requestStop(); requested = true }
          if scenario == .lostStatus { live.physicalStop = true; job.finishAfterPhysicalStop(); requested = true }
        }
        try await Task.sleep(for: .milliseconds(2))
      }
      precondition(!job.active, "Offline job hung: \(job.status)")
      precondition(!live.active)
      let expectedCommands: [DeckCommand] = scenario == .preflightStop ? []
        : scenario == .uncorroboratedBOT || scenario == .rewindStop ? [.rewind,.stop]
        : [.operatorStop, .stoppedBeforePlayObserved, .pendingStatusStop, .operatorZero, .operatorOther, .operatorFailedVerification, .operatorMissingVerification, .operatorHDV, .journalWriteFailure].contains(scenario) ? [.rewind,.play,.stop]
        : [.rewind,.play]
      precondition(bridge.commands == expectedCommands)
      if scenario == .blankTape || scenario == .operatorStop || scenario == .pendingStatusStop {
        precondition(model.optionalTimecodeSamples > 0, "Rewinding must offer optional deck timecode")
      }
      precondition(live.finalizationCount == (bridge.commands.contains(.play) ? 1 : 0))
      precondition(!job.canRequestStop && !job.canConfirmPhysicalStop)
      let journals = job.evidenceURL!.appendingPathComponent("journal")
      let directory = try FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil)[0]
      if scenario == .journalWriteFailure {
        precondition(job.needsAttention && job.status.contains("could not be persisted/verified"))
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let blocker = try entries.first { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }!
        try FileManager.default.removeItem(at: blocker)
      }
      let recovered = try WholeTapeJobJournal.recover(from: directory)
      let resetSuccess = [.busResetResume, .busResetTwice, .busResetDuringRearm].contains(scenario)
      if resetSuccess {
        let count = scenario == .busResetResume ? 1 : 2
        precondition(job.resetRecoveryCount == count && live.receiveStarts == count + 1)
        precondition(recovered.accounting?.previousSegments?.count == count)
        precondition(recovered.accounting!.previousSegments!.allSatisfy { $0.verification?.passed == true && $0.verification?.needsLossReview == true })
        precondition(recovered.stage == .segmentedCaptureFinished && job.needsAttention)
        precondition(job.status.contains("Missing footage"))
      }
      precondition(resetSuccess || recovered.stage == (scenario == .blankTape || scenario == .alreadyBOT || scenario == .finalizationStop || scenario == .hdvTape ? .transportBoundedVerified : .interrupted))
      if scenario == .operatorStop {
        FileHandle.standardError.write(Data("JOURNAL_REPRODUCTION early=6 final=\(live.verification!.completeDVFrames) persisted=\(recovered.receivedFrames) stopRequired=\(recovered.manualStopRequired)\n".utf8))
        precondition(recovered.currentSummary.evidence?.verification?.completeDVFrames == live.verification!.completeDVFrames
          && recovered.currentSummary.evidence?.stopped == true,
          "Cancelled job summary must account for subsequent stopped and verified evidence")
        precondition(recovered.receivedFrames == 6 && recovered.manualStopRequired && recovered.stage == .interrupted,
          "Historical cancellation values must remain intact")
        precondition(job.status == recovered.currentSummary.text, "UI/report must agree with reopened production reader")
        let originalFiles = try FileManager.default.contentsOfDirectory(at: live.flightURL!, includingPropertiesForKeys: nil)
        precondition(originalFiles.map(\.lastPathComponent) == ["synthetic-verification.json"],
          "Job reconciliation must not add files to finalized capture")
      }
      if [.operatorZero, .operatorOther, .operatorFailedVerification, .operatorMissingVerification, .operatorHDV].contains(scenario) {
        precondition(recovered.stage == .interrupted && recovered.accounting?.stopped == true)
        precondition(job.status == recovered.currentSummary.text)
        if scenario == .operatorZero { precondition(recovered.accounting?.verification?.completeDVFrames == 0) }
        if scenario == .operatorOther { precondition(recovered.accounting?.verification?.completeDVFrames == 42) }
        if scenario == .operatorFailedVerification { precondition(recovered.accounting?.verification?.passed == false && job.needsAttention) }
        if scenario == .operatorMissingVerification { precondition(recovered.accounting?.verification == nil && job.needsAttention) }
        if scenario == .operatorHDV { precondition(recovered.accounting?.verification?.transportPackets == 1 && recovered.accounting?.verification?.completeDVFrames == nil) }
      }
      if scenario == .preflightStop {
        precondition(recovered.accounting?.capture == nil && recovered.accounting?.verification == nil,
          "Pre-capture cancellation must not borrow the prior session verifier")
        precondition(job.status == recovered.currentSummary.text)
      }
      if let verification = live.verification { priorVerification = verification; priorFlight = live.flightURL }
      print("OFFLINE_CONTROLLER_PASS", scenario, job.status)
    }
    try await recoveryScenarios()
    print("NO DRIVER, HARDWARE, DV OUTPUT, NOTIFICATION DELIVERY OR TAPE COMMANDS WERE USED")
  }

  @MainActor static func recoveryScenarios() async throws {
    for scenario in [DriverBridge.Scenario.recoveryBounded, .recoveryStatusGap, .recoveryUncertainPlay,
      .recoveryRouteLoss, .recoveryStopFailure, .recoveryEarlyStop, .recoveryNaturalStop, .recoveryNoAdmission, .recoveryJournalWriteFailure] {
      let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RewindDV-offline-recovery-\(UUID())")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      var bytes = Data(repeating: 0, count: 48)
      func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
      }
      put(UInt32(1),0); put(UInt32(48),4)
      for offset in [8,16,24,32] { put(UInt64(1),offset) }
      put(UInt32(1),40); put(UInt16(1),44)
      let bridge = DriverBridge(scenario, route: try FoundationRoute(data: bytes), parent: parent)
      let model = RewindDVModel(bridge), live = LiveMonitorModel()
      let source = DVReviewedRangeExporter.Snapshot(schemaVersion: 1, sourceSHA256: String(repeating: "a", count: 64),
        frameCount: 100, frameByteCount: 120000, sourceByteCount: 12000000, videoSystem: .ntsc525_60)
      let target = DVGentleRecovery.Target(first: 1, endExclusive: 10, reason: "Synthetic")
      let mapHash = String(repeating: "b", count: 64)
      let plan = try DVGentleRecovery.Plan(source: source, mapSHA256: mapHash, tapeLabel: "SYNTHETIC NO HARDWARE",
        budget: .init(maximumAttempts: 1, attemptsPerTarget: 1, passSeconds: scenario == .recoveryNaturalStop ? 3 : 1,
          stopAllowanceSeconds: 5, totalReservedSeconds: 30, cooldownSeconds: 10), targets: [target])
      let journal = try DVGentleRecoveryJournal(directory: parent.appendingPathComponent("plan"), creating: plan,
        expectedSource: source, expectedMapSHA256: mapHash)
      let job = WholeTapeCaptureModel(sampleInterval: .milliseconds(20)); job.notifyWhenFinished = false
      if scenario == .recoveryJournalWriteFailure {
        live.onFinalize = {
          let checkpoints = job.evidenceURL!.appendingPathComponent("journal")
          let directory = try! FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)[0]
          let count = try! FileManager.default.contentsOfDirectory(atPath: directory.path).count
          try! FileManager.default.createDirectory(at: directory.appendingPathComponent(String(format: "%08d.json", count)), withIntermediateDirectories: false)
        }
      }
      job.start(model: model, live: live, destination: parent,
        recovery: .init(journal: journal, target: target.id, positioningSeconds: 0,
          confirmedTapeAndPosition: scenario != .recoveryNoAdmission))
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      var manualStop = false
      while job.active && ContinuousClock.now < deadline {
        if scenario == .recoveryEarlyStop, bridge.phase == .play, !job.stopRequested { job.requestStop() }
        if job.needsAttention && job.status.contains("Use physical STOP") {
          precondition(live.active && live.finalizationCount == 0, "Unsafe stop must retain receive")
          manualStop = true; live.physicalStop = true; job.finishAfterPhysicalStop()
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      precondition(!job.active && !live.active, "Recovery did not finish: \(job.status)")
      let expected: [DeckCommand] = scenario == .recoveryNoAdmission ? []
        : [.recoveryUncertainPlay, .recoveryRouteLoss, .recoveryNaturalStop].contains(scenario) ? [.play] : [.play,.stop]
      precondition(bridge.commands == expected, "No rewind, seek, duplicate PLAY or stale STOP: \(bridge.commands)")
      precondition(manualStop == [.recoveryUncertainPlay, .recoveryRouteLoss, .recoveryStopFailure].contains(scenario))
      let snapshot = try await journal.snapshot()
      precondition(snapshot.attempts.count == (scenario == .recoveryNoAdmission ? 0 : 1))
      if scenario != .recoveryNoAdmission {
        precondition(snapshot.unresolved == nil && snapshot.chargedSeconds >= plan.budget.passSeconds + 5)
        precondition(snapshot.attempts[0].result?.verificationSHA256?.count == 64)
        precondition(snapshot.attempts[0].result?.outcome == "verified_raw_capture_no_complete_DV")
        precondition(live.finalizationCount == 1)
        if scenario == .recoveryStopFailure { precondition(snapshot.hasOverrun) }
      }
      if scenario == .recoveryJournalWriteFailure {
        precondition(job.needsAttention && job.status.contains("Job summary could not be persisted/verified"),
          "Recovery completion must retain the job accounting warning")
      }
      print("OFFLINE_RECOVERY_PASS", scenario, job.status)
    }
  }
}
