// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import IOKit
import OSLog

enum DriverHealthEvidence: Equatable, Sendable {
  case unverified(rawStatusBytes: Int, note: String)
}

struct DriverSnapshot: Sendable {
  let capabilities: FoundationCapabilities
  let decks: [DiscoveredDeck]
  let health: DriverHealthEvidence
  let rawStatus: Data
  let discoveryNote: String
  let routes: [FoundationRoute]

  var presentation: DriverReadinessPresentation {
    .init(capabilityFlags: capabilities.flags, decks: decks, routes: routes,
      discoveryNote: discoveryNote)
  }
}

enum ControlAttemptDisposition: Equatable, Sendable {
  case protocolAcceptedMotionUnverified
  case uncertainLockedOut
}

struct ControlAttemptReport: Sendable {
  let disposition: ControlAttemptDisposition
  let command: DeckCommand
  let result: ControlResult?
  let receiptURL: URL
  let message: String
  let requiresSupervisedStop: Bool
  let firstError: String?
  let cleanupErrors: [String]
}

enum DriverBridgeError: Error, LocalizedError, Equatable {
  case requiredDriverIdentityUnavailable
  case noExactRequiredBuildService
  case ambiguousRequiredBuildServices(Int)
  case differentAttachedBuilds([UInt64?])
  case registryIdentityMismatch(String)
  case openFailed(Int32)
  case callFailed(selector: UInt32, status: Int32)
  case malformedReply(String)
  case deckNotFresh
  case operatorArmRequired
  case commandAlreadyInFlight
  case permanentSessionLockout
  case receiptUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .requiredDriverIdentityUnavailable:
      "The app has no valid required-driver identity. No driver connection or activation is permitted."
    case .noExactRequiredBuildService:
      "No exact \(DriverBuildRequirement.display) rewindDV Foundation service was found."
    case .ambiguousRequiredBuildServices(let count):
      "Refusing an ambiguous driver match (\(count) exact services)."
    case .differentAttachedBuilds(let builds):
      DriverBuildAssessment.mismatchMessage(builds, required: DriverBuildRequirement.bundled?.build ?? 0)
    case .registryIdentityMismatch(let reason):
      "Driver identity did not pass the exact registry gate: \(reason)"
    case .openFailed(let status):
      "Could not open the exact \(DriverBuildRequirement.display) (\(Self.hex(status)))."
    case .callFailed(let selector, let status):
      "Driver selector \(selector) failed (\(Self.hex(status)))."
    case .malformedReply(let reason):
      "Driver reply failed closed: \(reason)"
    case .deckNotFresh:
      "The selected deck is not present at the same fresh generation and node. Refresh and select it again."
    case .operatorArmRequired:
      "Arm one command before sending deck control."
    case .commandAlreadyInFlight:
      "Another deck operation or receive session is already in progress. No new operation was submitted."
    case .permanentSessionLockout:
      "Deck control is locked for this app session after an uncertain result. Use the deck's physical STOP control if motion may persist."
    case .receiptUnavailable(let reason):
      "No command was sent because its durable flight receipt could not be created: \(reason)"
    }
  }

  private static func hex(_ status: Int32) -> String {
    String(format: "0x%08X", UInt32(bitPattern: status))
  }
}

private final class OpenDriverConnection {
  let service: io_service_t
  let connect: io_connect_t

  init(service: io_service_t, connect: io_connect_t) {
    self.service = service
    self.connect = connect
  }

  deinit {
    IOServiceClose(connect)
    IOObjectRelease(service)
  }
}

private struct ControlFlightEvent: Codable {
  let schemaVersion: UInt16
  let event: String
  let utc: String
  let selector: UInt32
  let operationID: UInt64
  let attemptID: UInt64
  let guid: UInt64
  let driverInstanceID: UInt64
  let deviceIncarnation: UInt64
  let routeEpoch: UInt64
  let generation: UInt32
  let node: UInt8
  let nodeID: UInt16
  let rawRouteResultBase64: String?
  let rawInputBase64: String?
  let ioStatus: Int32?
  let requestID: UInt64?
  let rawResultBase64: String?
  let protocolAccepted: Bool?
  let physicalMotion: String
  let firstError: String?
  let cleanupErrors: [String]
}

private final class ControlFlightReceipt {
  let directoryURL: URL
  let fileURL: URL
  private var handle: FileHandle?

