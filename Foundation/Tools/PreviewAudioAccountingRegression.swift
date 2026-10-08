// Offline read-only audit of preserved DV frames. No driver or playback output.
import CryptoKit
import Foundation

@main struct PreviewAudioAccountingRegression {
  static func main() throws {
    for file in CommandLine.arguments.dropFirst() {
      let url = URL(fileURLWithPath: file)
      let bytes = try Data(contentsOf: url)
      precondition(bytes.count > 0 && bytes.count.isMultiple(of: 120_000))
      let originalHash = SHA256.hash(data: bytes)
      var accounting = LiveAudioFrameAccounting()
      var unavailable = 0, unknown = 0
      for i in 0..<(bytes.count / 120_000) {
        let frame = bytes.subdata(in: (i * 120_000)..<((i + 1) * 120_000))
        let media = LiveDVMedia(frame: frame)
        let pcm = media?.pcm16(frame: frame)
        let state: LiveAudioFrameAccounting.SourceAudio
        if media?.audio == nil { unknown += 1; state = .unknownFormat }
        else if pcm == nil { unavailable += 1; state = .unavailablePCM }
        else { state = .usable }
        precondition(!accounting.observe(ordinal: UInt64(i), source: state))
      }
      precondition(accounting.omittedBeforeAudio == 0)
      precondition(accounting.unavailablePCMFrames == unavailable)
      precondition(accounting.unknownFormatFrames == unknown)
      let reread = try Data(contentsOf: url)
      precondition(SHA256.hash(data: reread) == originalHash)
      print("\(url.deletingLastPathComponent().lastPathComponent): frames=\(accounting.offeredFrames) unknown_format=\(unknown) unavailable_pcm=\(unavailable) omitted_before_audio=0 SOURCE_UNCHANGED")
    }
  }
}
