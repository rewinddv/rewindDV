import Testing
import Foundation

@testable import RewindDVMonitorCore

private func nativeTimecodeFrame(pal: Bool) -> Data {
  var frame = Data(repeating: 0xff, count: pal ? 144_000 : 120_000)
  for sequence in 0..<(pal ? 12 : 10) {
    var block = 0
    for (section, count) in [1, 2, 3, 9, 135].enumerated() {
      for number in 0..<count {
        let offset = (sequence * 150 + block) * 80
        frame[offset] = UInt8(section << 5)
        frame[offset + 1] = UInt8(sequence << 4)
        frame[offset + 2] = UInt8(number)
        if section == 1 {
          frame.replaceSubrange((offset + 6)..<(offset + 11), with: [0x13, 0x12, 0x34, 0x23, 0x01])
        }
        block += 1
      }
    }
  }
  return frame
}

@Test func playbackTimecodeValidatesCompleteNTSCAndPALFrames() {
  for pal in [false, true] {
    let frame = nativeTimecodeFrame(pal: pal)
    #expect(MonitorSourceTimecode.display(nativeDVFrame: frame) == "01:23:34:12")
    #expect(MonitorSourceTimecode.display(nativeDVFrame: frame.dropLast()) == nil)
    var corrupted = frame
    corrupted[0] = 0x80 // Missing initial header.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[80] = 0 // Extra frame start instead of subcode.
    corrupted[81] = 0
    corrupted[82] = 0
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[80] = 0xe0 // Out-of-range section.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[81] = 0xf0 // Out-of-range sequence.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[80] = 0x80 // Wrong section count, still in-range.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[80 + 7] = 0x13 // Valid but conflicting TC.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    corrupted[80 + 7] = 0x1a // Invalid BCD.
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
    corrupted = frame
    for sequence in 0..<(pal ? 12 : 10) {
      for subcode in 1...2 { corrupted[(sequence * 150 + subcode) * 80 + 6] = 0xff }
    }
    #expect(MonitorSourceTimecode.display(nativeDVFrame: corrupted) == nil)
  }
}

@Test func sourceTimecodeRequiresValidConsistentPacks() {
  let p: [UInt8] = [0x13, 0x12, 0x34, 0x23, 0x01]
  #expect(MonitorSourceTimecode.display(packs: [p, p], isPAL: false) == "01:23:34:12")
  #expect(MonitorSourceTimecode.display(packs: [], isPAL: false) == nil)
  #expect(MonitorSourceTimecode.display(packs: [[0x13]], isPAL: false) == nil)
  #expect(
    MonitorSourceTimecode.display(packs: [p, [0x13, 0x13, 0x34, 0x23, 0x01]], isPAL: false) == nil)
  #expect(
    MonitorSourceTimecode.display(packs: [[0x13, 0x1a, 0x34, 0x23, 0x01]], isPAL: false) == nil)
  #expect(MonitorSourceTimecode.display(packs: [[0x13, 0x29, 0, 0, 0]], isPAL: true) == nil)
}

@Test func dropFrameTimecodeRejectsOmittedLabels() {
  #expect(MonitorSourceTimecode.display(packs: [[0x13, 0x40, 0, 0x01, 0]], isPAL: false) == nil)
  #expect(
    MonitorSourceTimecode.display(packs: [[0x13, 0x42, 0, 0x01, 0]], isPAL: false) == "00:01:00;02")
  #expect(
    MonitorSourceTimecode.display(packs: [[0x13, 0x40, 0, 0x10, 0]], isPAL: false) == "00:10:00;00")
  #expect(
    MonitorSourceTimecode.display(packs: [[0x13, 0x29, 0x59, 0x59, 0x23]], isPAL: false)
      == "23:59:59:29")
}