  init() throws {
    let manager = FileManager.default
    guard
      let support = manager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      throw DriverBridgeError.receiptUnavailable("Application Support is unavailable")
    }
    let root =
      support
      .appendingPathComponent("RewindDV", isDirectory: true)
      .appendingPathComponent("ControlFlights", isDirectory: true)
    do {
      try manager.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      directoryURL = root.appendingPathComponent(
        UUID().uuidString.lowercased(), isDirectory: true)
      try manager.createDirectory(
        at: directoryURL, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      fileURL = directoryURL.appendingPathComponent("flight.ndjson")
      let descriptor = Darwin.open(
        fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else {
        throw DriverBridgeError.receiptUnavailable(
          "exclusive journal creation failed with errno \(errno)")
      }
      handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try Self.synchronizeDirectory(support)
      try Self.synchronizeDirectory(root.deletingLastPathComponent())
      try Self.synchronizeDirectory(root)
      try Self.synchronizeDirectory(directoryURL)
    } catch let error as DriverBridgeError {
      throw error
    } catch {
      throw DriverBridgeError.receiptUnavailable(String(describing: error))
    }
  }

  func append(_ event: ControlFlightEvent) throws {
    guard let handle else {
      throw DriverBridgeError.receiptUnavailable("journal is closed")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(event) + Data([0x0a])
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
    } catch {
      throw DriverBridgeError.receiptUnavailable(String(describing: error))
    }
  }

  func close() throws {
    guard let handle else { return }
    self.handle = nil
    do {
      try handle.synchronize()
      try handle.close()
      try Self.synchronizeDirectory(directoryURL)
    } catch {
      throw DriverBridgeError.receiptUnavailable(String(describing: error))
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DriverBridgeError.receiptUnavailable(
        "directory open failed with errno \(errno)")
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw DriverBridgeError.receiptUnavailable(
        "directory synchronization failed with errno \(errno)")
    }
  }
}

struct LivePersistenceHealth: Sendable {
  let copiedThrough: UInt64
  let durableThrough: UInt64
  let acknowledgedThrough: UInt64
  let pendingRecords: Int
  let writerPressure: Bool
  let rawFailure: String?
  let diagnosticFailure: String?
}

actor DriverBridge {
  private static let readinessLog = Logger(subsystem: "net.rewinddigital.RewindDV", category: "DriverReadiness")
  private static let driverClass = "ASFWDriver"
  private static let driverIdentifier = "net.rewinddigital.RewindDV.Driver"
  private static let requiredBuildNumber = DriverBuildRequirement.bundled?.build
  private static let controllerVendor: UInt32 = 0x11c1
  private static let controllerDevice: UInt32 = 0x5901
  private static let capabilitiesSelector: UInt32 = 64
  private static let submitSelector: UInt32 = 65
  private static let resultSelector: UInt32 = 66
  private static let routeSelector: UInt32 = 67
  private static let discoverySelector: UInt32 = 16
  private static let statusSelector: UInt32 = 2

  private var commandInFlight = false
  private var inspectionInFlight = false
  private var commandOwner: AppOperationObservation?
  private var inspectionOwner: AppOperationObservation?
  private var receiveOwner: AppOperationObservation?
  // Retain ownership on an uncertain query; a UI cancellation is not a driver
  // cancellation barrier and must never allow a competing receive/control call.
  private var uncertainInspectionConnection: OpenDriverConnection?
  private var permanentlyLockedOut = false
  private var issuedIdentifiers = Set<UInt64>()
  private var inspectorAttempts = InspectorAttemptSequence()
  private var liveConnection: OpenDriverConnection?
  private var liveRing: LiveReceiveRing?
  private var liveFlight: LiveReceiveFlight?
  private var liveTransportDiagnostics = ReceiveTransportDiagnosticSampler()
  private var liveEpoch: UInt64?
  private var liveRoute: FoundationRoute?
  private var liveStopIssued = false
  private var liveAssembler = DVPreviewPacketAssembler()
  private var liveMediaFormats = ReceiveMediaFormatEvidence()
  private var liveLastMediaFormat: ReceiveMediaFormatEvidence.Format?
  private var liveOrdinal: UInt64 = 0
  private var liveAcknowledgementUncertain = false
  private var livePersistenceUncertain = false
  private var liveObservedSequence: UInt64 = 0
  private var liveKnownLoss: UInt64 = 0
  private var liveJournalState: UInt32?
  private var liveJournalDate = Date.distantPast
  private var liveDurableThrough: UInt64 = 0
  private var liveAcknowledgedThrough: UInt64 = 0
  private var liveCopiedThrough: UInt64 = 0
  private var liveWriterPressure = false
  private var finalLiveStatistics: LiveReceiveBatch?
  func completedReceiveStatistics() -> LiveReceiveBatch? { finalLiveStatistics }

  /// Opens a receive-only session. Never changes tape transport or a remote PCR.
  func beginLiveReceive(_ deck: DiscoveredDeck, destinationParent: URL? = nil,
                        captureFolderKind: CaptureDirectory.Kind = .manual,
                        expectedRoute: FoundationRoute? = nil,
                        existingStopObligation: Bool? = nil) throws -> URL {
    var attempt = ReceiveStartDiagnostic(existingStopObligation: existingStopObligation)
    attempt.blockers = [(liveConnection != nil, "liveConnection"),
      (commandInFlight, "commandInFlight"), (inspectionInFlight, "inspectionInFlight"),
      (permanentlyLockedOut, "permanentlyLockedOut")].compactMap { $0.0 ? $0.1 : nil }
    attempt.owners = [receiveOwner, commandOwner, inspectionOwner].compactMap { $0 }
    var attemptFlight: URL?
    do {
      try Task.checkCancellation()
      guard !permanentlyLockedOut else {
        throw DriverBridgeError.permanentSessionLockout
      }
      guard liveConnection == nil, !commandInFlight, !inspectionInFlight else {
        throw DriverBridgeError.commandAlreadyInFlight
      }
      finalLiveStatistics = nil
      let connection = try openExactRequiredBuildConnection()
      attempt.connectionCreated = true
      _ = try FoundationCapabilities(data: callStructureOutput(connection.connect,
        selector: Self.capabilitiesSelector, maximumBytes: 24))
      let rawRoute = try callScalarInputStructureOutput(connection.connect,
        selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48)
      let route = try FoundationRoute(data: rawRoute)
      guard deck.isOperational, route.guid == deck.guid, route.generation == deck.generation,
        route.nodeID == UInt16(deck.node) else { throw DriverBridgeError.deckNotFresh }
      if let expectedRoute, route != expectedRoute { throw DriverBridgeError.deckNotFresh }
      attempt.flightCreationAttempted = true
      let flight = try LiveReceiveFlight(route: rawRoute, destinationParent: destinationParent,
        captureFolderKind: captureFolderKind)
      attempt.flightCreated = true
      attemptFlight = flight.directory
      // Retain before submission: even malformed output must not erase ownership.
      liveConnection = connection
      attempt.acquiredOwnership = true
      receiveOwner = AppOperationObservation(category: "receive")
      liveFlight = flight
      liveTransportDiagnostics = ReceiveTransportDiagnosticSampler()
      liveRoute = route
      liveStopIssued = false
      liveAssembler = DVPreviewPacketAssembler()
      liveMediaFormats = ReceiveMediaFormatEvidence()
      liveLastMediaFormat = nil
      liveOrdinal = 0
      liveAcknowledgementUncertain = false
      livePersistenceUncertain = false
      liveObservedSequence = 0
      liveKnownLoss = 0
      liveJournalState = nil
      liveJournalDate = .distantPast
      liveDurableThrough = 0
      liveAcknowledgedThrough = 0
      liveCopiedThrough = 0
      liveWriterPressure = false
      var output = Data(count: 24)
      var size = output.count
      let receiveStartBegan = DispatchTime.now().uptimeNanoseconds
      attempt.receiveSubmitted = true
      receiveOwner?.stage = "receive_submitted"
      let status = rawRoute.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { out in
          IOConnectCallStructMethod(connection.connect, 68, input.baseAddress, rawRoute.count,
            out.baseAddress, &size)
        }
      }
      do {
        guard status == KERN_SUCCESS else {
          throw DriverBridgeError.callFailed(selector: 68, status: status)
        }
        let r = WireReader(data: output)
        guard size == 24, try r.integer(0, as: UInt32.self) == 1,
          try r.integer(4, as: UInt32.self) == 24,
          try r.integer(20, as: UInt32.self) == 0,
          try r.integer(8, as: UInt64.self) > 0,
          try r.integer(16, as: UInt32.self) <= 4 else {
          throw DriverBridgeError.malformedReply("Receive session ABI mismatch")
        }
        liveEpoch = try r.integer(8)
        _ = flight.event("receive_start_returned", data: output,
          message: "status=\(status); outputBytes=\(size); startCallNanoseconds=\(DispatchTime.now().uptimeNanoseconds - receiveStartBegan)")
        receiveOwner?.stage = "active"
        return flight.directory
      } catch {
        // No retry and no guessed epoch. Client-close cleanup belongs to the driver.
        _ = flight.event("receive_start_failed", data: output,
          message: "status=\(status); outputBytes=\(size); startCallNanoseconds=\(DispatchTime.now().uptimeNanoseconds - receiveStartBegan); error=\(error)")
        permanentlyLockedOut = true
        throw error
      }
    } catch {
      attempt.completedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
      let observation = attempt
      Self.readinessLog.error("receive_start_failed \(observation.json, privacy: .public)")
      Task { await AlphaSessionRecorder.shared.recordReceiveAdmission(observation) }
      let reason: String
      if attempt.blockers.contains("permanentlyLockedOut") {
        reason = DriverBridgeError.permanentSessionLockout.localizedDescription
      } else if attempt.blockers.contains("liveConnection") {
        reason = "Another receive session is already active. Finish that session before starting capture."
      } else if attempt.blockers.contains("commandInFlight") {
        reason = "A deck command is still completing. Wait for its result before starting capture."
      } else if attempt.blockers.contains("inspectionInFlight") {
        reason = "A device query is still completing. Wait for its result before starting capture."
      } else { reason = error.localizedDescription }
      throw ReceiveStartFailure(reason: reason, diagnostic: attempt, flightURL: attemptFlight)
    }
  }

  func readLiveBatch() throws -> LiveReceiveBatch {
    guard !liveAcknowledgementUncertain, !livePersistenceUncertain else { throw DriverBridgeError.permanentSessionLockout }
    let status = try liveSnapshot()
    guard let connection = liveConnection, let flight = liveFlight else {
      throw DriverBridgeError.malformedReply("Missing receive owner")
    }
    let writer = flight.progress()
    if let failure = writer.failure {
      livePersistenceUncertain = true
      permanentlyLockedOut = true
      throw DriverBridgeError.receiptUnavailable(
        "Raw persistence failed after copied preview bytes; durable prefix \(writer.durableThrough): \(failure)")
    }
    guard writer.durableThrough >= liveDurableThrough,
      writer.durableThrough <= status.writeSequence else {
      livePersistenceUncertain = true
      permanentlyLockedOut = true
      throw DriverBridgeError.malformedReply("Raw writer durable cursor escaped receive bounds")
    }
    liveDurableThrough = writer.durableThrough
    if liveDurableThrough > liveAcknowledgedThrough {
      do { try liveScalarCall(71, [status.epoch, liveDurableThrough]) }
      catch {
        liveAcknowledgementUncertain = true
        permanentlyLockedOut = true
        throw error
      }
      liveRing?.acknowledged(through: liveDurableThrough)
      liveAcknowledgedThrough = liveDurableThrough
    }
    if liveJournalState != status.state || Date().timeIntervalSince(liveJournalDate) >= 1 {
      _ = flight.event("receive_status", data: status.raw)
      liveJournalState = status.state
      liveJournalDate = Date()
    }
    if status.state == 5 {
      permanentlyLockedOut = true
      throw DriverBridgeError.permanentSessionLockout
    }
    if liveRing == nil, status.state != 0 {
      liveRing = try LiveReceiveRing(connection: connection.connect, status: status)
    }
    let availableCapacity = LiveReceiveFlight.maximumRetainedRecords - writer.retainedRecords
    liveWriterPressure = writer.pressure || availableCapacity == 0
    let records = availableCapacity > 0
      ? try liveRing?.copyAvailable(snapshot: status, limit: min(2048, availableCapacity)) ?? [] : []
    var frames: [LivePreservedFrame] = []
    if !records.isEmpty {
      let through = records.last!.sequence
      guard flight.enqueue(records) else {
        liveWriterPressure = true
        return LiveReceiveBatch(status: status, frames: [], drained: false,
          rejectedPackets: liveAssembler.rejectedPackets, assembledFrames: liveOrdinal,
          discontinuities: liveAssembler.discontinuities, incompleteFrames: liveAssembler.incompleteFrames)
      }
      liveRing?.copied(through: through)
      liveCopiedThrough = through
      // Presentation may consume immutable copied bytes before durability. It
      // is never archival verification; ACK remains behind the durable prefix.
      for record in records {
        let r = WireReader(data: record.header)
        let observed: UInt64 = try r.integer(40)
        let loss: UInt64 = try r.integer(48)
        if observed != liveObservedSequence + 1 || loss != liveKnownLoss {
          liveAssembler.markTransportGap()
        }
        liveObservedSequence = observed
        liveKnownLoss = loss
        // Classify only after the immutable raw record is queued. HDV belongs
        // to its own offline assembler, never the DV preview/DIF parser.
        let format = liveMediaFormats.observe(record.payload,
          transferStatus: record.transferStatus, sourceNode: status.route.node)
        if let format {
          if liveLastMediaFormat == .dv && format == .hdv {
            liveAssembler.markTransportGap()
          }
          liveLastMediaFormat = format
        }
        if liveMediaFormats.claimsHDV(record.payload,
          transferStatus: record.transferStatus, sourceNode: status.route.node) { continue }
        for frame in liveAssembler.consumePreservedPacket(record.payload,
          transferStatus: record.transferStatus, expectedSourceNode: status.route.node) {
          let timecode = LiveDVMedia(frame: frame)?.timecode
          frames.append(LivePreservedFrame(bytes: frame, ordinal: liveOrdinal, timecode: timecode))
          liveOrdinal += 1
        }
      }
    }
    return LiveReceiveBatch(status: status, frames: frames,
      // A full batch may already have been replenished while synchronizing.
      drained: records.isEmpty && writer.idle && status.writeSequence == liveAcknowledgedThrough,
      rejectedPackets: liveAssembler.rejectedPackets, assembledFrames: liveOrdinal,
      discontinuities: liveAssembler.discontinuities, incompleteFrames: liveAssembler.incompleteFrames)
  }

