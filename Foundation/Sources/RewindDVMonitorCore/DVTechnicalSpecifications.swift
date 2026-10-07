// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreMedia
import CoreVideo
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// Read-only file facts plus metadata of the first complete frame. Recording
/// date/time may come from a later frame, explicitly identified in its evidence.
/// Never uses preview aspect/zoom, decoded PCM depth, or filesystem dates as
/// substitutes for recorded source facts. No whole-file uniformity claim.
public struct DVTechnicalSpecifications: Sendable, Equatable {
  public struct Row: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String
    public let evidence: String
    public init(label: String, value: String, evidence: String) {
      self.label = label; self.value = value; self.evidence = evidence
    }
    public var id: String { label }
    public var isWarning: Bool {
      value.contains("(time unavailable:") || ["Unknown", "Missing", "Conflicting", "Unavailable", "Reserved", "Uninterpreted", "Invalid", "Last valid"].contains { value.hasPrefix($0) }
    }
  }
  public struct Section: Sendable, Equatable, Identifiable {
    public let title: String
    public let rows: [Row]
    public init(title: String, rows: [Row]) { self.title = title; self.rows = rows }
    public var id: String { title }
  }
  public let sections: [Section]
  public let coverage: String
  public var semanticReport: DVPackSemanticReport? = nil
  /// True only when date AND time agree within the same validated frame.
  /// A date-only sample must never replace a previously observed full clock.
  var hasCompleteRecordedClock = false

  public static func read(url: URL, searchRecordedClock: Bool = true, initialReport: (@Sendable (Self) -> Void)? = nil) throws -> Self {
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let length = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    let header = try handle.read(upToCount: 80) ?? Data()
    guard header.count == 80 else { throw CocoaError(.fileReadCorruptFile) }
    let frameSize = header[3] & 0x80 == 0 ? 120_000 : 144_000
    let tail = try handle.read(upToCount: frameSize - 80) ?? Data()
    let inventory = try DVMetadataInventory.inspect(frame: header + tail, ordinal: 0, byteOffset: 0)
    let first = make(path: url.path, byteCount: length, inventory: inventory)
    guard searchRecordedClock, first.validRecordedDate == nil else { return first }
    // Publish ordinary specs immediately. Search only on the caller's utility
    // worker, with constant memory and cancellation between complete frames.
    initialReport?(first)
    var offset = UInt64(frameSize), ordinal: UInt64 = 1
    var skippedIssues: Set<String> = [first.recordedDateRow?.value ?? "Unavailable"]
    var firstPartialDate: Row? = first.recordedDateRow.flatMap { $0.value.contains("(time unavailable:") ? $0 : nil }
    while offset < length {
      try Task.checkCancellation()
      let bytes = try handle.read(upToCount: 144_000) ?? Data()
      guard bytes.count >= 80 else { break }
      let size = bytes[3] & 0x80 == 0 ? 120_000 : 144_000
      guard bytes.count >= size else { break }
      // Do not advance using an unvalidated DSF bit. In particular, a corrupt
      // NTSC header claiming PAL would skip 24 KB and lose all later alignment.
      guard hasOrderedFrameBoundary(bytes, frameSize: size) else {
        return first.replacingRecordedDate(Row(label: "Recorded date & time",
          value: "Unavailable — recording-clock search incomplete",
          evidence: "Invalid DIF boundary at byte offset \(offset), frame \(ordinal). No guessed resynchronization. " + (firstPartialDate?.evidence ?? "")),
          coverage: first.coverage + " Recording-clock search stopped at an invalid boundary; later frames were not searched.")
      }
      let candidate: Self? = autoreleasepool {
        // Cheap candidate filter avoids hashing/decoding every gray or undated
        // frame in a long file. It grants no authority: a candidate still must
        // pass complete DIF validation and repetition/conflict checks below.
        guard hasRecordingDateCandidate(bytes, frameSize: size) else { return nil }
        guard let frame = try? DVMetadataInventory.inspect(frame: Data(bytes.prefix(size)), ordinal: ordinal, byteOffset: offset) else { return nil }
        return make(path: url.path, byteCount: length, inventory: frame)
      }
      if let found = candidate?.validRecordedDate {
        let evidence = found.evidence + " First valid recorded date in file: frame \(ordinal) (zero-based), byte offset \(offset). Earlier frames: " + skippedIssues.sorted().joined(separator: "; ") + ". Not a whole-file date-uniformity claim."
        return first.replacingRecordedDate(Row(label: found.label, value: found.value, evidence: evidence), completeClock: true,
          coverage: first.coverage + " Recorded date uses the first valid observation at frame \(ordinal), not necessarily frame zero.")
      }
      if firstPartialDate == nil, let row = candidate?.recordedDateRow, row.value.contains("(time unavailable:") {
        firstPartialDate = row
      }
      skippedIssues.insert(candidate?.recordedDateRow?.value ?? "Frames without a structurally validated recording date")
      offset += UInt64(size); ordinal += 1
      try handle.seek(toOffset: offset)
    }
    let issue = Row(label: "Recorded date & time", value: firstPartialDate?.value ?? "Unavailable — no valid recording date found",
      evidence: (firstPartialDate?.evidence ?? "") + " Searched structurally validated complete frames; no complete date/time pair found. " + skippedIssues.sorted().joined(separator: "; ") + ". Original bytes are unchanged.")
    return first.replacingRecordedDate(issue, coverage: first.coverage + " Recording-clock search found no complete date/time pair.")
  }

  /// Allocation-free validation of ordered DIF identities and every sequence's
  /// DSF before choosing the next boundary. No pixel/pack interpretation here.
  private static func hasOrderedFrameBoundary(_ bytes: Data, frameSize: Int) -> Bool {
    bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard raw.count >= frameSize else { return false }
      for index in 0..<(frameSize / 80) {
        let sequence = index / 150, local = index % 150, offset = index * 80
        let section: Int, number: Int
        switch local {
        case 0: section = 0; number = 0
        case 1...2: section = 1; number = local - 1
        case 3...5: section = 2; number = local - 3
        default:
          let group = (local - 6) / 16, within = (local - 6) % 16
          section = within == 0 ? 3 : 4
          number = within == 0 ? group : group * 15 + within - 1
        }
        guard Int(raw[offset] >> 5) == section, Int(raw[offset + 1] >> 4) == sequence,
          Int(raw[offset + 2]) == number,
          section != 0 || ((raw[offset + 3] & 0x80 != 0) == (frameSize == 144_000)) else { return false }
      }
      return true
    }
  }

  private static func hasRecordingDateCandidate(_ bytes: Data, frameSize: Int) -> Bool {
    bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for block in stride(from: 0, to: frameSize, by: 80) where raw[block] >> 5 == 2 {
        for slot in stride(from: 3, through: 73, by: 5) where raw[block + slot] == 0x62 {
          if recordingDate(Array(raw[(block + slot)..<(block + slot + 5)])) != nil { return true }
        }
      }
      return false
    }
  }

  var recordedDateRow: Row? { sections.first { $0.title == "General" }?.rows.first { $0.label == "Recorded date & time" } }
  var validRecordedDate: Row? { hasCompleteRecordedClock ? recordedDateRow : nil }
  func replacingRecordedDate(_ row: Row, completeClock: Bool = false, coverage: String? = nil) -> Self {
    Self(sections: sections.map { section in
      Section(title: section.title, rows: section.rows.map { section.title == "General" && $0.label == "Recorded date & time" ? row : $0 })
    }, coverage: coverage ?? self.coverage, semanticReport: semanticReport, hasCompleteRecordedClock: completeClock)
  }

  /// Lightweight clock side channel, evaluated on the native reader actor.
  /// Every DIF identity/system and consumer header is checked before VAUX.
  /// No interpolation, file-date fallback, or last-good retention.
  public static func frameRecordedClock(_ bytes: Data) -> Row {
    func result(_ value: String, _ evidence: String) -> Row {
      Row(label: "Recorded date & time", value: value, evidence: evidence)
    }
    guard (bytes.count == 120_000 || bytes.count == 144_000),
      hasOrderedFrameBoundary(bytes, frameSize: bytes.count) else {
      return result("Unavailable — invalid DV frame", "Complete ordered DIF structure required; no clock inferred.")
    }
    for start in stride(from: 0, to: bytes.count, by: 12_000) {
      guard (4...7).allSatisfy({ bytes[start + $0] & 7 == 0 }),
        bytes[start + 6] & 0x80 == 0 else {
        return result("Unavailable — recording clock not qualified", "Consumer header identity and VAUX transmission must agree across every sequence.")
      }
    }
    var dates: Set<[UInt8]> = [], times: Set<[UInt8]> = []
    for block in stride(from: 0, to: bytes.count, by: 80) where bytes[block] >> 5 == 2 {
      guard bytes[block + 1] & 0x0c == 0x04 else {
        return result("Unavailable — invalid VAUX transmission", "No interpretation of invalid VAUX source packs.")
      }
      for slot in stride(from: 3, through: 73, by: 5) {
        let start = block + slot
        if bytes[start] == 0x62 { dates.insert(Array(bytes[start..<(start + 5)])) }
        if bytes[start] == 0x63 { times.insert(Array(bytes[start..<(start + 5)])) }
      }
    }
    let date = unique(dates.map(recordingDate)), time = unique(times.map(recordingTime))
    let dateIssue = dates.isEmpty ? "missing date" : dates.contains(where: { recordingDate($0) == nil }) ? "invalid or no-information date" : "conflicting dates"
    let timeIssue = times.isEmpty ? "missing time" : times.contains(where: { recordingTime($0) == nil }) ? "invalid or no-information time" : "conflicting times"
    let value = date.map { $0 + (time.map { " @ " + $0 } ?? " (time unavailable: \(timeIssue))") }
      ?? "Unavailable — \(dateIssue)"
    return result(value, "Same-frame VAUX 0x62/0x63 repetitions; no interpolated seconds, timezone, or borrowed clock. Recorded clock ticks may be uneven; that alone does not prove dropped frames. Century is the requested 1990–2026 assumption. Raw packs: "
      + dates.union(times).map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }.sorted().joined(separator: "; "))
  }

  /// File facts retain file scope; all source-format fields come from one
  /// validated sampled frame. Missing current evidence never borrows frame zero.
  public func playbackReport(sampledFrame: Self?, timeline: DVPlaybackTimeline? = nil) -> Self {
    let fileLabels: Set<String> = ["Complete name", "File size", "Duration", "Overall bit rate mode", "Overall bit rate"]
    let fileGeneral = sections.first { $0.title == "General" }?.rows ?? []
    let sampleGeneral = sampledFrame?.sections.first { $0.title == "General" }?.rows ?? []
    let scope = sampledFrame?.semanticReport.map { "Sampled source \(timeline?.isPreviewEstimate == true ? "frame number is a preview estimate" : "frame \($0.frameOrdinal)"); SHA-256 \($0.frameSHA256). " }
      ?? "No validated metadata for the current source selection. "
    func sourceRow(_ row: Row) -> Row {
      Row(label: row.label == "Time code of first frame" ? "Observed timecode" : row.label,
        value: sampledFrame == nil ? "Unavailable — awaiting validated source frame" : row.value,
        evidence: scope + row.evidence.replacingOccurrences(of: "First complete DV frame", with: "Sampled source frame")
          .replacingOccurrences(of: "Complete first-frame DIF structure", with: "Complete sampled-frame DIF structure"))
    }
    let general = Section(title: "General", rows: fileGeneral.map { row in
      if fileLabels.contains(row.label) { return row }
      guard let current = sampleGeneral.first(where: { $0.label == row.label }) else {
        return Row(label: row.label, value: "Unavailable — awaiting validated source frame", evidence: scope)
      }
      return sourceRow(current)
    })
    let sourceSections = (sampledFrame?.sections ?? sections).filter { $0.title != "General" }.map { section in
      Section(title: section.title, rows: section.rows.map { row in
        if row.label == "Stream size" {
          return Row(label: row.label, value: "Unavailable — requires whole-file stream accounting",
            evidence: "A sampled frame does not establish a whole-file audio/video payload size.")
        }
        return sourceRow(row)
      })
    }
    let observedMotion = sampledFrame?.semanticReport
    let combined = [general] + sourceSections
    let sections = combined.map { section -> Section in
      guard let timeline else { return section }
      let mixed = timeline.runs.count > 1
      if timeline.isPreviewEstimate {
        return Section(title: section.title, rows: section.rows.map { row in
          if row.label == "Duration" {
            return Row(label: row.label, value: "Preview estimate: " + Self.durationText(timeline.durationSeconds),
              evidence: "Estimated from file length and the first frame's system. Whole-file system uniformity and exact duration are unassessed; selected frames are validated on demand.")
          }
          if section.title == "General", ["Overall bit rate", "Overall bit rate mode"].contains(row.label) {
            return Row(label: row.label, value: "Unavailable — whole file not assessed", evidence: "Frame-local playback does not assess the full source.")
          }
          return row
        })
      }
      if !timeline.isComplete {
        return Section(title: section.title, rows: section.rows.map { row in
          if row.label == "Duration" || (section.title == "General" &&
            ["Overall bit rate", "Overall bit rate mode"].contains(row.label)) {
            return Row(label: row.label, value: "Indexing — whole-file value not yet established",
              evidence: "Only the first \(timeline.frameCount) source frames have validated playback coordinates. Later source systems and duration remain unknown.")
          }
          return row
        })
      }
      let evidence = "Whole-file playback timeline: \(timeline.frameCount) structurally validated frames in \(timeline.runs.count) system runs. Exact sum of each stored frame's cadence; no source timecode interpolation."
      return Section(title: section.title, rows: section.rows.map { row in
        if row.label == "Duration", section.title == "General" {
          return Row(label: row.label, value: Self.durationText(timeline.durationSeconds), evidence: evidence)
        }
        if section.title.hasPrefix("Audio"), row.label == "Duration" {
          return Row(label: row.label, value: "Nominal video span: " + Self.durationText(timeline.durationSeconds),
            evidence: evidence + " Exact recorded audio-sample duration is assessed separately; no audio coverage is inferred.")
        }
        if section.title == "General", row.label == "Overall bit rate" {
          return Row(label: row.label, value: Self.rateText(Double(timeline.byteCount) * 8 / timeline.durationSeconds), evidence: evidence + " Average stored bit rate.")
        }
        if mixed, section.title == "General", row.label == "Overall bit rate mode" {
          return Row(label: row.label, value: "Variable (NTSC / PAL)", evidence: evidence)
        }
        if mixed, section.title.hasPrefix("Audio"), row.label == "Stream size" {
          return Row(label: row.label, value: "Unavailable — mixed source systems", evidence: "No whole-file audio payload estimate is extrapolated from the first frame.")
        }
        return row
      })
    }
    return Self(sections: sections + Self.recordedMotionSections(observedMotion),
      coverage: "Source format, audio, recording clock and pack details describe the identified sampled frame. During playback, samples update twice per second and immediately at a system change; pause for the selected frame. File duration and size describe the whole file. Unknown or conflicting metadata stays unavailable.", semanticReport: observedMotion)
  }

  public static func recordedMotionSections(_ report: DVPackSemanticReport?) -> [Section] {
    let rows = report.map(additionalMetadata)?.flatMap(\.rows) ?? []
    return [Section(title: "Recorded motion / lens", rows: ["Recorded speed", "Electronic zoom enable code", "Electronic zoom magnitude"].map { label in
      rows.first { $0.label == label } ?? Row(label: label, value: "Unavailable — no qualified observed value",
        evidence: "Optional recorded metadata; no deck motion or preview zoom inferred.")
    })]
  }

  public static func make(path: String, byteCount: UInt64, inventory: DVMetadataInventory, absoluteOffsetsKnown: Bool = true) -> Self {
    let semantic = DVPackSemanticReport.inspect(inventory, absoluteOffsetsKnown: absoluteOffsetsKnown)
    let pal = inventory.frameByteCount == 144_000
    let height = pal ? 576 : 480
    let fps = pal ? 25.0 : 30_000.0 / 1001.0
    let frames = byteCount / UInt64(inventory.frameByteCount)
    let complete = byteCount % UInt64(inventory.frameByteCount) == 0
    let seconds = Double(frames) / fps
    let overallRate = Double(inventory.frameByteCount) * fps * 8
    // MediaInfo's DV video-payload accounting convention (134/150 DIF blocks,
    // 76/80 payload bytes). Not raw receive loss or an independently sized file.
    let videoFraction = 134.0 / 150.0 * 76.0 / 80.0
    let videoRate = overallRate * videoFraction
    let scope = "First complete DV frame; raw packs remain in the original file."
    let arithmetic = "Calculated from DV25 frame size, exact stored frame cadence and file length; no whole-file format-uniformity guarantee."
    func row(_ label: String, _ value: String, _ evidence: String = "") -> Row {
      Row(label: label, value: value, evidence: evidence.isEmpty ? scope : evidence)
    }
    // Semantic fields are already format/context/TF validated by the existing
    // decoder. Collapse equal repetitions, never choose one conflicting value.
    func field(_ type: String, _ id: String) -> UInt8? {
      let fields = semantic.packs.filter { $0.typeHex == type }.flatMap(\.fields).filter { $0.id == id }
      guard !fields.isEmpty, fields.allSatisfy({ $0.status == "interpreted" || $0.status == "uninterpreted" }) else { return nil }
      let values = Set(fields.map(\.rawValue))
      return values.count == 1 ? values.first.flatMap(UInt8.init(exactly:)) : nil
    }
    func unavailable(_ type: String, _ id: String) -> String {
      let packs = semantic.packs.filter { $0.typeHex == type }
      guard !packs.isEmpty else { return "Missing pack \(type)" }
      let fields = packs.flatMap(\.fields).filter { $0.id == id }
      guard !fields.isEmpty else { return "Unavailable — format or transmission not qualified" }
      if Set(fields.map(\.rawValue)).count > 1 || fields.contains(where: { $0.meaning.hasPrefix("Conflicting") }) {
        return "Conflicting values — no selection"
      }
      if let issue = fields.first(where: { $0.status != "interpreted" }) {
        return issue.status.capitalized + ": " + issue.meaning
      }
      return "Unknown / unsupported code"
    }
    let knownFormat = semantic.format == "IEC 61834 consumer DV" || semantic.format == "SMPTE ST 314M-2005 DV"
    let sd = knownFormat && field("0x60", "STYPE") == 0
    let aspect: String
    switch field("0x61", "DISP") {
    case 0, 4: aspect = "4:3"
    case 1 where semantic.format == "IEC 61834 consumer DV": aspect = "4:3 — letterboxed"
    case 2: aspect = "16:9"
    default: aspect = unavailable("0x61", "DISP")
    }
    let scan: String
    switch field("0x61", "IL") {
    case 0: scan = "Progressive (flag)"
    case 1: scan = "Interlaced (flag)"
    default: scan = unavailable("0x61", "IL")
    }
    let order: String
    if sd, field("0x61", "IL") == 1,
      let first = field("0x61", "FS"), let both = field("0x61", "FF") {
      order = both == 1 ? (first == 1 ? "Bottom Field First" : "Top Field First")
        : (first == 1 ? "Bottom field only" : "Top field only")
    } else { order = scan.hasPrefix("Progressive") ? "Not applicable" : "Unknown / conflicting" }
    let chroma = sd ? (pal && semantic.format.hasPrefix("IEC") ? "4:2:0" : "4:1:1") : "Unknown / conflicting"
    let tcPacks = rawPacks(inventory, type: 0x13, section: 1)
    let tc = MonitorSourceTimecode.display(packs: tcPacks, isPAL: pal)
    let datePacks = semantic.format.hasPrefix("IEC") ? rawPacks(inventory, type: 0x62, section: 2) : []
    let dates = datePacks.map(recordingDate)
    let timePacks = semantic.format.hasPrefix("IEC") ? rawPacks(inventory, type: 0x63, section: 2) : []
    let times = timePacks.map(recordingTime)
    let date = unique(dates), time = unique(times)
    let timeIssue = times.isEmpty ? "missing pack" : timePacks.allSatisfy { $0.dropFirst().allSatisfy { $0 == 0xff } }
      ? "all-FF no-information code" : times.contains(nil) ? "invalid code" : "conflicting values"
    let recorded = date.map { $0 + (time.map { " @ " + $0 } ?? " (time unavailable: \(timeIssue))") }
      ?? (dates.isEmpty ? "Missing valid recording-date pack" : datePacks.allSatisfy { $0.dropFirst().allSatisfy { $0 == 0xff } }
        ? "Unavailable — recording-date pack contains only FF" : dates.contains(nil) ? "Invalid recording-date code" : "Conflicting recording dates")
    let duration = durationText(seconds)
    let general = Section(title: "General", rows: [
      row("Complete name", path, "Selected source URL; opened read-only."),
      row("Format", "DV", "Complete first-frame DIF structure validated."),
      row("Commercial name", knownFormat ? (semantic.format.hasPrefix("IEC") ? "DV (DV25)" : "DVCPRO (DV25 syntax)") : "Unknown / conflicting",
        semantic.formatEvidence + " Tape brand, MiniDV/DVCAM transport speed and camera model are not established. Audio-lock alone is not a commercial-format identifier."),
      row("File size", sizeText(Double(byteCount)), "Actual file length: \(byteCount) bytes."),
      row("Duration", duration, arithmetic),
      row("Overall bit rate mode", "Constant (DV25)", arithmetic),
      row("Overall bit rate", rateText(overallRate), arithmetic),
      row("Recorded date & time", recorded, "Observed DV frame \(inventory.frameOrdinal); SHA-256 \(inventory.frameSHA256). VAUX 0x62/0x63; local recorded clock, no timezone invented. Display century uses the 1990–2026 recording-window assumption: 90–99 → 1990–1999, 00–26 → 2000–2026. Weekday is calculated from that date; years outside the window remain unresolved. Original two-digit year and raw packs are retained; signed timezone is unknown. Recorded clock ticks may be uneven; that alone does not prove dropped frames (AAFS 2007 C49, pp.183–184). Raw packs: " + (datePacks + rawPacks(inventory, type: 0x63, section: 2)).map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }.reduce(into: Set<String>()) { $0.insert($1) }.sorted().joined(separator: "; "))
    ])
    let video = Section(title: "Video", rows: [
      row("Bit rate", rateText(videoRate), "Calculated DV video-payload rate using MediaInfo's 134/150 × 76/80 convention."),
      row("Width", "720 pixels", "Stored DV25 raster, not display geometry."),
      row("Height", "\(height) pixels", "Stored DSF system; not deinterlaced preview dimensions."),
      row("Tape-reported display aspect ratio", aspect,
        scope + " VAUX 0x61 DISP; format: \(semantic.format). Full-frame display ratio, not stored pixel dimensions or the shape of visible content within recorded black bars. Preview overrides do not change this value. "
          + (semantic.packs.filter { $0.typeHex == "0x61" }.flatMap(\.fields).filter { $0.id == "DISP" && $0.rawValue == 1 && $0.status == "interpreted" }.first.map { $0.reference + ". " + ($0.qualifier ?? "") } ?? "")),
      row("Frame rate mode", "Constant (stored DV)", arithmetic),
      row("Frame rate", pal ? "25.000 (25/1) FPS" : "29.970 (30000/1001) FPS", "Exact stored cadence; not a claim about 24p/pulldown acquisition."),
      row("Standard", pal ? "PAL" : "NTSC", "DV DSF 625/50 or 525/60 system."),
      row("Color space", "YUV", "DV25 Y′CbCr coding; not decoded display RGB."),
      row("Chroma subsampling", chroma),
      row("Bit depth", "8 bits", "DV25 source video coding."),
      row("Scan type", scan, scope + " Flag describes stored signal; no camera-cadence inference."),
      row("Scan order", order),
      row("Compression mode", "Lossy", "Original DV video compression; playback adds no encoding."),
      row("Bits/(Pixel*Frame)", String(format: "%.3f", videoRate / fps / 720 / Double(height)), "Calculated using the video-payload rate convention above."),
      row("Time code of first frame", tc ?? "Unknown / conflicting"),
      row("Time code source", tc == nil ? "No valid subcode timecode" : "Subcode time code"),
      row("Stream size", "≈ " + sizeText(Double(byteCount) * videoFraction) + " (85%)", "Estimated video-payload share, not a separately stored stream.")
    ])
    var sections = [general, video]
    let rate: Int?
    switch field("0x50", "SMP") { case 0: rate = 48_000; case 1: rate = 44_100; case 2: rate = 32_000; default: rate = nil }
    let quantization = field("0x50", "QU")
    let bits: Int? = quantization == 0 ? 16 : (quantization == 1 ? 12 : nil)
    // Raw DV25 12-bit/32k packs represent two stereo programs. Keep each pair
    // separate, rather than mistaking the native decoder's first pair for all audio.
    let supportedAudio = field("0x50", "STYPE") == 0 && rate != nil && bits != nil
    let pairCount = supportedAudio && quantization == 1 && rate == 32_000 ? 2 : 1
    for pair in 0..<pairCount {
      let audioRate = supportedAudio ? Double(rate! * bits! * 2) : nil
      sections.append(Section(title: pairCount == 1 ? "Audio" : "Audio \(pair + 1)", rows: [
        row("ID", supportedAudio ? "\(pair)" : "Unknown", "Zero-based audio-pair index, not a FireWire node or embedded track identifier."),
        row("Format", supportedAudio ? "PCM" : "Unknown / conflicting"),
        row("Format settings", bits == 16 && supportedAudio ? "Big / Signed" : (bits == 12 && supportedAudio ? "12-bit nonlinear" : "Unknown / conflicting")),
        row("Duration", supportedAudio ? "Nominal video span: " + duration : "Unknown", "Nominal span of the DV frames; exact recorded sample duration is reported separately by the whole-file source audit."),
        row("Bit rate mode", supportedAudio ? "Constant (nominal)" : "Unknown"),
        row("Bit rate", audioRate.map(rateText) ?? "Unknown", "Nominal rate × source quantization bits × channels in this pair."),
        row("Channel(s)", supportedAudio ? "2 channels" : "Unknown / conflicting"),
        row("Sampling rate", rate.map { String(format: "%.1f kHz", Double($0) / 1000) } ?? unavailable("0x50", "SMP")),
        row("Bit depth", bits.map { "\($0) bits" } ?? unavailable("0x50", "QU"), "AAUX source quantization, not the monitor's decoded PCM depth."),
        row("Stream size", audioRate.map {
          "≈ " + sizeText($0 * seconds / 8) + String(format: " (%.0f%%)", $0 / overallRate * 100)
        } ?? "Unknown", "Estimated nominal audio payload for this pair; DV embeds/shuffles audio inside DIF.")
      ]))
    }
    sections += additionalMetadata(semantic)
    return Self(sections: sections, coverage: "File facts + first-frame metadata. Values may change later in the recording. ≈ denotes calculated payload size. Preview controls never change these specs."
      + (complete ? "" : " Warning: incomplete trailing DV frame; duration counts complete frames only.")
      + (date != nil && time != nil ? "" : " The first stored frame has no complete recorded clock; its other specs are not established as representative of the recording."),
      semanticReport: semantic, hasCompleteRecordedClock: date != nil && time != nil)
  }

  /// Same format-specific decoders as Archives; never infer a value from pack
  /// presence alone. Conflicting repetitions are displayed, never voted away.
  private static func additionalMetadata(_ report: DVPackSemanticReport) -> [Section] {
    var groups: [(String, String, [(String, String)])] = [
      ("Audio source details", "0x50", [("LF", "Audio lock"), ("SM", "Stereo mode"), ("CHN", "Channels per audio block"), ("PA", "Audio pairing"), ("ML", "Multi-language"), ("EF", "Audio emphasis"), ("TC", "Emphasis time constant")]),
      ("Audio recording details", "0x51", [("ISR", "Previous input source"), ("CMP", "Compression count"), ("CGMS", "Copy-generation management"), ("SS", "Source restrictions"), ("REC_S", "Recording-start flag"), ("REC_E", "Recording-end flag"), ("REC_M", "Recording mode"), ("ICH", "Insert audio channel"), ("DRF", "Recorded direction flag"), ("SPD", "Recorded speed"), ("EFC", "Audio emphasis channel flag"), ("FADE_S", "Recording-start fade"), ("FADE_E", "Recording-end fade")]),
      ("Video source details", "0x60", [("BW", "Color / black-and-white"), ("EN", "Color-frame validity"), ("CLF", "Color-frame identification")]),
      ("Video recording details", "0x61", [("ISR", "Previous input source"), ("CMP", "Compression count"), ("CGMS", "Copy-generation management"), ("REC_S", "Recording-start flag"), ("REC_M", "Recording mode"), ("FF", "Frame / field delivery"), ("FS", "First / second field"), ("FC", "Frame-change flag"), ("SF", "Still-field timing"), ("SC", "Still-camera flag"), ("BCS", "Broadcast system")]),
      ("Timecode flags", "0x13", [("DF", "Drop-frame flag"), ("CF", "Color-frame synchronization"), ("PC", "Polarity correction")])
    ]
    // Optional packs are shown only when actually observed. The same
    // source-bound rows serve playback and the independently sampled live UI.
    let optional: [(String, String, [(String, String)])] = [
      ("Recorded camera settings", "0x70", [("AE_MODE", "Exposure mode"), ("WB_MODE", "White-balance mode"), ("WB_PRESET", "White-balance preset"), ("FOCUS_MODE", "Focus mode"), ("IRIS", "Iris code"), ("AGC", "Gain code"), ("FOCUS", "Focus position code")]),
      ("Recorded camera motion / lens codes", "0x71", [("VPD", "Vertical pan direction code"), ("VP_SPEED", "Vertical pan speed code"), ("IS", "Image stabilizer code"), ("HPD", "Horizontal pan direction code"), ("HP_SPEED", "Horizontal pan speed code"), ("FOCAL_LENGTH", "Focal length code"), ("ZEN", "Electronic zoom enable code"), ("ZOOM_MAGNITUDE", "Electronic zoom magnitude")]),
      ("User bits — encoding unspecified", "0x14", (1...8).map { ("BG\($0)", "User bits group \($0)") }),
      ("Caption payload — not decoded text", "0x65", [("CC_F1_BYTE1", "Field 1 byte 1"), ("CC_F1_BYTE2", "Field 1 byte 2"), ("CC_F2_BYTE1", "Field 2 byte 1"), ("CC_F2_BYTE2", "Field 2 byte 2")])
    ]
    groups += optional.filter { group in report.packs.contains { $0.typeHex == group.1 } }
    return groups.map { title, type, wanted in
      let packs = report.packs.filter { $0.typeHex == type }
      let rows = wanted.compactMap { id, label -> Row? in
        let fields = packs.flatMap(\.fields).filter { $0.id == id }
        // Format-specific fields not defined for this syntax are not implied
        // missing from the tape. Keep a pack-level missing row instead.
        guard !fields.isEmpty else { return nil }
        let meanings = Set(fields.map(\.meaning))
        let statuses = Set(fields.map(\.status))
        let value: String
        if fields.contains(where: { $0.meaning.hasPrefix("Conflicting") }) || meanings.count > 1 {
          value = "Conflicting values — no selection"
        } else if statuses == ["interpreted"] {
          value = fields[0].meaning + " — " + fields[0].confidence.label
        } else {
          value = statuses.sorted().map { $0.capitalized }.joined(separator: " / ") + ": " + fields[0].meaning
        }
        let evidence = report.format + "; frame \(report.frameOrdinal); SHA-256 \(report.frameSHA256). "
          + Set(fields.map(\.reference)).sorted().joined(separator: "; ") + ". "
          + Set(fields.compactMap(\.qualifier)).sorted().joined(separator: "; ") + ". "
          + packs.filter { $0.fields.contains { $0.id == id } }.map {
            "\($0.rawHex) (\($0.observationCount) occurrences); " + (($0.locations?.prefix(4).map(DVMetadataPresentation.location).joined(separator: "; ")) ?? "absolute byte offsets \($0.sourceByteOffsets.prefix(4).map(String.init).joined(separator: ","))")
          }.joined(separator: "; ")
        return Row(label: label, value: value, evidence: evidence)
      }
      return Section(title: title, rows: rows.isEmpty
        ? [Row(label: "Metadata", value: packs.isEmpty ? "Missing pack \(type)" : "Uninterpreted — semantic flags not decoded for this format / transmission",
               evidence: report.formatEvidence)]
        : rows.filter { !$0.isWarning } + rows.filter(\.isWarning))
    }
  }

  /// A sampled live frame is not a completed file. Remove file-wide arithmetic
  /// and relabel the timecode. Capture progress comes from its own counters.
  public func liveReport(progress: [Row]) -> Self {
    let liveSections = sections.map { section -> Section in
      if section.title == "General" {
        return Section(title: section.title, rows: progress + section.rows.filter {
          ["Format", "Commercial name", "Overall bit rate mode", "Overall bit rate", "Recorded date & time"].contains($0.label)
        }.map { Row(label: $0.label, value: $0.value, evidence: $0.evidence.replacingOccurrences(of: "First complete DV frame", with: "Sampled incoming DV frame")) })
      }
      return Section(title: section.title, rows: section.rows.filter {
        $0.label != "Stream size" && $0.label != "Duration"
      }.map {
        Row(label: $0.label == "Time code of first frame" ? "Observed timecode" : $0.label,
            value: $0.value, evidence: $0.evidence.replacingOccurrences(of: "First complete DV frame", with: "Sampled incoming DV frame")
              .replacingOccurrences(of: "at byte offsets", with: "at frame-relative byte offsets"))
      })
    }
    return Self(sections: liveSections, coverage: "Sampled incoming DV metadata, not a whole-tape audit. Brief recording-boundary flags can fall between samples. Recorded flags do not establish deck motion. Raw evidence remains authoritative.", semanticReport: semanticReport)
  }

  public static func completedDuration(bytes: UInt64, frames: UInt64, frameSize: Int?) -> String {
    guard let frameSize, frameSize == 120_000 || frameSize == 144_000 else { return "Unknown — DV system not established" }
    let product = frames.multipliedReportingOverflow(by: UInt64(frameSize))
    guard !product.overflow, product.partialValue == bytes else { return "Unknown — mixed or inconsistent frame sizes" }
    return durationText(Double(frames) / (frameSize == 144_000 ? 25 : 30_000.0 / 1001.0))
  }

  /// Presentation evidence is a separate overlay, never written back into the
  /// source report. Apple geometry and preview choices cannot repair tape flags.
  public func inspectorSections(apple: DVAppleGeometry?, preview: String,
    appleScope: String) -> [Section] {
    let tapeDAR = sections.first { $0.title == "Video" }?.rows.first { $0.label == "Tape-reported display aspect ratio" }?.value
    let comparison: String
    if let tapeDAR, ["4:3", "4:3 — letterboxed", "16:9"].contains(tapeDAR), let ratio = apple?.displayRatio {
      let expected = tapeDAR == "16:9" ? 16.0 / 9 : 4.0 / 3
      comparison = abs(ratio - expected) < 0.001 ? "Agrees with tape-reported DAR"
        : "Conflicting geometry — Apple and tape-reported DAR differ"
    } else { comparison = "Unavailable — both interpretations are needed" }
    let geometry = Section(title: "Apple presentation geometry", rows:
      (apple?.rows ?? DVAppleGeometry.unavailableRows).map {
        Row(label: $0.label, value: $0.value, evidence: appleScope + " " + $0.evidence)
      } + [Row(label: "Aspect comparison", value: comparison,
        evidence: "Compares the tape's DV-pack interpretation with Apple's aperture-aware presentation ratio, not the preview selection. Neither overrides the other. " + appleScope),
        Row(label: "Preview aspect — display only", value: preview,
          evidence: "Current viewing selection; not tape metadata. It never changes the captured or exported DV bytes.")])
    var result = sections
    result.insert(geometry, at: min((result.firstIndex { $0.title == "Video" } ?? 0) + 1, result.count))
    return result
  }

  private static func rawPacks(_ inventory: DVMetadataInventory, type: UInt8, section: UInt8) -> [[UInt8]] {
    let groups = Dictionary(grouping: inventory.extents.filter { $0.section == 0 }, by: \.sequence)
    let headers = groups.compactMapValues { values in values.count == 1 ? values[0].bytes : nil }
    return inventory.extents.filter { $0.section == section }.flatMap { extent -> [[UInt8]] in
      let tfIndex = section == 1 ? 7 : 6
      guard let header = headers[extent.sequence], header.count == 80, header[tfIndex] & 0x80 == 0 else { return [] }
      let slots = section == 1 ? Array(stride(from: 6, through: 46, by: 8)) : Array(stride(from: 3, through: 73, by: 5))
      return slots.compactMap { offset in
        guard offset + 5 <= extent.bytes.count, extent.bytes[offset] == type else { return nil }
        return Array(extent.bytes[offset..<(offset + 5)])
      }
    }
  }

  private static func unique(_ values: [String?]) -> String? {
    guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
    let unique = Set(values.compactMap { $0 })
    return unique.count == 1 ? unique.first : nil
  }
  /// Inspector presentation policy only. Raw packs and archival semantics keep
  /// their two-digit year; the century is inferred from the requested 1990–2026 window.
  static func recordingDate(_ pack: [UInt8]) -> String? {
    guard let original = DVPackSemanticReport.recordedDate(from: pack) else { return nil }
    func bcd(_ value: UInt8) -> Int { Int(value >> 4) * 10 + Int(value & 15) }
    let shortYear = bcd(pack[4]), month = bcd(pack[3] & 0x1f), day = bcd(pack[2] & 0x3f)
    let year: Int
    switch shortYear {
    case 90...99: year = 1900 + shortYear
    case 0...26: year = 2000 + shortYear
    default: return original // Outside the supplied window: no invented century or weekday.
    }
    var calendar = Calendar(identifier: .gregorian)
    // Calendar arithmetic for a local recorded date, not a timezone conversion.
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
      calendar.component(.year, from: date) == year,
      calendar.component(.month, from: date) == month,
      calendar.component(.day, from: date) == day else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEEE, d MMMM yyyy"
    return formatter.string(from: date)
  }
  static func recordingTime(_ pack: [UInt8]) -> String? { DVPackSemanticReport.recordedTime(from: pack) }
  private static func durationText(_ seconds: Double) -> String {
    let ms = Int((seconds * 1000).rounded())
    return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
  }
  private static func sizeText(_ bytes: Double) -> String { String(format: "%.2f MiB", bytes / 1_048_576) }
  private static func rateText(_ bits: Double) -> String {
    bits >= 10_000_000 ? String(format: "%.1f Mb/s", bits / 1_000_000) : String(format: "%.0f kb/s", bits / 1000)
  }
}

