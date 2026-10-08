// Offline native regression. No driver, deck, or source mutation.
import AVFoundation
import Foundation

@main struct DVFilmExportRegression {
  static func main() async {
    do { try await run() }
    catch {
      try? FileHandle.standardError.write(contentsOf: Data("NATIVE_EXPORT_FAIL \(error)\n".utf8))
      exit(1)
    }
  }
  static func run() async throws {
    for height in [480, 576] {
      func buffer(_ marker: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 720, height, kCVPixelFormatType_422YpCbCr8, nil, &result) == 0,
          let result else { throw DVFilmExporter.failure("fixture allocation") }
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddress(result), Int32(marker), CVPixelBufferGetBytesPerRow(result) * height)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
      }
      let first = try buffer(37), second = try buffer(201)
      let woven = try DVFilmExporter.assemble(first: first, second: second)
      CVPixelBufferLockBaseAddress(woven, .readOnly)
      let base = CVPixelBufferGetBaseAddress(woven)!.assumingMemoryBound(to: UInt8.self)
      for row in 0..<height {
        for byte in 0..<1440 { precondition(base[row * CVPixelBufferGetBytesPerRow(woven) + byte] == (row % 2 == 1 ? 37 : 201)) }
      }
      CVPixelBufferUnlockBaseAddress(woven, .readOnly)
      precondition((CVBufferCopyAttachment(woven, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue == 1)
      print("FIELD_ASSEMBLY_PASS height=\(height) every_luma_chroma_byte_checked=true")
    }
    guard CommandLine.arguments.count == 3 else { throw DVFilmExporter.failure("Usage: regression source.dv new-output-parent") }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let parent = URL(fileURLWithPath: CommandLine.arguments[2])
    var runStart: UInt64 = 0, selected: UInt64?
    let scan = try DVFilmScan.scan(url: source) { observation in
      if !observation.boundaryReasons.isEmpty || observation.frame.audioRateHz == nil {
        runStart = observation.frame.ordinal + 1
      }
      if selected == nil, observation.frame.ordinal >= runStart + 29 { selected = runStart }
    }
    guard let selected else { throw DVFilmExporter.failure("Fixture lacks 30 continuous qualified frames") }
    let modes: [DVFilmMode] = scan.systems == ["625/50 PAL"] ? [.pal25p] : [.ntsc30p, .ntsc24p, .ntsc24pa]
    for mode in modes {
      // This is an operator-forced software integration test, NOT a claim that
      // the unknown camera fixture was recorded in any of these film modes.
      let plan = try DVFilmPlan(mode: mode, firstSourceFrame: selected, sourceFrameCount: 30, sourceSHA256: scan.sourceSHA256)
      let receipt = try await DVFilmExporter.export(source: source, plan: plan, destination: parent.appendingPathComponent(mode.rawValue))
      precondition(receipt.outputVideoFrames == (mode.isFilm ? 24 : 30))
      precondition(receipt.decodedPCMSHA256.count == 64)
      let map = try Data(contentsOf: parent.appendingPathComponent(mode.rawValue).appendingPathComponent("frame-map.ndjson"))
      let entries = try map.split(separator: 10).map { try JSONDecoder().decode(DVFilmExporter.PictureProvenance.self, from: Data($0)) }
      precondition(entries.count == Int(plan.outputFrameCount))
      for (index, entry) in entries.enumerated() {
        let expected = try plan.picture(UInt64(index))
        precondition(entry.picture == expected)
        precondition(entry.firstTemporalFieldSource.sha256.count == 64)
        precondition(entry.firstTemporalFieldSource.metadata.ordinal == entry.picture.firstFieldSourceFrame)
        precondition(entry.secondTemporalFieldSource.metadata.ordinal == entry.picture.secondFieldSourceFrame)
      }
      let preview = try await DVFilmExporter.previewCycle(source: source, plan: plan)
      precondition(preview.count == 4 && preview.allSatisfy { $0.count > 100 })
      print("NATIVE_EXPORT_PASS mode=\(mode.rawValue) frames=\(receipt.outputVideoFrames) audioSamples=\(receipt.outputAudioSamples) rate=\(receipt.audioSampleRate ?? 0) sourceUnchanged=true")
    }
  }
}
