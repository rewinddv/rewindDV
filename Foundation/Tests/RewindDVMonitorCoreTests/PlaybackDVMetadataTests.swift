import Foundation
import Testing
import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func snapshot(_ ordinal: UInt64) throws -> DVPackSemanticReport {
  try JSONDecoder().decode(DVPackSemanticReport.self, from: Data("""
  {"schema_version":1,"frame_ordinal":\(ordinal),"frame_byte_offset":0,"frame_sha256":"synthetic scheduling oracle","format":"test","format_evidence":"synthetic only","packs":[],"missing_principal_packs":[]}
  """.utf8))
}
private actor HeldMetadataAnalyzer {
  var requests: [UInt64] = []
  var active = 0
  var maximum = 0
  var gate: CheckedContinuation<Void, Never>?
  func parse(_ ordinal: UInt64) async throws -> DVPackSemanticReport {
    requests.append(ordinal); active += 1; maximum = max(maximum, active)
    await withCheckedContinuation { gate = $0 }
    active -= 1
    return try snapshot(ordinal)
  }
  func release() { gate?.resume(); gate = nil }
}
@MainActor private func eventually(_ condition: () async -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
  #expect(await condition())
}

@Test @MainActor func playbackMetadataRejectsOldSeekAndFileAndKeepsOneWorker() async throws {
  let held = HeldMetadataAnalyzer()
  let sampler = PlaybackDVMetadata { _, ordinal, _ in try await held.parse(ordinal) }
  sampler.offer(Data(), ordinal: 1, paused: true, presentationConfirmed: true)
  try await eventually { await held.requests == [1] }
  for ordinal in 2...1000 { sampler.offer(Data(), ordinal: UInt64(ordinal), paused: true, presentationConfirmed: true) }
  #expect(sampler.maxPendingFrames == 1)
  sampler.reset() // different file/seek, same ordinal cannot accept old result
  sampler.offer(Data(), ordinal: 5000, paused: true, presentationConfirmed: true)
  await held.release()
  try await eventually { await held.requests == [1,5000] }
  #expect(sampler.report == nil)
  #expect(await held.maximum == 1)
  await held.release()
  try await eventually { sampler.report?.frameOrdinal == 5000 }
  #expect(sampler.sampledFrames == 1)
  sampler.reset()
  #expect(sampler.report == nil)
}

@Test @MainActor func playbackMetadataPlayingIsBoundedAndPauseConverges() async throws {
  let sampler = PlaybackDVMetadata { _, ordinal, _ in try snapshot(ordinal) }
  let began = ContinuousClock.now
  for ordinal in 0..<70 {
    sampler.offer(Data(), ordinal: UInt64(ordinal), paused: false)
    try await Task.sleep(for: .milliseconds(10))
  }
  let elapsed = ContinuousClock.now - began
  #expect(sampler.sampledFrames <= Int(elapsed.components.seconds) * 2 + 2)
  #expect(sampler.maxPendingFrames == 1)
  sampler.offer(Data(), ordinal: 999, paused: true, presentationConfirmed: true)
  try await eventually { sampler.report?.frameOrdinal == 999 }
  #expect(sampler.status.contains("displayed source frame"))
  sampler.reset()
}

@Test @MainActor func playbackMetadataFailureDoesNotRetainPriorFrameAsCurrent() async throws {
  let sampler = PlaybackDVMetadata { _, ordinal, _ in
    if ordinal == 2 { throw CocoaError(.fileReadCorruptFile) }
    return try snapshot(ordinal)
  }
  sampler.offer(Data(), ordinal: 1, paused: true, presentationConfirmed: true)
  try await eventually { sampler.report != nil }
  sampler.offer(Data(), ordinal: 2, paused: true, presentationConfirmed: true)
  try await eventually { sampler.sampledFrames == 2 }
  #expect(sampler.report == nil && sampler.status.hasPrefix("Unavailable"))
}

@Test @MainActor func queuedPausedMetadataRequiresRendererConfirmation() async throws {
  let sampler = PlaybackDVMetadata { _, ordinal, _ in try snapshot(ordinal) }
  sampler.offer(Data(), ordinal: 99, paused: true)
  try await Task.sleep(for: .milliseconds(30))
  #expect(sampler.report == nil && sampler.sampledFrames == 0)
  sampler.offer(Data(), ordinal: 7, paused: true, presentationConfirmed: true)
  try await eventually { sampler.report?.frameOrdinal == 7 }
  #expect(sampler.presentationStatus.contains("sampled 0s ago"))
  sampler.unavailable("Renderer failed")
  #expect(sampler.report == nil)
}

