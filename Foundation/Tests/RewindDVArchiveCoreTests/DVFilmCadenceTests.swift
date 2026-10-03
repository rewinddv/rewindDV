import Foundation
import Testing
@testable import RewindDVArchiveCore

private let filmHash = String(repeating: "a", count: 64)

@Test func filmMappingsRecoverOriginalProgressivePicturesFromBothPulldowns() throws {
  // Independent input oracle transcribed as picture labels from Panasonic's
  // progressive-mode diagrams, not generated from the implementation map.
  for (mode, tape) in [(DVFilmMode.ntsc24p, ["AA", "BB", "BC", "CD", "DD"]),
                       (.ntsc24pa, ["AA", "BB", "BC", "CC", "DD"])] {
    for origin in UInt64(0)...4 {
      let plan = try DVFilmPlan(mode: mode, firstSourceFrame: origin, sourceFrameCount: 10, sourceSHA256: filmHash)
      for ordinal in UInt64(0)..<8 {
        let p = try plan.picture(ordinal)
        let a = Array(tape[Int((p.firstFieldSourceFrame - origin) % 5)])[0]
        let b = Array(tape[Int((p.secondFieldSourceFrame - origin) % 5)])[1]
        #expect(a == b)
        #expect(a == Array("ABCD")[Int(ordinal % 4)])
        #expect(p.presentationTicks == Int64(ordinal) * 5005)
      }
      #expect(plan.durationTicks == 10 * 4004)
      #expect(plan.outputFrameCount == 8)
    }
  }
}

@Test func filmPALAndNTSCProgressiveHaveNoFrameRemovalOrTimingConform() throws {
  for mode in [DVFilmMode.pal25p, .ntsc30p, .pal50i, .ntsc60i] {
    let p = try DVFilmPlan(mode: mode, firstSourceFrame: 13, sourceFrameCount: 7, sourceSHA256: filmHash)
    #expect(p.outputFrameCount == 7)
    #expect(p.durationTicks == (mode.isPAL ? 33600 : 28028))
    for i in UInt64(0)..<7 {
      #expect(try p.picture(i).firstFieldSourceFrame == 13 + i)
      #expect(try p.picture(i).secondFieldSourceFrame == 13 + i)
    }
  }
}

@Test func filmInvalidRangesAndForgedPlanCannotProduceMappings() throws {
  for count in [UInt64(0), 1, 4, 6, UInt64.max] {
    #expect(throws: (any Error).self) { try DVFilmPlan(mode: .ntsc24pa, firstSourceFrame: 0, sourceFrameCount: count, sourceSHA256: filmHash) }
  }
  #expect(throws: (any Error).self) { try DVFilmPlan(mode: .pal25p, firstSourceFrame: UInt64.max, sourceFrameCount: 10, sourceSHA256: filmHash) }
  let plan = try DVFilmPlan(mode: .ntsc24p, firstSourceFrame: 0, sourceFrameCount: 5, sourceSHA256: filmHash)
  #expect(throws: (any Error).self) { try plan.picture(4) }
  let bytes = try JSONEncoder().encode(plan)
  var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  object["outputFrameCount"] = 100
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(DVFilmPlan.self, from: JSONSerialization.data(withJSONObject: object))
  }
  #expect(try JSONDecoder().decode(DVFilmPlan.self, from: bytes) == plan)
}

private func filmEvidence(_ n: UInt64, sf: UInt8? = 0, il: UInt8? = 1, pal: Bool = false,
                          tc: Int? = nil, recordingStart: UInt8? = 1, damage: Int = 0) -> DVFilmFrameEvidence {
  DVFilmFrameEvidence(ordinal: n, byteOffset: n * (pal ? 144000 : 120000), isPAL: pal,
    format: "IEC 61834 consumer DV", videoControlHex: ["61 3F 81 FC FF"], videoControlOffsets: [n * 120000 + 248],
    frameField: 1, fieldOrder: 1, frameChange: 1, interlace: il, fieldTimeDifference: sf,
    recordingStart: recordingStart, timecodeFrame: tc ?? Int(n), timecodeDropFrame: false,
    audioRateHz: 48000, audioQuantizationCode: 0, videoStatusBlocks: damage)
}

