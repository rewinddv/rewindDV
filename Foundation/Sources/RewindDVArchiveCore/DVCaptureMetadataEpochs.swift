// Adapted from RewindDV Build158 DVCaptureMetadataEpochs.swift.
// Structure and audio validity checks strengthened in September 2026.
// RewindDV source provenance: local qualification candidate supplied for this migration.
import CryptoKit
import Foundation

/// A fail-closed interpretation of one complete DV frame's AAUX source packs.
///
/// Known rates are suitable for tagging a derived audio track. Unknown states
/// deliberately carry no sample-rate tag; the raw DV remains authoritative.
public enum DVAudioSampleRateClassification: String, Codable, Equatable, Sendable {
  case known32000Hz = "known_32000_hz"
  case known44100Hz = "known_44100_hz"
  case known48000Hz = "known_48000_hz"
  case absent = "absent"
  case malformed = "malformed"
  case conflicting = "conflicting"

  public var sampleRateHz: Int? {
    switch self {
    case .known32000Hz: 32_000
    case .known44100Hz: 44_100
    case .known48000Hz: 48_000
    case .absent, .malformed, .conflicting: nil
    }
  }
}

/// A raw five-byte DV metadata pack and its independent source coordinate.
public struct DVRawMetadataPackObservation: Codable, Equatable, Sendable {
  public let fileByteOffset: UInt64
  public let difSequence: UInt8
  public let difSection: UInt8
  public let difBlock: UInt8
  public let packSlotByteOffset: UInt8
  public let rawBytes: [UInt8]

  private enum CodingKeys: String, CodingKey {
    case fileByteOffset = "file_byte_offset"
    case difSequence = "dif_sequence"
    case difSection = "dif_section"
    case difBlock = "dif_block"
    case packSlotByteOffset = "pack_slot_byte_offset"
    case rawBytes = "raw_bytes"
  }

  public init(
    fileByteOffset: UInt64,
    difSequence: UInt8,
    difSection: UInt8,
    difBlock: UInt8,
    packSlotByteOffset: UInt8,
    rawBytes: [UInt8]
  ) {
    self.fileByteOffset = fileByteOffset
    self.difSequence = difSequence
    self.difSection = difSection
    self.difBlock = difBlock
    self.packSlotByteOffset = packSlotByteOffset
    self.rawBytes = rawBytes
  }
}

public struct DVFrameCaptureMetadata: Codable, Equatable, Sendable {
  public let sourceFrameOrdinal: UInt64
  public let fileByteOffset: UInt64
  public let byteCount: UInt64
  public let audioSampleRate: DVAudioSampleRateClassification
  public let aauxSourcePacks: [DVRawMetadataPackObservation]
  public let sourceTimecodePacks: [DVRawMetadataPackObservation]

  private enum CodingKeys: String, CodingKey {
    case sourceFrameOrdinal = "source_frame_ordinal"
    case fileByteOffset = "file_byte_offset"
    case byteCount = "byte_count"
    case audioSampleRate = "audio_sample_rate"
    case aauxSourcePacks = "aaux_source_packs"
    case sourceTimecodePacks = "source_timecode_packs"
  }

  public init(
    sourceFrameOrdinal: UInt64,
    fileByteOffset: UInt64,
    byteCount: UInt64,
    audioSampleRate: DVAudioSampleRateClassification,
    aauxSourcePacks: [DVRawMetadataPackObservation],
    sourceTimecodePacks: [DVRawMetadataPackObservation]
  ) {
    self.sourceFrameOrdinal = sourceFrameOrdinal
    self.fileByteOffset = fileByteOffset
    self.byteCount = byteCount
    self.audioSampleRate = audioSampleRate
    self.aauxSourcePacks = aauxSourcePacks
    self.sourceTimecodePacks = sourceTimecodePacks
  }
}

