// Read-only AVFoundation decode audit. No driver or capture code is linked.
import AVFoundation
import Foundation

@main
struct OfflineAudioAudit {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Provide one raw DV path") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
      let video = try await asset.loadTracks(withMediaType: .video).first
    else {
      fatalError("Audio and video tracks required")
    }
    let videoDuration = try await CMTimeGetSeconds(video.load(.timeRange).duration)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    var totalFrames = 0
    var decodedSeconds = 0.0
    var rates: Set<Double> = []
    var channelCounts: Set<UInt32> = []
    var buffers = 0
    var greatestBufferSeconds = 0.0
    while let sample = output.copyNextSampleBuffer() {
      guard let description = CMSampleBufferGetFormatDescription(sample),
        let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
        format.mSampleRate > 0
      else { fatalError("Missing PCM format") }
      let frames = CMSampleBufferGetNumSamples(sample)
      let seconds = Double(frames) / format.mSampleRate
      totalFrames += frames
      decodedSeconds += seconds
      buffers += 1
      greatestBufferSeconds = max(greatestBufferSeconds, seconds)
      rates.insert(format.mSampleRate)
      channelCounts.insert(format.mChannelsPerFrame)
    }
    guard reader.status == .completed else { throw reader.error! }
    print("video_duration_seconds=\(videoDuration)")
    print("decoded_pcm_frames=\(totalFrames)")
    print("decoded_pcm_duration_seconds=\(decodedSeconds)")
    print("decoded_rates_hz=\(rates.sorted())")
    print("decoded_channel_counts=\(channelCounts.sorted())")
    print("decoded_buffers=\(buffers)")
    print("greatest_buffer_seconds=\(greatestBufferSeconds)")
    print("audio_minus_video_seconds=\(decodedSeconds - videoDuration)")
    // This is a decoder audit, not raw audio-bitstream preservation proof.
  }
}
