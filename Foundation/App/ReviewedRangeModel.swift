// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import Combine

/// Offline file ownership only. This model has no driver or transport reference.
@MainActor final class ReviewedRangeModel: ObservableObject {
  @Published private(set) var source: URL?
  @Published private(set) var snapshot: DVReviewedRangeExporter.Snapshot?
  @Published private(set) var isBusy = false
  @Published private(set) var message = "Prepare this file for frame-range review. The original is never changed."
  @Published private(set) var failed = false
  @Published private(set) var exportedDirectory: URL?
  @Published var firstFrameText = "1" { didSet { if oldValue != firstFrameText { confirmed = false } } }
  @Published var lastFrameText = "1" { didSet { if oldValue != lastFrameText { confirmed = false } } }
  @Published var confirmed = false
  @Published var isEditingFields = false
  private var generation = UUID()
  private var task: Task<Void, Never>?

  var range: (first: UInt64, end: UInt64)? {
    guard let snapshot, let first = UInt64(firstFrameText), let last = UInt64(lastFrameText),
      first >= 1, first <= last, last <= snapshot.frameCount else { return nil }
    return (first - 1, last)
  }
  var canExport: Bool { snapshot != nil && range != nil && confirmed && !isBusy }
  var frameDuration: Double { snapshot?.frameByteCount == 144_000 ? 1.0 / 25 : 1001.0 / 30000 }

  func cancel() {
    guard isBusy else { return }
    task?.cancel()
    message = "Cancelling… Any incomplete export evidence will be retained."
  }

  func reset() {
    task?.cancel(); task = nil; generation = UUID()
    source = nil; snapshot = nil; exportedDirectory = nil; isBusy = false
    confirmed = false; failed = false; isEditingFields = false
    message = "Prepare this file for frame-range review. The original is never changed."
  }

  func prepare(_ url: URL) {
    reset(); source = url; isBusy = true
    message = "Checking every DV frame and calculating source identity…"
    let id = generation, lease = ReviewedFileLease(url)
    task = Task { [weak self] in
      let scan = Task.detached(priority: .utility) {
        defer { withExtendedLifetime(lease) {} }
        return try DVReviewedRangeExporter.inspect(source: url)
      }
      do {
        let value = try await withTaskCancellationHandler { try await scan.value }
          onCancel: { scan.cancel() }
        try Task.checkCancellation()
        guard let self, generation == id else { return }
        snapshot = value; firstFrameText = "1"; lastFrameText = String(value.frameCount)
        isBusy = false
        message = "\(value.frameCount.formatted()) complete source frames. Choose the first and last frames to keep."
      } catch {
        guard let self, generation == id else { return }
        isBusy = false; failed = true; message = error.localizedDescription
      }
    }
  }

  func export(toParent parent: URL) {
    guard canExport, let source, let snapshot, let range else { return }
    let id = generation
    let destination = parent.appendingPathComponent("RewindDV-Reviewed-\(UUID().uuidString)", isDirectory: true)
    let sourceLease = ReviewedFileLease(source), destinationLease = ReviewedFileLease(parent)
    isBusy = true; failed = false; exportedDirectory = nil
    message = "Exporting selected frame bytes and verifying the source and output…"
    task = Task { [weak self] in
      let operation = Task.detached(priority: .utility) {
        defer { withExtendedLifetime((sourceLease, destinationLease)) {} }
        return try DVReviewedRangeExporter.export(source: source, snapshot: snapshot,
          first: range.first, endExclusive: range.end, destination: destination)
      }
      do {
        _ = try await withTaskCancellationHandler { try await operation.value }
          onCancel: { operation.cancel() }
        guard let self, generation == id else { return }
        isBusy = false; exportedDirectory = destination; confirmed = false
        message = "Verified export complete: \((range.end - range.first).formatted()) frames. Original unchanged; provenance records all omitted frames."
      } catch {
        guard let self, generation == id else { return }
        isBusy = false; failed = true
        message = "Export not completed: \(error.localizedDescription). Any partial evidence is retained at \(destination.path)."
      }
    }
  }
}

private final class ReviewedFileLease: @unchecked Sendable {
  private let url: URL
  private let active: Bool
  init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
  deinit { if active { url.stopAccessingSecurityScopedResource() } }
}