/// One contiguous range that may be represented by one derived audio track.
/// A known epoch's `derivedTrackSampleRateHz` is the only permitted tag for
/// that epoch. An unknown epoch must remain untagged until independently
/// resolved; it must never inherit a neighboring epoch's value.
public struct DVAudioSampleRateEpoch: Codable, Equatable, Sendable {
  public let epochOrdinal: UInt64
  public let firstSourceFrameOrdinal: UInt64
  public let lastSourceFrameOrdinal: UInt64
  public let fileByteOffset: UInt64
  public let byteCount: UInt64
  public let classification: DVAudioSampleRateClassification
  public let derivedTrackSampleRateHz: Int?

  private enum CodingKeys: String, CodingKey {
    case epochOrdinal = "epoch_ordinal"
    case firstSourceFrameOrdinal = "first_source_frame_ordinal"
    case lastSourceFrameOrdinal = "last_source_frame_ordinal"
    case fileByteOffset = "file_byte_offset"
    case byteCount = "byte_count"
    case classification
    case derivedTrackSampleRateHz = "derived_track_sample_rate_hz"
  }

  public init(
    epochOrdinal: UInt64,
    firstSourceFrameOrdinal: UInt64,
    lastSourceFrameOrdinal: UInt64,
    fileByteOffset: UInt64,
    byteCount: UInt64,
    classification: DVAudioSampleRateClassification
  ) {
    self.epochOrdinal = epochOrdinal
    self.firstSourceFrameOrdinal = firstSourceFrameOrdinal
    self.lastSourceFrameOrdinal = lastSourceFrameOrdinal
    self.fileByteOffset = fileByteOffset
    self.byteCount = byteCount
    self.classification = classification
    derivedTrackSampleRateHz = classification.sampleRateHz
  }
}

public struct DVUnclassifiedCaptureExtent: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Equatable, Sendable {
    case beforeFirstFrame = "before_first_frame"
    case incompleteFrame = "incomplete_frame"
    case trailingBytes = "trailing_bytes"
  }

  public let fileByteOffset: UInt64
  public let byteCount: UInt64
  public let reason: Reason

  private enum CodingKeys: String, CodingKey {
    case fileByteOffset = "file_byte_offset"
    case byteCount = "byte_count"
    case reason
  }

  public init(fileByteOffset: UInt64, byteCount: UInt64, reason: Reason) {
    self.fileByteOffset = fileByteOffset
    self.byteCount = byteCount
    self.reason = reason
  }
}

/// Deterministic, rebuildable analysis of the immutable native-DV file.
/// Metadata is observational: it does not control intake, frame discovery, or
/// raw-file splitting. Derived media must honor the listed rate epochs.
public struct DVCaptureMetadataEpochManifest: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let classifierVersion: String
  public let sourceByteCount: UInt64
  public let sourceSHA256: String
  public let completeFrameCount: UInt64
  public let frames: [DVFrameCaptureMetadata]
  public let audioSampleRateEpochs: [DVAudioSampleRateEpoch]
  public let unclassifiedExtents: [DVUnclassifiedCaptureExtent]
  public let derivedAudioTrackPolicy: String
  public let timecodeAuthority: String

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case classifierVersion = "classifier_version"
    case sourceByteCount = "source_byte_count"
    case sourceSHA256 = "source_sha256"
    case completeFrameCount = "complete_frame_count"
    case frames
    case audioSampleRateEpochs = "audio_sample_rate_epochs"
    case unclassifiedExtents = "unclassified_extents"
    case derivedAudioTrackPolicy = "derived_audio_track_policy"
    case timecodeAuthority = "timecode_authority"
  }

  public init(
    sourceByteCount: UInt64,
    sourceSHA256: String,
    frames: [DVFrameCaptureMetadata],
    audioSampleRateEpochs: [DVAudioSampleRateEpoch],
    unclassifiedExtents: [DVUnclassifiedCaptureExtent]
  ) {
    schemaVersion = 1
    classifierVersion = "rewinddv-dv-aaux-rate-epochs-v2"
    self.sourceByteCount = sourceByteCount
    self.sourceSHA256 = sourceSHA256
    completeFrameCount = UInt64(frames.count)
    self.frames = frames
    self.audioSampleRateEpochs = audioSampleRateEpochs
    self.unclassifiedExtents = unclassifiedExtents
    derivedAudioTrackPolicy =
      "one_track_per_contiguous_known_rate_epoch; unknown_epochs_must_not_inherit_a_rate"
    timecodeAuthority = "raw_observation_only; never_controls_intake_or_epoch_boundaries"
  }
}

