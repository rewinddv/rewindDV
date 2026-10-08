import Foundation
import CoreMedia
import CoreVideo
import Testing
import RewindDVArchiveCore
@testable import RewindDVMonitorCore

private func techFixture(pal: Bool = false, smpte: Bool = false,
  audioCode: UInt8 = 0, aspect: UInt8 = 0, broadcastSystem: UInt8 = 0, invalidVAUX: Bool = false,
  camera: [UInt8]? = nil) throws -> DVMetadataInventory {
  var bytes = Data()
  for sequence in 0..<(pal ? 12 : 10) {
    func block(_ section: Int, _ number: Int) {
      var b = Data(repeating: 0xff, count: 80)
      b[0] = UInt8(section << 5); b[1] = UInt8(sequence << 4) | 4; b[2] = UInt8(number)
      if section == 0 {
        b[3] = pal ? 0x80 : 0
        for i in 4...7 { b[i] = smpte ? 1 : 0 }
        if invalidVAUX { b[6] |= 0x80 }
      }
      if section == 1 {
        b.replaceSubrange(6..<11, with: [0x13, 0x60, 0x08, 0x01, 0x00])
      }
      if section == 2 {
        b.replaceSubrange(3..<8, with: [0x60, 0xff, 0xff, pal ? 0xe0 : 0xc0, 0xff])
        b.replaceSubrange(8..<13, with: [0x61, 0, 0xc8 | aspect, 0xf0 | broadcastSystem, 0xff])
        b.replaceSubrange(13..<18, with: [0x62, 0xff, 0xe8, 0xc2, 0x02])
        b.replaceSubrange(18..<23, with: [0x63, 0xff, 0x80, 0x89, 0xd3])
        if let camera { b.replaceSubrange(23..<28, with: camera) }
      }
      if section == 3 { b.replaceSubrange(3..<8, with: [0x50, 0xd4, 0, pal ? 0xa0 : 0x80, 0xc0 | audioCode]) }
      if section == 4 { b[3] = 0 }
      bytes.append(b)
    }
    block(0, 0)
    for i in 0..<2 { block(1, i) }
    for i in 0..<3 { block(2, i) }
    for i in 0..<9 { block(3, i); for j in (i * 15)..<(i * 15 + 15) { block(4, j) } }
  }
  return try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0)
}

private func frameBytes(_ inventory: DVMetadataInventory) -> Data {
  var bytes = Data(repeating: 0xff, count: inventory.frameByteCount)
  for extent in inventory.extents {
    let start = Int(extent.sourceByteOffset - inventory.frameByteOffset)
    bytes.replaceSubrange(start..<(start + extent.bytes.count), with: extent.bytes)
  }
  return bytes
}

@Test func playbackClockReadsExactFrameAndNeverBorrowsFileClock() throws {
  var frame = frameBytes(try techFixture())
  let original = DVTechnicalSpecifications.frameRecordedClock(frame)
  #expect(original.value == "Thursday, 28 February 2002 @ 13:09:00")
  let specs = DVTechnicalSpecifications.make(path: "test.dv", byteCount: 120_000, inventory: try techFixture())
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 2 {
    frame[at + 20] = 0x81 // one recorded second later, in every time repetition
  }
  let next = DVTechnicalSpecifications.frameRecordedClock(frame)
  #expect(next.value == "Thursday, 28 February 2002 @ 13:09:01")
  #expect(value(specs.playbackReport(sampledFrame: DVTechnicalSpecifications.make(path: "", byteCount: 120_000, inventory: try DVMetadataInventory.inspect(frame: frame, ordinal: 1, byteOffset: 120_000))), "General", "Recorded date & time") == next.value)
  #expect(value(specs.playbackReport(sampledFrame: nil), "General", "Recorded date & time")?.hasPrefix("Unavailable") == true)
  frame[3 * 80 + 20] = 0x82
  #expect(DVTechnicalSpecifications.frameRecordedClock(frame).value.contains("conflicting times"))
  for at in stride(from: 0, to: frame.count, by: 80) where frame[at] >> 5 == 2 {
    frame.replaceSubrange((at + 13)..<(at + 23), with: Array(repeating: UInt8(0xff), count: 10))
  }
  #expect(DVTechnicalSpecifications.frameRecordedClock(frame).value.hasPrefix("Unavailable"))
}

@Test(arguments: [false, true]) func playbackClockRejectsInvalidStructureAndTransmission(pal: Bool) throws {
  let original = frameBytes(try techFixture(pal: pal))
  for kind in 0..<5 {
    var bytes = original
    switch kind {
    case 0: bytes[80 + 2] = 99
    case 1: bytes[12_000 + 3] ^= 0x80
    case 2: bytes[12_000 + 4] = 1
    case 3: bytes[12_000 + 6] |= 0x80
    default: bytes[3 * 80 + 1] |= 0x08
    }
    #expect(DVTechnicalSpecifications.frameRecordedClock(bytes).value.hasPrefix("Unavailable"))
  }
  #expect(DVTechnicalSpecifications.frameRecordedClock(Data()).value.hasPrefix("Unavailable"))
}

@Test(arguments: [false, true]) func sourceAudioAuditCountsExactSamplesWithoutVideoSubstitution(pal: Bool) throws {
  let data = frameBytes(try techFixture(pal: pal))
  let inspected = try DVFrameForensics.inspect(frame: data, ordinal: 0, offset: 0)
  var audit = DVSourceFileAudit()
  for _ in 0..<30 { audit.append(inspected) }
  let count = pal ? 1916 : 1600 // fixture AF_SIZE=20
  #expect(audit.channels.count == 2)
  #expect(audit.channels.allSatisfy { $0.samples == UInt64(count * 30) && $0.assessedFrames == 30 })
  let exact = try #require(audit.sections.first { $0.title == "Exact source audio · channel 1" })
  #expect(exact.rows.first { $0.label == "Recorded audio duration" }?.value == String(format: "%.6f s", Double(count * 30) / 48_000))
  #expect(exact.rows.first { $0.label == "Audio minus video duration" }?.value == (pal ? "-2.500 ms" : "-1.000 ms"))
  var missing = data
  for start in stride(from: 0, to: missing.count, by: 12_000) { missing[start + 5] |= 0x80 }
  audit.append(try DVFrameForensics.inspect(frame: missing, ordinal: 30, offset: UInt64(data.count * 30)))
  #expect(audit.sections.filter { $0.title.hasPrefix("Exact source audio") }.allSatisfy {
    $0.rows.first { $0.label == "Recorded audio duration" }?.value.hasPrefix("Unavailable") == true
  })
}

