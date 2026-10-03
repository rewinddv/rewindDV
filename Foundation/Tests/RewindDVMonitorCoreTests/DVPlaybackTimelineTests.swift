import Foundation
import Testing
@testable import RewindDVMonitorCore

private func timelineFrame(pal: Bool) -> Data {
  var data = Data(repeating: 0xff, count: pal ? 144_000 : 120_000)
  for sequence in 0..<(pal ? 12 : 10) {
    var local = 0
    func block(_ section: Int, _ number: Int) {
      let at = sequence * 12_000 + local * 80
      data[at] = UInt8(section << 5) | 0x1f
      data[at + 1] = UInt8(sequence << 4) | 7; data[at + 2] = UInt8(number)
      if section == 0 { data[at + 3] = pal ? 0xbf : 0x3f }
      local += 1
    }
    block(0, 0)
    for i in 0..<2 { block(1, i) }
    for i in 0..<3 { block(2, i) }
    for i in 0..<9 { block(3, i); for j in 0..<15 { block(4, i * 15 + j) } }
  }
  return data
}
private func withTimelineFile(_ data: Data, _ body: (URL) throws -> Void) throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dv")
  try data.write(to: url, options: .withoutOverwriting)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url)
}

@Test func mixedDVTimelineKeepsExactOffsetsCadenceAndReverseSeeks() throws {
  let n = timelineFrame(pal: false), p = timelineFrame(pal: true)
  try withTimelineFile(n + n + p + p + p + n) { url in
    let t = try DVPlaybackTimeline.read(url: url)
    #expect(t.frameCount == 6 && t.runs.count == 3)
    #expect(t.durationTicks == 3 * 1001 + 3 * 1200)
    let ticks: [Int64] = [0, 1001, 2002, 3202, 4402, 5602]
    let offsets: [UInt64] = [0, 120000, 240000, 384000, 528000, 672000]
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    for i in [0, 1, 2, 5, 3, 4, 2, 1, 0] {
      #expect(t.frame(i).startTick == ticks[i])
      #expect(t.frame(i).byteOffset == offsets[i])
      #expect(t.frame(at: Double(ticks[i]) / 30000).ordinal == i)
      #expect(t.frame(at: Double(ticks[i] + (i < 2 || i == 5 ? 1000 : 1199)) / 30000).ordinal == i)
      #expect(try t.readFrame(i, from: handle) == (i >= 2 && i < 5 ? p : n))
    }
    #expect(t.frame(at: t.durationSeconds).ordinal == 5)
    #expect(t.frame(at: -.infinity).ordinal == 0)
    #expect(t.frame(at: -1).ordinal == 0)
    #expect(t.frame(at: .nan).ordinal == 0)
  }
}
@Test func uniformPALAndNTSCUseOneRun() throws {
  for pal in [false, true] {
    let frame = timelineFrame(pal: pal)
    try withTimelineFile(frame + frame) { url in
      let t = try DVPlaybackTimeline.read(url: url)
      #expect(t.runs.count == 1 && t.frameCount == 2)
      #expect(t.durationTicks == (pal ? 2400 : 2002))
    }
  }
}
@Test func playbackTimelineRejectsBrokenBoundariesAndIncompleteTails() throws {
  let frame = timelineFrame(pal: true)
  var broken = frame; broken[12_000 + 3] &= 0x7f
  var duplicate = frame; duplicate[7 * 80 + 2] = 1
  for data in [Data(), frame.dropLast(), frame + Data([0]), broken, duplicate, Data(repeating: 0x47, count: 144000)] {
    try withTimelineFile(Data(data)) { url in
      #expect(throws: DVPlaybackTimeline.Failure.self) { try DVPlaybackTimeline.read(url: url) }
    }
  }
}
@Test func playbackTimelineRejectsSourceChanges() throws {
  let frame = timelineFrame(pal: false)
  try withTimelineFile(frame) { url in
    let t = try DVPlaybackTimeline.read(url: url)
    try (frame + frame).write(to: url)
    #expect(throws: DVPlaybackTimeline.Failure.self) { try t.verifyUnchanged(url: url) }
  }
}

@Test func playbackFileFactsUseWholeMixedTimelineWithoutRewritingFirstFrameFacts() throws {
  try withTimelineFile(timelineFrame(pal: false) + timelineFrame(pal: true)) { url in
    let timeline = try DVPlaybackTimeline.read(url: url)
    let original = DVTechnicalSpecifications(sections: [
      .init(title: "General", rows: [.init(label: "Duration", value: "incorrect uniform estimate", evidence: "first frame"),
        .init(label: "Overall bit rate mode", value: "Constant", evidence: "first frame")]),
      .init(title: "Video", rows: [.init(label: "Standard", value: "NTSC", evidence: "first frame")]),
      .init(title: "Audio", rows: [.init(label: "Duration", value: "incorrect nominal span", evidence: "first frame"),
        .init(label: "Stream size", value: "incorrect extrapolation", evidence: "first frame")])], coverage: "synthetic")
    let report = original.playbackReport(sampledFrame: original, timeline: timeline)
    #expect(report.sections[0].rows.first?.value == "00:00:00.073")
    #expect(report.sections[0].rows[1].value == "Variable (NTSC / PAL)")
    #expect(report.sections[1].rows.first?.value == "NTSC")
    #expect(report.sections[2].rows.first?.value == "Nominal video span: 00:00:00.073")
    #expect(report.sections[2].rows[1].value == "Unavailable — mixed source systems")
    #expect(original.sections[0].rows.first?.value == "incorrect uniform estimate")
  }
}