public enum DVCaptureMetadataEpochError: Error, Equatable, LocalizedError, Sendable {
  case sourceNotRegularFile(String)

  public var errorDescription: String? {
    switch self {
    case .sourceNotRegularFile(let path):
      "DV metadata source is not a regular file: \(path)"
    }
  }
}

/// Derived complete-file facts for display. Raw per-frame observations remain
/// available through the full manifest API and the unchanged source bytes.
/// Storage scales with actual epoch/invalid-extent transitions, not every pack.
public struct DVCaptureMetadataEpochSummary: Equatable, Sendable {
  public let sourceByteCount: UInt64
  public let sourceSHA256: String
  public let completeFrameCount: UInt64
  public let audioSampleRateEpochs: [DVAudioSampleRateEpoch]
  public let unclassifiedExtents: [DVUnclassifiedCaptureExtent]
}

/// Bounded-frame scanner for native DV. The full manifest retains every frame;
/// the display summary retains only epochs and unclassified extents.
public enum DVCaptureMetadataEpochAnalyzer {
  private static let difBlockBytes = 80
  private static let ntscFrameBlocks = 1_500
  private static let palFrameBlocks = 1_800

  private final class BufferedReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var cursor = 0
    private let refillByteCount = 1 << 20

    init(handle: FileHandle) {
      self.handle = handle
    }