@Test func sourceAudioAuditWithholdsChangingRateAndRejectsMalformedFile() throws {
  var audit = DVSourceFileAudit()
  for code: UInt8 in [0, 8] {
    audit.append(try DVFrameForensics.inspect(frame: frameBytes(try techFixture(audioCode: code)), ordinal: 0, offset: 0))
  }
  #expect(audit.channels.allSatisfy { $0.formatChanged })
  #expect(audit.sections.filter { $0.title.hasPrefix("Exact source audio") }.allSatisfy {
    $0.rows.first { $0.label == "Recorded audio duration" }?.value.hasPrefix("Unavailable") == true
  })
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(repeating: 0, count: 120_000).write(to: url)
  #expect(throws: Error.self) { try DVSourceFileAudit.read(url: url) }
}

@Test func motionSummaryExposesQualifiedSpeedAndCombinedZoom() throws {
  var bytes = frameBytes(try techFixture(camera: [0x71, 0xff, 0xff, 0xff, 0x23]))
  for at in stride(from: 0, to: bytes.count, by: 80) where bytes[at] >> 5 == 3 {
    bytes.replaceSubrange((at + 3)..<(at + 8), with: [0x51, 0, 0, 0x20, 0x80])
  }
  let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: 12, byteOffset: 0)
  let rows = DVTechnicalSpecifications.recordedMotionSections(DVPackSemanticReport.inspect(inventory))[0].rows
  #expect(rows.first { $0.label == "Recorded speed" }?.value.hasPrefix("1×") == true)
  #expect(rows.first { $0.label == "Electronic zoom magnitude" }?.value.hasPrefix("2.3×") == true)
  #expect(rows.allSatisfy { $0.evidence.contains("frame 12") })
  #expect(DVMetadataPresentation.summarySections([.init(title: "Recorded motion / lens", rows: rows)]).count == 1)
}

@Test(arguments: [false, true]) func cameraMotionEvidenceReachesCaptureAndPlaybackReports(pal: Bool) throws {
  let inventory = try techFixture(pal: pal, camera: [0x71, 30, 62 | 64, 0xff, 126])
  let specs = DVTechnicalSpecifications.make(path: "test.dv", byteCount: UInt64(inventory.frameByteCount), inventory: inventory)
  let title = "Recorded camera motion / lens codes"
  for report in [specs, specs.liveReport(progress: [])] {
    let rows = try #require(report.sections.first { $0.title == title }?.rows)
    #expect(rows.first { $0.label == "Vertical pan speed code" }?.value.hasPrefix("> 29 lines/field") == true)
    #expect(rows.first { $0.label == "Horizontal pan speed code" }?.value.hasPrefix("> 122 pixels/field") == true)
    #expect(rows.first { $0.label == "Horizontal pan direction code" }?.value.hasPrefix("Against raster scanning") == true)
    let zoom = try #require(rows.first { $0.label == "Electronic zoom magnitude" })
    #expect(zoom.value == "≥ 8× — " + DVMetadataConfidence.normativeConfirmed.label)
    #expect(zoom.evidence.contains("PRIMARY_STANDARD") && zoom.evidence.contains("§10.2"))
    #expect(zoom.evidence.contains("71 1E 7E FF 7E") && zoom.evidence.contains("SHA-256"))
  }
  let professional = try techFixture(smpte: true, camera: [0x71, 30, 62, 0xff, 126])
  let fields = DVPackSemanticReport.inspect(professional).packs.filter { $0.typeHex == "0x71" }.flatMap(\.fields)
  #expect(!fields.contains { $0.id == "HP_SPEED" || $0.id == "ZOOM_MAGNITUDE" })
}
private func value(_ report: DVTechnicalSpecifications, _ section: String, _ label: String) -> String? {
  report.sections.first { $0.title == section }?.rows.first { $0.label == label }?.value
}

private func geometryFixture(pal: Bool = false, apertureWidth: Double? = 704,
  horizontal: Double? = 10, vertical: Double = 11) throws -> CMVideoFormatDescription {
  var extensions: [String: Any] = [:]
  if let horizontal {
    extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String] = [
      kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: horizontal,
      kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: vertical]
  }
  if let apertureWidth {
    extensions[kCMFormatDescriptionExtension_CleanAperture as String] = [
      kCMFormatDescriptionKey_CleanApertureWidth as String: apertureWidth,
      kCMFormatDescriptionKey_CleanApertureHeight as String: pal ? 576 : 480,
      kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String: 0,
      kCMFormatDescriptionKey_CleanApertureVerticalOffset as String: 0]
  }
  var format: CMVideoFormatDescription?
  #expect(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
    codecType: pal ? kCMVideoCodecType_DVCPAL : kCMVideoCodecType_DVCNTSC,
    width: 720, height: pal ? 576 : 480, extensions: extensions as CFDictionary,
    formatDescriptionOut: &format) == noErr)
  return try #require(format)
}

@Test(arguments: [false, true]) func appleGeometryAccountsForApertureAndPAR(pal: Bool) throws {
  let format = try geometryFixture(pal: pal, horizontal: pal ? 12 : 10)
  let geometry = DVAppleGeometry.inspect(format: format)
  func v(_ label: String) -> String? { geometry.rows.first { $0.label == label }?.value }
  #expect(v("Stored dimensions") == (pal ? "720 × 576" : "720 × 480"))
  #expect(v("Storage aspect ratio") == (pal ? "5:4" : "3:2"))
  #expect(v("Clean aperture") == (pal ? "704 × 576" : "704 × 480"))
  #expect(v("Pixel aspect ratio (PAR / sample AR)") == (pal ? "12:11" : "10:11"))
  #expect(v("Display aspect ratio (DAR)") == "4:3")
  #expect(v("Presentation dimensions") == (pal ? "768 × 576" : "640 × 480"))
  // Reading the snapshot must not modify the original description.
  #expect(DVAppleGeometry.inspect(format: format) == geometry)
}