@Test func filmObserverRequiresThreeCompleteCyclesAndFindsEveryPhase() {
  for (mode, pattern) in [(DVFilmMode.ntsc24p, [0, 0, 1, 1, 0]), (.ntsc24pa, [0, 0, 1, 0, 0])] {
    for phase in 0..<5 {
      var observer = DVFilmCadenceObserver()
      for n in 0..<30 {
        let o = observer.observe(filmEvidence(UInt64(n), sf: UInt8(pattern[(n + phase) % 5])))
        #expect(o.candidate == (n < 14 ? nil : mode))
        if let origin = o.candidateAFrame { #expect((Int(origin) + phase) % 5 == 0) }
      }
    }
  }
}

@Test func filmObserverDoesNotCallOrdinaryInterlace24POrTreatPALAs24PA() {
  var ntsc = DVFilmCadenceObserver(), pal = DVFilmCadenceObserver(), progressive = DVFilmCadenceObserver()
  for n in UInt64(0)..<30 {
    #expect(ntsc.observe(filmEvidence(n, sf: 1)).candidate == nil)
    #expect(pal.observe(filmEvidence(n, sf: [0, 0, 1, 0, 0][Int(n % 5)], pal: true)).candidate == nil)
    let p = progressive.observe(filmEvidence(n, sf: 0, il: 0, pal: true))
    #expect(p.candidate == (n < 14 ? nil : .pal25p))
  }
}

@Test func filmObserverLosesLockAtGapRecordingBreakDamageAndUnknownEvidence() {
  for reason in 0..<5 {
    var observer = DVFilmCadenceObserver()
    for n in UInt64(0)..<15 { _ = observer.observe(filmEvidence(n, il: 0)) }
    let bad: DVFilmFrameEvidence
    switch reason {
    case 0: bad = filmEvidence(16, il: 0)
    case 1: bad = filmEvidence(15, il: 0, tc: 90)
    case 2: bad = filmEvidence(15, il: 0, recordingStart: 0)
    case 3: bad = filmEvidence(15, il: 0, damage: 1)
    default: bad = filmEvidence(15, il: nil)
    }
    let o = observer.observe(bad)
    #expect(o.candidate == nil)
    #expect(!o.boundaryReasons.isEmpty)
  }
}

@Test func filmPlanLongDurationUsesExactRationalClock() throws {
  let p = try DVFilmPlan(mode: .ntsc24pa, firstSourceFrame: 0, sourceFrameCount: 300000, sourceSHA256: filmHash)
  #expect(p.outputFrameCount == 240000)
  #expect(p.durationTicks == 1_201_200_000)
  #expect(try p.picture(239999).presentationTicks + 5005 == p.durationTicks)
}

@Test func filmExtractsFormatSpecificEvidenceWithoutBorrowingSMPTEBits() throws {
  for pal in [false, true] {
    for sf in UInt8(0)...1 {
      let raw = semanticFrame(pal: pal, videoControl: [0x61, 0x3f, 0x80, 0xf0 | sf << 3, 0xff])
      let inventory = try DVMetadataInventory.inspect(frame: raw, ordinal: 3, byteOffset: 4321)
      let evidence = DVFilmFrameEvidence.inspect(inventory)
      #expect(evidence.isPAL == pal)
      #expect(evidence.fieldTimeDifference == sf)
      #expect(evidence.frameField == 1 && evidence.fieldOrder == 1)
      #expect(evidence.interlace == 1 && evidence.videoStatusBlocks == 0)
      #expect(!evidence.videoControlOffsets.isEmpty)
      for offset in evidence.videoControlOffsets {
        #expect(raw[Int(offset - 4321)] == 0x61)
      }
    }
    let smpte = try DVMetadataInventory.inspect(frame: semanticFrame(smpte: true, pal: pal), ordinal: 0, byteOffset: 0)
    #expect(DVFilmFrameEvidence.inspect(smpte).fieldTimeDifference == nil)
  }
}

@Test func filmConflictingVideoPacksAreNotAveragedOrSilentlyChosen() throws {
  var frame = semanticFrame(videoControl: [0x61, 0x3f, 0x80, 0xf0, 0xff])
  // One sequence disagrees on SF; keep every copy as evidence.
  frame[3 * 80 + 11] = 0xf8
  let evidence = DVFilmFrameEvidence.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 0, byteOffset: 0))
  #expect(evidence.fieldTimeDifference == nil)
  #expect(Set(evidence.videoControlHex).count == 2)
}