  func recordMonitorDiagnostics(_ message: String) throws {
    _ = liveFlight?.event("monitor_statistics", message: message)
  }

  /// One receive stop; never a tape STOP. Terminal records are drained before close.
  func endLiveReceive() async throws -> LivePreservedFrame? {
    guard liveConnection != nil else { return nil }
    guard let epoch = liveEpoch else {
      // A malformed start result gives no usable epoch. Closing this exact owner
      // invokes the driver's reviewed client-close quiesce/quarantine path.
      permanentlyLockedOut = true
      _ = liveFlight?.event("receive_unknown_epoch_owner_close",
        message: "No epoch guessed; driver client-close owns shutdown; outcome unknown")
      liveRing?.unmap()
      liveRing = nil
      liveConnection = nil
      throw DriverBridgeError.permanentSessionLockout
    }
    guard !liveStopIssued else {
      throw DriverBridgeError.permanentSessionLockout
    }
    liveStopIssued = true
    receiveOwner?.stage = "finishing"
    var lastObservedShutdownStatus: LiveReceiveStatus?
    do {
      // A disk fault must not prevent an owner-bound receive shutdown.
      _ = liveFlight?.event("receive_stop_intent")
      try liveScalarCall(69, [epoch])
      var status = try liveSnapshot()
      lastObservedShutdownStatus = status
      _ = liveFlight?.event("receive_stop_returned", data: status.raw)
      // State6 means DMA is quiesced but the owned remote connection/resource
      // lease is still being released. It is not a successful terminal receipt.
      let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(30))
      while status.state == 6 {
        guard ContinuousClock.now < cleanupDeadline else {
          throw DriverBridgeError.malformedReply("Managed receive cleanup deadline expired; ownership is unresolved")
        }
        // Shutdown must finish even when the monitor task was cancelled by Stop.
        await Task.detached { try? await Task.sleep(for: .milliseconds(25)) }.value
        status = try liveSnapshot()
        lastObservedShutdownStatus = status
      }
      _ = liveFlight?.event("receive_cleanup_completed", data: status.raw)
      guard (2...4).contains(status.state) else {
        throw DriverBridgeError.malformedReply("Receive shutdown ended in state \(status.state), status \(Self.ioReturnHex(status.lastStatus)); successful cleanup was not confirmed")
      }
      guard !liveAcknowledgementUncertain, !livePersistenceUncertain else { throw DriverBridgeError.permanentSessionLockout }
      // Terminal occupancy is bounded by the validated ring capacity, not run duration.
      var lastFrame: LivePreservedFrame?
      let drainDeadline = ContinuousClock.now.advanced(by: .seconds(30))
      while ContinuousClock.now < drainDeadline {
        let batch = try readLiveBatch()
        if let frame = batch.frames.last { lastFrame = frame }
        if batch.drained {
          let finalStatus = try liveSnapshot()
          guard finalStatus.state == status.state,
            finalStatus.writeSequence == finalStatus.acknowledged else {
            throw DriverBridgeError.malformedReply("Final receive acknowledgement was not confirmed")
          }
          if finalStatus.dropped > liveKnownLoss { liveAssembler.markTransportGap() }
          liveAssembler.finish()
          let finalStatistics = LiveReceiveBatch(status: finalStatus, frames: [], drained: true,
            rejectedPackets: liveAssembler.rejectedPackets, assembledFrames: liveOrdinal,
            discontinuities: liveAssembler.discontinuities, incompleteFrames: liveAssembler.incompleteFrames)
          _ = liveFlight?.event("receive_final_statistics", message: finalStatistics.finalDiagnosticMessage
            + "; dv_payload_records=\(liveMediaFormats.dvPayloadRecords); hdv_payload_records=\(liveMediaFormats.hdvPayloadRecords); hdv_claimed_payload_records=\(liveMediaFormats.hdvClaimedPayloadRecords); mixed_media=\(liveMediaFormats.isMixed)")
          // The verifier requires final status immediately before receive_closed.
          _ = liveFlight?.event("receive_final_status", data: finalStatus.raw)
          try await liveFlight?.finish("Quiesced state=\(status.state), known ring drops=\(finalStatus.dropped), oversized=\(finalStatus.oversized)")
          finalLiveStatistics = finalStatistics
          liveRing?.unmap()
          liveRing = nil
          liveEpoch = nil
          liveRoute = nil
          liveFlight = nil
          liveConnection = nil
          receiveOwner = nil
          return lastFrame
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
      }
      throw DriverBridgeError.malformedReply("Terminal receive ring did not drain")
    } catch {
      permanentlyLockedOut = true
      if let status = try? liveSnapshot() {
        lastObservedShutdownStatus = status
        _ = liveFlight?.event("receive_cleanup_status", data: status.raw)
      }
      // Preserve even a pending status if the driver's containment gate blocks
      // further reads. This is an observation, never a final successful receipt.
      if let status = lastObservedShutdownStatus {
        _ = liveFlight?.event("receive_cleanup_last_observed_status", data: status.raw)
      }
      let message = ReceiveCleanupEvidence.failureMessage(
        lastObservedState: lastObservedShutdownStatus?.state,
        cause: String(describing: error))
      _ = liveFlight?.event("receive_cleanup_failed", message: message)
      throw DriverBridgeError.malformedReply(message)
    }
  }

  func receiveRequiresLockout() -> Bool { permanentlyLockedOut }

  func receivedMediaFormats() -> ReceiveMediaFormatEvidence { liveMediaFormats }

  func livePersistenceHealth() -> LivePersistenceHealth {
    let writer = liveFlight?.progress()
    return LivePersistenceHealth(copiedThrough: liveCopiedThrough,
      durableThrough: liveDurableThrough, acknowledgedThrough: liveAcknowledgedThrough,
      pendingRecords: writer?.retainedRecords ?? 0,
      writerPressure: liveWriterPressure || (writer?.pressure ?? false),
      rawFailure: writer?.failure, diagnosticFailure: liveFlight?.diagnosticFailure)
  }

  private func liveSnapshot() throws -> LiveReceiveStatus {
    guard let connection = liveConnection, let epoch = liveEpoch, let route = liveRoute else {
      throw DriverBridgeError.malformedReply("No valid receive session")
    }
    let status = try LiveReceiveStatus(callScalarInputStructureOutput(connection.connect,
      selector: 70, scalarInput: [epoch], maximumBytes: 128))
    guard status.epoch == epoch, status.route == route else {
      throw DriverBridgeError.malformedReply("Receive route identity changed")
    }
    return status
  }

  private func liveScalarCall(_ selector: UInt32, _ input: [UInt64]) throws {
    guard let connection = liveConnection else { throw DriverBridgeError.permanentSessionLockout }
    var count: UInt32 = 0
    let status = input.withUnsafeBufferPointer {
      IOConnectCallScalarMethod(connection.connect, selector, $0.baseAddress, UInt32($0.count), nil, &count)
    }
    guard status == KERN_SUCCESS, count == 0 else {
      throw DriverBridgeError.callFailed(selector: selector, status: status)
    }
  }

