// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Metal
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif

/// Confined to the decoder actor. Ordinary field views retain YCbCr; optional
/// solid signal-limit overlays produce a BT.601 RGB display derivative. The timed,
/// color-managed sink remains AVSampleBufferVideoRenderer.
/// Input 2vuy is decoder-upsampled 4:2:2, not the original DV 4:1:1/4:2:0 samples.
final class DVMetalFieldProcessor {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private var input: MTLBuffer?
  private var output: MTLBuffer?
  private var pool: CVPixelBufferPool?
  private var poolHeight = 0
  private var poolZebras = false

  // Metal device/queue/pipeline are immutable, thread-safe shared resources.
  // Pixel pools and in-flight buffers remain per-decoder, actor-confined.
  private struct Context: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    init() throws {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw Failure("Metal is unavailable; choose Standard (Apple).")
      }
      self.device = device; self.queue = queue
      let library = try device.makeLibrary(source: DVMetalFieldProcessor.kernel, options: nil)
      guard let function = library.makeFunction(name: "dvFields") else { throw Failure("Missing field kernel") }
      pipeline = try device.makeComputePipelineState(function: function)
    }
  }
  private static let context = Result { try Context() }

  init() throws {
    let context = try Self.context.get()
    device = context.device; queue = context.queue; pipeline = context.pipeline
  }

  func process(_ source: CVPixelBuffer, mode: DVViewingMode,
    extremeZebras: Bool = false) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_422YpCbCr8,
      CVPixelBufferGetWidth(source) == 720,
      [480, 576].contains(CVPixelBufferGetHeight(source)) else {
      throw Failure("Unsupported inspection pixel format; no guessed conversion.")
    }
    let height = CVPixelBufferGetHeight(source), stride = 720 * 2, count = stride * height
    // DV SD uses BT.601. Never silently apply this display conversion to another matrix.
    if extremeZebras, let matrix = CVBufferCopyAttachment(source, kCVImageBufferYCbCrMatrixKey, nil),
      !CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
      throw Failure("Measured signal limits require the DV BT.601 matrix.")
    }
    let outputStride = extremeZebras ? 720 * 4 : stride
    if input?.length != count {
      input = device.makeBuffer(length: count, options: .storageModeShared)
    }
    if output?.length != outputStride * height {
      output = device.makeBuffer(length: outputStride * height, options: .storageModeShared)
    }
    guard let input, let output else { throw Failure("Cannot allocate bounded Metal buffers") }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw Failure("Cannot read decoded raster") }
    do {
      defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(source) else { throw Failure("Missing decoded raster") }
      for row in 0..<height {
        memcpy(input.contents().advanced(by: row * stride),
          base.advanced(by: row * CVPixelBufferGetBytesPerRow(source)), stride)
      }
    }
    guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw Failure("Cannot encode field presentation")
    }
    var parameters = SIMD4<UInt32>(UInt32(stride), UInt32(height), mode.shaderMode, extremeZebras ? 1 : 0)
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(output, offset: 0, index: 1)
    encoder.setBytes(&parameters, length: MemoryLayout.size(ofValue: parameters), index: 2)
    encoder.dispatchThreads(MTLSize(width: stride, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
    encoder.endEncoding()
    // Off-main, actor-serialized completion: buffers cannot be reused while GPU owns them.
    command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw Failure("Metal field processing failed: \(String(describing: command.error))") }
    if poolHeight != height || poolZebras != extremeZebras {
      pool = nil
      let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
        kCVPixelBufferWidthKey: 720, kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: extremeZebras ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_422YpCbCr8,
        kCVPixelBufferIOSurfacePropertiesKey: [:]
      ] as CFDictionary, &pool)
      guard status == kCVReturnSuccess else { throw Failure("Cannot create inspection buffer pool") }
      poolHeight = height
      poolZebras = extremeZebras
    }
    guard let pool else { throw Failure("Missing inspection pool") }
    var destination: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: 24] as CFDictionary, &destination)
    guard status == kCVReturnSuccess, let destination else { throw Failure("Inspection presentation pool is full") }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw Failure("Cannot write preview raster") }
    do {
      defer { CVPixelBufferUnlockBaseAddress(destination, []) }
      guard let base = CVPixelBufferGetBaseAddress(destination) else { throw Failure("Missing preview raster") }
      for row in 0..<height {
        memcpy(base.advanced(by: row * CVPixelBufferGetBytesPerRow(destination)),
          output.contents().advanced(by: row * outputStride), outputStride)
      }
    }
    // Preserve color/geometry/chroma provenance on a NEW buffer. Do not alter source.
    CVBufferPropagateAttachments(source, destination)
    if extremeZebras {
      // RGB is a display derivative; YCbCr sampling tags no longer describe it.
      for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey] { CVBufferRemoveAttachment(destination, key) }
      CVBufferSetAttachment(destination, "rewindDV.SignalLimits" as CFString,
        "decoded_luma_0_255; suspected_only" as CFString, .shouldPropagate)
    }
    // Baked raster: prevent the downstream compositor applying another field filter.
    CVBufferSetAttachment(destination, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
    CVBufferRemoveAttachment(destination, kCVImageBufferFieldDetailKey)
    CVBufferSetAttachment(destination, "rewindDV.ViewMode" as CFString, mode.rawValue as CFString, .shouldPropagate)
    return destination
  }

  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  private static let kernel = """
  #include <metal_stdlib>
  using namespace metal;
  float fieldByte(device const uchar *src, uint x, uint y, constant uint4 &p) {
    float value = src[y * p.x + x];
    if (p.z == 3) value = floor((float(src[(y == 0 ? 0 : y-1)*p.x+x]) +
      2.0f*value + float(src[min(p.y-1,y+1)*p.x+x]) + 2.0f)/4.0f);
    return value;
  }
  kernel void dvFields(device const uchar *src [[buffer(0)]],
                       device uchar *dst [[buffer(1)]],
                       constant uint4 &p [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.x || xy.y >= p.y) return;
    uint y = xy.y;
    if (p.z == 1) y = (y / 2) * 2;
    if (p.z == 2) y = min(p.y - 1, (y / 2) * 2 + 1);
    if (p.w == 1) {
      if (xy.x >= p.x / 2) return;
      uint x = xy.x, pair = (x / 2) * 4, luma = x * 2 + 1;
      // Classify the decoded source BEFORE field blending or RGB range expansion.
      uint observed = src[y*p.x+luma];
      float Y = (fieldByte(src, luma, y, p)-16.0f)/219.0f;
      float Cb = (fieldByte(src, pair, y, p)-128.0f)/224.0f;
      float Cr = (fieldByte(src, pair+2, y, p)-128.0f)/224.0f;
      float3 rgb = clamp(float3(Y+1.402f*Cr, Y-0.344136f*Cb-0.714136f*Cr,
        Y+1.772f*Cb), 0.0f, 1.0f);
      if (observed == 255) rgb = float3(1,0,0);
      if (observed == 0) rgb = float3(0.8f,0,1);
      uint offset = (xy.y*(p.x/2)+x)*4;
      dst[offset] = uchar(round(rgb.b*255)); dst[offset+1] = uchar(round(rgb.g*255));
      dst[offset+2] = uchar(round(rgb.r*255)); dst[offset+3] = 255;
      return;
    }
    uint value = src[y * p.x + xy.x];
    if (p.z == 3) {
      uint above = y == 0 ? 0 : y - 1;
      uint below = min(p.y - 1, y + 1);
      value = (uint(src[above * p.x + xy.x]) + 2 * value + uint(src[below * p.x + xy.x]) + 2) / 4;
    }
    dst[xy.y * p.x + xy.x] = uchar(value);
  }
  """
}
