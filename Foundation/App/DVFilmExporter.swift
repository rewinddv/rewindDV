// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
@preconcurrency import AVFoundation
import CryptoKit
import CoreImage
import Foundation

/// Offline native derivative writer. The existing decoder explicitly requests
/// both fields; 2vuy stays YCbCr through field assembly and ProRes encoding.
/// Source DV is always opened read-only. Completion receipt is published last.
enum DVFilmExporter {
  struct SourcePictureEvidence: Codable {
    let sha256: String
    let metadata: DVFilmFrameEvidence
  }
  struct PictureProvenance: Codable {
    let picture: DVFilmPlan.Picture
    let firstTemporalFieldSource: SourcePictureEvidence
    let secondTemporalFieldSource: SourcePictureEvidence
  }
  /// Display-only RGB thumbnails. Export never passes through this conversion.
  static func previewCycle(source: URL, plan: DVFilmPlan) async throws -> [Data] {
    _ = try plan.picture(0)
    guard try hashFile(source) == plan.sourceSHA256 else { throw failure("Source changed since analysis") }
    let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
    let decoder = LiveDVFrameDecoder(), context = CIContext()
    var frames: [UInt64: LiveDVDecodedFrame] = [:], images: [Data] = []
    for n in 0..<min(UInt64(4), plan.outputFrameCount) {
      try Task.checkCancellation()
      let picture = try plan.picture(n)
      for index in [picture.firstFieldSourceFrame, picture.secondFieldSourceFrame] where frames[index] == nil {
        try input.seek(toOffset: index * UInt64(plan.mode.sourceFrameBytes))
        guard let bytes = try input.read(upToCount: plan.mode.sourceFrameBytes), bytes.count == plan.mode.sourceFrameBytes else {
          throw failure("Incomplete source picture")
        }
        frames[index] = try await decoder.decode(bytes, ordinal: index, timecode: nil)
      }
      guard let a = frames[picture.firstFieldSourceFrame], let b = frames[picture.secondFieldSourceFrame] else { throw failure("Missing preview fields") }
      let pixel = try assemble(first: a.pixelBuffer, second: b.pixelBuffer)
      guard let data = context.pngRepresentation(of: CIImage(cvPixelBuffer: pixel), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()) else { throw failure("Cannot render cycle preview") }
      images.append(data)
    }
    return images
  }

  struct Receipt: Codable, Sendable {
    let schemaVersion: Int
    let plan: DVFilmPlan
    let outputSHA256: String
    let outputVideoFrames: UInt64
    let outputAudioSamples: Int64
    let audioSampleRate: Double?
    let audioChannels: UInt32?
    let audioSourceStartOffsetSeconds: Double
    let decodedPCMSHA256: String
    let videoCodec: String
    let pixelFormat: String
    let fieldMapping: String
    let interpretationAuthority: String
    let sourceFileName: String
    let sourceBytes: UInt64
    let colorPolicy: String
  }