  /// Read-only discovery, also used at launch and while idle. Never interrupts
  /// an active receive owner, inspection, or transport attempt.
  func refresh() throws -> DriverSnapshot {
    guard !permanentlyLockedOut else { throw DriverBridgeError.permanentSessionLockout }
    guard liveConnection == nil, !commandInFlight, !inspectionInFlight else {
      throw DriverBridgeError.commandAlreadyInFlight
    }
    let connection = try openExactRequiredBuildConnection()
    let capabilitiesData = try callStructureOutput(
      connection.connect, selector: Self.capabilitiesSelector, maximumBytes: 24)
    let capabilities: FoundationCapabilities
    do {
      capabilities = try FoundationCapabilities(data: capabilitiesData)
    } catch {
      throw DriverBridgeError.malformedReply(String(describing: error))
    }

    let discoveryCall = callStructureOutputAllowingNotReady(
      connection.connect, selector: Self.discoverySelector,
      maximumBytes: 4_096)
    let decks: [DiscoveredDeck]
    let discoveryNote: String
    switch discoveryCall {
    case .success(let data):
      do {
        decks = try DiscoveredDeck.decode(data)
        discoveryNote =
          decks.isEmpty
          ? "The exact driver reported no discovered decks."
          : "Fresh full-GUID discovery completed."
      } catch {
        throw DriverBridgeError.malformedReply(String(describing: error))
      }
    case .notReady:
      decks = []
      discoveryNote = "Deck discovery is not ready; no deck identity is assumed."
    case .failed(let status):
      throw DriverBridgeError.callFailed(
        selector: Self.discoverySelector, status: status)
    case .malformedOutput(let bytes):
      throw DriverBridgeError.malformedReply(
        "selector \(Self.discoverySelector) returned invalid size \(bytes)")
    }

    let statusCall = callStructureOutputAllowingNotReady(
      connection.connect, selector: Self.statusSelector, maximumBytes: 4_096)
    let statusData: Data
    let health: DriverHealthEvidence
    switch statusCall {
    case .success(let data):
      statusData = data
      health = .unverified(
        rawStatusBytes: data.count,
        note: "Raw status retained for diagnostics; controller health is UNVERIFIED.")
    case .notReady:
      statusData = Data()
      health = .unverified(
        rawStatusBytes: 0,
        note: "Status selector returned not-ready; controller health is UNVERIFIED.")
    case .failed(let status):
      statusData = Data()
      health = .unverified(
        rawStatusBytes: 0,
        note:
          "Status selector failed with \(Self.ioReturnHex(status)); controller health is UNVERIFIED."
      )
    case .malformedOutput(let bytes):
      statusData = Data()
      health = .unverified(
        rawStatusBytes: 0,
        note:
          "Status selector returned invalid size \(bytes); controller health is UNVERIFIED."
      )
    }
    // Complete route identities let a reconnect invalidate capability observations.
    let routes = try decks.filter(\.isOperational).map { deck in
      let route = try FoundationRoute(data: callScalarInputStructureOutput(connection.connect,
        selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48))
      guard route.guid == deck.guid, route.generation == deck.generation,
        route.node == deck.node else { throw DriverBridgeError.deckNotFresh }
      return route
    }
    return DriverSnapshot(
      capabilities: capabilities,
      decks: decks,
      health: health,
      rawStatus: statusData,
      discoveryNote: discoveryNote, routes: routes)
  }

  /// Read-only rediscovery. A new session must still revalidate this complete
  /// route at admission. A restarted driver or ambiguous GUID is not recovery.
  func rediscoverAfterBusReset(previous: FoundationRoute) throws -> (DiscoveredDeck, FoundationRoute)? {
    let snapshot: DriverSnapshot
    do { snapshot = try refresh() }
    catch DriverBridgeError.deckNotFresh { return nil }
    catch DriverBridgeError.callFailed(let selector, let status)
      where selector == Self.routeSelector && [kIOReturnNotFound, kIOReturnNotReady, kIOReturnAborted].contains(status) {
      return nil
    }
    let decks = snapshot.decks.filter { $0.guid == previous.guid && $0.isOperational }
    let routes = snapshot.routes.filter { $0.guid == previous.guid }
    guard decks.count <= 1, routes.count <= 1 else {
      throw DriverBridgeError.malformedReply("Ambiguous deck identity during reconnect")
    }
    guard let deck = decks.first, let route = routes.first else { return nil }
    guard route.driverInstanceID == previous.driverInstanceID else {
      throw DriverBridgeError.malformedReply("Driver restarted; automatic receive recovery is unsafe")
    }
    guard route != previous else { return nil }
    return (deck, route)
  }

