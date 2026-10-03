// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// One utility worker plus one replaceable pending frame. The renderer only
/// lends immutable source bytes; metadata never restarts or waits for playback.
@MainActor public final class PlaybackDVMetadata: ObservableObject {
  @Published public private(set) var report: DVPackSemanticReport?
  @Published public private(set) var recordedClock: DVTechnicalSpecifications.Row?
  public private(set) var recordedClockFrameOrdinal: UInt64?
  @Published public private(set) var status = "Waiting for displayed DV frame"
  public private(set) var sampledFrames = 0
  public private(set) var maxPendingFrames = 0
  private struct Request: Sendable {
    let bytes: Data
    let ordinal: UInt64
    let offset: UInt64?
    let generation: UUID
    let immediate: Bool
    let selectionOnly: Bool
    let observedAt: ContinuousClock.Instant
  }
  private var generation = UUID()
  private var latest: Request?
  private var worker: Task<Void, Never>?
  private var lastOrdinal: UInt64?
  private var sampledAt: ContinuousClock.Instant?
  public var presentationStatus: String {
    guard let sampledAt, report != nil else { return status }
    let seconds = max(0, (ContinuousClock.now - sampledAt).components.seconds)
    return status + " · sampled \(seconds)s ago"
  }
  private var lastStarted: ContinuousClock.Instant?
  private let analyze: @Sendable (Data, UInt64, UInt64?) async throws -> DVPackSemanticReport

  public init(analyze: @escaping @Sendable (Data, UInt64, UInt64?) async throws -> DVPackSemanticReport = { bytes, ordinal, offset in
    DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: bytes, ordinal: ordinal,
      byteOffset: offset ?? 0), absoluteOffsetsKnown: offset != nil)
  }) { self.analyze = analyze }

  /// Called for every file/seek generation before any frame is presented.
  public func reset() {
    generation = UUID(); latest = nil; lastOrdinal = nil
    report = nil; sampledAt = nil; status = "Waiting for displayed DV frame"
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
  public func offer(_ bytes: Data, ordinal: UInt64, byteOffset: UInt64? = nil, paused: Bool, presentationConfirmed: Bool = false, selectionConfirmed: Bool = false, observedAt: ContinuousClock.Instant = .now) {
    guard !paused || presentationConfirmed || selectionConfirmed else {
      unavailable("Waiting for renderer-confirmed paused frame")
      return
    }
    guard lastOrdinal != ordinal || latest != nil else { return }
    if latest?.ordinal == ordinal && latest?.generation == generation { return }
    latest = Request(bytes: bytes, ordinal: ordinal, offset: byteOffset, generation: generation, immediate: paused, selectionOnly: paused && !presentationConfirmed, observedAt: observedAt)
    maxPendingFrames = max(maxPendingFrames, 1)
    guard worker == nil else { return }
    worker = Task { [weak self] in await self?.drain() }
  }

  private func drain() async {
    defer { worker = nil }
    while latest != nil {
      if latest?.immediate == false, let started = lastStarted {
        let remaining = Duration.milliseconds(500) - (ContinuousClock.now - started)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
      }
      guard let request = latest else { return }
      latest = nil; lastStarted = .now
      let analyze = analyze
      let result = await Task.detached(priority: .utility) {
        do { return Result<DVPackSemanticReport, Error>.success(try await analyze(request.bytes, request.ordinal, request.offset)) }
        catch { return .failure(error) }
      }.value
      guard request.generation == generation else { continue }
      // In a paused scrub the newer frame supersedes an in-flight sample.
      if let pending = latest, pending.immediate && pending.ordinal != request.ordinal { continue }
      lastOrdinal = request.ordinal; sampledFrames += 1
      switch result {
      case .success(let value):
        report = value; sampledAt = request.observedAt
        status = "Frame \(request.ordinal) · " + (request.selectionOnly ? "selected source frame; renderer association unavailable" : request.immediate ? "displayed source frame" : "sampled playback clock; display association unverified")
      case .failure:
        report = nil; status = "Unavailable — displayed source frame failed metadata validation"
      }
    }
  }
}