@Test func appleGeometryDoesNotInventMissingOrInvalidPAROrAperture() throws {
  for pair in [(nil as Double?, 11.0), (0.0, 11.0), (-1.0, 11.0), (10.0, 0.0), (10.5, 11.0)] {
    let geometry = DVAppleGeometry.inspect(format: try geometryFixture(horizontal: pair.0, vertical: pair.1))
    #expect(geometry.displayRatio == nil)
    #expect(geometry.rows.first { $0.label == "Pixel aspect ratio (PAR / sample AR)" }?.isWarning == true)
  }
  let missing = DVAppleGeometry.inspect(format: try geometryFixture(apertureWidth: nil))
  #expect(missing.rows.first { $0.label == "Clean aperture" }?.value == "Not reported — full raster used")
  #expect(missing.rows.first { $0.label == "Display aspect ratio (DAR)" }?.value != "4:3")
  let invalid = DVAppleGeometry.inspect(format: try geometryFixture(apertureWidth: 800))
  #expect(invalid.displayRatio == nil)
}

@Test func geometryOverlaySeparatesTapeAppleAndPreviewWithoutChangingSource() throws {
  let specs = DVTechnicalSpecifications.make(path: "/letterbox.dv", byteCount: 120_000,
    inventory: try techFixture(aspect: 1))
  let original = specs
  let apple = DVAppleGeometry.inspect(format: try geometryFixture())
  let sections = specs.inspectorSections(apple: apple, preview: "16:9", appleScope: "Test source format")
  let rows = try #require(sections.first { $0.title == "Apple presentation geometry" }?.rows)
  #expect(rows.first { $0.label == "Aspect comparison" }?.value == "Agrees with tape-reported DAR")
  #expect(rows.first { $0.label == "Preview aspect — display only" }?.value == "16:9")
  #expect(value(specs, "Video", "Tape-reported display aspect ratio") == "4:3 — letterboxed")
  #expect(specs == original)
  let wide = DVAppleGeometry.inspect(format: try geometryFixture(horizontal: 40, vertical: 33))
  #expect(wide.rows.first { $0.label == "Display aspect ratio (DAR)" }?.value == "16:9")
  let conflict = specs.liveReport(progress: []).inspectorSections(apple: wide, preview: "4:3", appleScope: "Sampled frame 42")
  #expect(conflict.first { $0.title == "Apple presentation geometry" }?.rows.first { $0.label == "Aspect comparison" }?.isWarning == true)
  let unknown = specs.inspectorSections(apple: nil, preview: "4:3", appleScope: "No observation")
  #expect(unknown.first { $0.title == "Apple presentation geometry" }?.rows.first?.isWarning == true)
}

@Test func decodedGeometrySnapshotIsImmutableAcrossPreviewTagOverrides() throws {
  var buffer: CVPixelBuffer?
  #expect(CVPixelBufferCreate(kCFAllocatorDefault, 720, 480, kCVPixelFormatType_422YpCbCr8,
    nil, &buffer) == kCVReturnSuccess)
  let pixel = try #require(buffer)
  let source = try geometryFixture()
  for (key, destination) in [
    (kCMFormatDescriptionExtension_PixelAspectRatio, kCVImageBufferPixelAspectRatioKey),
    (kCMFormatDescriptionExtension_CleanAperture, kCVImageBufferCleanApertureKey)
  ] {
    CVBufferSetAttachment(pixel, destination, try #require(CMFormatDescriptionGetExtension(source, extensionKey: key)), .shouldPropagate)
  }
  let original = try #require(DVAppleGeometry.inspect(imageBuffer: pixel))
  #expect(original.rows.first { $0.label == "Display aspect ratio (DAR)" }?.value == "4:3")
  CVBufferSetAttachment(pixel, kCVImageBufferPixelAspectRatioKey,
    [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
  #expect(original.rows.first { $0.label == "Pixel aspect ratio (PAR / sample AR)" }?.value == "10:11")
  #expect(DVAppleGeometry.inspect(imageBuffer: pixel) != original)
}

@Test func cameraInspectorAppearsOnlyWhenObservedAndMatchesLiveEvidence() throws {
  let absent = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000,
    inventory: try techFixture())
  #expect(!absent.sections.contains { $0.title == "Recorded camera settings" })
  for pal in [false, true] {
    let specs = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: pal ? 144_000 : 120_000,
      inventory: try techFixture(pal: pal, camera: [0x70, 0xc0, 0x40, 0x64, 0x80]))
    #expect(value(specs, "Recorded camera settings", "Exposure mode") == "Manual — Confirmed")
    #expect(value(specs, "Recorded camera settings", "White-balance preset") == "Sunlight — Confirmed")
    #expect(value(specs, "Recorded camera settings", "Gain code") == "0 — Confirmed")
    let live = specs.liveReport(progress: [])
    #expect(value(live, "Recorded camera settings", "Exposure mode") == "Manual — Confirmed")
    let row = try #require(specs.sections.first { $0.title == "Recorded camera settings" }?.rows.first)
    #expect(row.evidence.contains("PRIMARY_STANDARD") && row.evidence.contains("SHA-256") && row.evidence.contains("70 C0 40 64 80"))
  }
  let invalid = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000,
    inventory: try techFixture(invalidVAUX: true, camera: [0x70, 0xc0, 0x40, 0x64, 0x80]))
  #expect(value(invalid, "Recorded camera settings", "Exposure mode")?.hasPrefix("Invalid") == true)
}

@Test func techSpecsMatchRequestedOrderAndExactNTSCArithmetic() throws {
  let specs = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 171_960_000, inventory: try techFixture())
  #expect(Array(specs.sections.prefix(3).map(\.title)) == ["General", "Video", "Audio"])
  #expect(specs.sections[0].rows.map(\.label) == ["Complete name", "Format", "Commercial name", "File size", "Duration", "Overall bit rate mode", "Overall bit rate", "Recorded date & time"])
  #expect(specs.sections[1].rows.map(\.label) == ["Bit rate", "Width", "Height", "Tape-reported display aspect ratio", "Frame rate mode", "Frame rate", "Standard", "Color space", "Chroma subsampling", "Bit depth", "Scan type", "Scan order", "Compression mode", "Bits/(Pixel*Frame)", "Time code of first frame", "Time code source", "Stream size"])
  #expect(value(specs, "General", "Duration") == "00:00:47.814")
  #expect(value(specs, "General", "Recorded date & time") == "Thursday, 28 February 2002 @ 13:09:00")
  #expect(value(specs, "General", "Commercial name") == "DV (DV25)")
  #expect(value(specs, "Video", "Bit rate") == "24.4 Mb/s")
  #expect(value(specs, "Video", "Frame rate") == "29.970 (30000/1001) FPS")
  #expect(value(specs, "Video", "Bits/(Pixel*Frame)") == "2.357")
  #expect(value(specs, "Video", "Scan order") == "Bottom Field First")
  #expect(value(specs, "Video", "Time code of first frame") == "00:01:08;20")
  #expect(value(specs, "Audio", "Bit rate") == "1536 kb/s")
  #expect(value(specs, "Audio", "Bit depth") == "16 bits")
}