  func perform(
    _ command: DeckCommand,
    selectedDeck: DiscoveredDeck,
    explicitlyArmed: Bool,
    expectedRoute: FoundationRoute? = nil
  ) async throws -> ControlAttemptReport {
    guard explicitlyArmed else { throw DriverBridgeError.operatorArmRequired }
    guard selectedDeck.isOperational else { throw DriverBridgeError.deckNotFresh }
    guard !permanentlyLockedOut else {
      throw DriverBridgeError.permanentSessionLockout
    }
    guard !commandInFlight, !inspectionInFlight else { throw DriverBridgeError.commandAlreadyInFlight }
    commandInFlight = true
    commandOwner = AppOperationObservation(category: "transport_" + command.title)
    defer { commandInFlight = false; commandOwner = nil }
    let diagnosticFlight = liveFlight

    let connection = try openExactRequiredBuildConnection()
    let capabilitiesData = try callStructureOutput(
      connection.connect, selector: Self.capabilitiesSelector, maximumBytes: 24)
    do {
      _ = try FoundationCapabilities(data: capabilitiesData)
    } catch {
      throw DriverBridgeError.malformedReply(String(describing: error))
    }
    let freshDiscovery = try callStructureOutput(
      connection.connect, selector: Self.discoverySelector,
      maximumBytes: 4_096)
    let freshDecks: [DiscoveredDeck]
    do {
      freshDecks = try DiscoveredDeck.decode(freshDiscovery)
    } catch {
      throw DriverBridgeError.malformedReply(String(describing: error))
    }
    guard
      freshDecks.contains(where: {
        $0.isOperational && $0.guid == selectedDeck.guid && $0.generation == selectedDeck.generation
          && $0.node == selectedDeck.node
      })
    else {
      throw DriverBridgeError.deckNotFresh
    }

    let rawRoute = try callScalarInputStructureOutput(
      connection.connect, selector: Self.routeSelector,
      scalarInput: [selectedDeck.guid], maximumBytes: FoundationRoute.wireBytes)
    let route: FoundationRoute
    do {
      route = try FoundationRoute(data: rawRoute)
    } catch {
      throw DriverBridgeError.malformedReply(String(describing: error))
    }
    guard route.guid == selectedDeck.guid,
      route.generation == selectedDeck.generation,
      route.nodeID == UInt16(selectedDeck.node)
    else {
      throw DriverBridgeError.deckNotFresh
    }
    if let expectedRoute, route != expectedRoute { throw DriverBridgeError.deckNotFresh }

    let operationID = uniqueIdentifier()
    let attemptID = uniqueIdentifier()
    let request: Data
    do {
      request = try command.encode(
        operationID: operationID, attemptID: attemptID, route: route)
    } catch {
      throw DriverBridgeError.malformedReply(String(describing: error))
    }
    let receipt: ControlFlightReceipt
    do {
      receipt = try ControlFlightReceipt()
      try receipt.append(
        ControlFlightEvent(
          schemaVersion: 1,
          event: "intent_durable_before_mutation",
          utc: Self.utcNow(),
          selector: Self.submitSelector,
          operationID: operationID,
          attemptID: attemptID,
          guid: route.guid,
          driverInstanceID: route.driverInstanceID,
          deviceIncarnation: route.deviceIncarnation,
          routeEpoch: route.routeEpoch,
          generation: route.generation,
          node: route.node,
          nodeID: route.nodeID,
          rawRouteResultBase64: rawRoute.base64EncodedString(),
          rawInputBase64: request.base64EncodedString(),
          ioStatus: nil,
          requestID: nil,
          rawResultBase64: nil,
          protocolAccepted: nil,
          physicalMotion: "unknown",
          firstError: nil,
          cleanupErrors: []))
    } catch {
      throw DriverBridgeError.receiptUnavailable(String(describing: error))
    }

    commandOwner?.stage = "command_submitted"
    let submission = submit(
      connection.connect, request: request, selector: Self.submitSelector)
    // Best-effort correlation after submission; the control receipt remains the
    // authority. Never add a durability wait or change command admission.
    if let diagnosticFlight, diagnosticFlight === liveFlight,
      route == liveRoute, !liveStopIssued {
      diagnosticFlight.event("transport_command_submission", data: request,
        message: "command=\(command.title); receipt=\(receipt.directoryURL.path); operation_id=\(operationID); attempt_id=\(attemptID); io_status=\(submission.status); physical_motion=unverified", transportDiagnostic: true)
    }
    guard submission.status == KERN_SUCCESS, let requestID = submission.requestID else {
      return uncertainReport(
        command: command,
        receipt: receipt,
        route: route,
        operationID: operationID,
        attemptID: attemptID,
        ioStatus: submission.status,
        requestID: submission.requestID,
        rawResult: nil,
        firstError: "Command submission returned an uncertain status.")
    }

    do {
      try receipt.append(
        ControlFlightEvent(
          schemaVersion: 1,
          event: "submission_returned",
          utc: Self.utcNow(),
          selector: Self.submitSelector,
          operationID: operationID,
          attemptID: attemptID,
          guid: route.guid,
          driverInstanceID: route.driverInstanceID,
          deviceIncarnation: route.deviceIncarnation,
          routeEpoch: route.routeEpoch,
          generation: route.generation,
          node: route.node,
          nodeID: route.nodeID,
          rawRouteResultBase64: rawRoute.base64EncodedString(),
          rawInputBase64: request.base64EncodedString(),
          ioStatus: submission.status,
          requestID: requestID,
          rawResultBase64: nil,
          protocolAccepted: nil,
          physicalMotion: "unknown",
          firstError: nil,
          cleanupErrors: []))
    } catch {
      return uncertainReport(
        command: command,
        receipt: receipt,
        route: route,
        operationID: operationID,
        attemptID: attemptID,
        ioStatus: submission.status,
        requestID: requestID,
        rawResult: nil,
        firstError: "The command may be in flight, but its submission receipt failed: \(error)")
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while clock.now < deadline {
      let poll = pollResult(
        connection.connect, requestID: requestID,
        operationID: operationID, attemptID: attemptID,
        selector: Self.resultSelector,
        maximumBytes: ControlResult.maximumWireBytes)
      if poll.status == kIOReturnNotReady {
        do {
          try await Task.sleep(for: .milliseconds(100))
        } catch {
          return uncertainReport(
            command: command,
            receipt: receipt,
            route: route,
            operationID: operationID,
            attemptID: attemptID,
            ioStatus: kIOReturnAborted,
            requestID: requestID,
            rawResult: nil,
            firstError:
              "Result polling was interrupted; the command was not resubmitted.")
        }
        continue
      }
      guard poll.status == KERN_SUCCESS, let rawResult = poll.data else {
        return uncertainReport(
          command: command,
          receipt: receipt,
          route: route,
          operationID: operationID,
          attemptID: attemptID,
          ioStatus: poll.status,
          requestID: requestID,
          rawResult: poll.data,
          firstError: "Result polling ended without a trustworthy terminal record.")
      }
      let result: ControlResult
      do {
        result = try ControlResult(data: rawResult)
      } catch {
        return uncertainReport(
          command: command,
          receipt: receipt,
          route: route,
          operationID: operationID,
          attemptID: attemptID,
          ioStatus: poll.status,
          requestID: requestID,
          rawResult: rawResult,
          firstError: "Terminal result failed ABI validation: \(error)")
      }
      guard result.requestID == requestID,
        result.operationID == operationID,
        result.attemptID == attemptID,
        result.guid == route.guid,
        result.driverInstanceID == route.driverInstanceID,
        result.deviceIncarnation == route.deviceIncarnation,
        result.routeEpoch == route.routeEpoch,
        result.command == command,
        result.generation == route.generation,
        result.nodeID == route.nodeID
      else {
        return uncertainReport(
          command: command,
          receipt: receipt,
          route: route,
          operationID: operationID,
          attemptID: attemptID,
          ioStatus: poll.status,
          requestID: requestID,
          rawResult: rawResult,
          firstError: "Terminal result was not bound to the fresh selected route.")
      }

      commandOwner?.stage = "terminal_result_consumed"
      guard result.accepted else {
        return uncertainReport(
          command: command,
          receipt: receipt,
          route: route,
          operationID: operationID,
          attemptID: attemptID,
          ioStatus: poll.status,
          requestID: requestID,
          rawResult: rawResult,
          firstError: "The protocol result was not an exact ACCEPTED response.",
          result: result)
      }

      do {
        try receipt.append(
          ControlFlightEvent(
            schemaVersion: 1,
            event: "terminal_result",
            utc: Self.utcNow(),
            selector: Self.resultSelector,
            operationID: operationID,
            attemptID: attemptID,
            guid: route.guid,
            driverInstanceID: route.driverInstanceID,
            deviceIncarnation: route.deviceIncarnation,
            routeEpoch: route.routeEpoch,
            generation: route.generation,
            node: route.node,
            nodeID: route.nodeID,
            rawRouteResultBase64: nil,
            rawInputBase64: nil,
            ioStatus: poll.status,
            requestID: requestID,
            rawResultBase64: rawResult.base64EncodedString(),
            protocolAccepted: true,
            physicalMotion: "unknown",
            firstError: nil,
            cleanupErrors: []))
        try receipt.close()
      } catch {
        return uncertainReport(
          command: command,
          receipt: receipt,
          route: route,
          operationID: operationID,
          attemptID: attemptID,
          ioStatus: poll.status,
          requestID: requestID,
          rawResult: rawResult,
          firstError: "Terminal evidence could not be made durable: \(error)",
          result: result)
      }
      if let diagnosticFlight, diagnosticFlight === liveFlight,
        route == liveRoute, !liveStopIssued {
        diagnosticFlight.event("transport_command_result", data: rawResult,
          message: "command=\(command.title); receipt=\(receipt.directoryURL.path); operation_id=\(operationID); attempt_id=\(attemptID); protocol_accepted=true; physical_motion=unverified", transportDiagnostic: true)
      }
      return ControlAttemptReport(
        disposition: .protocolAcceptedMotionUnverified,
        command: command,
        result: result,
        receiptURL: receipt.directoryURL,
        message: command == .stop
          ? "STOP was accepted. Verify physically that the deck has stopped."
          : "Protocol ACCEPTED is recorded; motion remains unverified. Keep supervising and finish with a fresh-route software STOP, or physical STOP if anything becomes uncertain.",
        requiresSupervisedStop: command != .stop,
        firstError: nil,
        cleanupErrors: [])
    }

    return uncertainReport(
      command: command,
      receipt: receipt,
      route: route,
      operationID: operationID,
      attemptID: attemptID,
      ioStatus: kIOReturnTimeout,
      requestID: requestID,
      rawResult: nil,
      firstError: "The bounded 10-second result poll timed out; the command was not resubmitted.")
  }

  private func uncertainReport(
    command: DeckCommand,
    receipt: ControlFlightReceipt,
    route: FoundationRoute,
    operationID: UInt64,
    attemptID: UInt64,
    ioStatus: Int32,
    requestID: UInt64?,
    rawResult: Data?,
    firstError: String,
    result: ControlResult? = nil
  ) -> ControlAttemptReport {
    permanentlyLockedOut = true
    var cleanupErrors: [String] = []
    do {
      try receipt.append(
        ControlFlightEvent(
          schemaVersion: 1,
          event: "uncertain_terminal_lockout",
          utc: Self.utcNow(),
          selector: Self.resultSelector,
          operationID: operationID,
          attemptID: attemptID,
          guid: route.guid,
          driverInstanceID: route.driverInstanceID,
          deviceIncarnation: route.deviceIncarnation,
          routeEpoch: route.routeEpoch,
          generation: route.generation,
          node: route.node,
          nodeID: route.nodeID,
          rawRouteResultBase64: nil,
          rawInputBase64: nil,
          ioStatus: ioStatus,
          requestID: requestID,
          rawResultBase64: rawResult?.base64EncodedString(),
          protocolAccepted: result?.accepted,
          physicalMotion: "unknown_manual_stop_required_if_motion_may_persist",
          firstError: firstError,
          cleanupErrors: []))
    } catch {
      cleanupErrors.append("Could not append lockout evidence: \(error)")
    }
    do {
      try receipt.close()
    } catch {
      cleanupErrors.append("Could not close flight receipt: \(error)")
    }
    return ControlAttemptReport(
      disposition: .uncertainLockedOut,
      command: command,
      result: result,
      receiptURL: receipt.directoryURL,
      message:
        "Result is uncertain. Control is permanently locked for this app session; use the deck's physical STOP control if motion may persist.",
      requiresSupervisedStop: true,
      firstError: firstError,
      cleanupErrors: cleanupErrors)
  }

  /// Generic inventory is idle-only. A route-bound transport-only STATUS can
  /// coexist with receive, never with another FCP request. No CONTROL or retry.
  func inspectDevice(_ deck: DiscoveredDeck, tapeStateOnly: Bool = false,
    transportOnly: Bool = false, expectedRoute: FoundationRoute? = nil,
    passiveTransport: Bool = false, timecodeOnly: Bool = false,
    rapidIdleObservation: Bool = false) async throws -> DeviceInspectionReport {
    guard !rapidIdleObservation || (passiveTransport && expectedRoute != nil &&
      liveConnection == nil && (transportOnly || timecodeOnly) && !tapeStateOnly) else {
      throw ControlWireError.invalid("Rapid observation requires one idle exact-route passive STATUS")
    }
    guard !timecodeOnly || (!transportOnly && !tapeStateOnly && expectedRoute != nil) else {
      throw ControlWireError.invalid("Timecode requires one exact route-bound STATUS")
    }
    guard !passiveTransport || ((transportOnly || timecodeOnly) && !tapeStateOnly && expectedRoute != nil) else {
      throw ControlWireError.invalid("Compact passive evidence requires one route-bound transport STATUS")
    }
    guard !permanentlyLockedOut else { throw DriverBridgeError.permanentSessionLockout }
    guard !commandInFlight, !inspectionInFlight,
      liveConnection == nil || (transportOnly && !tapeStateOnly && expectedRoute != nil && expectedRoute == liveRoute) else {
      throw DriverBridgeError.commandAlreadyInFlight
    }
    guard deck.isOperational else { throw DriverBridgeError.deckNotFresh }
    inspectionInFlight = true
    inspectionOwner = AppOperationObservation(category: timecodeOnly ? "passive_timecode" :
      passiveTransport ? "passive_transport" : transportOnly ? "transport_status" :
      tapeStateOnly ? "tape_state" : "inventory")
    defer { inspectionInFlight = false; inspectionOwner = nil }
    let diagnosticFlight = liveFlight
    let connection = try openExactRequiredBuildConnection()
    _ = try FoundationCapabilities(data: callStructureOutput(connection.connect,
      selector: Self.capabilitiesSelector, maximumBytes: 24))
    _ = try InspectorCapabilities(data: callStructureOutput(connection.connect,
      selector: 72, maximumBytes: 40))
    let rawRoute = try callScalarInputStructureOutput(connection.connect,
      selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48)
    let route = try FoundationRoute(data: rawRoute)
    guard route.guid == deck.guid, route.generation == deck.generation,
      route.nodeID == UInt16(deck.node) else { throw DriverBridgeError.deckNotFresh }
    if let expectedRoute, route != expectedRoute { throw DriverBridgeError.deckNotFresh }
    let receipt = try await InspectorFlight.open(tapeStateProbe: tapeStateOnly || transportOnly || timecodeOnly, passiveTransport: passiveTransport)
    let observedAt = Date()
    var entries: [DeviceInspectionEntry] = []
    var completion = "Inventory finished. These are protocol observations, not physical qualification."
    var mayBePending = false
    var validatedTransportState: [UInt8]?
    var transportDiagnosticResult: Data?
    var validatedDeckTimecode: [UInt8]?
    var queries: [InspectorQuery] = timecodeOnly ? [.tapeTimecode] : transportOnly ? [.tapeTransportState] : tapeStateOnly ? [.tapeMediumInfo, .tapeTransportState, .tapeAbsoluteTrackNumber] :
      [.unitInfo, .subunitInfo(page: 0), .unitPlugInfo]
    var currentQuery: InspectorQuery?
    do {
      let intent = timecodeOnly ? "One optional idle-receiver deck timecode STATUS; no CONTROL, search or retry; display only" : transportOnly ? "One route-bound transport STATUS; receive may remain active; no CONTROL or retry; no absolute BOT/EOT proof" : tapeStateOnly ? "Three typed STATUS observations: medium, transport, DV ATN; receive/control idle; no motion or retry; no BOT/EOT proof" :
        "STATUS-only inventory; maximum ten queries; ten-second host deadline per query; no retry"
      try await receipt.appendAsync(event: "inventory_started", query: nil, route: rawRoute,
        message: intent + (rapidIdleObservation ? "; rapid_idle_local_completion_poll=1ms_then_backoff; no AV/C replay" : ""))
      while !queries.isEmpty {
        if Task.isCancelled {
          completion = "Inventory cancelled between queries. No command was replayed."
          break
        }
        let query = queries.removeFirst()
        currentQuery = query
        // Every query must remain in the same complete route epoch as the batch.
        let freshRoute = try callScalarInputStructureOutput(connection.connect,
          selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48)
        guard freshRoute == rawRoute else { throw DriverBridgeError.deckNotFresh }
        let attemptID = try inspectorAttempts.next(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        let operationID = attemptID
        let request = try query.encode(operationID: operationID, attemptID: attemptID, route: route)
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        try await receipt.appendAsync(event: "query_intent_durable", query: query, route: rawRoute, request: request,
          hostDeadlineUptimeNanoseconds: deadline)
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw ControlWireError.invalid("Host deadline expired before submission; query not sent")
        }
        mayBePending = true
        inspectionOwner?.stage = "query_submitted"
        let submission = submit(connection.connect, request: request, selector: 73)
        try await receipt.appendAsync(event: "query_submission_returned", query: query, route: rawRoute,
          request: request, status: submission.status,
          message: "requestID=\(submission.requestID.map(String.init) ?? "missing")")
        guard submission.status == KERN_SUCCESS, let requestID = submission.requestID else {
          throw DriverBridgeError.callFailed(selector: 73, status: submission.status)
        }
        var result: InspectorResult?
        var notReadyCount = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
          let poll = pollResult(connection.connect, requestID: requestID,
            operationID: operationID, attemptID: attemptID, selector: 74,
            maximumBytes: InspectorResult.wireBytes)
          if poll.status == kIOReturnNotReady {
            let interval = InspectorCompletionPolling.interval(rapidIdle: rapidIdleObservation,
              notReadyCount: notReadyCount)
            notReadyCount += 1
            try await Task.sleep(for: interval)
            continue
          }
          try await receipt.appendAsync(event: "query_result_returned", query: query, route: rawRoute,
            result: poll.data, status: poll.status,
            message: rapidIdleObservation ? "local_not_ready_polls=\(notReadyCount); rapid_idle=true" : nil)
          guard poll.status == KERN_SUCCESS, let raw = poll.data else {
            throw DriverBridgeError.callFailed(selector: 74, status: poll.status)
          }
          result = try InspectorResult(data: raw, requestID: requestID,
            operationID: operationID, attemptID: attemptID, route: route, query: query)
          if query == .tapeTransportState { transportDiagnosticResult = raw }
          break
        }
        guard let result else { throw ControlWireError.invalid("Inspector host deadline expired; support remains unknown") }
        // A consumed, bound terminal record establishes completion, not success.
        mayBePending = false
        inspectionOwner?.stage = "terminal_result_consumed"
        let response = result.events.last?.bytes ?? []
        guard result.status == 0, result.routeState == 1 else {
          let reason: String
          if result.routeState == 2 {
            reason = "Route invalidated by an observed bus reset"
          } else if result.status == kIOReturnTimeout {
            reason = result.events.contains(where: { $0.classification == 2 })
              ? "Interim limit reached — timed out; support unknown"
              : "Timed out — support unknown"
          } else if result.status != 0 {
            reason = "Transport failed (\(Self.ioReturnHex(result.status))) — support unknown"
          } else { reason = "Route authority unknown — no interpretation" }
          entries.append(.init(query: query, disposition: reason,
            facts: [], response: response))
          completion = "Inventory stopped after a transport/route failure. Remaining queries were not sent."
          break
        }
        let interpretation: InspectorInterpretation?
        do { interpretation = try result.interpretation(for: query) }
        catch {
          entries.append(.init(query: query, disposition: "Interpretation unavailable: \(error.localizedDescription)", facts: [], response: response))
          continue
        }
        if query == .tapeTransportState, interpretation != nil {
          validatedTransportState = response
        }
        if query == .tapeTimecode, interpretation != nil,
          AVCTapeStatusDecoder.timecode(response) != nil {
          validatedDeckTimecode = response
        }
        entries.append(.init(query: query,
          disposition: interpretation?.disposition ?? (result.classification == 6
            ? "ACCEPTED is invalid for this STATUS query" : result.classification == 8
            ? "CHANGED is invalid for this STATUS query" : "Response retained; no valid inventory interpretation"),
          facts: interpretation?.facts ?? [], response: response))
        if ![UInt32(3),4,5].contains(result.classification) && !(query == .tapeTransportState && result.classification == 7) {
          completion = "Inventory stopped after an invalid STATUS response. Remaining queries were not sent."
          break
        }
        if case .subunitInfo(let page) = query,
          let interpretation, interpretation.disposition == "Implemented status",
          !interpretation.lastSubunitPage, page < 7 {
          queries.insert(.subunitInfo(page: page + 1), at: 0)
        }
      }
      for query in queries {
        entries.append(.init(query: query, disposition: "Not queried — inventory stopped", facts: [], response: []))
      }
      try await receipt.appendAsync(event: "inventory_finished", query: nil, route: rawRoute, message: completion)
      try await receipt.finishAsync()
    } catch {
      validatedTransportState = nil
      completion = "Inventory incomplete: \(error.localizedDescription). No retry or fallback was sent."
      if let currentQuery, entries.last?.query != currentQuery {
        entries.append(.init(query: currentQuery,
          disposition: mayBePending ? "Completion uncertain — support unknown" : "Not queried — \(error.localizedDescription)",
          facts: [], response: []))
      }
      for query in queries {
        entries.append(.init(query: query, disposition: "Not queried — inventory stopped", facts: [], response: []))
      }
      if mayBePending {
        permanentlyLockedOut = true
        uncertainInspectionConnection = connection
        completion += " Control and capture are locked for this app session because query completion is uncertain."
      }
      do {
        try await receipt.appendAsync(event: "inventory_failed", query: currentQuery, route: rawRoute, message: completion)
        try await receipt.finishAsync()
      } catch { completion += " Evidence finalization also failed: \(error.localizedDescription)." }
    }
    // Sample existing observations only. Identity and shutdown guards prevent
    // late replies from entering another flight or its terminal journal pair.
    if transportOnly, let diagnosticFlight, diagnosticFlight === liveFlight,
      route == liveRoute, !liveStopIssued,
      liveTransportDiagnostics.shouldRecord(validatedTransportState) {
      diagnosticFlight.event("transport_status_observed", data: transportDiagnosticResult ?? Data(),
        message: "receipt=\(receipt.directoryURL.path); observation_id=\(receipt.observationID); raw_route_base64=\(rawRoute.base64EncodedString()); validated_response_base64=\(validatedTransportState.map { Data($0).base64EncodedString() } ?? "unknown"); diagnostic_sample=state_change_or_followup; physical_motion=unverified; \(completion)", transportDiagnostic: true)
    }
    return DeviceInspectionReport(deck: deck, observedAt: observedAt, receiptURL: receipt.directoryURL,
      entries: entries, completion: completion, controlLockedOut: permanentlyLockedOut,
      route: route, validatedTransportState: validatedTransportState,
      observationID: passiveTransport ? receipt.observationID : nil,
      validatedDeckTimecode: validatedDeckTimecode)
  }

