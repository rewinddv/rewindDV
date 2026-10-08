// OFFLINE ONLY: immutable local DV fixture; no driver access or audio output.
import AVFoundation
import CryptoKit
import Foundation

@main struct LiveMediaRegression {
  static func main() async throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let raw = try Data(contentsOf: url)
    var pcm: [Int16] = []
    let begin = Date()
    var nilAudio = 0
    for offset in stride(from: 0, to: raw.count, by: 120_000) {
      let frame = Data(raw[offset..<offset + 120_000])
      guard let facts = LiveDVMedia(frame: frame) else { fatalError("frame") }
      if offset == 0 { print("FACTS", facts) }
      if let samples = facts.pcm16(frame: frame) { pcm += samples } else { nilAudio += 1 }
    }
    print("LIGHTWEIGHT_SECONDS", Date().timeIntervalSince(begin), "NIL_AUDIO_FRAMES", nilAudio)
    precondition(nilAudio == 0)
    let asset = AVURLAsset(url: url)
    let audio = try await asset.loadTracks(withMediaType: .audio)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false])
    reader.add(output); precondition(reader.startReading())
    var reference: [Int16] = []
    var sourceCursor = 0
    var importerOmittedSamples = 0
    var bufferCount = 0
    while let s = output.copyNextSampleBuffer() {
      guard let b = CMSampleBufferGetDataBuffer(s) else { continue }
      var bytes = Data(count: CMBlockBufferGetDataLength(b))
      let status = bytes.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
      }
      precondition(status == noErr)
      let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      // Inspect each importer buffer separately: the native DV importer can
      // omit source samples at its two-second read boundaries. Do not change
      // source PCM to imitate that behavior or disguise it as global equality.
      let possible = stride(from: max(0, sourceCursor - 64), through: min(sourceCursor + 64, pcm.count - values.count), by: 2)
      let matches = possible.filter { start in
        Array(pcm[start..<start + min(64, values.count)]) == Array(values.prefix(64))
      }
      guard let start = matches.first else {
        print("NO_ALIGNMENT", bufferCount, sourceCursor, values.count)
        fatalError("Native importer buffer does not match source sample values")
      }
      let mismatches = (0..<values.count).filter { pcm[start + $0] != values[$0] }
      if start != sourceCursor || !mismatches.isEmpty {
        print("IMPORTER_BOUNDARY", bufferCount, "SOURCE_SAMPLE_DELTA", start - sourceCursor,
          "DIFFERENCES", mismatches.count)
      }
      precondition(mismatches.isEmpty)
      importerOmittedSamples += start - sourceCursor
      sourceCursor = start + values.count
      reference += values
      bufferCount += 1
    }
    precondition(reader.status == .completed)
    print("PCM_SAMPLES", pcm.count, "APPLE_REFERENCE_SAMPLES", reference.count)
    let count = min(pcm.count, reference.count)
    let differences = zip(pcm.prefix(count), reference.prefix(count)).filter { $0 != $1 }.count
    print("APPLE_PCM_DIFFERENCES", differences)
    print("APPLE_MATCHING_BUFFERS", bufferCount, "IMPORTER_OMITTED_SAMPLES", importerOmittedSamples,
      "UNREAD_SOURCE_TAIL_SAMPLES", pcm.count - sourceCursor)
    print("LIVE_MEDIA_APPLE_BUFFER_VALUES_PASS; global concatenated PCM is NOT byte-identical")
  }
}