@Test func techSpecsPALConsumerAndSMPTEChromaRemainDistinct() throws {
  for smpte in [false, true] {
    let specs = DVTechnicalSpecifications.make(path: "/pal.dv", byteCount: 3_600_000,
      inventory: try techFixture(pal: true, smpte: smpte, aspect: 2))
    #expect(value(specs, "Video", "Height") == "576 pixels")
    #expect(value(specs, "Video", "Frame rate") == "25.000 (25/1) FPS")
    #expect(value(specs, "Video", "Tape-reported display aspect ratio") == "16:9")
    #expect(value(specs, "Video", "Chroma subsampling") == (smpte ? "4:1:1" : "4:2:0"))
  }
}

@Test(arguments: [false, true]) func consumerAspectOneIsLetterboxedFourByThree(pal: Bool) throws {
  let specs = DVTechnicalSpecifications.make(path: "/letterboxed.dv", byteCount: pal ? 144_000 : 120_000,
    inventory: try techFixture(pal: pal, aspect: 1))
  #expect(value(specs, "Video", "Tape-reported display aspect ratio") == "4:3 — letterboxed")
  #expect(value(specs.liveReport(progress: []), "Video", "Tape-reported display aspect ratio") == "4:3 — letterboxed")
  let row = try #require(specs.sections.first { $0.title == "Video" }?.rows.first { $0.label == "Tape-reported display aspect ratio" })
  #expect(!row.isWarning && row.evidence.contains("PRIMARY_STANDARD: IEC 61834-4:1998 §9.2"))
  #expect(row.evidence.contains("stored raster dimensions"))
  let disp = try #require(specs.semanticReport?.packs.first { $0.typeHex == "0x61" }?.fields.first { $0.id == "DISP" })
  #expect(disp.rawValue == 1 && disp.status == "interpreted")
  #expect(disp.confidence == .normativeConfirmed)
}

@Test(arguments: [UInt8(1), 3, 4, 5, 6, 7]) func smpteUnmappedAspectIsNotConsumerMeaning(code: UInt8) throws {
  let specs = DVTechnicalSpecifications.make(path: "/smpte.dv", byteCount: 120_000,
    inventory: try techFixture(smpte: true, aspect: code))
  let aspect = try #require(value(specs, "Video", "Tape-reported display aspect ratio"))
  #expect(aspect != "4:3" && aspect != "16:9" && aspect != "4:3 — letterboxed")
}

@Test func letterboxInterpretationStillRejectsInvalidTransmission() throws {
  let specs = DVTechnicalSpecifications.make(path: "/invalid-letterbox.dv", byteCount: 120_000,
    inventory: try techFixture(aspect: 1, invalidVAUX: true))
  #expect(value(specs, "Video", "Tape-reported display aspect ratio")?.hasPrefix("Invalid") == true)
}

@Test func techSpecsNonlinearAudioIsNotDecodedPCMDepth() throws {
  let specs = DVTechnicalSpecifications.make(path: "/12bit.dv", byteCount: 120_000,
    inventory: try techFixture(audioCode: 0x11))
  #expect(Array(specs.sections.prefix(4).map(\.title)) == ["General", "Video", "Audio 1", "Audio 2"])
  for section in ["Audio 1", "Audio 2"] {
    #expect(value(specs, section, "Bit depth") == "12 bits")
    #expect(value(specs, section, "Sampling rate") == "32.0 kHz")
    #expect(value(specs, section, "Format settings") == "12-bit nonlinear")
  }
}

@Test func techSpecsInvalidFlagsMissingCodesAndPartialFileStayExplicit() throws {
  let specs = DVTechnicalSpecifications.make(path: "/invalid.dv", byteCount: 120_001,
    inventory: try techFixture(audioCode: 0x3f, invalidVAUX: true))
  #expect(value(specs, "Video", "Tape-reported display aspect ratio")?.hasPrefix("Invalid") == true)
  #expect(value(specs, "General", "Recorded date & time") == "Missing valid recording-date pack")
  #expect(value(specs, "Audio", "Format") == "Unknown / conflicting")
  #expect(specs.coverage.contains("incomplete trailing"))
}

@Test func techSpecsDatesRejectInvalidBCDAndImpossibleCalendarDates() {
  #expect(DVTechnicalSpecifications.recordingDate([0x62, 0xff, 0xe9, 0xc2, 0x04]) == "Sunday, 29 February 2004")
  #expect(DVTechnicalSpecifications.recordingDate([0x62, 0xff, 0xe9, 0xc2, 0x02]) == nil)
  #expect(DVTechnicalSpecifications.recordingDate([0x62, 0xff, 0xea, 0xc2, 0x02]) == nil)
  #expect(DVTechnicalSpecifications.recordingDate([0x62, 0xff, 0xc1, 0xc1, 0x95]) == "Sunday, 1 January 1995")
  #expect(DVTechnicalSpecifications.recordingTime([0x63, 0xff, 0x60, 0, 0]) == nil)
  #expect(DVTechnicalSpecifications.recordingTime([0x63, 0xff, 0, 0, 0x24]) == nil)
}

