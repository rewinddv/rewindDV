// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Presentation-only side channel. Offer is an O(1) retained Data snapshot,
/// not a parse, copy, file read or awaited operation on the receive path.
/// One latest slot, one worker, at most two refreshes/s. No driver dependency.
@MainActor public final class LiveDVMetadata: ObservableObject {
  @Published public private(set) var report: DVTechnicalSpecifications?
  @Published public private(set) var status = "Waiting for complete DV frames"
  @Published public private(set) var rawFileBytes: UInt64?
  @Published public private(set) var isStale = true
  public private(set) var sampledFrames: UInt64 = 0
  public private(set) var parseFailures: UInt64 = 0
  public var diagnostics: String {
    "metadata_sampled_frames=\(sampledFrames); metadata_parse_failures=\(parseFailures); metadata_stale=\(staleNow); metadata_scope=sampled_preview_only"
  }
  private var latest: (Data, UInt64, ContinuousClock.Instant)?
  private var sampledAt: ContinuousClock.Instant?
  private var sampledOrdinal: UInt64?
  private var rawURL: URL?
  private var epoch = UUID()
  private var active = false
  private var refreshing = false
  private var timer: Task<Void, Never>?
  private var lastValidRecordedDate: DVTechnicalSpecifications.Row?
  private var latestParseFailed = false

  public init() {}

  // UI clock can age a snapshot even if a slow volume is delaying a background
  // filesystem size observation. Never keep calling old metadata "Live".
  public var staleNow: Bool {
    isStale || (active && sampledAt.map { ContinuousClock.now - $0 > .seconds(2) } == true)
  }
  public var presentationStatus: String {
    active && !latestParseFailed && report != nil && staleNow ? "Stale — no newly sampled DV frame for over 2 seconds" : status
  }

  public func begin(rawURL: URL? = nil, automatic: Bool = true) {
    timer?.cancel(); epoch = UUID(); active = true
    latest = nil; sampledAt = nil; sampledOrdinal = nil
    report = nil; rawFileBytes = nil; isStale = true
    lastValidRecordedDate = nil
    latestParseFailed = false
    sampledFrames = 0; parseFailures = 0
    status = "Waiting for complete DV frames"
    self.rawURL = rawURL
    let id = epoch
    if automatic {
      timer = Task { [weak self] in
        while !Task.isCancelled {
          guard let self, self.epoch == id, self.active else { return }
          await self.refresh()
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
      }
    }
  }

  public func setRawURL(_ url: URL?) { rawURL = url }

  public func offer(_ bytes: Data, ordinal: UInt64) {
    guard active else { return }
    latest = (bytes, ordinal, .now)
  }

  public func end() {
    active = false; epoch = UUID(); timer?.cancel(); timer = nil; latest = nil
    isStale = true
    status = report == nil ? "Stopped — no decoded metadata" : "Stopped — last observed metadata (not current)"
  }

  public func refresh(now: ContinuousClock.Instant = .now) async {
    guard active, !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let id = epoch, frame = latest, url = rawURL
    let needsParse = frame?.1 != sampledOrdinal
    // Utility priority and bounded work; no wait is introduced in capture.
    let result = await Task.detached(priority: .utility) {
      var report: DVTechnicalSpecifications?
      var failed = false
      if needsParse, let frame {
        do {
          let inventory = try DVMetadataInventory.inspect(frame: frame.0, ordinal: frame.1, byteOffset: 0)
          report = DVTechnicalSpecifications.make(path: "Incoming DV", byteCount: UInt64(frame.0.count), inventory: inventory, absoluteOffsetsKnown: false)
        } catch { failed = true }
      }
      // Do not use URL's cached resource values for a growing raw file.
      let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
      return (report, failed, size?.uint64Value)
    }.value
    guard epoch == id, active else { return }
    if rawFileBytes != result.2 { rawFileBytes = result.2 }
    if needsParse, let frame {
      sampledFrames &+= 1
      if result.1 { parseFailures &+= 1 }
      latestParseFailed = result.1
      sampledOrdinal = frame.1
      sampledAt = frame.2
      var nextReport = result.0
      if result.1, let previous = lastValidRecordedDate {
        // Preserve only the historical clock, not the old video/audio specs
        // presented as if they belonged to an unparseable current frame.
        nextReport = DVTechnicalSpecifications(sections: [.init(title: "General", rows: [
          .init(label: "Recorded date & time", value: "Last valid: \(previous.value) — latest frame invalid",
            evidence: previous.evidence + " Latest frame \(frame.1) failed structural validation; this is historical, not current.")
        ])], coverage: "Latest sampled frame failed structural validation. Other current metadata is unavailable.")
      }
      if let valid = nextReport?.validRecordedDate {
        lastValidRecordedDate = valid
      } else if !result.1, let previous = lastValidRecordedDate, let current = nextReport?.recordedDateRow {
        nextReport = nextReport?.replacingRecordedDate(.init(label: "Recorded date & time",
          value: "Last valid: \(previous.value) — latest frame: \(current.value)",
          evidence: previous.evidence + " Retained observation, not current metadata. Latest sample: " + current.evidence))
      }
      if report != nextReport { report = nextReport }
    }
    let stale = latestParseFailed || (sampledAt.map { now - $0 > .seconds(2) } ?? true)
    let next: String
    if latestParseFailed || (sampledOrdinal != nil && report == nil) {
      next = "Unavailable — latest sampled frame metadata could not be validated"
    } else if report == nil { next = "Waiting for complete DV frames" }
    else if stale { next = "Stale — no newly sampled DV frame for over 2 seconds" }
    else { next = "Live — sampled incoming DV metadata" }
    if isStale != stale { isStale = stale }
    if status != next { status = next }
  }
}
