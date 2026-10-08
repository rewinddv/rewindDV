// Offline, silent GPU tests. No driver linked or hardware commands.
import AVFoundation
import Foundation

@main struct DVMetalFieldRegression {
  static func require(_ value: Bool, _ message: String) throws {
    guard value else { throw DVMetalFieldProcessor.Failure(message) }
  }
  static func bytes(_ pixel: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
    let width = CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA ? 2880 : 1440
    return (0..<CVPixelBufferGetHeight(pixel)).flatMap { row in
      Array(UnsafeBufferPointer(start: base.advanced(by: row * CVPixelBufferGetBytesPerRow(pixel)), count: width))
    }
  }
  static func main() async throws {
    let processor = try DVMetalFieldProcessor()
    for height in [480, 576] {
      var pixel: CVPixelBuffer?
      let status = CVPixelBufferCreate(kCFAllocatorDefault, 720, height, kCVPixelFormatType_422YpCbCr8,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
      try require(status == noErr, "allocate synthetic buffer")
      let source = pixel!
      CVPixelBufferLockBaseAddress(source, [])
      let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
      for row in 0..<height {
        for x in 0..<1440 { base[row * CVPixelBufferGetBytesPerRow(source) + x] = UInt8((row * 37 + x * 13) % 256) }
      }
      CVPixelBufferUnlockBaseAddress(source, [])
      CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalBottomFirst, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey,
        [kCVImageBufferCleanApertureWidthKey: 704,
         kCVImageBufferCleanApertureHeightKey: height,
         kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
         kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary, .shouldPropagate)
      CVBufferSetAttachment(source, kCVImageBufferPixelAspectRatioKey,
        [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 8,
         kCVImageBufferPixelAspectRatioVerticalSpacingKey: 9] as CFDictionary, .shouldPropagate)
      let original = bytes(source)
      for mode in [DVViewingMode.weave, .top, .bottom, .blend] {
        let result = try processor.process(source, mode: mode)
        let actual = bytes(result)
        for y in 0..<height {
          for x in 0..<1440 {
            let row = mode.sourceRow(for: y, height: height)
            let expected: UInt8
            if mode == .blend {
              expected = UInt8((Int(original[max(0, y-1)*1440+x]) + 2*Int(original[y*1440+x]) + Int(original[min(height-1,y+1)*1440+x]) + 2)/4)
            } else { expected = original[row*1440+x] }
            try require(actual[y*1440+x] == expected, "GPU pixel mismatch: \(mode), \(x), \(y)")
          }
        }
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey,
          kCVImageBufferTransferFunctionKey, kCVImageBufferPixelAspectRatioKey,
          kCVImageBufferCleanApertureKey, kCVImageBufferChromaLocationTopFieldKey,
          kCVImageBufferChromaLocationBottomFieldKey] {
          try require(CFEqual(CVBufferCopyAttachment(source, key, nil), CVBufferCopyAttachment(result, key, nil)), "metadata lost")
        }
        try require((CVBufferCopyAttachment(result, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue == 1, "derived presentation must not be deinterlaced again")
        try require(CVBufferCopyAttachment(result, kCVImageBufferFieldDetailKey, nil) == nil, "derived raster must not carry temporal field order")
        try require(CFEqual(CVBufferCopyAttachment(source, kCVImageBufferFieldDetailKey, nil), kCVImageBufferFieldDetailTemporalBottomFirst), "source field order changed")
        try require(bytes(source) == original, "source pixels changed")
        try require((CVBufferCopyAttachment(source, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue == 2, "source metadata changed")
        print("PASS GPU \(height) \(mode.rawValue): every raster byte and retained metadata")
      }
    }
    // Neutral chroma ramp: both endpoint polarities, all recoverable codes,
    // every field mode, and NTSC/PAL. Check every pixel, including stripe gaps.
    for height in [480, 576] {
      var pixel: CVPixelBuffer?
      CVPixelBufferCreate(kCFAllocatorDefault, 720, height, kCVPixelFormatType_422YpCbCr8,
        nil, &pixel)
      let source = pixel!
      CVPixelBufferLockBaseAddress(source, [])
      let base = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<height {
        for x in 0..<720 {
          base[y*CVPixelBufferGetBytesPerRow(source)+x*2] = 128
          base[y*CVPixelBufferGetBytesPerRow(source)+x*2+1] = UInt8((x+y)%256)
        }
      }
      CVPixelBufferUnlockBaseAddress(source, [])
      let before = bytes(source)
      for mode in DVViewingMode.allCases {
        let actual = bytes(try processor.process(source, mode: mode, extremeZebras: true))
        for y in 0..<height {
          for x in 0..<720 {
            let row = mode.sourceRow(for: y, height: height)
            let observed = (x+row)%256
            var value = observed
            if mode == .blend {
              value = (((x+max(0,y-1))%256) + 2*observed + ((x+min(height-1,y+1))%256) + 2)/4
            }
            let gray = UInt8((min(1.0,max(0.0,Double(value-16)/219))*255).rounded())
            var expected: [UInt8] = [gray,gray,gray,255]
            if observed == 255 { expected = [0,0,255,255] }
            if observed == 0 { expected = [255,0,204,255] }
            let offset = (y*720+x)*4
            try require(Array(actual[offset..<offset+4]) == expected, "solid clipping overlay mismatch \(height) \(mode) \(x),\(y)")
          }
        }
        try require(bytes(source) == before, "clipping overlay modified source")
        // Returning to ordinary presentation must reset output format/pool.
        try require(bytes(try processor.process(source, mode: .weave)) == before, "toggle-off altered raster")
        print("PASS solid clipping overlay \(height) \(mode): every endpoint pixel covered, interior values unmarked, source unchanged, toggle off")
      }
    }
    if CommandLine.arguments.count > 1 {
      let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
      defer { try? file.close() }
      let data = try file.read(upToCount: 120_000)!
      let decoder = LiveDVFrameDecoder()
      let native = try await decoder.decode(data, ordinal: 0, timecode: nil)
      let woven = try await decoder.decode(data, ordinal: 0, timecode: nil, viewingMode: .weave)
      try require(bytes(native.pixelBuffer) == bytes(woven.pixelBuffer), "native decoded raster changed in weave")
      print("PASS real NTSC DV: both-fields decode and Metal weave are byte-identical")
    }
    print("DV_METAL_FIELD_REGRESSION_PASS; display/camera qualification remains separate")
  }
}