@Test func inspectorRecordingWindowFormatsCivilDatesWithoutChangingRawSemantics() throws {
  for (pack, expected) in [
    ([UInt8](arrayLiteral: 0x62,0xff,0xc1,0xc1,0x90), "Monday, 1 January 1990"),
    ([0x62,0xff,0xd8,0xd1,0x04], "Thursday, 18 November 2004"),
    ([0x62,0xff,0xd1,0xc4,0x04], "Sunday, 11 April 2004"),
    ([0x62,0xff,0xf1,0xd2,0x99], "Friday, 31 December 1999"),
    ([0x62,0xff,0xc1,0xc1,0x00], "Saturday, 1 January 2000"),
    ([0x62,0xff,0xe9,0xc2,0x00], "Tuesday, 29 February 2000"),
    ([0x62,0xff,0xe8,0xc9,0x26], "Monday, 28 September 2026")
  ] {
    #expect(DVTechnicalSpecifications.recordingDate(pack) == expected)
    #expect(DVPackSemanticReport.recordedDate(from: pack)?.contains("century unknown") == true)
  }
  for year: UInt8 in [0x27,0x50,0x89] {
    let pack: [UInt8] = [0x62,0xff,0xc1,0xc1,year]
    #expect(DVTechnicalSpecifications.recordingDate(pack) == DVPackSemanticReport.recordedDate(from: pack))
  }
  let specs = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000,
    inventory: try techFixture())
  #expect(specs.recordedDateRow?.label == "Recorded date & time")
  #expect(specs.recordedDateRow?.value == "Thursday, 28 February 2002 @ 13:09:00")
  #expect(specs.recordedDateRow?.evidence.contains("recording-window assumption") == true)
  #expect(specs.liveReport(progress: []).recordedDateRow == specs.recordedDateRow)
}

@Test func technicalDetailsReuseQualifiedSemanticsAndRetainEvidence() throws {
  let specs = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000, inventory: try techFixture())
  #expect(value(specs, "Audio source details", "Audio lock") == "Unlocked — Confirmed")
  #expect(value(specs, "Audio recording details", "Metadata") == "Missing pack 0x51")
  let field = try #require(specs.sections.first { $0.title == "Audio source details" }?.rows.first)
  #expect(field.evidence.contains("SHA-256"))
  #expect(field.evidence.contains("source byte") && field.evidence.contains("occurrences"))
  let invalid = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000,
    inventory: try techFixture(invalidVAUX: true))
  #expect(invalid.sections.first { $0.title == "Video recording details" }?.rows.allSatisfy(\.isWarning) == true)
}

@Test func liveTechnicalReportNeverPretendsToBeCompletedFile() throws {
  let specs = DVTechnicalSpecifications.make(path: "/fixture.dv", byteCount: 120_000, inventory: try techFixture())
  let live = specs.liveReport(progress: [.init(label: "Complete frames received", value: "123", evidence: "Receive counter")])
  #expect(value(live, "General", "Complete frames received") == "123")
  #expect(value(live, "General", "File size") == nil)
  #expect(value(live, "General", "Duration") == nil)
  #expect(value(live, "Audio", "Stream size") == nil)
  #expect(value(live, "Audio", "Duration") == nil)
  #expect(value(live, "Video", "Observed timecode") == "00:01:08;20")
  #expect(live.coverage.contains("between samples"))
  #expect(DVTechnicalSpecifications.completedDuration(bytes: 120_000 * 30, frames: 30, frameSize: 120_000) == "00:00:01.001")
  #expect(DVTechnicalSpecifications.completedDuration(bytes: 144_000 * 25, frames: 25, frameSize: 144_000) == "00:00:01.000")
  #expect(DVTechnicalSpecifications.completedDuration(bytes: 264_000, frames: 2, frameSize: 120_000).hasPrefix("Unknown"))
  #expect(DVTechnicalSpecifications.completedDuration(bytes: 0, frames: .max, frameSize: 120_000).hasPrefix("Unknown"))
}

// Recreate the synthetic bytes from the retained metadata extents; pixel and
// audio payload bytes are immaterial to this metadata-only worker.
private func liveFixture(pal: Bool = false) throws -> Data {
  let inventory = try techFixture(pal: pal)
  var bytes = Data(repeating: 0, count: inventory.frameByteCount)
  for extent in inventory.extents {
    let start = Int(extent.sourceByteOffset)
    bytes.replaceSubrange(start..<(start + extent.bytes.count), with: extent.bytes)
  }
  return bytes
}

private func withoutRecordedClock(_ source: Data) -> Data {
  var bytes = source
  for offset in stride(from: 0, to: bytes.count, by: 80) where bytes[offset] >> 5 == 2 {
    for slot in stride(from: 3, through: 73, by: 5) where [0x62, 0x63].contains(bytes[offset + slot]) {
      bytes.replaceSubrange((offset + slot + 1)..<(offset + slot + 5), with: [UInt8](repeating: 0xff, count: 4))
    }
  }
  return bytes
}

private func withClockIssue(_ source: Data, kind: Int) -> Data {
  var bytes = source
  for offset in stride(from: 0, to: bytes.count, by: 80) where bytes[offset] >> 5 == 2 {
    for slot in stride(from: 3, through: 73, by: 5) where bytes[offset + slot] == 0x63 {
      switch kind {
      case 0: bytes[offset + slot] = 0xff
      case 1: bytes.replaceSubrange((offset + slot + 1)..<(offset + slot + 5), with: [UInt8](repeating: 0xff, count: 4))
      case 2: bytes[offset + slot + 2] = 0xfa
      default: if offset == 240 { bytes[offset + slot + 2] = 0x81 }
      }
    }
  }
  return bytes
}

@Test(arguments: [0, 1, 2, 3]) @MainActor func partialClockNeverReplacesCompleteClock(kind: Int) async throws {
  let valid = try liveFixture(), partial = withClockIssue(valid, kind: kind)
  let report = DVTechnicalSpecifications.make(path: "synthetic", byteCount: UInt64(partial.count),
    inventory: try DVMetadataInventory.inspect(frame: partial, ordinal: 1, byteOffset: 0))
  #expect(report.validRecordedDate == nil)
  #expect(report.recordedDateRow?.isWarning == true)
  #expect(report.recordedDateRow?.value.contains(["missing pack", "all-FF", "invalid code", "conflicting values"][kind]) == true)
  let worker = LiveDVMetadata(); worker.begin(automatic: false)
  worker.offer(valid, ordinal: 0); await worker.refresh()
  worker.offer(partial, ordinal: 1); await worker.refresh()
  #expect(worker.report?.recordedDateRow?.value.hasPrefix("Last valid: Thursday, 28 February 2002 @ 13:09:00") == true)
  worker.offer(Data([0]), ordinal: 2); await worker.refresh()
  #expect(worker.report?.sections.count == 1)
  #expect(worker.report?.recordedDateRow?.value.contains("latest frame invalid") == true)
  #expect(worker.isStale && worker.status.hasPrefix("Unavailable"))
  #expect(worker.presentationStatus.hasPrefix("Unavailable"))
  await worker.refresh()
  #expect(worker.isStale && worker.status.hasPrefix("Unavailable"))
  #expect(worker.presentationStatus.hasPrefix("Unavailable"))
  worker.end()
}

