// Read-only native video format audit. No audio renderer or driver is linked.
import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

@main struct OfflineVideoFormatAudit {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide one DV path") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let source = try await track.load(.formatDescriptions)[0]
    dumpFormat(source, label: "SOURCE")
    for pixelFormat in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr8] {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ])
      reader.add(output)
      guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
        let description = CMSampleBufferGetFormatDescription(sample),
        let pixel = CMSampleBufferGetImageBuffer(sample)
      else { fatalError("No decoded image") }
      dumpFormat(description, label: "DECODED_\(fourCC(pixelFormat))")
      for key in [
        kCVImageBufferFieldCountKey, kCVImageBufferFieldDetailKey,
        kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
      ] {
        print("PIXEL.\(key)=\(String(describing: CVBufferCopyAttachment(pixel, key, nil)))")
      }
      print("IOSurface=\(CVPixelBufferGetIOSurface(pixel) != nil)")
      reader.cancelReading()
    }
    var session: VTDecompressionSession?
    let create = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: source, decoderSpecification: nil,
      imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8]
        as CFDictionary,
      outputCallback: nil, decompressionSessionOut: &session)
    print("VT_SESSION_CREATE=\(create)")
    if let session {
      defer { VTDecompressionSessionInvalidate(session) }
      let set = VTSessionSetProperty(
        session, key: kVTDecompressionPropertyKey_FieldMode,
        value: kVTDecompressionProperty_FieldMode_BothFields)
      print("VT_REQUEST_BOTH_FIELDS=\(set)")
      let value = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
      value.initialize(to: nil)
      defer {
        value.deinitialize(count: 1)
        value.deallocate()
      }
      let get = VTSessionCopyProperty(
        session, key: kVTDecompressionPropertyKey_FieldMode,
        allocator: kCFAllocatorDefault, valueOut: value)
      print("VT_READ_FIELD_MODE=\(get) VALUE=\(String(describing: value.pointee))")
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      reader.add(output)
      guard reader.startReading() else {
        fatalError("No native DV sample")
      }
      // The raw DV reader can emit an empty timing marker first. It is not
      // compressed picture data and VideoToolbox correctly rejects it.
      var picture: CMSampleBuffer?
      for _ in 0..<8 {
        guard let candidate = output.copyNextSampleBuffer() else { break }
        if CMSampleBufferGetTotalSampleSize(candidate) > 0 {
          picture = candidate
          break
        }
      }
      guard let sample = picture else { fatalError("No nonempty native DV picture") }
      print("VT_INPUT_BYTES=\(CMSampleBufferGetTotalSampleSize(sample))")
      let decode = VTDecompressionSessionDecodeFrame(
        session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
      ) { status, _, image, pts, duration in
        print(
          "VT_DECODE_CALLBACK=\(status) PTS=\(CMTimeGetSeconds(pts)) DURATION=\(CMTimeGetSeconds(duration))"
        )
        if let image {
          for key in [
            kCVImageBufferFieldCountKey, kCVImageBufferFieldDetailKey,
            kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
          ] {
            print(
              "VT_BOTH_FIELDS.\(key)=\(String(describing: CVBufferCopyAttachment(image, key, nil)))"
            )
          }
        }
      }
      print("VT_DECODE_SUBMISSION=\(decode)")
      print("VT_DECODE_WAIT=\(VTDecompressionSessionWaitForAsynchronousFrames(session))")
      reader.cancelReading()
    }
  }

  static func dumpFormat(_ format: CMFormatDescription, label: String) {
    print("\(label).codec=\(fourCC(CMFormatDescriptionGetMediaSubType(format)))")
    for key in [
      kCMFormatDescriptionExtension_FieldCount, kCMFormatDescriptionExtension_FieldDetail,
      kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
      kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionExtension_PixelAspectRatio,
      kCMFormatDescriptionExtension_CleanAperture,
    ] {
      print(
        "\(label).\(key)=\(String(describing: CMFormatDescriptionGetExtension(format, extensionKey: key)))"
      )
    }
  }
  static func fourCC(_ value: FourCharCode) -> String {
    String(
      bytes: [
        UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
        UInt8((value >> 8) & 255), UInt8(value & 255),
      ], encoding: .ascii) ?? "unknown"
  }
}
