// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Offline-tested live-preview building block. No driver access or tape commands.
import AVFoundation
import Foundation
import VideoToolbox
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif

/// Immutable CoreMedia format retained across the decode actor boundary.
struct DVInspectionSourceFormat: @unchecked Sendable {
  let value: CMVideoFormatDescription
}

/// The decoder transfers an immutable retained pixel buffer to presentation.
/// Consumers must not mutate pixels or attachments while another consumer uses it.
struct LiveDVDecodedFrame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let timecode: String?
  let sourceOrdinal: UInt64
  let isPAL: Bool
}

enum LiveDVDecodeError: Error {
  case malformedFrame
  case nativeFailure(String, OSStatus)
  case noDecodedImage
}

/// Serial VideoToolbox ownership; no queued unbounded decode tasks belong here.
/// The caller must admit one in-flight frame and retain/drop preview work
/// separately from the raw transport archive. Dropped previews are not raw loss.
actor LiveDVFrameDecoder {
  private var session: NativeDecoderSession?
  private var format: CMVideoFormatDescription?
  private var sourceIsPAL: Bool?
  private var sourceIsDVCPROPAL = false
  private var fieldProcessor: DVMetalFieldProcessor?

  func reset() {
    session = nil
    format = nil
    sourceIsPAL = nil
    sourceIsDVCPROPAL = false
  }

  func decode(_ bytes: Data, ordinal: UInt64, timecode: String?,
    viewingMode: DVViewingMode = .standard,
    sourceFormat: DVInspectionSourceFormat? = nil,
    extremeZebras: Bool = false, forensicDVCPROPAL: Bool = false) throws -> LiveDVDecodedFrame {
    guard bytes.count == 120_000 || bytes.count == 144_000,
      bytes[0] >> 5 == 0, bytes[1] >> 4 == 0, bytes[2] == 0,
      ((bytes[3] & 0x80) != 0) == (bytes.count == 144_000),
      ordinal <= UInt64(Int64.max / 1001)
    else { throw LiveDVDecodeError.malformedFrame }
    let pal = bytes.count == 144_000
    guard !forensicDVCPROPAL || pal else { throw LiveDVDecodeError.malformedFrame }
    if sourceIsPAL != pal || sourceIsDVCPROPAL != forensicDVCPROPAL { reset() }
    if session == nil {
      var description: CMVideoFormatDescription?
      try check(
        CMVideoFormatDescriptionCreate(
          allocator: kCFAllocatorDefault,
          codecType: forensicDVCPROPAL ? kCMVideoCodecType_DVCProPAL : (pal ? kCMVideoCodecType_DVCPAL : kCMVideoCodecType_DVCNTSC),
          width: 720, height: pal ? 576 : 480,
          extensions: sourceFormat.flatMap { CMFormatDescriptionGetExtensions($0.value) },
          formatDescriptionOut: &description), "create DV format")
      guard let description else { throw LiveDVDecodeError.noDecodedImage }
      var created: VTDecompressionSession?
      try check(
        VTDecompressionSessionCreate(
          allocator: kCFAllocatorDefault,
          formatDescription: description, decoderSpecification: nil,
          imageBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
          ] as CFDictionary, outputCallback: nil, decompressionSessionOut: &created),
        "create DV decoder")
      guard let created else { throw LiveDVDecodeError.noDecodedImage }
      do {
        try check(
          VTSessionSetProperty(
            created, key: kVTDecompressionPropertyKey_FieldMode,
            value: kVTDecompressionProperty_FieldMode_BothFields), "request both fields")
      } catch {
        VTDecompressionSessionInvalidate(created)
        throw error
      }
      format = description
      session = NativeDecoderSession(created)
      sourceIsPAL = pal
      sourceIsDVCPROPAL = forensicDVCPROPAL
    }
    guard let session, let format else { throw LiveDVDecodeError.noDecodedImage }
    let nativeSession = session.value
    let block = try Self.makeBlock(bytes)
    let duration = CMTime(value: pal ? 1 : 1001, timescale: pal ? 25 : 30000)
    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: CMTime(
        value: Int64(ordinal) * (pal ? 1 : 1001), timescale: duration.timescale),
      decodeTimeStamp: .invalid)
    var size = bytes.count
    var sample: CMSampleBuffer?
    try check(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sample), "create compressed DV sample")
    guard let sample else { throw LiveDVDecodeError.noDecodedImage }
    let result = DecodeResult()
    try check(
      VTDecompressionSessionDecodeFrame(
        nativeSession, sampleBuffer: sample,
        flags: [], infoFlagsOut: nil
      ) { status, _, image, _, _ in
        result.store(status: status, image: image)
      }, "submit DV frame")
    try check(VTDecompressionSessionWaitForAsynchronousFrames(nativeSession), "finish DV frame")
    let decoded = result.load()
    try check(decoded.0, "decode DV frame")
    guard let pixel = decoded.1 else { throw LiveDVDecodeError.noDecodedImage }
    // Geometry/color evidence from the file format remains attached even when
    // a decoder omits propagation. No default matrix/primaries are invented.
    if let sourceFormat {
      let mappings: [(CFString, CFString)] = [
        (kCMFormatDescriptionExtension_PixelAspectRatio, kCVImageBufferPixelAspectRatioKey),
        (kCMFormatDescriptionExtension_CleanAperture, kCVImageBufferCleanApertureKey),
        (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
        (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
        (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey),
        (kCMFormatDescriptionExtension_ChromaLocationTopField, kCVImageBufferChromaLocationTopFieldKey),
        (kCMFormatDescriptionExtension_ChromaLocationBottomField, kCVImageBufferChromaLocationBottomFieldKey),
        (kCMFormatDescriptionExtension_FieldCount, kCVImageBufferFieldCountKey),
        (kCMFormatDescriptionExtension_FieldDetail, kCVImageBufferFieldDetailKey)
      ]
      for (sourceKey, destinationKey) in mappings {
        // Decoder output tags take precedence (notably after chroma upsampling).
        // Retain source tags only where the decoder provided no output tag.
        if CVBufferCopyAttachment(pixel, destinationKey, nil) == nil,
          let value = CMFormatDescriptionGetExtension(sourceFormat.value, extensionKey: sourceKey) {
          CVBufferSetAttachment(pixel, destinationKey, value, .shouldPropagate)
        }
      }
    }
    let presented: CVPixelBuffer
    if viewingMode == .standard && !extremeZebras { presented = pixel }
    else {
      if fieldProcessor == nil { fieldProcessor = try DVMetalFieldProcessor() }
      guard let fieldProcessor else { throw LiveDVDecodeError.noDecodedImage }
      presented = try fieldProcessor.process(pixel, mode: viewingMode, extremeZebras: extremeZebras)
    }
    return LiveDVDecodedFrame(
      pixelBuffer: presented, timecode: timecode,
      sourceOrdinal: ordinal, isPAL: pal)
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw LiveDVDecodeError.nativeFailure(operation, status) }
  }

  nonisolated private static func makeBlock(_ bytes: Data) throws -> sending CMBlockBuffer {
    var block: CMBlockBuffer?
    let allocated = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0,
      blockBufferOut: &block)
    guard allocated == noErr, let block else {
      throw LiveDVDecodeError.nativeFailure("allocate DV frame", allocated)
    }
    let copied = bytes.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: bytes.count)
    }
    guard copied == noErr else { throw LiveDVDecodeError.nativeFailure("copy DV frame", copied) }
    return block
  }
}

// Confined to LiveDVFrameDecoder; this owner invalidates even if the actor is
// released without an explicit reset. No concurrent access is exposed.
private final class NativeDecoderSession: @unchecked Sendable {
  let value: VTDecompressionSession
  init(_ value: VTDecompressionSession) { self.value = value }
  deinit { VTDecompressionSessionInvalidate(value) }
}

private final class DecodeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var status: OSStatus = noErr
  private var image: CVPixelBuffer?
  func store(status: OSStatus, image: CVPixelBuffer?) {
    lock.withLock {
      self.status = status
      self.image = image
    }
  }
  func load() -> (OSStatus, CVPixelBuffer?) { lock.withLock { (status, image) } }
}
