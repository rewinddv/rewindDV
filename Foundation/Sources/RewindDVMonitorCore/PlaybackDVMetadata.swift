// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// One utility worker plus one replaceable pending frame. The renderer only
/// lends immutable source bytes; metadata never restarts or waits for playback.
@MainActor public final class PlaybackDVMetadata: ObservableObject {
  public struct Snapshot: Sendable {
    public let report: DVPackSemanticReport
    public let specifications: DVTechnicalSpecifications?
    public let geometry: DVAppleGeometry?
  }
  @Published public private(set) var snapshot: Snapshot?
  public var report: DVPackSemanticReport? { snapshot?.report }
  public var specifications: DVTechnicalSpecifications? { snapshot?.specifications }
  public var geometry: DVAppleGeometry? { snapshot?.geometry }
  @Published public private(set) var recordedClock: DVTechnicalSpecifications.Row?
  public private(set) var recordedClockFrameOrdinal: UInt64?
  @Published public private(set) var status = "Waiting for displayed DV frame"
  @Published public private(set) var ordinalIsEstimated = false
  public private(set) var sampledFrames = 0
  public private(set) var maxPendingFrames = 0
  private struct Request: Sendable {
    let bytes: Data
    let ordinal: UInt64
    let offset: UInt64?
    let geometry: DVAppleGeometry?
    let generation: UUID
    let immediate: Bool
    let selectionOnly: Bool
    let ordinalIsEstimated: Bool
    let observedAt: ContinuousClock.Instant
  }
  private var generation = UUID()
  private var latest: Request?
  private var worker: Task<Void, Never>?
  private var delay: Task<Void, Never>?
  private var lastOrdinal: UInt64?
  private var sourceFrameSize: Int?
  private var sampledAt: ContinuousClock.Instant?
  public var presentationStatus: String {
    guard let sampledAt, report != nil else { return status }
    let seconds = max(0, (ContinuousClock.now - sampledAt).components.seconds)
    return status + " · sampled \(seconds)s ago"
  }
  private var lastStarted: ContinuousClock.Instant?
  private let analyze: @Sendable (Data, UInt64, UInt64?) async throws -> Snapshot

  public init(analyze: (@Sendable (Data, UInt64, UInt64?) async throws -> DVPackSemanticReport)? = nil) {
    if let analyze {
      self.analyze = { bytes, ordinal, offset in
        Snapshot(report: try await analyze(bytes, ordinal, offset), specifications: nil, geometry: nil)
      }
    } else {
      self.analyze = { bytes, ordinal, offset in
        let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: ordinal, byteOffset: offset ?? 0)
        let specs = DVTechnicalSpecifications.make(path: "", byteCount: UInt64(bytes.count),
          inventory: inventory, absoluteOffsetsKnown: offset != nil)
        guard let report = specs.semanticReport else { throw CocoaError(.fileReadCorruptFile) }
        return Snapshot(report: report, specifications: specs, geometry: nil)
      }
    }
  }

  /// Called for every file/seek generation before any frame is presented.
  public func reset() {
    delay?.cancel()
    generation = UUID(); latest = nil; lastOrdinal = nil; sourceFrameSize = nil
    snapshot = nil; sampledAt = nil; status = "Waiting for displayed DV frame"
    clearRecordedClock()
    // Do not clear worker: its old result will be rejected, then it drains the
    // new latest slot. Resetting cannot create overlapping utility parses.
  }

  /// Independent, lightweight frame-clock channel. Updating it cannot invalidate
  /// the workspace or rehost the video layer on every presentation tick.
  public func setRecordedClock(_ row: DVTechnicalSpecifications.Row, ordinal: UInt64) {
    if recordedClock != row { recordedClock = row }
    recordedClockFrameOrdinal = ordinal
  }
  public func clearRecordedClock() {
    if recordedClock != nil { recordedClock = nil }
    recordedClockFrameOrdinal = nil
  }

  public func unavailable(_ reason: String) {
    clearRecordedClock()
    if report != nil || latest != nil || lastOrdinal != nil || worker != nil { reset() }
    if status != reason { status = reason }
  }

  /// A paused offer is accepted only after the renderer confirms its pixel
  /// buffer. Playing samples are explicitly clock-associated, not display proof.
  public func offer(_ bytes: Data, ordinal: UInt64, byteOffset: UInt64? = nil, geometry: DVAppleGeometry? = nil, paused: Bool, presentationConfirmed: Bool = false, selectionConfirmed: Bool = false, ordinalIsEstimated: Bool = false, observedAt: ContinuousClock.Instant = .now) {
    guard !paused || presentationConfirmed || selectionConfirmed else {
      unavailable("Waiting for renderer-confirmed paused frame")
      return
    }
    if let sourceFrameSize, sourceFrameSize != bytes.count {
      // Reject an in-flight report from the preceding system immediately.
      // Preserve the one-worker bound while admitting this transition promptly.
      delay?.cancel()
      generation = UUID(); latest = nil; lastOrdinal = nil; lastStarted = nil
      snapshot = nil; sampledAt = nil; status = "Reading metadata for the new source format"
    }
    if paused { delay?.cancel() }
    sourceFrameSize = bytes.count
    guard lastOrdinal != ordinal || latest != nil else { return }
    if latest?.ordinal == ordinal && latest?.generation == generation { return }
    latest = Request(bytes: bytes, ordinal: ordinal, offset: byteOffset, geometry: geometry, generation: generation, immediate: paused, selectionOnly: paused && !presentationConfirmed, ordinalIsEstimated: ordinalIsEstimated, observedAt: observedAt)
    maxPendingFrames = max(maxPendingFrames, 1)
    guard worker == nil else { return }
    worker = Task { [weak self] in await self?.drain() }
  }

  private func drain() async {
    defer { worker = nil }
    while latest != nil {
      if latest?.immediate == false, let started = lastStarted {
        let remaining = Duration.milliseconds(500) - (ContinuousClock.now - started)
        if remaining > .zero {
          let wait = Task<Void, Never> { try? await Task.sleep(for: remaining) }
          delay = wait
          await wait.value
          delay = nil
        }
      }
      guard let request = latest else { return }
      latest = nil; lastStarted = .now
      let analyze = analyze
      let result = await Task.detached(priority: .utility) {
        do { return Result<Snapshot, Error>.success(try await analyze(request.bytes, request.ordinal, request.offset)) }
        catch { return .failure(error) }
      }.value
      guard request.generation == generation else { continue }
      // In a paused scrub the newer frame supersedes an in-flight sample.
      if let pending = latest, pending.immediate && pending.ordinal != request.ordinal { continue }
      lastOrdinal = request.ordinal; sampledFrames += 1
      switch result {
      case .success(let value):
        snapshot = Snapshot(report: value.report, specifications: value.specifications, geometry: request.geometry); sampledAt = request.observedAt
        if ordinalIsEstimated != request.ordinalIsEstimated { ordinalIsEstimated = request.ordinalIsEstimated }
        let position = request.ordinalIsEstimated ? "Source byte \(request.offset?.description ?? "unknown") · estimated frame \(request.ordinal)" : "Frame \(request.ordinal)"
        status = position + " · " + (request.selectionOnly ? "selected source frame; renderer association unavailable" : request.immediate ? "displayed source frame" : "sampled playback clock; display association unverified")
      case .failure:
        snapshot = nil; status = "Unavailable — displayed source frame failed metadata validation"
      }
    }
  }
}
