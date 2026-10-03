// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

struct ReviewedRangeView: View {
  @ObservedObject var review: ReviewedRangeModel
  @ObservedObject var playback: OfflineDVPlaybackModel
  @FocusState private var editingFields: Bool

  private var alignedPlayback: Bool {
    guard let snapshot = review.snapshot, review.source == playback.sourceURL,
      snapshot.frameCount <= UInt64(Int32.max), playback.durationSeconds.isFinite else { return false }
    return abs(playback.durationSeconds - Double(snapshot.frameCount) * review.frameDuration) < review.frameDuration * 0.51
  }
  private var canMark: Bool {
    guard alignedPlayback, playback.state == .paused, let snapshot = review.snapshot,
      playback.currentFrameOrdinal >= 0, UInt64(playback.currentFrameOrdinal) < snapshot.frameCount,
      let decodedTime = playback.latestEnqueuedVideoTimeSeconds else { return false }
    return abs(decodedTime - Double(playback.currentFrameOrdinal) * review.frameDuration) < 0.000_001
  }

  var body: some View {
    RewindDVSection {
      VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 10) {
        Text(review.message).font(.callout).foregroundStyle(review.failed ? .orange : .secondary)
          .textSelection(.enabled)
        if review.isBusy { ProgressView().controlSize(.small) }
        if let snapshot = review.snapshot {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text("First frame · included").font(.caption)
              HStack {
                TextField("First frame", text: $review.firstFrameText).frame(width: 110)
                  .focused($editingFields).accessibilityIdentifier("review-first-frame")
                Button("Set first here") { review.firstFrameText = String(playback.currentFrameOrdinal + 1) }
                  .disabled(!canMark).accessibilityIdentifier("review-mark-first")
              }
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Last frame · included").font(.caption)
              HStack {
                TextField("Last frame", text: $review.lastFrameText).frame(width: 110)
                  .focused($editingFields).accessibilityIdentifier("review-last-frame")
                Button("Set last here") { review.lastFrameText = String(playback.currentFrameOrdinal + 1) }
                  .disabled(!canMark).accessibilityIdentifier("review-mark-last")
              }
            }
          }.textFieldStyle(.roundedBorder)
          Text("Frames are numbered from 1; the last frame is included. Pause or step to a frame before setting a boundary.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Show first frame") { if let range = review.range { playback.seek(to: Double(range.first) * review.frameDuration) } }
              .disabled(review.range == nil || !alignedPlayback)
              .accessibilityIdentifier("review-show-first")
            Button("Show last frame") { if let range = review.range { playback.seek(to: Double(range.end - 1) * review.frameDuration) } }
              .disabled(review.range == nil || !alignedPlayback)
              .accessibilityIdentifier("review-show-last")
            Button("Use entire file") { review.firstFrameText = "1"; review.lastFrameText = String(snapshot.frameCount) }
          }
          if let range = review.range {
            Text("Keep \((range.end - range.first).formatted()) frames · omit \(range.first.formatted()) at start and \((snapshot.frameCount - range.end).formatted()) at end")
              .font(.caption.monospacedDigit())
          } else {
            Text("Enter a valid range from 1 through \(snapshot.frameCount.formatted()).").foregroundStyle(.orange)
          }
          if !alignedPlayback {
            Text("Playback timing does not match the verified raw frame count. Playhead shortcuts are unavailable; numeric range export remains explicit.")
              .font(.caption).foregroundStyle(.orange)
          }
          Toggle("I reviewed this range and approve the listed omissions", isOn: $review.confirmed)
            .toggleStyle(.checkbox).disabled(review.range == nil)
            .accessibilityIdentifier("review-confirm-range")
          Button("Export reviewed range…", systemImage: "square.and.arrow.up") { chooseDestination() }
            .disabled(!review.canExport).accessibilityIdentifier("review-export")
        } else if !review.isBusy {
          Button("Prepare range review", systemImage: "scissors") {
            if let source = playback.sourceURL { playback.pause(); review.prepare(source) }
          }.disabled(playback.sourceURL == nil || playback.isLoading)
            .accessibilityIdentifier("review-prepare")
        }
        if let output = review.exportedDirectory {
          Button("Show verified export", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([output])
          }
        }
        Text("Creates a separate reviewed DV copy and provenance record. No re-encoding, audio resampling, timecode rewriting or automatic blank-frame removal. The full original remains authoritative; export does not repair source damage or loss.")
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        .disabled(review.isBusy)
        if review.isBusy {
          Button("Cancel file operation") { review.cancel() }
            .accessibilityIdentifier("review-cancel")
        }
      }
    } label: { Label("Reviewed export", systemImage: "scissors") }
      .onChange(of: editingFields) { _, value in review.isEditingFields = value }
      .onDisappear { review.isEditingFields = false }
  }

  private func chooseDestination() {
    guard review.canExport else { return }
    playback.pause()
    let panel = NSOpenPanel()
    panel.title = "Choose reviewed export destination"
    panel.message = "Creates a new uniquely named folder containing reviewed-range.dv and provenance.json. Existing files and the original are never replaced."
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let parent = panel.url, review.canExport else { return }
    review.export(toParent: parent)
  }
}
