import Foundation

/// Capture continues until the operator or the producing transport explicitly ends it.
/// There is deliberately no elapsed-time stop policy.
public enum CapturePolicy: String, Codable, Equatable, Sendable {
  case operatorControlledContinuous = "operator_controlled_continuous"

  public var automaticStopAfterNanoseconds: UInt64? { nil }
}

public enum DriverState: String, Codable, Equatable, Sendable {
  case unknown
  case unavailable
  /// Exact service/capabilities connected; controller health is not yet proven.
  case connected
  case ready
  case disconnected
  case failed
}

public enum DeckState: String, Codable, Equatable, Sendable {
  case unknown
  case stopped
  case playing
  case paused
  case disconnected
}

public enum IntakeState: String, Codable, Equatable, Sendable {
  case disabled
  case ready
  case accepting
  case stopped
  case rejected
}

public enum ArchiveState: String, Codable, Equatable, Sendable {
  case notCreated = "not_created"
  case incomplete
  case finalizing
  case finalized
  case failed
}

public struct CaptureFailure: Codable, Equatable, Sendable {
  public let phase: String
  public let message: String

  public init(phase: String, message: String) {
    self.phase = phase
    self.message = message
  }
}

/// A presentation-safe snapshot. Unknown states remain unknown; byte verification
/// never promotes driver, deck, intake, or acquisition state.
public struct CaptureStatus: Codable, Equatable, Sendable {
  public var driver: DriverState
  public var deck: DeckState
  public var intake: IntakeState
  public var archive: ArchiveState
  public var firstError: CaptureFailure?
  public var cleanupErrors: [CaptureFailure]

  public init(
    driver: DriverState = .unknown,
    deck: DeckState = .unknown,
    intake: IntakeState = .disabled,
    archive: ArchiveState = .notCreated,
    firstError: CaptureFailure? = nil,
    cleanupErrors: [CaptureFailure] = []
  ) {
    self.driver = driver
    self.deck = deck
    self.intake = intake
    self.archive = archive
    self.firstError = firstError
    self.cleanupErrors = cleanupErrors
  }
}