/// Immutable Apple format-description evidence, not a guessed DV PAR table.
/// No square-pixel fallback when PAR is absent. Never examines picture content
/// to infer letterboxing. CoreMedia applies aperture and PAR together.
public struct DVAppleGeometry: Sendable, Equatable {
  public let rows: [DVTechnicalSpecifications.Row]
  public let displayRatio: Double?
  public static let unavailableRows: [DVTechnicalSpecifications.Row] = [
    "Stored dimensions", "Storage aspect ratio", "Clean aperture", "Pixel aspect ratio (PAR / sample AR)",
    "Display aspect ratio (DAR)", "Presentation dimensions"
  ].map { .init(label: $0, value: "Unavailable — no Apple geometry observation", evidence: "No defaults synthesized.") }

  public static func inspect(imageBuffer: CVPixelBuffer) -> Self? {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: imageBuffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
    return inspect(format: format)
  }

  public static func inspect(format: CMVideoFormatDescription) -> Self {
    let size = CMVideoFormatDescriptionGetDimensions(format)
    let validRaster = size.width > 0 && size.height > 0
    let par = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any]
    let horizontal = (par?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue
    let vertical = (par?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue
    let validPAR = horizontal.map { $0.isFinite && $0 > 0 && $0 <= Double(Int32.max) && $0.rounded() == $0 } == true
      && vertical.map { $0.isFinite && $0 > 0 && $0 <= Double(Int32.max) && $0.rounded() == $0 } == true
    let aperturePresent = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_CleanAperture) != nil
    let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
    // CoreMedia may silently fall back to the full raster for an invalid
    // aperture. Reject that normalized fallback when an explicit tag disagrees.
    let declared = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_CleanAperture) as? [String: Any]
    func apertureNumber(_ key: CFString) -> Double? {
      guard let value = (declared?[key as String] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
      return value
    }
    let declaredWidth = apertureNumber(kCMFormatDescriptionKey_CleanApertureWidth)
    let declaredHeight = apertureNumber(kCMFormatDescriptionKey_CleanApertureHeight)
    let declaredApertureValid = !aperturePresent ||
      (declaredWidth.map { $0 > 0 && abs($0 - aperture.width) < 0.000001 } == true
       && declaredHeight.map { $0 > 0 && abs($0 - aperture.height) < 0.000001 } == true
       && apertureNumber(kCMFormatDescriptionKey_CleanApertureHorizontalOffset) != nil
       && apertureNumber(kCMFormatDescriptionKey_CleanApertureVerticalOffset) != nil)
    let validAperture = validRaster && declaredApertureValid && aperture.width.isFinite && aperture.height.isFinite
      && aperture.minX.isFinite && aperture.minY.isFinite && aperture.width > 0 && aperture.height > 0
      && aperture.minX >= 0 && aperture.minY >= 0 && aperture.maxX <= Double(size.width) && aperture.maxY <= Double(size.height)
    let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
    let validPresentation = validRaster && validPAR && validAperture
      && presentation.width.isFinite && presentation.height.isFinite && presentation.width > 0 && presentation.height > 0
    let ratio: Double? = validPresentation ? Double(presentation.width / presentation.height) : nil
    func number(_ value: Double) -> String { String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    func dimensions(_ width: Double, _ height: Double) -> String { "\(number(width)) × \(number(height))" }
    func row(_ label: String, _ value: String, _ evidence: String) -> DVTechnicalSpecifications.Row {
      .init(label: label, value: value, evidence: evidence)
    }
    let unavailable = "Unavailable — missing or invalid geometry"
    return Self(rows: [
      row("Stored dimensions", validRaster ? "\(size.width) × \(size.height)" : unavailable,
        "CMVideoFormatDescription coded dimensions; not display pixels."),
      row("Storage aspect ratio", validRaster ? rational(Int64(size.width), Int64(size.height)) : unavailable,
        "Calculated coded width:height. Written out because SAR can instead mean sample aspect ratio (the same as PAR)."),
      row("Clean aperture", validAperture ? (aperturePresent ? dimensions(aperture.width, aperture.height) : "Not reported — full raster used") : unavailable,
        "Apple clean aperture, not detected black-bar cropping. Origin in coded raster: \(number(aperture.origin.x)), \(number(aperture.origin.y))."),
      row("Pixel aspect ratio (PAR / sample AR)", validPAR ? rational(Int64(horizontal!), Int64(vertical!)) : "Unavailable — PAR not reported or invalid",
        "Apple format-description horizontal:vertical pixel spacing. Sample aspect ratio is a synonym, not a third independent ratio."),
      row("Display aspect ratio (DAR)", ratio.map(ratioText) ?? unavailable,
        "Apple presentation width:height with pixel aspect and clean aperture applied. Not the preview override."),
      row("Presentation dimensions", validPresentation ? dimensions(presentation.width, presentation.height) : unavailable,
        "CMVideoFormatDescriptionGetPresentationDimensions, usePixelAspectRatio=true, useCleanAperture=true; before viewing overrides.")
    ], displayRatio: ratio)
  }

  private static func rational(_ numerator: Int64, _ denominator: Int64) -> String {
    var a = numerator, b = denominator
    while b != 0 { (a, b) = (b, a % b) }
    return "\(numerator / a):\(denominator / a)"
  }
  private static func ratioText(_ ratio: Double) -> String {
    if abs(ratio - 4.0 / 3) < 0.000001 { return "4:3" }
    if abs(ratio - 16.0 / 9) < 0.000001 { return "16:9" }
    return String(format: "%.6f:1", ratio)
  }
}
