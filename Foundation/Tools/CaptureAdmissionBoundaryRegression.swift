// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// OFFLINE ONLY. The runner inserts the entire production beginLiveReceive body.
// Local shims replace every connection, filesystem flight and IOKit submission.
import Foundation
import OSLog
let KERN_SUCCESS: Int32 = 0
struct OfflineConnection: Sendable { let failSubmission: Bool; let malformed: Bool }
struct OpenDriverConnection: Sendable { let connect: OfflineConnection }
func IOConnectCallStructMethod(_ connection: OfflineConnection, _ selector: Int,
  _ input: UnsafeRawPointer?, _ inputSize: Int, _ output: UnsafeMutableRawPointer?,
  _ size: UnsafeMutablePointer<Int>) -> Int32 {
  precondition(selector == 68)
  if connection.failSubmission { return -1 }
  var bytes = Data()
  for value: UInt64 in [UInt64(24) << 32 | 1, connection.malformed ? 0 : 1, 1] {
    var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
  }
  bytes.withUnsafeBytes { output!.copyMemory(from: $0.baseAddress!, byteCount: 24) }
  size.pointee = 24
  return 0
}
final class LiveReceiveFlight: @unchecked Sendable {
  let directory = URL(fileURLWithPath: "/offline-flight-no-files")
  init(route: Data, destinationParent: URL?, captureFolderKind: CaptureDirectory.Kind) throws {
    if destinationParent?.lastPathComponent == "fail-flight" { throw ControlWireError.invalid("fixture flight failure") }
  }
  func event(_ event: String, data: Data, message: String) -> Bool { true }
}
actor AlphaSessionRecorder {
  static let shared = AlphaSessionRecorder()
  func recordReceiveAdmission(_ observation: ReceiveStartDiagnostic) {}
}
enum DriverBridgeError: Error, LocalizedError {
  case permanentSessionLockout, commandAlreadyInFlight, deckNotFresh
  case callFailed(selector: Int, status: Int32), malformedReply(String)
  var errorDescription: String? { String(describing: self) }
}
actor DriverBridge {
  static let readinessLog = Logger(subsystem: "net.rewinddigital.offline", category: "AdmissionBoundary")
  static let capabilitiesSelector: UInt32 = 64, routeSelector: UInt32 = 67
  var mode = "idle", connectionOpens = 0
  var routeData: Data
  init(route: Data) { routeData = route }
  var commandInFlight = false, inspectionInFlight = false, permanentlyLockedOut = false
  var commandOwner: AppOperationObservation?, inspectionOwner: AppOperationObservation?, receiveOwner: AppOperationObservation?
  var liveConnection: OpenDriverConnection?, liveFlight: LiveReceiveFlight?
  var liveTransportDiagnostics = ReceiveTransportDiagnosticSampler()
  var liveRoute: FoundationRoute?, liveEpoch: UInt64?
  var liveStopIssued = false
  var liveAssembler = DVPreviewPacketAssembler(), liveMediaFormats = ReceiveMediaFormatEvidence()
  var liveLastMediaFormat: ReceiveMediaFormatEvidence.Format?
  var liveOrdinal: UInt64 = 0, liveObservedSequence: UInt64 = 0, liveKnownLoss: UInt64 = 0
  var liveAcknowledgementUncertain = false, livePersistenceUncertain = false, liveWriterPressure = false
  var liveJournalState: UInt32?, liveJournalDate = Date.distantPast
  var liveDurableThrough: UInt64 = 0, liveAcknowledgedThrough: UInt64 = 0, liveCopiedThrough: UInt64 = 0
  var finalLiveStatistics: Int? = 37
  func configure(mask: Int = 0, mode: String = "idle") {
    self.mode = mode
    permanentlyLockedOut = mask & 1 != 0; commandInFlight = mask & 2 != 0; inspectionInFlight = mask & 4 != 0
    liveConnection = mask & 8 != 0 ? .init(connect: .init(failSubmission: false, malformed: false)) : nil
    commandOwner = commandInFlight ? .init(category: "transport_PLAY") : nil
    inspectionOwner = inspectionInFlight ? .init(category: "passive_transport") : nil
    receiveOwner = liveConnection != nil ? .init(category: "receive") : nil
  }
  func openExactBuild183Connection() throws -> OpenDriverConnection {
    connectionOpens += 1
    if mode == "open" { throw ControlWireError.invalid("fixture connection failure") }
    return .init(connect: .init(failSubmission: mode == "submit", malformed: mode == "malformed"))
  }
  func callStructureOutput(_ connection: OfflineConnection, selector: UInt32, maximumBytes: Int) throws -> Data {
    if mode == "capabilities" { throw ControlWireError.invalid("fixture capabilities failure") }
    var bytes = Data()
    for v: UInt32 in [1, 24, 0x3ff, 7, 1, 4] {
      var x = v.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
    }
    return bytes
  }
  func callScalarInputStructureOutput(_ connection: OfflineConnection, selector: UInt32,
    scalarInput: [UInt64], maximumBytes: Int) throws -> Data { routeData }
  // PRODUCTION_BEGIN_RECEIVE
}
@main struct AdmissionBoundaryRegression {
  static func main() async throws {
    var bytes = Data()
    func put<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) } }
    put(UInt32(1)); put(UInt32(48)); for _ in 0..<4 { put(UInt64(1)) }
    put(UInt32(1)); put(UInt16(1)); put(UInt16(0))
    let route = try FoundationRoute(data: bytes)
    let deck = DiscoveredDeck(guid: 1, generation: 1, node: 1, state: 1, vendor: "Synthetic", model: "Offline")
    for mask in 1..<16 {
      let bridge = DriverBridge(route: bytes); await bridge.configure(mask: mask)
      do { _ = try await bridge.beginLiveReceive(deck); preconditionFailure("conflict admitted") }
      catch let failure as ReceiveStartFailure {
        let expected = [(1,"permanentlyLockedOut"),(2,"commandInFlight"),(4,"inspectionInFlight"),(8,"liveConnection")]
          .filter { mask & $0.0 != 0 }.map { $0.1 }
        precondition(Set(failure.diagnostic.blockers) == Set(expected))
        precondition(!failure.diagnostic.connectionCreated && !failure.diagnostic.flightCreationAttempted)
        precondition(!failure.diagnostic.acquiredOwnership && !failure.diagnostic.receiveSubmitted && failure.flightURL == nil)
        let opens = await bridge.connectionOpens, final = await bridge.finalLiveStatistics
        precondition(opens == 0 && final == 37, "Rejected start disturbed another session's statistics")
        let decoded = try JSONDecoder().decode(ReceiveStartDiagnostic.self, from: Data(failure.diagnostic.json.utf8))
        precondition(decoded == failure.diagnostic && decoded.completedUptimeNanoseconds! >= decoded.startedUptimeNanoseconds)
      }
    }
    print("PASS: production boundary retains every blocker and immutable owner/timing evidence; no connection/flight/submission/statistics mutation")
    for mode in ["open", "capabilities", "flight", "submit", "malformed", "idle"] {
      let bridge = DriverBridge(route: bytes); await bridge.configure(mode: mode)
      do {
        _ = try await bridge.beginLiveReceive(deck,
          destinationParent: URL(fileURLWithPath: mode == "flight" ? "/fail-flight" : "/offline"), expectedRoute: route,
          existingStopObligation: true)
        precondition(mode == "idle")
      } catch let failure as ReceiveStartFailure {
        let d = failure.diagnostic
        precondition(d.existingStopObligation == true && d.blockers.isEmpty)
        precondition(d.connectionCreated == (mode != "open"))
        precondition(d.flightCreationAttempted == !["open","capabilities"].contains(mode))
        precondition(d.acquiredOwnership == ["submit","malformed"].contains(mode))
        precondition(d.receiveSubmitted == d.acquiredOwnership && d.flightCreated == d.acquiredOwnership)
        precondition((failure.flightURL != nil) == d.acquiredOwnership)
      }
    }
    print("PASS: actual begin body distinguishes open, capability, flight, submission, malformed-result and accepted phases; no real I/O")
  }
}