@Test func metadataSummaryRetainsHDVTransport() {
  let sections = [DVTechnicalSpecifications.Section(title: "HDV transport", rows: [
    .init(label: "Format", value: "HDV", evidence: "Synthetic transport observation")])]
  #expect(DVMetadataPresentation.summarySections(sections) == sections)
}

@Test @MainActor func unavailableRejectsFirstInFlightPresentation() async throws {
  let held = HeldMetadataAnalyzer()
  let sampler = PlaybackDVMetadata { _, ordinal, _ in try await held.parse(ordinal) }
  sampler.offer(Data(), ordinal: 1, paused: true, presentationConfirmed: true)
  try await eventually { await held.requests == [1] }
  sampler.unavailable("Renderer failed")
  await held.release()
  try await Task.sleep(for: .milliseconds(30))
  #expect(sampler.report == nil && sampler.status == "Renderer failed")
  sampler.offer(Data(), ordinal: 2, paused: true, presentationConfirmed: true,
    observedAt: ContinuousClock.now.advanced(by: .seconds(-5)))
  try await eventually { await held.requests == [1,2] }
  await held.release()
  try await eventually { sampler.report?.frameOrdinal == 2 }
  #expect(sampler.presentationStatus.contains("sampled 5s ago"))
}

@Test @MainActor func selectionOnlyMetadataNeverClaimsRendererConfirmationAndClockClears() async throws {
  let sampler = PlaybackDVMetadata { _, ordinal, _ in try snapshot(ordinal) }
  sampler.setRecordedClock(.init(label: "Recorded date & time", value: "Synthetic same-frame clock", evidence: "selected source only"), ordinal: 9)
  sampler.offer(Data(), ordinal: 9, paused: true, selectionConfirmed: true)
  try await eventually { sampler.report?.frameOrdinal == 9 }
  #expect(sampler.status.contains("selected source frame; renderer association unavailable"))
  #expect(!sampler.status.contains("displayed source frame"))
  #expect(sampler.recordedClockFrameOrdinal == 9)
  sampler.unavailable("Selection changed")
  #expect(sampler.recordedClock == nil && sampler.recordedClockFrameOrdinal == nil)
  sampler.setRecordedClock(.init(label: "Recorded date & time", value: "Another clock", evidence: "synthetic"), ordinal: 12)
  sampler.reset()
  #expect(sampler.recordedClock == nil)
}

@Test func sharedInspectorCaptionsPreserveEveryConfidenceAndState() {
  for confidence in DVMetadataConfidence.allCases {
    for state in ["interpreted", "uninterpreted", "unavailable", "invalid", "conflicting"] {
      let field = DVPackSemanticReport.Field(id: "raw", name: "Raw", rawValue: 513,
        meaning: "Observation", status: state, reference: "Synthetic", confidence: confidence)
      let caption = DVMetadataPresentation.fieldCaption(field)
      #expect(caption.contains(confidence.label) && caption.contains(state) && caption.contains("513"))
    }
  }
}

@Test func inspectorSourcePrefixesNeverInventPackIDsForFormatConstants() {
  #expect(DVMetadataPresentation.inspectorLabel("Standard", section: "Video") == "[DIF SYSTEM] — Standard")
  #expect(DVMetadataPresentation.inspectorLabel("Color space", section: "Video") == "[DV CODING] — Color space")
  #expect(DVMetadataPresentation.inspectorLabel("Recorded date & time", section: "General") == "[0x62 / 0x63] — Recorded date & time")
  #expect(DVMetadataPresentation.inspectorLabel("Sampling rate", section: "Audio 2") == "[0x50] — Sampling rate")
  #expect(DVMetadataPresentation.inspectorLabel("Tape-reported display aspect ratio", section: "Video") == "[0x61] — Tape-reported display aspect ratio")
  #expect(DVMetadataPresentation.inspectorLabel("File size", section: "General") == "[FILE] — File size")
  #expect(DVMetadataPresentation.inspectorLabel("Pixel aspect ratio (PAR / sample AR)", section: "Apple presentation geometry").hasPrefix("[APPLE]"))
}