  static func export(source: URL, plan: DVFilmPlan, destination: URL,
    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Receipt {
    _ = try plan.picture(0)
    guard plan.mode.isProgressive else {
      throw failure("Interlaced footage is already represented by the original DV. Select a progressive recording mode for this derivative.")
    }
    // Verify the complete source and inspect each selected frame before output.
    // A metadata candidate never substitutes for the operator's mode selection.
    var recordedAudioRates = Set<Int>()
    var recordedQuantizations = Set<UInt8>()
    var missingAudioRate = false
    let sourceScan = try DVFilmScan.scan(url: source) { observation in
      let f = observation.frame
      guard f.ordinal >= plan.firstSourceFrame,
        f.ordinal < plan.firstSourceFrame + plan.sourceFrameCount else { return }
      guard f.isPAL == plan.mode.isPAL else { throw failure("Selected mode disagrees with recorded NTSC/PAL system") }
      if let rate = f.audioRateHz { recordedAudioRates.insert(rate) } else { missingAudioRate = true }
      guard let quantization = f.audioQuantizationCode, quantization <= 1 else {
        throw failure("Audio quantization is unknown or outside the qualified 16-bit/12-bit DV path; do not reduce source precision")
      }
      recordedQuantizations.insert(quantization)
      guard f.fieldOrder == nil || f.fieldOrder == 1 else { throw failure("Source field-order metadata contradicts standard DV bottom-field-first reconstruction") }
      guard f.videoStatusBlocks == 0 else { throw failure("Source video reports damage at frame \(f.ordinal); review and split the range before cadence reconstruction") }
      if f.ordinal > plan.firstSourceFrame {
        let breaks = observation.boundaryReasons.filter {
          $0.contains("Timecode discontinuity") || $0.contains("format changed") || $0 == "Recording-start flag" || $0.contains("Audio-rate")
        }
        guard breaks.isEmpty else { throw failure("Split the selected range at frame \(f.ordinal): \(breaks.joined(separator: "; "))") }
      }
    }
    guard sourceScan.sourceSHA256 == plan.sourceSHA256,
      plan.firstSourceFrame + plan.sourceFrameCount <= sourceScan.frameCount,
      sourceScan.systems.count == 1 else { throw failure("Source identity/range changed or source has mixed NTSC/PAL frames") }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let json = JSONEncoder(); json.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try json.encode(plan).write(to: destination.appendingPathComponent("interpretation.json"), options: .withoutOverwriting)
    let movie = destination.appendingPathComponent("progressive.partial.mov")
    let mappingURL = destination.appendingPathComponent("frame-map.ndjson")
    try Data().write(to: mappingURL, options: .withoutOverwriting)
    let mapping = try FileHandle(forWritingTo: mappingURL)
    defer { try? mapping.close() }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let decoder = LiveDVFrameDecoder()
    // Only one cadence group is retained, independent of tape length.
    var cachedGroup: UInt64?, cache: [UInt64: LiveDVDecodedFrame] = [:]
    var sourceEvidence: [UInt64: SourcePictureEvidence] = [:]
    func loadGroup(_ group: UInt64) async throws {
      if cachedGroup == group { return }
      cache.removeAll(keepingCapacity: true)
      sourceEvidence.removeAll(keepingCapacity: true)
      let first = plan.firstSourceFrame + group * (plan.mode.isFilm ? 5 : 1)
      for index in first..<(first + (plan.mode.isFilm ? 5 : 1)) {
        try Task.checkCancellation()
        try input.seek(toOffset: index * UInt64(plan.mode.sourceFrameBytes))
        guard let bytes = try input.read(upToCount: plan.mode.sourceFrameBytes), bytes.count == plan.mode.sourceFrameBytes else {
          throw failure("Source frame became incomplete")
        }
        cache[index] = try await decoder.decode(bytes, ordinal: index, timecode: nil)
        let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: index,
          byteOffset: index * UInt64(plan.mode.sourceFrameBytes))
        sourceEvidence[index] = SourcePictureEvidence(sha256: inventory.frameSHA256,
          metadata: DVFilmFrameEvidence.inspect(inventory))
      }
      cachedGroup = group
    }
    try await loadGroup(0)
    guard let initial = cache[plan.firstSourceFrame]?.pixelBuffer else { throw failure("No initial decoded picture") }
    let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
    defer { if writer.status == .writing { writer.cancelWriting() } }
    var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
      AVVideoWidthKey: 720, AVVideoHeightKey: plan.mode.isPAL ? 576 : 480,
      AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: Double(DVFilmMode.timeScale) / Double(plan.mode.outputFrameTicks)]]
    var colors: [String: Any] = [:]
    for (sourceKey, targetKey) in [(kCVImageBufferColorPrimariesKey, AVVideoColorPrimariesKey),
      (kCVImageBufferTransferFunctionKey, AVVideoTransferFunctionKey), (kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrixKey)] {
      if let value = CVBufferCopyAttachment(initial, sourceKey, nil) { colors[targetKey] = value }
    }
    if !colors.isEmpty { settings[AVVideoColorPropertiesKey] = colors }
    if let aspect = CVBufferCopyAttachment(initial, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any],
      let h = aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String],
      let v = aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] {
      settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: h, AVVideoPixelAspectRatioVerticalSpacingKey: v]
    }
    if plan.displayAspect != .decoder {
      let spacing = plan.mode.isPAL
        ? (plan.displayAspect == .fullRaster16x9 ? (64, 45) : (16, 15))
        : (plan.displayAspect == .fullRaster16x9 ? (32, 27) : (8, 9))
      settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: spacing.0,
        AVVideoPixelAspectRatioVerticalSpacingKey: spacing.1]
    }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    // MOV's default video timescale can round 1001-based frame intervals.
    // Preserve the exact rational clock used by the provenance map.
    video.mediaTimeScale = DVFilmMode.timeScale
    video.expectsMediaDataInRealTime = false
    guard writer.canAdd(video) else { throw failure("Native ProRes writer rejected video settings") }
    writer.add(video)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8,
        kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: plan.mode.isPAL ? 576 : 480])
    let start = CMTime(value: Int64(plan.firstSourceFrame) * plan.mode.sourceFrameTicks, timescale: DVFilmMode.timeScale)
    let duration = CMTime(value: plan.durationTicks, timescale: DVFilmMode.timeScale)
    let audio = try await FilmAudioReader(source: source, start: start, duration: duration)
    guard !missingAudioRate, recordedAudioRates.count == 1,
      let recordedRate = recordedAudioRates.first, audio.sampleRate == Double(recordedRate) else {
      throw failure("Native decoded audio must agree with one verified raw-DV sample-rate epoch. Unknown, absent or conflicting audio is not silently retagged or omitted.")
    }
    guard recordedQuantizations.count == 1,
      audio.channels == (recordedQuantizations.first == 1 ? 4 : 2) else {
      throw failure("Native decoded channel coverage disagrees with the DV audio mode. This candidate refuses a derivative that could omit channels.")
    }
    if let a = audio.writerInput {
      guard writer.canAdd(a) else { throw failure("Native writer rejected source PCM format") }
      writer.add(a)
    }
    guard writer.startWriting() else { throw writer.error ?? failure("Native writer could not start") }
    writer.startSession(atSourceTime: .zero)
    let lineEncoder = JSONEncoder(); lineEncoder.outputFormatting = [.sortedKeys]
    for index in 0..<plan.outputFrameCount {
      try Task.checkCancellation()
      try await loadGroup(index / (plan.mode.isFilm ? 4 : 1))
      let picture = try plan.picture(index)
      guard let first = cache[picture.firstFieldSourceFrame]?.pixelBuffer,
        let second = cache[picture.secondFieldSourceFrame]?.pixelBuffer else { throw failure("Missing mapped source fields") }
      let pixel = try assemble(first: first, second: second)
      try await waitReady(video, writer: writer)
      guard adaptor.append(pixel, withPresentationTime: CMTime(value: picture.presentationTicks, timescale: DVFilmMode.timeScale)) else {
        throw writer.error ?? failure("ProRes encoder rejected picture \(index)")
      }
      guard let firstEvidence = sourceEvidence[picture.firstFieldSourceFrame],
        let secondEvidence = sourceEvidence[picture.secondFieldSourceFrame] else { throw failure("Missing source-picture provenance") }
      try mapping.write(contentsOf: lineEncoder.encode(PictureProvenance(picture: picture,
        firstTemporalFieldSource: firstEvidence, secondTemporalFieldSource: secondEvidence)) + Data([10]))
      try await audio.drain(until: CMTime(value: picture.presentationTicks + picture.durationTicks, timescale: DVFilmMode.timeScale), writer: writer)
      if index % 30 == 0 { progress(Double(index + 1) / Double(plan.outputFrameCount)) }
    }
    try await audio.drain(until: duration, writer: writer, finish: true)
    video.markAsFinished(); audio.writerInput?.markAsFinished()
    writer.endSession(atSourceTime: duration)
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? failure("Native writer did not complete") }
    try mapping.synchronize()
    // Hash the current source again: a successful receipt requires the source
    // to retain the identity reviewed before the derivative was made.
    guard try hashFile(source) == plan.sourceSHA256 else { throw failure("Source changed during export; incomplete derivative retained") }
    let verifyAsset = AVURLAsset(url: movie)
    guard let track = try await verifyAsset.loadTracks(withMediaType: .video).first else { throw failure("Output lacks video") }
    let reader = try AVAssetReader(asset: verifyAsset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); reader.add(output)
    guard reader.startReading() else { throw failure("Cannot verify derivative") }
    var verified: UInt64 = 0
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      // AVAssetReader includes zero-sample track boundary markers. They are
      // not pictures and must not be compared against the next picture PTS.
      if CMSampleBufferGetNumSamples(sample) == 0 { continue }
      guard verified < plan.outputFrameCount,
        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(verified) * plan.mode.outputFrameTicks, timescale: DVFilmMode.timeScale)) == 0,
        CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: plan.mode.outputFrameTicks, timescale: DVFilmMode.timeScale)) == 0 else {
        let actual = CMSampleBufferGetPresentationTimeStamp(sample)
        throw failure("Output picture \(verified) timing \(actual.value)/\(actual.timescale) does not match provenance \(Int64(verified) * plan.mode.outputFrameTicks)/\(DVFilmMode.timeScale)")
      }
      verified += UInt64(CMSampleBufferGetNumSamples(sample))
    }
    guard reader.status == .completed, verified == plan.outputFrameCount else { throw failure("Output frame-count verification failed") }
    try await verifyAudio(asset: verifyAsset, samples: audio.samplesWritten, rate: recordedRate,
      channels: audio.channels, expectedPCMHash: audio.pcmSHA256)
    let receipt = Receipt(schemaVersion: 1, plan: plan, outputSHA256: try hashFile(movie),
      outputVideoFrames: verified, outputAudioSamples: audio.samplesWritten,
      audioSampleRate: audio.sampleRate, audioChannels: audio.channels,
      audioSourceStartOffsetSeconds: audio.sourceStartOffsetSeconds,
      decodedPCMSHA256: audio.pcmSHA256,
      videoCodec: "Apple ProRes 422 HQ", pixelFormat: "2vuy: native decoded 8-bit YCbCr 4:2:2",
      fieldMapping: "frame-map.ndjson; first temporal DV field is bottom/odd raster rows, second is top/even rows. No blending.",
      interpretationAuthority: plan.interpretation, sourceFileName: source.lastPathComponent,
      sourceBytes: sourceScan.sourceBytes,
      colorPolicy: "Native decoder color attachments propagated. Display aspect: \(plan.displayAspect.label). No RGB conversion, scaling, cropping, denoising, sharpening or gamma adjustment. ProRes is a decoded derivative, not the raw DV master.")
    try FileManager.default.moveItem(at: movie, to: destination.appendingPathComponent("progressive.mov"))
    try json.encode(receipt).write(to: destination.appendingPathComponent("provenance.json"), options: .withoutOverwriting)
    progress(1)
    return receipt
  }

  /// Assemble temporal fields at original raster coordinates in packed 4:2:2.
  /// Copying whole rows preserves chroma alignment and avoids RGB round trips.
  static func assemble(first: CVPixelBuffer, second: CVPixelBuffer) throws -> CVPixelBuffer {
    let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
    guard width == 720, [480, 576].contains(height),
      CVPixelBufferGetWidth(second) == width, CVPixelBufferGetHeight(second) == height,
      CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_422YpCbCr8,
      CVPixelBufferGetPixelFormatType(second) == kCVPixelFormatType_422YpCbCr8 else { throw failure("Unexpected native DV pixel layout") }
    var result: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_422YpCbCr8,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
      let result else { throw failure("Cannot allocate progressive picture") }
    CVPixelBufferLockBaseAddress(first, .readOnly)
    if first !== second { CVPixelBufferLockBaseAddress(second, .readOnly) }
    CVPixelBufferLockBaseAddress(result, [])
    defer {
      CVPixelBufferUnlockBaseAddress(first, .readOnly)
      if first !== second { CVPixelBufferUnlockBaseAddress(second, .readOnly) }
      CVPixelBufferUnlockBaseAddress(result, [])
    }
    guard let a = CVPixelBufferGetBaseAddress(first), let b = CVPixelBufferGetBaseAddress(second),
      let dst = CVPixelBufferGetBaseAddress(result) else { throw failure("Native DV pixel memory unavailable") }
    for row in 0..<height {
      let source = row % 2 == 1 ? a.advanced(by: row * CVPixelBufferGetBytesPerRow(first))
        : b.advanced(by: row * CVPixelBufferGetBytesPerRow(second))
      memcpy(dst.advanced(by: row * CVPixelBufferGetBytesPerRow(result)), source, width * 2)
    }
    CVBufferPropagateAttachments(first, result)
    CVBufferSetAttachment(result, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
    CVBufferRemoveAttachment(result, kCVImageBufferFieldDetailKey)
    return result
  }

  static func waitReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? failure("Native writer stalled") }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  static func hashFile(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
    var digest = SHA256()
    while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
      try Task.checkCancellation(); digest.update(data: bytes)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func verifyAudio(asset: AVAsset, samples: Int64, rate: Int, channels: UInt32?, expectedPCMHash: String) async throws {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw failure("Derivative lost its audio track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    guard reader.startReading() else { throw failure("Cannot reread derivative audio") }
    var count: Int64 = 0
    var digest = SHA256()
    while let sample = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      if CMSampleBufferGetNumSamples(sample) == 0 { continue }
      guard let format = CMSampleBufferGetFormatDescription(sample),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
        asbd.mSampleRate == Double(rate), asbd.mChannelsPerFrame == channels,
        abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * Double(rate) - Double(count)) <= 1.01 else {
        throw failure("Derivative audio format or sample continuity verification failed")
      }
      count += Int64(CMSampleBufferGetNumSamples(sample))
      digest.update(data: try pcmBytes(sample))
    }
    guard reader.status == .completed, count == samples, count > 0 else { throw failure("Derivative audio sample-count verification failed: wrote \(samples), reread \(count), reader status \(reader.status.rawValue)") }
    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedPCMHash else {
      throw failure("Derivative PCM samples differ from the selected native-decoded source audio")
    }
  }
  static func pcmBytes(_ sample: CMSampleBuffer) throws -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample),
      let format = CMSampleBufferGetFormatDescription(sample),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { throw failure("PCM buffer unavailable") }
    let size = CMSampleBufferGetNumSamples(sample) * Int(asbd.mBytesPerFrame)
    guard size == CMBlockBufferGetDataLength(block) else { throw failure("PCM sample extent is ambiguous") }
    var bytes = Data(count: size)
    let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
    guard status == kCMBlockBufferNoErr else { throw failure("Cannot verify PCM bytes") }
    return bytes
  }
  static func failure(_ text: String) -> Error { DVIngestError.invalidEvidence(text) }
}