@Test func clockSearchContinuesPastDateOnlyAndRejectsUnvalidatedDSFAdvance() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("clock.dv"), valid = try liveFixture()
  let partial = withClockIssue(valid, kind: 1)
  try (partial + valid).write(to: url)
  let report = try DVTechnicalSpecifications.read(url: url)
  #expect(report.validRecordedDate?.value == "Thursday, 28 February 2002 @ 13:09:00")
  #expect(report.recordedDateRow?.evidence.contains("frame 1 (zero-based)") == true)
  try (partial + partial).write(to: url)
  let dateOnly = try DVTechnicalSpecifications.read(url: url)
  #expect(dateOnly.validRecordedDate == nil)
  #expect(dateOnly.recordedDateRow?.value.contains("Thursday, 28 February 2002 (time unavailable: all-FF") == true)
  var corrupt = withoutRecordedClock(valid); corrupt[3] |= 0x80
  let bytes = withoutRecordedClock(valid) + corrupt + valid
  try bytes.write(to: url)
  let incomplete = try DVTechnicalSpecifications.read(url: url)
  #expect(incomplete.recordedDateRow?.value.contains("search incomplete") == true)
  #expect(incomplete.coverage.contains("later frames were not searched"))
  #expect(try Data(contentsOf: url) == bytes)
}

@Test(arguments: [false, true]) func recordedDateSearchPassesOpeningPlaceholdersWithoutChangingFirstFrameFacts(pal: Bool) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("opening-grey.dv")
  let valid = try liveFixture(pal: pal), blank = withoutRecordedClock(valid)
  var file = Data()
  for _ in 0..<6 { file.append(blank) }
  file.append(valid); file.append(blank)
  try file.write(to: url)
  let report = try DVTechnicalSpecifications.read(url: url)
  #expect(value(report, "General", "Recorded date & time") == "Thursday, 28 February 2002 @ 13:09:00")
  #expect(report.recordedDateRow?.evidence.contains("frame 6 (zero-based), byte offset \(valid.count * 6)") == true)
  #expect(report.coverage.contains("not necessarily frame zero"))
  #expect(value(report, "Video", "Time code of first frame") == (pal ? "00:01:08:20" : "00:01:08;20"))
  #expect(try Data(contentsOf: url) == file)
  try (blank + Data([0])).write(to: url)
  let unavailable = try DVTechnicalSpecifications.read(url: url)
  #expect(value(unavailable, "General", "Recorded date & time") == "Unavailable — no valid recording date found")
  #expect(unavailable.recordedDateRow?.evidence.contains("only FF") == true)
  #expect(unavailable.coverage.contains("incomplete trailing"))
}

@Test @MainActor func liveRecordedDateSurvivesStopPlaceholdersButNeverCrossesSessions() async throws {
  let worker = LiveDVMetadata(), valid = try liveFixture()
  worker.begin(automatic: false)
  worker.offer(withoutRecordedClock(valid), ordinal: 0)
  await worker.refresh()
  #expect(worker.report?.recordedDateRow?.value == "Unavailable — recording-date pack contains only FF")
  worker.offer(valid, ordinal: 6)
  await worker.refresh()
  #expect(worker.report?.validRecordedDate?.value == "Thursday, 28 February 2002 @ 13:09:00")
  worker.offer(withoutRecordedClock(valid), ordinal: 498)
  await worker.refresh()
  #expect(worker.report?.recordedDateRow?.value.hasPrefix("Last valid: Thursday, 28 February 2002 @ 13:09:00") == true)
  #expect(worker.report?.recordedDateRow?.isWarning == true)
  #expect(worker.report?.recordedDateRow?.evidence.contains("frame 6;") == true)
  #expect(worker.report?.recordedDateRow?.evidence.contains("frame 498;") == true)
  worker.end()
  #expect(worker.report?.recordedDateRow?.value.hasPrefix("Last valid:") == true)
  worker.begin(automatic: false)
  worker.offer(withoutRecordedClock(valid), ordinal: 0)
  await worker.refresh()
  #expect(worker.report?.recordedDateRow?.value.contains("2002") == false)
  worker.end()
}

@Test func recordedDateConflictIsNotSelectedAndMalformedBCDRemainsInvalid() throws {
  var bytes = try liveFixture()
  bytes[240 + 13 + 2] = 0xe7 // Valid but contradictory repeated day.
  var report = DVTechnicalSpecifications.make(path: "fixture", byteCount: UInt64(bytes.count),
    inventory: try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0))
  #expect(report.recordedDateRow?.value == "Conflicting recording dates")
  #expect(report.validRecordedDate == nil)
  bytes[240 + 13 + 2] = 0xea // Invalid BCD, not a no-information placeholder.
  report = DVTechnicalSpecifications.make(path: "fixture", byteCount: UInt64(bytes.count),
    inventory: try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0))
  #expect(report.recordedDateRow?.value == "Invalid recording-date code")
}

@Test func recordedDateSearchPublishesInitialSpecsAndHonorsCancellation() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("cancel.dv"), valid = try liveFixture()
  let source = withoutRecordedClock(valid) + valid
  try source.write(to: url)
  let task = Task.detached {
    try DVTechnicalSpecifications.read(url: url) { initial in
      #expect(initial.recordedDateRow?.value.contains("only FF") == true)
      #expect(value(initial, "Video", "Width") == "720 pixels")
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }
  do {
    _ = try await task.value
    Issue.record("Recording-date search ignored cancellation")
  } catch is CancellationError { /* Expected: no long scan after file switch. */ }
  #expect(try Data(contentsOf: url) == source)
}

