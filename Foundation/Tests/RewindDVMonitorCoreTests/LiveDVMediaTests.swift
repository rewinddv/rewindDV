import Foundation
import Testing
import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func mediaFixture(pal: Bool = false, rate: Int = 0, nonlinear: Bool = false) -> Data {
  let sequences = pal ? 12 : 10
  var frame = Data(repeating: 0, count: sequences * 12000)
  for sequence in 0..<sequences {
    let base = sequence * 12000
    frame[base] = 0x1f; frame[base + 1] = UInt8(sequence << 4) | 7
    frame[base + 3] = pal ? 0xbf : 0x3f
    for field in 4...7 { frame[base + field] = 0x78 }
    let pack = base + 6 * 80 + 3
    frame[pack] = 0x50
    frame[pack + 1] = 15 // actual count = minimum + 15
    frame[pack + 3] = pal ? 0xe0 : 0xc0
    frame[pack + 4] = 0xc0 | UInt8(rate << 3) | (nonlinear ? 1 : 0)
  }
  return frame
}

@Test(arguments: [false, true]) func livePCM16KeepsSourceRateAndChannelOrder(pal: Bool) throws {
  for rate in 0...2 {
    var frame = mediaFixture(pal: pal, rate: rate)
    let sequences = pal ? 12 : 10
    for seq in 0..<sequences {
      for block in 0..<9 {
        for word in 0..<36 {
          let at = seq * 12000 + (6 + block * 16) * 80 + 8 + word * 2
          let value: UInt16 = seq < sequences / 2 ? 1234 : UInt16(bitPattern: -2345)
          frame[at] = UInt8(value >> 8); frame[at + 1] = UInt8(value & 255)
        }
      }
    }
    let media = try #require(LiveDVMedia(frame: frame))
    #expect(media.audio?.sampleRate == [48000, 44100, 32000][rate])
    let pcm = try #require(media.pcm16(frame: frame))
    #expect(pcm.count == media.audio!.samplesPerChannel * 2)
    #expect(stride(from: 0, to: pcm.count, by: 2).allSatisfy { pcm[$0] == 1234 && pcm[$0 + 1] == -2345 })
  }
}

@Test(arguments: [false, true]) func liveNonlinear32kHasFourDistinctChannels(pal: Bool) throws {
  var frame = mediaFixture(pal: pal, rate: 2, nonlinear: true)
  let sequences = pal ? 12 : 10
  for seq in 0..<sequences {
    for block in 0..<9 {
      for word in 0..<24 {
        let at = seq * 12000 + (6 + block * 16) * 80 + 8 + word * 3
        // Codes 0x100/0xeff expand to 256/-257; 0x700/0x8ff to 16384/-16385.
        let first: UInt16 = seq < sequences / 2 ? 0x100 : 0x700
        let second: UInt16 = seq < sequences / 2 ? 0xeff : 0x8ff
        frame[at] = UInt8(first >> 4); frame[at + 1] = UInt8(second >> 4)
        frame[at + 2] = UInt8((first & 15) << 4 | (second & 15))
      }
    }
  }
  let media = try #require(LiveDVMedia(frame: frame))
  #expect(media.audio?.sampleRate == 32000)
  #expect(media.audio?.channelCount == 4)
  let pcm = try #require(media.pcm16(frame: frame))
  #expect(stride(from: 0, to: pcm.count, by: 4).allSatisfy {
    Array(pcm[$0..<$0 + 4]) == [256, -257, 16384, -16385]
  })
}

@Test func livePCMShuffleHasKnownIndependentPositions() throws {
  var frame = mediaFixture()
  // First word of selected audio DIF blocks. Independent NTSC placement facts:
  // (seq0,block1)->sample15,left; (seq2,block3)->sample1,left;
  // (seq9,block8)->sample32,right.
  for (seq, block, value) in [(0, 1, 101), (2, 3, 202), (9, 8, 303)] {
    let at = seq * 12000 + (6 + block * 16) * 80 + 8
    frame[at] = UInt8(value >> 8); frame[at + 1] = UInt8(value & 255)
  }
  let media = try #require(LiveDVMedia(frame: frame))
  let pcm = try #require(media.pcm16(frame: frame))
  #expect(pcm[30] == 101); #expect(pcm[2] == 202); #expect(pcm[65] == 303)
}

@Test func liveUnknownConflictingAndErrorAudioDoesNotBorrowRate() throws {
  var frame = mediaFixture()
  let secondPack = 12000 + 6 * 80 + 3
  frame[secondPack + 4] = 0xd0 // 32k conflicts with this frame's other 48k packs
  #expect(LiveDVMedia(frame: frame)?.audio == nil)
  frame = mediaFixture()
  frame[6 * 80 + 8] = 0x80 // invalid sample sentinel, not fabricated zero
  #expect(LiveDVMedia(frame: frame)?.pcm16(frame: frame) == nil)
  frame = mediaFixture()
  frame[6 * 80 + 7] &= 0x7f // emphasis on: unsupported rather than wrong sound
  #expect(LiveDVMedia(frame: frame)?.audio == nil)
  #expect(LiveDVMedia(frame: Data(repeating: 0, count: 119999)) == nil)
  #expect(LiveDVMedia(frame: mediaFixture(rate: 2))?.audio?.sampleRate == 32000)
  #expect(LiveDVMedia(frame: mediaFixture())?.audio?.sampleRate == 48000)
}

@Test func liveAspectIsExplicitAndNeverRewritesFrame() throws {
  var frame = mediaFixture()
  #expect(LiveDVMedia(frame: frame)?.widescreen == nil)
  frame[3 * 80 + 3] = 0x61; frame[3 * 80 + 5] = 2
  #expect(LiveDVMedia(frame: frame)?.widescreen == true)
  frame[3 * 80 + 5] = 1
  let original = frame
  #expect(LiveDVMedia(frame: frame)?.widescreen == false)
  #expect(frame == original)
  #expect(DVPackSemanticReport.displayWidescreen(code: 1, consumer: false) == nil)
  frame[3 * 80 + 5] = 7
  #expect(LiveDVMedia(frame: frame)?.widescreen == nil)
  frame[3 * 80 + 5] = 2
  frame[4 * 80 + 3] = 0x61; frame[4 * 80 + 5] = 0
  #expect(LiveDVMedia(frame: frame)?.widescreen == nil)
  #expect(LiveDisplayAspect.source.ratio(widescreen: nil) == 4.0 / 3.0)
  #expect(LiveDisplayAspect.anamorphic.ratio(widescreen: false) == 16.0 / 9.0)
  #expect(LiveDisplayAspect.standard.ratio(widescreen: true) == 4.0 / 3.0)
}