/// Native PCM extraction stays on the source clock, including the DV frame
/// omitted by 24PA video reconstruction. Sample-boundary trimming only.
private final class FilmAudioReader {
  let writerInput: AVAssetWriterInput?
  let sampleRate: Double?
  let channels: UInt32?
  private let reader: AVAssetReader?
  private let output: AVAssetReaderTrackOutput?
  private let start: CMTime
  private let duration: CMTime
  private var pending: CMSampleBuffer?
  private var audioOrigin: CMTime?
  private var pcmDigest = SHA256()
  var pcmSHA256: String { pcmDigest.finalize().map { String(format: "%02x", $0) }.joined() }
  private(set) var sourceStartOffsetSeconds = 0.0
  private(set) var samplesWritten: Int64 = 0

  init(source: URL, start: CMTime, duration: CMTime) async throws {
    self.start = start; self.duration = duration
    let asset = AVURLAsset(url: source)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count <= 1 else {
      throw DVFilmExporter.failure("Native reader exposed multiple audio tracks; this candidate refuses to omit tracks. Preserve the raw DV and qualify multitrack export separately.")
    }
    guard let track = tracks.first else {
      reader = nil; output = nil; writerInput = nil; sampleRate = nil; channels = nil; return
    }
    let r = try AVAssetReader(asset: asset)
    r.timeRange = CMTimeRange(start: start, duration: duration)
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    guard r.canAdd(o) else { throw DVFilmExporter.failure("Cannot configure native PCM reader") }
    r.add(o)
    guard r.startReading(), let sample = o.copyNextSampleBuffer(),
      let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      asbd.mSampleRate.isFinite, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
      throw r.error ?? DVFilmExporter.failure("Audio exists but native PCM is unavailable; export cannot silently omit it")
    }
    self.reader = r; self.output = o; pending = sample
    self.sampleRate = asbd.mSampleRate; self.channels = asbd.mChannelsPerFrame
    self.writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], sourceFormatHint: format)
  }
  deinit { reader?.cancelReading() }

  func drain(until: CMTime, writer: AVAssetWriter, finish: Bool = false) async throws {
    guard let input = writerInput, let rate = sampleRate else { return }
    while let sample = pending {
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      if !finish && CMTimeCompare(CMTimeSubtract(pts, start), until) >= 0 { break }
      guard let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
        asbd.mSampleRate == rate, asbd.mChannelsPerFrame == channels else { throw DVFilmExporter.failure("Decoded audio format changed; split this range into audio epochs") }
      let count = CMSampleBufferGetNumSamples(sample)
      let first = max(0, Int(ceil(CMTimeGetSeconds(CMTimeSubtract(start, pts)) * rate - 0.000_001)))
      let targetSamples = Int64(floor(CMTimeGetSeconds(duration) * rate + 0.000_001))
      let end = min(count, first + Int(max(0, targetSamples - samplesWritten)),
        Int(ceil(CMTimeGetSeconds(CMTimeSubtract(CMTimeAdd(start, duration), pts)) * rate - 0.000_001)))
      if end > first {
        var trimmed: CMSampleBuffer?
        guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
          sampleRange: CFRange(location: first, length: end - first), sampleBufferOut: &trimmed) == noErr,
          let trimmed else { throw DVFilmExporter.failure("Cannot trim PCM to selected source interval") }
        if audioOrigin == nil {
          let origin = CMSampleBufferGetPresentationTimeStamp(trimmed)
          sourceStartOffsetSeconds = CMTimeGetSeconds(CMTimeSubtract(origin, start))
          guard sourceStartOffsetSeconds >= -0.000_000_1, sourceStartOffsetSeconds * rate < 1.01 else {
            throw DVFilmExporter.failure("Source audio does not start at the selected sample boundary")
          }
          audioOrigin = origin
        }
        guard let audioOrigin else { throw DVFilmExporter.failure("Missing source audio origin") }
        var timingCount = 0
        CMSampleBufferGetSampleTimingInfoArray(trimmed, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(trimmed, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: nil) == noErr else { throw DVFilmExporter.failure("PCM timing unavailable") }
        for i in timings.indices {
          // A video boundary can fall between PCM samples. Map the first whole
          // retained source sample to zero and disclose the sub-sample offset.
          // This is a constant phase translation, never rate conversion.
          timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, audioOrigin)
          if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, audioOrigin) }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: trimmed,
          sampleTimingEntryCount: timingCount, sampleTimingArray: &timings, sampleBufferOut: &shifted) == noErr,
          let shifted else { throw DVFilmExporter.failure("Cannot place PCM on derivative timeline") }
        guard abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(shifted)) * rate - Double(samplesWritten)) <= 1.01 else {
          throw DVFilmExporter.failure("Source PCM contains a timing gap or overlap; no silence or time-stretch is inserted")
        }
        try await DVFilmExporter.waitReady(input, writer: writer)
        guard input.append(shifted) else { throw writer.error ?? DVFilmExporter.failure("PCM writer rejected sample") }
        pcmDigest.update(data: try DVFilmExporter.pcmBytes(shifted))
        samplesWritten += Int64(end - first)
      }
      pending = output?.copyNextSampleBuffer()
      if pending == nil, reader?.status != .completed { throw reader?.error ?? DVFilmExporter.failure("Audio reader ended unexpectedly") }
    }
    if finish {
      guard abs(Double(samplesWritten) - CMTimeGetSeconds(duration) * rate) <= 1.01 else {
        throw DVFilmExporter.failure("Source PCM does not cover the selected video interval; shorten the range instead of fabricating audio")
      }
    }
  }
}
