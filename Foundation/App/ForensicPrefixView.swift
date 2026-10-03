// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

@MainActor final class ForensicPrefixModel: ObservableObject {
  @Published private(set) var busy = false
  @Published private(set) var message = "Recover a recorded durable prefix from an interrupted raw flight. Never a clean or whole-tape completion."
  @Published private(set) var fraction = 0.0
  @Published private(set) var output: URL?
  @Published private(set) var receipt: DVForensicPrefix.Receipt?
  private var task: Task<Void, Never>?
  private var id = UUID()
  func cancel() { task?.cancel() }
  func recover(source: URL, parent: URL) {
    guard !busy else { return }
    let grants = [source, parent].filter { $0.startAccessingSecurityScopedResource() }
    let destination = parent.appendingPathComponent("Incomplete-prefix-\(UUID().uuidString)")
    busy = true; output = nil; receipt = nil; fraction = 0; id = UUID()
    let operation = id
    message = "Checking original flight and durable-prefix evidence…"
    task = Task {
      defer { busy = false; task = nil; for url in grants { url.stopAccessingSecurityScopedResource() } }
      let updates = AsyncStream<(String, UInt64, UInt64)>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let worker = Task.detached(priority: .utility) {
        defer { updates.continuation.finish() }
        return try DVForensicPrefix.export(source: source, destination: destination) { stage, done, total in
          updates.continuation.yield((stage, done, total))
        }
      }
      do {
        let result = try await withTaskCancellationHandler {
          for await (stage, done, total) in updates.stream where id == operation {
            message = stage; fraction = Double(done) / Double(max(1, total))
          }
          return try await worker.value
        } onCancel: { worker.cancel() }
        receipt = result; output = destination; fraction = 1
        message = "INCOMPLETE ACQUISITION — verified prefix recovered. \(result.completeFrames) complete frames; \(result.unverifiedTailBytes) trailing bytes excluded as unverified. This does not establish a complete capture or pristine tape content."
      } catch {
        message = "Recovery incomplete: \(error.localizedDescription). Original flight unchanged. Any partial destination is not a completed recovery."
        if FileManager.default.fileExists(atPath: destination.path) { output = destination }
      }
    }
  }
}

struct ForensicPrefixView: View {
  @ObservedObject var model: ForensicPrefixModel
  let available: Bool
  @State private var stopped = false
  var body: some View {
    ArchiveSection("Interrupted-flight recovery") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Separate forensic export: original raw flight, checkpoint journal and byte provenance remain intact. Unverified tail bytes are not silently recovered or discarded from the original.").font(.caption)
        Toggle("The flight has ended; capture and monitoring are idle", isOn: $stopped).disabled(model.busy)
        HStack {
          Button("Recover verified prefix…") { choose() }
            .disabled(!available || !stopped || model.busy)
            .accessibilityIdentifier("forensic-prefix-recover")
          if model.busy { Button("Cancel recovery") { model.cancel() } }
          if let output = model.output { Button("Show recovery evidence") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
        }
        if model.busy { ProgressView(value: model.fraction) }
        Text(model.message).foregroundStyle(.orange).textSelection(.enabled)
          .accessibilityIdentifier("forensic-prefix-status")
        if let receipt = model.receipt {
          Text("Known dropped packets: \(receipt.knownDroppedPackets) · continuity events: \(receipt.continuityEvents) · incomplete frames: \(receipt.incompleteFrames). Counts cover this prefix only.").font(.caption)
        }
      }
    }
  }
  private func choose() {
    guard available, stopped, !model.busy else { return }
    let source = NSOpenPanel(); source.canChooseFiles = false; source.canChooseDirectories = true; source.allowsMultipleSelection = false
    source.message = "Choose the ended flight folder containing receive.records.raw and flight.ndjson."
    guard source.runModal() == .OK, let original = source.url else { return }
    let target = NSOpenPanel(); target.canChooseFiles = false; target.canChooseDirectories = true; target.canCreateDirectories = true; target.allowsMultipleSelection = false
    target.message = "Choose a destination outside the original flight. A new, uniquely named recovery folder will be created."
    guard target.runModal() == .OK, let parent = target.url else { return }
    model.recover(source: original, parent: parent)
  }
}