@Test @MainActor func liveRecordedClockAdvancesAndValidObservationReplacesRetainedOne() async throws {
  let worker = LiveDVMetadata(), first = try liveFixture()
  var next = first
  for offset in stride(from: 0, to: next.count, by: 80) where next[offset] >> 5 == 2 {
    for slot in stride(from: 3, through: 73, by: 5) where next[offset + slot] == 0x63 {
      next[offset + slot + 2] = 0x81
    }
  }
  worker.begin(automatic: false)
  worker.offer(first, ordinal: 0); await worker.refresh()
  worker.offer(withoutRecordedClock(first), ordinal: 1); await worker.refresh()
  #expect(worker.report?.recordedDateRow?.value.hasPrefix("Last valid:") == true)
  worker.offer(next, ordinal: 2); await worker.refresh()
  #expect(worker.report?.validRecordedDate?.value == "Thursday, 28 February 2002 @ 13:09:01")
  worker.end()
}

@Test @MainActor func liveMetadataIsLatestOnlyStaleAndSessionBound() async throws {
  let worker = LiveDVMetadata()
  worker.begin(automatic: false)
  let bytes = try liveFixture()
  for ordinal in 0..<100 { worker.offer(bytes, ordinal: UInt64(ordinal)) }
  #expect(worker.report == nil) // Offers never synchronously parse.
  await worker.refresh()
  #expect(worker.report != nil)
  #expect(worker.sampledFrames == 1)
  #expect(worker.isStale == false)
  #expect(worker.report?.sections.last?.rows.first?.evidence.isEmpty == false)
  await worker.refresh(now: .now.advanced(by: .seconds(3)))
  #expect(worker.sampledFrames == 1)
  #expect(worker.isStale && worker.status.hasPrefix("Stale"))
  worker.offer(bytes, ordinal: 100)
  await worker.refresh()
  #expect(!worker.isStale && worker.status.hasPrefix("Live"))
  worker.end()
  #expect(worker.isStale && worker.status.hasPrefix("Stopped"))
  worker.begin(automatic: false)
  #expect(worker.report == nil && worker.rawFileBytes == nil)
  worker.offer(Data([0]), ordinal: 0)
  await worker.refresh()
  #expect(worker.report == nil && worker.status.hasPrefix("Unavailable"))
  #expect(worker.parseFailures == 1)
  worker.offer(bytes, ordinal: 1)
  await worker.refresh()
  #expect(worker.report != nil && !worker.isStale)
  worker.end()
}

@Test func additionalMetadataDoesNotSelectConflictingFlag() throws {
  var bytes = try liveFixture()
  // First VAUX block of sequence zero: source-control REC_S differs from all
  // remaining repetitions. The native semantic conflict detector must win.
  bytes[240 + 8 + 2] ^= 0x80
  let inventory = try DVMetadataInventory.inspect(frame: bytes, ordinal: 12, byteOffset: 0)
  let specs = DVTechnicalSpecifications.make(path: "/conflict.dv", byteCount: UInt64(bytes.count), inventory: inventory)
  #expect(value(specs, "Video recording details", "Recording-start flag") == "Conflicting values — no selection")
  let section = try #require(specs.sections.first { $0.title == "Video recording details" })
  if let firstWarning = section.rows.firstIndex(where: \.isWarning) {
    let warningsAreLast = section.rows[firstWarning...].allSatisfy { $0.isWarning }
    #expect(warningsAreLast)
  }
}

@Test @MainActor func liveMetadataRawSizeGrowsAndOldSessionCannotPublish() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("receive.records.raw")
  try Data(repeating: 0, count: 8).write(to: url)
  let worker = LiveDVMetadata()
  worker.begin(rawURL: url, automatic: false)
  await worker.refresh()
  #expect(worker.rawFileBytes == 8)
  try Data(repeating: 0, count: 4096).write(to: url)
  await worker.refresh()
  #expect(worker.rawFileBytes == 4096)
  worker.offer(try liveFixture(), ordinal: 1)
  let pending = Task { await worker.refresh() }
  await Task.yield()
  worker.end()
  worker.begin(automatic: false)
  await pending.value
  #expect(worker.report == nil && worker.rawFileBytes == nil)
  worker.end()
}

@Test func inspectorShowsEveryObservedPackAndLabelsUnknownPayloads() throws {
  var frame = frameBytes(try techFixture())
  for (index, header) in [UInt8(0x72), 0xf0, 0x01, 0x96].enumerated() {
    let offset = 253 + index * 5
    frame.replaceSubrange(offset..<(offset + 5), with: [header, 1, 2, 3, 4])
  }
  let report = DVPackSemanticReport.inspect(try DVMetadataInventory.inspect(frame: frame, ordinal: 0, byteOffset: 0))
  let visible = DVMetadataPresentation.groups(report).flatMap(\.packs)
  #expect(Set(visible.map(\.id)) == Set(report.packs.map(\.id)))
  for header in ["0x72", "0xF0", "0x96"] {
    let pack = try #require(visible.first { $0.typeHex == header })
    let raw = DVMetadataPresentation.rawPayloadFields(pack)
    #expect(raw.map(\.rawValue) == [1,2,3,4])
    #expect(raw.allSatisfy { $0.status == "uninterpreted" && $0.confidence == .unknown })
    #expect(DVMetadataPresentation.packFieldLabel(pack.name, packID: header).hasPrefix("[\(header)] — "))
  }
}

@Test func playbackInspectorFormatAudioAndClockFollowOneSampledFrame() throws {
  let file = DVTechnicalSpecifications.make(path: "mixed.dv", byteCount: 264_000, inventory: try techFixture())
  let pal = DVTechnicalSpecifications.make(path: "", byteCount: 144_000,
    inventory: try techFixture(pal: true, audioCode: 0x11, aspect: 2))
  let report = file.playbackReport(sampledFrame: pal)
  #expect(value(report, "General", "Complete name") == "mixed.dv")
  #expect(value(report, "General", "File size") == value(file, "General", "File size"))
  #expect(value(report, "Video", "Standard") == "PAL")
  #expect(value(report, "Video", "Height") == "576 pixels")
  #expect(value(report, "Video", "Width") == "720 pixels")
  #expect(value(report, "Video", "Chroma subsampling") == "4:2:0")
  #expect(value(report, "Video", "Frame rate") == "25.000 (25/1) FPS")
  #expect(value(report, "Video", "Tape-reported display aspect ratio") == "16:9")
  #expect(value(report, "Audio 1", "Sampling rate") == "32.0 kHz")
  #expect(value(report, "Audio 2", "Bit depth") == "12 bits")
  #expect(value(report, "Video", "Observed timecode") == value(pal, "Video", "Time code of first frame"))
  let returned = file.playbackReport(sampledFrame: file)
  #expect(value(returned, "Video", "Standard") == "NTSC")
  #expect(value(returned, "Video", "Height") == "480 pixels")
  #expect(value(returned, "Video", "Chroma subsampling") == "4:1:1")
  #expect(value(returned, "Audio", "Sampling rate") == "48.0 kHz")
  #expect(!returned.sections.contains { $0.title == "Audio 2" })
}

