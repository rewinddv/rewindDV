// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Lightweight presentation facts from an already complete, ordered DV25 frame.
/// No full-file manifest/hash construction belongs on the receive hot path.
public struct LiveDVMedia: Sendable {
  public let isPAL: Bool
  public let timecode: String?
  public let widescreen: Bool?
  public let audio: Audio?

  public struct Audio: Equatable, Sendable {
    public let sampleRate: Int
    public let nonlinear: Bool
    public let samplesPerChannel: Int
    public var channelCount: Int { nonlinear ? 4 : 2 }
  }

  public init?(frame: Data) {
    guard frame.count == 120_000 || frame.count == 144_000,
      frame[0] >> 5 == 0, frame[1] >> 4 == 0, frame[2] == 0,
      (frame[3] & 0x80 != 0) == (frame.count == 144_000) else { return nil }
    isPAL = frame.count == 144_000
    let sequences = isPAL ? 12 : 10
    var tc: [[UInt8]] = []
    var aspects = Set<Bool>()
    var invalidAspect = false
    var audioFacts: [Audio] = []
    var invalidAudio = false
    frame.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      for seq in 0..<sequences {
        let base = seq * 12000
        for block in 1...2 {
          for slot in stride(from: 6, through: 46, by: 8) {
            let at = base + block * 80 + slot
            if p[at] == 0x13 { tc.append(Array(p[at..<(at + 5)])) }
          }
        }
        for block in 3...5 {
          for slot in stride(from: 3, through: 73, by: 5) {
            let at = base + block * 80 + slot
            if p[at] == 0x61 {
              let flag = p[at + 2] & 7
              let applications = (4...7).map { p[base + $0] & 7 }
              let consumer = applications.allSatisfy { $0 == 0 }
              let professional = applications.allSatisfy { $0 == 1 }
              if (consumer || professional), p[base + 6] & 128 == 0,
                let value = DVPackSemanticReport.displayWidescreen(code: flag, consumer: consumer) {
                aspects.insert(value)
              } else { invalidAspect = true }
            }
          }
        }
        for block in 0..<9 {
          let at = base + (6 + block * 16) * 80 + 3
          guard p[at] == 0x50 else { continue }
          let rate = Int((p[at + 4] >> 3) & 7)
          let quant = p[at + 4] & 7
          let type = p[at + 3] & 31
          // DV25 only; unsupported quantization is not guessed.
          guard (4...7).allSatisfy({ p[base + $0] & 7 == 0 }),
            rate < 3, quant <= 1, type == 0,
            quant == 0 || rate == 2,
            p[at + 4] & 0x80 != 0 else { // AAUX EF=1: emphasis off; no guessed deemphasis
            invalidAudio = true; continue
          }
          let minimum = (sequences == 12 ? [1896, 1742, 1264] : [1580, 1452, 1053])[rate]
          audioFacts.append(Audio(sampleRate: [48000, 44100, 32000][rate],
            nonlinear: quant == 1, samplesPerChannel: minimum + Int(p[at + 1] & 63)))
        }
      }
    }
    timecode = MonitorSourceTimecode.display(packs: tc, isPAL: isPAL)
    widescreen = !invalidAspect && aspects.count == 1 ? aspects.first : nil
    audio = !invalidAudio && !audioFacts.isEmpty && audioFacts.allSatisfy({ $0 == audioFacts[0] })
      ? audioFacts.first : nil
  }

  /// RewindDV Swift implementation of DV25 sample placement. Behavioral checks:
  /// FFmpeg libavformat/dv.c (AAUX/sample decoding) and libavcodec/dv_profile.c
  /// (525/625 sample geometry), accessed 2026-09-13. No external runtime or code
  /// tables are embedded. Output is monitor PCM, never a replacement raw capture.
  public func pcm16(frame: Data) -> [Int16]? {
    guard let audio, frame.count == (isPAL ? 144_000 : 120_000) else { return nil }
    let sequences = isPAL ? 12 : 10, half = sequences / 2
    var result = [Int16](repeating: 0, count: audio.samplesPerChannel * audio.channelCount)
    var seen = [Bool](repeating: false, count: result.count)
    var invalid = false
    frame.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      func put(_ code: Int, sample: Int, channel: Int) {
        guard sample < audio.samplesPerChannel else { return } // unused audio capacity
        let index = sample * audio.channelCount + channel
        guard !seen[index], code != (audio.nonlinear ? 0x800 : 0x8000) else {
          invalid = true; return
        }
        seen[index] = true
        result[index] = audio.nonlinear ? Self.expand12(code) : Int16(bitPattern: UInt16(code))
      }
      for seq in 0..<sequences {
        for block in 0..<9 {
          let at = seq * 12000 + (6 + block * 16) * 80 + 8
          let phase = ((seq % half) * 6 + (block / 3) * (half * 6 - 10)) % (half * 6)
          let base = phase + (block % 3) * half * 6
          if audio.nonlinear {
            for word in 0..<24 {
              let source = at + word * 3
              let sample = (base + word * sequences * 9) / 2
              put(Int(p[source]) * 16 + Int(p[source + 2] >> 4), sample: sample, channel: (seq / half) * 2)
              put(Int(p[source + 1]) * 16 + Int(p[source + 2] & 15), sample: sample, channel: (seq / half) * 2 + 1)
            }
          } else {
            for word in 0..<36 {
              put(Int(p[at + word * 2]) * 256 + Int(p[at + word * 2 + 1]),
                sample: (base + word * sequences * 9) / 2, channel: seq / half)
            }
          }
        }
      }
    }
    return !invalid && seen.allSatisfy({ $0 }) ? result : nil
  }

  private static func expand12(_ value: Int) -> Int16 {
    let negative = value & 0x800 != 0
    let magnitude = negative ? 0xfff - value : value
    let band = magnitude >> 8
    let shift = max(0, band - 1)
    let expanded = (magnitude - shift * 256) * (1 << shift)
    return Int16(negative ? -expanded - 1 : expanded)
  }
}

public enum LiveDisplayAspect: String, CaseIterable, Identifiable, Sendable {
  case source = "Tape flags"
  case standard = "4:3"
  case anamorphic = "16:9 anamorphic"
  public var id: Self { self }
  public func ratio(widescreen: Bool?) -> Double {
    self == .anamorphic || (self == .source && widescreen == true) ? 16.0 / 9.0 : 4.0 / 3.0
  }
}