@Test func filmFileScanHashesOriginalBytesAndRejectsPartialFrames() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("fixture.dv")
  let frame = semanticFrame(pal: true, videoControl: [0x61, 0x3f, 0x80, 0xe0, 0xff])
  var bytes = Data()
  for _ in 0..<20 { bytes.append(frame) }
  try bytes.write(to: url)
  let report = try DVFilmScan.scan(url: url)
  #expect(report.frameCount == 20 && report.sourceBytes == 2_880_000)
  #expect(report.systems == ["625/50 PAL"])
  #expect(report.segments.last?.candidate == .pal25p)
  #expect(try Data(contentsOf: url) == bytes)
  #expect(report.sourceSHA256.count == 64)
  try bytes.dropLast().write(to: url)
  #expect(throws: (any Error).self) { try DVFilmScan.scan(url: url) }
}

@Test func filmTimecodeRequiresValidBCDSystemAndConsensus() throws {
  func inspect(_ pack: [UInt8], pal: Bool = false, conflict: Bool = false, invalidTF: Bool = false) throws -> DVFilmFrameEvidence {
    var frame = semanticFrame(pal: pal)
    frame.replaceSubrange(86..<91, with: pack)
    if conflict { frame.replaceSubrange(94..<99, with: [0x13, 0x05, 0, 0, 0]) }
    if invalidTF { frame[7] |= 0x80 }
    return DVFilmFrameEvidence.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 0, byteOffset: 0))
  }
  #expect(try inspect([0x13, 0x04, 0, 0, 0]).timecodeFrame == 4)
  #expect(try inspect([0x13, 0x04, 0, 0, 0], conflict: true).timecodeFrame == nil)
  #expect(try inspect([0x13, 0x04, 0, 0, 0], invalidTF: true).timecodeFrame == nil)
  #expect(try inspect([0x13, 0x1a, 0, 0, 0]).timecodeFrame == nil)
  #expect(try inspect([0x13, 0x25, 0, 0, 0], pal: true).timecodeFrame == nil)
  #expect(try inspect([0x13, 0x40, 0, 1, 0]).timecodeFrame == nil) // skipped DF label
  #expect(try inspect([0x13, 0x42, 0, 1, 0]).timecodeFrame == 1800)
  #expect(try inspect([0x13, 0x42, 0, 1, 0], pal: true).timecodeFrame == nil)
}

@Test func filmDisplayAspectRoundTripsWithoutChangingTimingOrFieldMap() throws {
  for mode in [DVFilmMode.pal25p, .ntsc24pa] {
    for aspect in DVFilmDisplayAspect.allCases {
      let plan = try DVFilmPlan(mode: mode, firstSourceFrame: 10, sourceFrameCount: 20,
        sourceSHA256: filmHash, displayAspect: aspect)
      #expect(try JSONDecoder().decode(DVFilmPlan.self, from: JSONEncoder().encode(plan)) == plan)
      #expect(plan.displayAspect == aspect)
      #expect(try plan.picture(0).firstFieldSourceFrame == 10)
    }
  }
}
