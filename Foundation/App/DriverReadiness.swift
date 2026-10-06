// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Local app ownership evidence. No device identity or filesystem paths.
struct AppOperationObservation: Codable, Equatable, Sendable {
  var id = UUID()
  let category: String
  var startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  var stage = "preparing"
}

struct ReceiveStartDiagnostic: Codable, Equatable, Sendable {
  var id = UUID()
  var startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  var completedUptimeNanoseconds: UInt64?
  var blockers: [String] = []
  var owners: [AppOperationObservation] = []
  var connectionCreated = false
  var flightCreationAttempted = false
  var flightCreated = false
  var receiveSubmitted = false
  var acquiredOwnership = false
  var existingStopObligation: Bool?
  var json: String {
    (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
  }
}

/// Every begin failure identifies whether THIS attempt owns receive cleanup.
/// Rejection must never close an existing session or consume its final counters.
struct ReceiveStartFailure: LocalizedError {
  let reason: String
  let diagnostic: ReceiveStartDiagnostic
  let flightURL: URL?
  var errorDescription: String? { reason }
}

/// Diagnostic sampling only: retain a state change and its next observation.
/// Never authorizes transport, determines readiness, or changes polling cadence.
struct ReceiveTransportDiagnosticSampler {
  private var lastResponse: [UInt8]?
  private var consecutive = 0

  mutating func shouldRecord(_ response: [UInt8]?) -> Bool {
    if consecutive == 0 || response != lastResponse {
      lastResponse = response
      consecutive = 1
      return true
    }
    if consecutive == 1 {
      consecutive = 2
      return true
    }
    return false
  }
}

// Describe only the last status actually observed. A later failed status read
// must not erase earlier proof that local DMA stopped, or invent resource release.
enum ReceiveCleanupEvidence {
  static func failureMessage(lastObservedState: UInt32?, cause: String) -> String {
    if lastObservedState == 6 {
      return "Local receive DMA stopped, but deck connection/resource cleanup could not be confirmed. Control remains locked; reopening the app will not clear a driver lockout. Cause: \(cause)"
    }
    return "Receive shutdown could not be confirmed. Control remains locked; use physical STOP if the tape is moving. Cause: \(cause)"
  }
}

/// One bounded read-only handshake per observed full route. Failed attempts do
/// not become five-second retry loops. Only reconnection/reset or an explicit
/// diagnostic action authorizes another batch.
struct DeviceHandshakeGate: Sendable {
  private(set) var currentRoute: FoundationRoute?
  private var attemptedRoute: FoundationRoute?

  mutating func observe(_ route: FoundationRoute?) {
    if currentRoute != route { attemptedRoute = nil }
    currentRoute = route
  }

  mutating func beginIfNeeded(_ route: FoundationRoute?, eligible: Bool) -> Bool {
    observe(route)
    guard eligible, let route, attemptedRoute != route else { return false }
    attemptedRoute = route
    return true
  }

  func accepts(_ route: FoundationRoute, selected: FoundationRoute?) -> Bool {
    currentRoute == route && selected == route && attemptedRoute == route
  }

  func needsAttempt(_ route: FoundationRoute?) -> Bool {
    guard let route else { return false }
    return currentRoute != route || attemptedRoute != route
  }
}

/// UI scheduling only; the bridge independently enforces exclusive ownership.
enum DriverRefreshPolicy {
  // Fast attachment detection without repeatedly invalidating the workspace.
  // These are local read-only checks, not AV/C inquiry or transport retries.
  static func intervalMilliseconds(hasAttachedDriver: Bool) -> Int {
    hasAttachedDriver ? 1_000 : 250
  }
  static func mayCheck(sceneActive: Bool, modelBusy: Bool, activationInFlight: Bool,
    receiveActive: Bool, lockedOut: Bool, stopOutstanding: Bool) -> Bool {
    sceneActive && !modelBusy && !activationInFlight && !receiveActive && !lockedOut && !stopOutstanding
  }
}

struct DriverReadinessPresentation: Equatable, Sendable {
  let capabilityFlags: UInt32
  let decks: [DiscoveredDeck]
  let routes: [FoundationRoute]
  let discoveryNote: String
}

/// Assesses only services whose bundle/server identity and PCI provider already
/// passed the exact identity gate. Installed/activated is not attached/ready.
enum DriverBuildAssessment: Equatable, Sendable {
  case absent
  case differentBuilds([UInt64?])
  case exact
  case ambiguous(Int)

  static func assess(_ attached: [UInt64?], required: UInt64) -> Self {
    let exactCount = attached.filter { $0 == required }.count
    if exactCount > 1 { return .ambiguous(exactCount) }
    if exactCount == 1 { return .exact }
    return attached.isEmpty ? .absent : .differentBuilds(attached)
  }

  static func mismatchMessage(_ attached: [UInt64?], required: UInt64) -> String {
    let values = attached.map { $0.map { "Build\($0)" } ?? "an unidentified build" }.joined(separator: ", ")
    return "\(values) is still attached to the FireWire controller; this app requires Build\(required). Refresh only checks readiness—it does not activate or replace a driver. If activation was already accepted, the replacement has not attached yet; macOS may require a restart to finish it. Do not uninstall or repeatedly activate the driver."
  }
}

// App build and required driver build are independent identities. Missing or
// malformed signed metadata never broadens the exact driver admission gate.
struct DriverBuildRequirement: Equatable, Sendable {
  let build: UInt64

  init?(metadata: String?) {
    guard let metadata, !metadata.isEmpty,
      metadata.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
      let value = UInt64(metadata), value > 0, value <= UInt64(UInt32.max),
      String(value) == metadata else { return nil }
    build = value
  }

  static let bundled = DriverBuildRequirement(
    metadata: Bundle.main.object(forInfoDictionaryKey: "RewindDVRequiredDriverBuild") as? String)
  static var display: String { bundled.map { "Driver B\($0.build)" } ?? "Driver identity unavailable" }

  func permitsReplacement(bundleVersion: String) -> Bool {
    DriverBuildRequirement(metadata: bundleVersion)?.build == build
  }
}