@Test func playbackInspectorNeverBorrowsFileFormatWhenCurrentEvidenceIsMissingOrUnknown() throws {
  let file = DVTechnicalSpecifications.make(path: "mixed.dv", byteCount: 264_000, inventory: try techFixture())
  let pending = file.playbackReport(sampledFrame: nil)
  for label in ["Standard", "Height", "Width", "Chroma subsampling", "Frame rate", "Tape-reported display aspect ratio"] {
    #expect(value(pending, "Video", label)?.hasPrefix("Unavailable") == true)
  }
  let invalid = DVTechnicalSpecifications.make(path: "", byteCount: 144_000,
    inventory: try techFixture(pal: true, invalidVAUX: true))
  let report = file.playbackReport(sampledFrame: invalid)
  #expect(value(report, "Video", "Standard") == "PAL")
  #expect(value(report, "Video", "Height") == "576 pixels")
  #expect(value(report, "Video", "Chroma subsampling") == "Unknown / conflicting")
  #expect(value(report, "Video", "Tape-reported display aspect ratio")?.contains("4:3") == false)
}

@Test func iecBroadcastAspectUsesItsOwnCodebook() throws {
  for code in UInt8(0)...7 {
    let specs = DVTechnicalSpecifications.make(path: "broadcast.dv", byteCount: 120000,
      inventory: try techFixture(aspect: code, broadcastSystem: 1))
    let aspect = try #require(value(specs,"Video","Tape-reported display aspect ratio"))
    #expect(code == 7 ? aspect == "16:9" : aspect.hasPrefix("4:3"))
    #expect(DVPackSemanticReport.displayWidescreen(code: code,consumer:true,broadcastSystem:1) == (code == 7))
  }
  for system in UInt8(2)...3 {
    #expect(DVPackSemanticReport.displayWidescreen(code: 2,consumer:true,broadcastSystem:system) == nil)
  }
}

// Independently authored AAUX control witnesses: PC2 bits 5...3 carry REC_M.
// Half 1 is marked invalid (111); half 2 is original audio (001). They are
// separate audio contexts, not contradictory repetitions of the same field.
@Test func technicalAAUXRecordingModesPreserveIndependentSequenceHalves() throws {
  var bytes = frameBytes(try techFixture())
  for at in stride(from: 0, to: bytes.count, by: 80)
    where bytes[at] >> 5 == 3 && bytes[at + 2] == 1 {
    let halfOne = bytes[at + 1] >> 4 < 5
    bytes.replaceSubrange((at + 3)..<(at + 8), with: [0x51, 0x03, halfOne ? 0xff : 0xcf, 0xa0, 0xff])
  }
  let report = DVTechnicalSpecifications.make(path: "synthetic.dv", byteCount: UInt64(bytes.count),
    inventory: try DVMetadataInventory.inspect(frame: bytes, ordinal: 42, byteOffset: 600_000))
  let rows = try #require(report.sections.first { $0.title == "Audio recording details" }?.rows)
  let first = try #require(rows.first { $0.label == "Recording mode — AAUX sequence half 1" })
  let second = try #require(rows.first { $0.label == "Recording mode — AAUX sequence half 2" })
  #expect(first.value == "Invalid: Recording marked invalid")
  #expect(!second.value.hasPrefix("Conflicting") && !second.value.hasPrefix("Invalid"))
  #expect(first.evidence.contains("51 03 FF A0 FF") && !first.evidence.contains("51 03 CF A0 FF"))
  #expect(second.evidence.contains("51 03 CF A0 FF") && !second.evidence.contains("51 03 FF A0 FF"))
  #expect(first.evidence.contains("frame 42") && first.evidence.contains("source byte"))
  #expect(!rows.contains { $0.value.contains("damage") })
}

@Test func technicalAAUXMissingHalfDoesNotBorrowOtherHalf() throws {
  var bytes = frameBytes(try techFixture())
  for at in stride(from: 0, to: bytes.count, by: 80)
    where bytes[at] >> 5 == 3 && bytes[at + 2] == 1 && bytes[at + 1] >> 4 < 5 {
    bytes.replaceSubrange((at + 3)..<(at + 8), with: [0x51, 0x03, 0xff, 0xa0, 0xff])
  }
  let report = DVTechnicalSpecifications.make(path: "synthetic.dv", byteCount: UInt64(bytes.count),
    inventory: try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0))
  let rows = try #require(report.sections.first { $0.title == "Audio recording details" }?.rows)
  #expect(rows.first { $0.label == "Recording mode — AAUX sequence half 1" }?.value == "Invalid: Recording marked invalid")
  #expect(rows.first { $0.label == "Metadata — AAUX sequence half 2" }?.value == "Missing pack 0x51")
}

@Test func technicalAAUXWithinHalfConflictsRemainConflicts() throws {
  var bytes = frameBytes(try techFixture())
  for at in stride(from: 0, to: bytes.count, by: 80)
    where bytes[at] >> 5 == 3 && bytes[at + 2] == 1 {
    bytes.replaceSubrange((at + 3)..<(at + 8), with: [0x51, 0x03, bytes[at + 1] >> 4 == 0 ? 0xff : 0xcf, 0xa0, 0xff])
  }
  let report = DVTechnicalSpecifications.make(path: "synthetic.dv", byteCount: UInt64(bytes.count),
    inventory: try DVMetadataInventory.inspect(frame: bytes, ordinal: 0, byteOffset: 0))
  let rows = try #require(report.sections.first { $0.title == "Audio recording details" }?.rows)
  #expect(rows.first { $0.label == "Recording mode — AAUX sequence half 1" }?.value == "Conflicting values — no selection")
  #expect(rows.first { $0.label == "Recording mode — AAUX sequence half 2" }?.value.hasPrefix("Conflicting") == false)
}