    func read(upTo count: Int) throws -> Data? {
      var output = Data()
      output.reserveCapacity(count)
      while output.count < count {
        if cursor == buffer.count {
          try Task.checkCancellation()
          buffer = try handle.read(upToCount: refillByteCount) ?? Data()
          cursor = 0
          if buffer.isEmpty {
            return output.isEmpty ? nil : output
          }
        }
        let amount = min(count - output.count, buffer.count - cursor)
        output.append(buffer[cursor..<(cursor + amount)])
        cursor += amount
      }
      return output
    }
  }

  public static func analyze(url: URL) throws -> DVCaptureMetadataEpochManifest {
    var scan = try read(url: url, retainFrames: true)
    return scan.builder.finish(sourceByteCount: scan.byteCount, sourceSHA256: scan.sha)
  }

  public static func analyzeSummary(url: URL) throws -> DVCaptureMetadataEpochSummary {
    var scan = try read(url: url, retainFrames: false)
    return scan.builder.finishSummary(sourceByteCount: scan.byteCount, sourceSHA256: scan.sha)
  }

  private static func read(url: URL, retainFrames: Bool) throws
    -> (builder: Builder, byteCount: UInt64, sha: String) {
    try Task.checkCancellation()
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw DVCaptureMetadataEpochError.sourceNotRegularFile(url.path)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let reader = BufferedReader(handle: handle)

    var builder = Builder(retainFrames: retainFrames)
    var digest = SHA256()
    var sourceByteCount: UInt64 = 0
    // Drain Foundation read/slice temporaries in bounded batches. A long-lived
    // detached task otherwise retains autoreleased objects for the whole tape.
    while try autoreleasepool(invoking: { () throws -> Bool in
      for _ in 0..<16_384 {
        guard let chunk = try reader.read(upTo: difBlockBytes) else { return false }
        digest.update(data: chunk)
        builder.consume(chunk, at: sourceByteCount)
        sourceByteCount += UInt64(chunk.count)
      }
      return true
    }) {}
    return (builder, sourceByteCount, digest.finalize().map { String(format: "%02x", $0) }.joined())
  }

  public static func analyze(data: Data) -> DVCaptureMetadataEpochManifest {
    let data = data.startIndex == 0 ? data : Data(data)
    var builder = Builder()
    var offset = 0
    while offset < data.count {
      let end = min(offset + difBlockBytes, data.count)
      builder.consume(Data(data[offset..<end]), at: UInt64(offset))
      offset = end
    }
    let digest = SHA256.hash(data: data).map {
      String(format: "%02x", $0)
    }.joined()
    return builder.finish(
      sourceByteCount: UInt64(data.count), sourceSHA256: digest)
  }

  public static func canonicalJSONData(
    _ manifest: DVCaptureMetadataEpochManifest
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest) + Data([0x0a])
  }

  // Internal so bounded malformed-frame retention can be verified directly.
  struct FrameAccumulator {
    let fileByteOffset: UInt64
    private static let sectionSizes = [1, 2, 3, 9, 135]
    private static let sectionStarts = [0, 1, 3, 6, 15]
    var blockCount = 0
    var sectionCounts = Array(
      repeating: Array(repeating: 0, count: 5), count: 12)
    var structureInvalid = false
    var expectedSequenceCount: Int?
    var seenIdentities = [Bool](repeating: false, count: 12 * 150)
    var audioTransmittedBySequence: [UInt8: Bool] = [:]
    var applicationIdentityBySequence: [UInt8: [UInt8]] = [:]
    var aauxSourcePacks: [DVRawMetadataPackObservation] = []
    var sourceTimecodePacks: [DVRawMetadataPackObservation] = []

    mutating func consume(_ block: Data, at offset: UInt64) {
      // After invalidation, Builder still hashes/counts every source byte and
      // records the full unclassified extent. No interpretation can be emitted
      // for this candidate, so do not retain unbounded duplicate packs.
      guard !structureInvalid else { return }
      blockCount += 1
      let section = block[0] >> 5
      let sequence = block[1] >> 4
      let difBlock = block[2]
      if expectedSequenceCount == nil {
        guard section == 0, sequence == 0, difBlock == 0 else {
          invalidateStructure(); return
        }
        expectedSequenceCount = block[3] & 0x80 == 0 ? 10 : 12
      }
      let sequenceCount = expectedSequenceCount!
      guard blockCount <= sequenceCount * 150, Int(sequence) < sequenceCount,
        section < 5, Int(difBlock) < Self.sectionSizes[Int(section)] else {
        invalidateStructure(); return
      }
      let identity = Int(sequence) * 150 + Self.sectionStarts[Int(section)] + Int(difBlock)
      guard !seenIdentities[identity] else { invalidateStructure(); return }
      seenIdentities[identity] = true
      sectionCounts[Int(sequence)][Int(section)] += 1

      if section == 0 {
        guard (block[3] & 0x80 == 0 ? 10 : 12) == sequenceCount else {
          invalidateStructure(); return
        }
        // Match the existing inventory/semantic interpretation of header TF1.
        audioTransmittedBySequence[sequence] = block[5] & 0x80 == 0
        applicationIdentityBySequence[sequence] = [
          block[4] & 0x07, block[5] & 0x07,
          block[6] & 0x07, block[7] & 0x07,
        ]
      }
      if section == 3 {
        appendPack(
          from: block, slotOffset: 3, expectedType: 0x50,
          fileByteOffset: offset, sequence: sequence,
          section: section, difBlock: difBlock,
          into: &aauxSourcePacks)
      } else if section == 1 {
        for slotOffset in stride(from: 6, through: 46, by: 8) {
          appendPack(
            from: block, slotOffset: slotOffset,
            expectedType: 0x13, fileByteOffset: offset,
            sequence: sequence, section: section,
            difBlock: difBlock, into: &sourceTimecodePacks)
        }
      }
    }

    func materialize(sourceFrameOrdinal: UInt64) -> DVFrameCaptureMetadata? {
      guard let sequenceCount = expectedSequenceCount,
        blockCount == sequenceCount * 150 else { return nil }
      let expectedCounts = Self.sectionSizes
      guard !structureInvalid,
        sectionCounts[..<sequenceCount].allSatisfy({ $0 == expectedCounts }),
        sectionCounts[sequenceCount...].allSatisfy({
          $0.allSatisfy { $0 == 0 }
        })
      else {
        return nil
      }

      return DVFrameCaptureMetadata(
        sourceFrameOrdinal: sourceFrameOrdinal,
        fileByteOffset: fileByteOffset,
        byteCount: UInt64(blockCount * DVCaptureMetadataEpochAnalyzer.difBlockBytes),
        audioSampleRate: classifyAudioRate(),
        aauxSourcePacks: aauxSourcePacks,
        sourceTimecodePacks: sourceTimecodePacks)
    }

    private mutating func invalidateStructure() {
      structureInvalid = true
      aauxSourcePacks.removeAll()
      sourceTimecodePacks.removeAll()
      applicationIdentityBySequence.removeAll()
      audioTransmittedBySequence.removeAll()
      seenIdentities.removeAll()
    }

    private func classifyAudioRate() -> DVAudioSampleRateClassification {
      guard !aauxSourcePacks.isEmpty else { return .absent }
      var observedRates = Set<Int>()
      var malformed = false
      for observation in aauxSourcePacks {
        let raw = observation.rawBytes
        let identity = applicationIdentityBySequence[observation.difSequence]
        guard identity == [0, 0, 0, 0],
          audioTransmittedBySequence[observation.difSequence] == true,
          raw.count == 5 else {
          malformed = true
          continue
        }
        let rateCode = Int((raw[4] >> 3) & 0x07)
        let quantizationCode = raw[4] & 0x07
        let sourceType = raw[3] & 0x1f
        guard rateCode < 3,
          quantizationCode == 0 || quantizationCode == 1,
          sourceType == 0 || sourceType == 2
        else {
          malformed = true
          continue
        }
        observedRates.insert([48_000, 44_100, 32_000][rateCode])
      }
      if malformed { return .malformed }
      guard observedRates.count == 1, let rate = observedRates.first else {
        return observedRates.isEmpty ? .malformed : .conflicting
      }
      switch rate {
      case 32_000: return .known32000Hz
      case 44_100: return .known44100Hz
      case 48_000: return .known48000Hz
      default: return .malformed
      }
    }

    private func appendPack(
      from block: Data,
      slotOffset: Int,
      expectedType: UInt8,
      fileByteOffset: UInt64,
      sequence: UInt8,
      section: UInt8,
      difBlock: UInt8,
      into observations: inout [DVRawMetadataPackObservation]
    ) {
      guard slotOffset + 5 <= block.count,
        block[slotOffset] == expectedType
      else { return }
      observations.append(
        DVRawMetadataPackObservation(
          fileByteOffset: fileByteOffset + UInt64(slotOffset),
          difSequence: sequence,
          difSection: section,
          difBlock: difBlock,
          packSlotByteOffset: UInt8(slotOffset),
          rawBytes: Array(block[slotOffset..<(slotOffset + 5)])))
    }
  }

  private struct Builder {
    var retainFrames = true
    var currentFrame: FrameAccumulator?
    var frames: [DVFrameCaptureMetadata] = []
    var completeFrameCount: UInt64 = 0
    var epochs: [DVAudioSampleRateEpoch] = []
    var unclassifiedExtents: [DVUnclassifiedCaptureExtent] = []
    var bytesBeforeFirstFrame: UInt64 = 0

    mutating func consume(_ chunk: Data, at offset: UInt64) {
      guard chunk.count == DVCaptureMetadataEpochAnalyzer.difBlockBytes else {
        flushCurrentFrame(endOffset: offset)
        if chunk.count > 0 {
          unclassifiedExtents.append(
            DVUnclassifiedCaptureExtent(
              fileByteOffset: offset,
              byteCount: UInt64(chunk.count),
              reason: .trailingBytes))
        }
        return
      }
      if isFrameStart(chunk) {
        flushCurrentFrame(endOffset: offset)
        currentFrame = FrameAccumulator(fileByteOffset: offset)
      }
      if currentFrame != nil {
        currentFrame?.consume(chunk, at: offset)
      } else {
        bytesBeforeFirstFrame += UInt64(chunk.count)
      }
    }

    mutating func finish(
      sourceByteCount: UInt64,
      sourceSHA256: String
    ) -> DVCaptureMetadataEpochManifest {
      let summary = finishSummary(sourceByteCount: sourceByteCount, sourceSHA256: sourceSHA256)
      return DVCaptureMetadataEpochManifest(
        sourceByteCount: sourceByteCount,
        sourceSHA256: sourceSHA256,
        frames: frames,
        audioSampleRateEpochs: summary.audioSampleRateEpochs,
        unclassifiedExtents: summary.unclassifiedExtents)
    }

    mutating func finishSummary(
      sourceByteCount: UInt64, sourceSHA256: String
    ) -> DVCaptureMetadataEpochSummary {
      flushCurrentFrame(endOffset: sourceByteCount)
      if bytesBeforeFirstFrame > 0 {
        unclassifiedExtents.insert(
          DVUnclassifiedCaptureExtent(
            fileByteOffset: 0,
            byteCount: bytesBeforeFirstFrame,
            reason: .beforeFirstFrame), at: 0)
      }
      return DVCaptureMetadataEpochSummary(
        sourceByteCount: sourceByteCount,
        sourceSHA256: sourceSHA256,
        completeFrameCount: completeFrameCount,
        audioSampleRateEpochs: epochs,
        unclassifiedExtents: unclassifiedExtents)
    }

    private mutating func flushCurrentFrame(endOffset: UInt64) {
      guard let accumulator = currentFrame else { return }
      if let frame = accumulator.materialize(
        sourceFrameOrdinal: completeFrameCount)
      {
        completeFrameCount += 1
        if retainFrames { frames.append(frame) }
        appendEpoch(frame)
      } else if endOffset > accumulator.fileByteOffset {
        unclassifiedExtents.append(
          DVUnclassifiedCaptureExtent(
            fileByteOffset: accumulator.fileByteOffset,
            byteCount: endOffset - accumulator.fileByteOffset,
            reason: .incompleteFrame))
      }
      currentFrame = nil
    }

    private func isFrameStart(_ block: Data) -> Bool {
      block[0] >> 5 == 0 && block[1] >> 4 == 0 && block[2] == 0
    }

    private mutating func appendEpoch(_ frame: DVFrameCaptureMetadata) {
      if let previous = epochs.last,
        previous.classification == frame.audioSampleRate,
        previous.fileByteOffset + previous.byteCount == frame.fileByteOffset
      {
        epochs[epochs.count - 1] = DVAudioSampleRateEpoch(
          epochOrdinal: previous.epochOrdinal,
          firstSourceFrameOrdinal: previous.firstSourceFrameOrdinal,
          lastSourceFrameOrdinal: frame.sourceFrameOrdinal,
          fileByteOffset: previous.fileByteOffset,
          byteCount: previous.byteCount + frame.byteCount,
          classification: previous.classification)
      } else {
        epochs.append(
          DVAudioSampleRateEpoch(
            epochOrdinal: UInt64(epochs.count),
            firstSourceFrameOrdinal: frame.sourceFrameOrdinal,
            lastSourceFrameOrdinal: frame.sourceFrameOrdinal,
            fileByteOffset: frame.fileByteOffset,
            byteCount: frame.byteCount,
            classification: frame.audioSampleRate))
      }
    }
  }
}
