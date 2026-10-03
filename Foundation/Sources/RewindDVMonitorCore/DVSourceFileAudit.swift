// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Constant-memory, cancellable, read-only source audit. Decoded/concealed PCM
/// is never substituted for the counts declared in qualified AAUX source packs.
public struct DVSourceFileAudit: Sendable, Equatable {
  public struct Channel: Sendable, Equatable {
    public let index: Int
    public var samples: UInt64 = 0
    public var assessedFrames: UInt64 = 0
    public var sampleRate: Int
    public var nonlinear: Bool
    public var formatChanged = false
  }
  public private(set) var frames: UInt64 = 0
  public private(set) var videoSeconds = 0.0
  public private(set) var videoStatusBlocks: UInt64 = 0
  public private(set) var audioErrorSamples: UInt64 = 0
  public private(set) var assessedAudioHalves: UInt64 = 0
  public private(set) var channels: [Channel] = []
  public private(set) var incompleteBytes: Int = 0

  public init() {}
  public mutating func append(_ frame: DVFrameForensics) {
    frames += 1
    videoSeconds += frame.blocks.count == 1800 ? 1 / 25 : 1001 / 30_000
    videoStatusBlocks += UInt64(frame.summary.videoStatusBySequence.reduce(0, +))
    audioErrorSamples += UInt64(frame.audioErrors.count)
    assessedAudioHalves += UInt64(Set(frame.audioChannels.map { $0.nonlinear ? $0.channel / 2 : $0.channel }).count)
    for observed in frame.audioChannels {
      if let index = channels.firstIndex(where: { $0.index == observed.channel }) {
        channels[index].formatChanged = channels[index].formatChanged || channels[index].sampleRate != observed.sampleRate || channels[index].nonlinear != observed.nonlinear
        channels[index].samples += UInt64(observed.sampleCount)
        channels[index].assessedFrames += 1
      } else {
        channels.append(Channel(index: observed.channel, samples: UInt64(observed.sampleCount), assessedFrames: 1,
          sampleRate: observed.sampleRate, nonlinear: observed.nonlinear))
      }
    }
  }

  public static func read(url: URL) throws -> Self {
    let keys: [FileAttributeKey] = [.size, .modificationDate, .systemFileNumber, .systemNumber]
    func identity() throws -> NSDictionary {
      let values = try FileManager.default.attributesOfItem(atPath: url.path)
      guard values[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
      return values.filter { keys.contains($0.key) } as NSDictionary
    }
    let before = try identity()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var audit = Self(), offset: UInt64 = 0
    while true {
      try Task.checkCancellation()
      let header = try handle.read(upToCount: 80) ?? Data()
      if header.isEmpty { break }
      guard header.count == 80 else { audit.incompleteBytes = header.count; break }
      let size = header[3] & 0x80 == 0 ? 120_000 : 144_000
      let bytes = header + (try handle.read(upToCount: size - 80) ?? Data())
      guard bytes.count == size else { audit.incompleteBytes = bytes.count; break }
      try autoreleasepool {
        audit.append(try DVFrameForensics.inspect(frame: bytes, ordinal: audit.frames, offset: offset))
      }
      offset += UInt64(size)
    }
    guard before == (try identity()) else { throw CocoaError(.fileReadCorruptFile) }
    return audit
  }

  public var sections: [DVTechnicalSpecifications.Section] {
    typealias Row = DVTechnicalSpecifications.Row
    let scope = "Whole saved file: \(frames) structurally validated complete frames. Original source bytes; read-only audit."
    let audioCoverage = "\(assessedAudioHalves)/\(frames * 2) consumer audio halves assessed; only declared active samples count. Unsupported, missing or conflicting layouts remain unassessed."
    var rows = [
      Row(label: "Nonzero video STA blocks", value: String(videoStatusBlocks), evidence: scope + " Recorded status flags, not an exact lost-frame count or proof of clean picture."),
      Row(label: "Active audio error sentinels", value: assessedAudioHalves > 0 ? "\(audioErrorSamples) observed" : "Unavailable — audio unassessed", evidence: scope + " " + audioCoverage + " Source 0x8000 / 0x800 codes; padding excluded. No silence substitution."),
      Row(label: "Audio assessment coverage", value: audioCoverage, evidence: scope)
    ]
    if incompleteBytes > 0 {
      rows.append(Row(label: "Trailing source bytes", value: "Unavailable — \(incompleteBytes) bytes form an incomplete frame", evidence: "Excluded from duration and quality assessment; retained untouched."))
    }
    let audio = channels.sorted { $0.index < $1.index }.map { channel in
      let complete = channel.assessedFrames == frames && !channel.formatChanged && incompleteBytes == 0
      let duration = Double(channel.samples) / Double(channel.sampleRate)
      return DVTechnicalSpecifications.Section(title: "Exact source audio · channel \(channel.index + 1)", rows: [
        Row(label: "Declared active samples", value: "\(channel.samples)", evidence: scope + " Qualified AAUX AF_SIZE + system/rate minimum; channel \(channel.index + 1). Counts include error-coded active samples, not padding."),
        Row(label: "Assessed frames", value: "\(channel.assessedFrames)/\(frames)", evidence: audioCoverage),
        Row(label: "Recorded audio duration", value: complete ? String(format: "%.6f s", duration) : "Unavailable — incomplete or changing audio metadata", evidence: "Exact rational \(channel.samples)/\(channel.sampleRate) seconds only when every frame qualifies with one rate/quantization. No video-span substitution."),
        Row(label: "Audio minus video duration", value: complete ? String(format: "%+.3f ms", (duration - videoSeconds) * 1000) : "Unavailable — exact audio duration not established", evidence: "Declared source samples compared with complete stored DV frame cadence. A difference is not proof of audible drift, loss, or synchronization failure.")
      ])
    }
    return [.init(title: "Source error summary", rows: rows)] + audio
  }
}
