import Foundation

public struct ArchiveAdmissionLimits: Codable, Equatable, Sendable {
  public let maximumExtentBytes: Int
  public let maximumOutstandingExtents: Int
  public let maximumOutstandingBytes: Int

  public init(
    maximumExtentBytes: Int,
    maximumOutstandingExtents: Int,
    maximumOutstandingBytes: Int
  ) {
    precondition(maximumExtentBytes > 0)
    precondition(maximumOutstandingExtents > 0)
    precondition(maximumOutstandingBytes >= maximumExtentBytes)
    self.maximumExtentBytes = maximumExtentBytes
    self.maximumOutstandingExtents = maximumOutstandingExtents
    self.maximumOutstandingBytes = maximumOutstandingBytes
  }

  public static let conservativeTransport = ArchiveAdmissionLimits(
    maximumExtentBytes: 2_048,
    maximumOutstandingExtents: 1_024,
    maximumOutstandingBytes: 2 * 1_024 * 1_024)
}

public enum ArchiveAdmissionRejection: String, Codable, Equatable, Sendable {
  case emptyExtent = "empty_extent"
  case extentTooLarge = "extent_too_large"
  case extentCountCapacityExceeded = "extent_count_capacity_exceeded"
  case byteCapacityExceeded = "byte_capacity_exceeded"
}

public enum ArchiveAdmissionDecision: Equatable, Sendable {
  case admitted
  case rejected(ArchiveAdmissionRejection)

  /// Pure capacity accounting for a caller-owned, genuinely bounded transport.
  /// This is not a queue and does not claim that an actor mailbox is bounded.
  public static func evaluate(
    extentByteCount: Int,
    outstandingExtentCount: Int,
    outstandingByteCount: Int,
    limits: ArchiveAdmissionLimits
  ) -> ArchiveAdmissionDecision {
    guard extentByteCount > 0 else { return .rejected(.emptyExtent) }
    guard extentByteCount <= limits.maximumExtentBytes else {
      return .rejected(.extentTooLarge)
    }
    guard outstandingExtentCount >= 0,
      outstandingExtentCount < limits.maximumOutstandingExtents
    else {
      return .rejected(.extentCountCapacityExceeded)
    }
    guard outstandingByteCount >= 0,
      outstandingByteCount <= limits.maximumOutstandingBytes - extentByteCount
    else {
      return .rejected(.byteCapacityExceeded)
    }
    return .admitted
  }
}