  /// Explicit idle-only closed SPECIFIC INQUIRY catalog. No CONTROL, retries,
  /// receive selectors or generic opcode input. Uncertain completion retains owner.
  func probeTransportCapabilities(_ deck: DiscoveredDeck) async throws -> TransportCapabilityReport {
    guard !permanentlyLockedOut else { throw DriverBridgeError.permanentSessionLockout }
    guard !commandInFlight, !inspectionInFlight, liveConnection == nil else {
      throw DriverBridgeError.commandAlreadyInFlight
    }
    guard deck.isOperational else { throw DriverBridgeError.deckNotFresh }
    inspectionInFlight = true
    inspectionOwner = AppOperationObservation(category: "capability_probe")
    defer { inspectionInFlight = false; inspectionOwner = nil }
    let connection = try openExactRequiredBuildConnection()
    let catalog = try callStructureOutput(connection.connect, selector: 75, maximumBytes: 176)
    try TransportCapabilityCatalog.validate(catalog)
    let rawRoute = try callScalarInputStructureOutput(connection.connect,
      selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48)
    let route = try FoundationRoute(data: rawRoute)
    guard route.guid == deck.guid, route.generation == deck.generation, route.node == deck.node else {
      throw DriverBridgeError.deckNotFresh
    }
    let flight = try await InspectorFlight.open(capabilityProbe: true)
    var entries: [TransportCapabilityEntry] = []
    let observedAt = Date()
    var pending = false
    var completion = "Probe finished. Reported support is not physical qualification or present-state readiness."
    do {
      try await flight.appendAsync(event: "catalog_validated", query: nil, route: rawRoute, result: catalog)
      for command in TransportCapabilityCatalog.commands {
        try Task.checkCancellation()
        let fresh = try callScalarInputStructureOutput(connection.connect,
          selector: Self.routeSelector, scalarInput: [deck.guid], maximumBytes: 48)
        guard fresh == rawRoute else { throw DriverBridgeError.deckNotFresh }
        let operationID = uniqueIdentifier(), attemptID = uniqueIdentifier()
        let request = try TransportCapabilityCatalog.request(command, operationID: operationID,
          attemptID: attemptID, route: route)
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        try await flight.appendAsync(event: "probe_intent_durable", query: nil, route: rawRoute,
          request: request, hostDeadlineUptimeNanoseconds: deadline, command: command)
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ControlWireError.invalid("Deadline before probe submission") }
        pending = true
        inspectionOwner?.stage = "query_submitted"
        let submission = submit(connection.connect, request: request, selector: 76)
        try await flight.appendAsync(event: "probe_submission_returned", query: nil, route: rawRoute,
          request: request, status: submission.status,
          message: "requestID=\(submission.requestID.map(String.init) ?? "missing")", command: command)
        guard submission.status == KERN_SUCCESS, let requestID = submission.requestID else {
          throw DriverBridgeError.callFailed(selector: 76, status: submission.status)
        }
        var result: TransportCapabilityResult?
        while DispatchTime.now().uptimeNanoseconds < deadline {
          let poll = pollResult(connection.connect, requestID: requestID, operationID: operationID,
            attemptID: attemptID, selector: 77, maximumBytes: TransportCapabilityResult.wireBytes)
          if poll.status == kIOReturnNotReady { try await Task.sleep(for: .milliseconds(50)); continue }
          try await flight.appendAsync(event: "probe_result_returned", query: nil, route: rawRoute,
            result: poll.data, status: poll.status, command: command)
          guard poll.status == KERN_SUCCESS, let bytes = poll.data else {
            throw DriverBridgeError.callFailed(selector: 77, status: poll.status)
          }
          result = try TransportCapabilityResult(data: bytes, requestID: requestID,
            operationID: operationID, attemptID: attemptID, route: route, command: command)
          break
        }
        guard let result else { throw ControlWireError.invalid("Probe deadline expired; completion unknown") }
        pending = false
        inspectionOwner?.stage = "terminal_result_consumed"
        entries.append(.init(command: command, support: result.support,
          detail: result.cleanObservation ? result.support.title
            : "No valid support observation. Status \(result.status); route \(result.routeState); classification \(result.classification).",
          responses: result.responses, conditionalAuthorization: result.conditionalAuthorization))
        if !result.cleanObservation {
          completion = "Probe stopped after an unknown/failed response. Remaining commands were not queried."
          break
        }
      }
      try await flight.appendAsync(event: "probe_finished", query: nil, route: rawRoute, message: completion)
      try await flight.finishAsync()
    } catch {
      completion = "Probe incomplete: \(error.localizedDescription). No retry or fallback was sent."
      // No partially successful batch may expose the new motion control.
      entries = entries.map { .init(command: $0.command, support: $0.support,
        detail: $0.detail, responses: $0.responses, conditionalAuthorization: false) }
      if pending {
        permanentlyLockedOut = true
        uncertainInspectionConnection = connection
        completion += " Session locked: query completion is uncertain."
      }
      do {
        try await flight.appendAsync(event: "probe_failed", query: nil, route: rawRoute, message: completion)
        try await flight.finishAsync()
      } catch { completion += " Evidence finalization failed: \(error.localizedDescription)." }
    }
    for command in TransportCapabilityCatalog.commands where !entries.contains(where: { $0.command == command }) {
      entries.append(.init(command: command, support: .unknown, detail: "Not queried or no bound terminal result",
        responses: [], conditionalAuthorization: false))
    }
    return .init(route: route, observedAt: observedAt, receiptURL: flight.directoryURL,
      entries: entries, completion: completion, lockedOut: permanentlyLockedOut)
  }

  private func openExactRequiredBuildConnection() throws -> OpenDriverConnection {
    guard let requiredBuildNumber = Self.requiredBuildNumber else {
      throw DriverBridgeError.requiredDriverIdentityUnavailable
    }
    guard let matching = IOServiceNameMatching(Self.driverClass) else {
      throw DriverBridgeError.noExactRequiredBuildService
    }
    var iterator: io_iterator_t = 0
    let matchStatus = IOServiceGetMatchingServices(
      kIOMainPortDefault, matching, &iterator)
    guard matchStatus == KERN_SUCCESS else {
      throw DriverBridgeError.openFailed(matchStatus)
    }
    defer { IOObjectRelease(iterator) }

    var exact: [io_service_t] = []
    var attachedBuilds: [UInt64?] = []
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      let identityMatches = exactRegistryIdentity(service, requireBuild: false)
      let build = registryInteger(service, key: "FoundationBuildNumber")
      if identityMatches { attachedBuilds.append(build) }
      if identityMatches && build == requiredBuildNumber {
        exact.append(service)
      } else {
        IOObjectRelease(service)
      }
    }
    let assessment = DriverBuildAssessment.assess(attachedBuilds, required: requiredBuildNumber)
    Self.readinessLog.notice("registry_check required=\(requiredBuildNumber) attached=\(String(describing: attachedBuilds), privacy: .public) exact_count=\(exact.count)")
    guard assessment == .exact else {
      for service in exact { IOObjectRelease(service) }
      switch assessment {
      case .differentBuilds(let builds): throw DriverBridgeError.differentAttachedBuilds(builds)
      case .ambiguous(let count): throw DriverBridgeError.ambiguousRequiredBuildServices(count)
      default: throw DriverBridgeError.noExactRequiredBuildService
      }
    }
    let service = exact[0]
    var connect: io_connect_t = 0
    let openStatus = IOServiceOpen(service, mach_task_self_, 0, &connect)
    guard openStatus == KERN_SUCCESS, connect != 0 else {
      IOObjectRelease(service)
      throw DriverBridgeError.openFailed(openStatus)
    }
    return OpenDriverConnection(service: service, connect: connect)
  }

  private func exactRegistryIdentity(_ service: io_service_t, requireBuild: Bool = true) -> Bool {
    guard let requiredBuildNumber = Self.requiredBuildNumber else { return false }
    guard registryString(service, key: "IOUserServerName") == Self.driverIdentifier,
      registryString(service, key: "CFBundleIdentifier") == Self.driverIdentifier,
      (!requireBuild || registryInteger(service, key: "FoundationBuildNumber")
        == requiredBuildNumber)
    else { return false }

    var provider: io_registry_entry_t = 0
    guard
      IORegistryEntryGetParentEntry(service, kIOServicePlane, &provider)
        == KERN_SUCCESS
    else { return false }
    defer { IOObjectRelease(provider) }
    guard IOObjectConformsTo(provider, "IOPCIDevice") != 0 else { return false }
    return registryUInt32(provider, key: "vendor-id") == Self.controllerVendor
      && registryUInt32(provider, key: "device-id") == Self.controllerDevice
  }

  private func registryValue(_ entry: io_registry_entry_t, key: String) -> Any? {
    IORegistryEntryCreateCFProperty(
      entry, key as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue()
  }

  private func registryString(_ entry: io_registry_entry_t, key: String) -> String? {
    registryValue(entry, key: key) as? String
  }

  private func registryInteger(_ entry: io_registry_entry_t, key: String) -> UInt64? {
    if let number = registryValue(entry, key: key) as? NSNumber {
      return number.uint64Value
    }
    if let text = registryValue(entry, key: key) as? String {
      return UInt64(text)
    }
    return nil
  }

  private func registryUInt32(_ entry: io_registry_entry_t, key: String) -> UInt32? {
    if let number = registryValue(entry, key: key) as? NSNumber {
      return number.uint32Value
    }
    guard let data = registryValue(entry, key: key) as? Data, data.count == 4
    else { return nil }
    return data.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
    }
  }

  private enum OptionalStructureResult {
    case success(Data)
    case notReady
    case failed(Int32)
    case malformedOutput(Int)
  }

  private func callStructureOutputAllowingNotReady(
    _ connect: io_connect_t,
    selector: UInt32,
    maximumBytes: Int
  ) -> OptionalStructureResult {
    var output = Data(count: maximumBytes)
    var outputSize = maximumBytes
    let status = output.withUnsafeMutableBytes {
      IOConnectCallStructMethod(
        connect, selector, nil, 0, $0.baseAddress, &outputSize)
    }
    if status == kIOReturnNotReady { return .notReady }
    guard status == KERN_SUCCESS else { return .failed(status) }
    guard outputSize >= 0, outputSize <= maximumBytes else {
      return .malformedOutput(outputSize)
    }
    output.count = outputSize
    return .success(output)
  }

  private func callStructureOutput(
    _ connect: io_connect_t,
    selector: UInt32,
    maximumBytes: Int
  ) throws -> Data {
    var output = Data(count: maximumBytes)
    var outputSize = maximumBytes
    let status = output.withUnsafeMutableBytes {
      IOConnectCallStructMethod(
        connect, selector, nil, 0, $0.baseAddress, &outputSize)
    }
    guard status == KERN_SUCCESS else {
      throw DriverBridgeError.callFailed(selector: selector, status: status)
    }
    guard outputSize >= 0, outputSize <= maximumBytes else {
      throw DriverBridgeError.malformedReply("selector \(selector) output overflow")
    }
    output.count = outputSize
    return output
  }

  private func callScalarInputStructureOutput(
    _ connect: io_connect_t,
    selector: UInt32,
    scalarInput: [UInt64],
    maximumBytes: Int
  ) throws -> Data {
    var output = Data(count: maximumBytes)
    var outputSize = maximumBytes
    var scalarOutputCount: UInt32 = 0
    let status = scalarInput.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBytes {
        IOConnectCallMethod(
          connect, selector, input.baseAddress, UInt32(input.count), nil, 0,
          nil, &scalarOutputCount, $0.baseAddress, &outputSize)
      }
    }
    guard status == KERN_SUCCESS else {
      throw DriverBridgeError.callFailed(selector: selector, status: status)
    }
    guard scalarOutputCount == 0, outputSize >= 0, outputSize <= maximumBytes else {
      throw DriverBridgeError.malformedReply("selector \(selector) output overflow")
    }
    output.count = outputSize
    return output
  }

  private func submit(
    _ connect: io_connect_t,
    request: Data,
    selector: UInt32
  ) -> (status: Int32, requestID: UInt64?) {
    var scalarOutput: UInt64 = 0
    var scalarOutputCount: UInt32 = 1
    var structureOutputSize = 0
    let status = request.withUnsafeBytes {
      IOConnectCallMethod(
        connect, selector, nil, 0, $0.baseAddress, request.count,
        &scalarOutput, &scalarOutputCount, nil, &structureOutputSize)
    }
    guard status == KERN_SUCCESS, scalarOutputCount == 1, scalarOutput != 0,
      structureOutputSize == 0
    else {
      return (status, nil)
    }
    return (status, scalarOutput)
  }

  private func pollResult(
    _ connect: io_connect_t,
    requestID: UInt64,
    operationID: UInt64,
    attemptID: UInt64,
    selector: UInt32,
    maximumBytes: Int
  ) -> (status: Int32, data: Data?) {
    let input = [requestID, operationID, attemptID]
    var output = Data(count: maximumBytes)
    var outputSize = maximumBytes
    var scalarOutputCount: UInt32 = 0
    let status = input.withUnsafeBufferPointer { inputPointer in
      output.withUnsafeMutableBytes {
        IOConnectCallMethod(
          connect, selector, inputPointer.baseAddress, UInt32(input.count), nil, 0,
          nil, &scalarOutputCount, $0.baseAddress, &outputSize)
      }
    }
    guard status == KERN_SUCCESS, scalarOutputCount == 0,
      outputSize >= 0, outputSize <= maximumBytes
    else { return (status, nil) }
    output.count = outputSize
    return (status, output)
  }

  private func uniqueIdentifier() -> UInt64 {
    while true {
      var generator = SystemRandomNumberGenerator()
      let candidate = UInt64.random(in: 1...UInt64.max, using: &generator)
      if issuedIdentifiers.insert(candidate).inserted { return candidate }
    }
  }

  private static func utcNow() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private static func ioReturnHex(_ status: Int32) -> String {
    String(format: "0x%08X", UInt32(bitPattern: status))
  }
}
