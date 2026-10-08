// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Raw pack geometry and stable report identities. Numeric coordinates remain
/// distinct from generated presentation and qualified semantic decoding.
public enum DVPackCatalog {
  static let reconciliationReference = "INFERENCE: user-supplied DV pack research reconciliation, 2026-10-07; corroboration with existing EP1668434A1 layout fragments where available; complete IEC images and metadata-recovery package not available for inspection; not final-IEC qualification"
  public struct Entry: Sendable, Equatable {
    public let header: UInt8
    public let group: String
    public let name: String
    public let allocation: String
    public let evidence: String
    public let confidence: DVMetadataConfidence
    public var components: [Component] { DVPackCatalog.components.filter { $0.pack == header } }
    public var hasQualifiedSDLayout: Bool { !components.isEmpty && header != 0x56 && header != 0x66 }
  }
  public struct Component: Sendable, Equatable {
    public let id: String
    public let pack: UInt8
    public let name: String
    public let byte: Int
    public let mask: UInt8
    public let shift: Int
    public let width: Int
    public let aggregate: Bool
    public let confidence: DVMetadataConfidence
    public let reference: String
    public let qualifier: String
    public func extract(_ bytes: [UInt8]) -> UInt8? {
      guard bytes.count == 5, bytes[0] == pack, (1...4).contains(byte) else { return nil }
      return (bytes[byte] & mask) >> shift
    }
  }
  public static func entry(_ header: UInt8) -> Entry { entries[Int(header)] }
  /// Compatibility profile gate. MIC-only and MPEG fields are never promoted
  /// from ordinary SD DIF observations, even if their bytes happen to match.
  public static func permitsSDObservation(_ type: UInt8, context: String) -> Bool {
    guard context == "subcode-frame" || context == "vaux-frame" || context.hasPrefix("aaux-") else { return false }
    guard entry(type).allocation == "named" || type >= 0xf0 else { return false }
    if [0x00,0x01,0x02,0x03,0x04,0x05,0x1f,0x42,0x7b].contains(type) { return false }
    if [0x5a,0x5b,0x5e,0x5f].contains(type) { return context != "vaux-frame" }
    if (0x90...0x9f).contains(type) { return false }
    if type == 0x13 { return context == "subcode-frame" }
    if (0x6a...0x7f).contains(type) || (0x88...0x8f).contains(type) { return !context.hasPrefix("aaux-") }
    if (0x80...0x83).contains(type) { return context == "vaux-frame" }
    // Main-area source, recording and caption families retain their area gate.
    if (0x50...0x56).contains(type) { return context.hasPrefix("aaux-") || ([0x52,0x53].contains(type) && context == "subcode-frame") }
    if (0x60...0x67).contains(type) { return context == "vaux-frame" || ([0x62,0x63].contains(type) && context == "subcode-frame") }
    return true // common optional areas; raw position remains separately recorded
  }
  public static let entries: [Entry] = (0...255).map { value in
    let h = UInt8(value), low = Int(h & 15), group = Int(h >> 4)
    let reserved: Set<UInt8> = [0x25,0x26,0x27,0x2c,0x2d,0x35,0x36,0x37,0x3c,0x3d,0x45,0x46,0x47,0x4c,0x4d,0x57,0x5c,0x5d,0x72,0x7a,0x84,0x85,0x86,0x87,0x8c,0x8d,0x96,0x9c,0x9d]
    let allocation = reserved.contains(h) ? "reserved" : (0xa0...0xef).contains(h) ? "unassigned" : h == 0xf0 ? "maker-code" : h >= 0xf1 ? "maker-defined" : "named"
    let groups = ["Control","Title","Chapter","Part","Programme","AAUX","VAUX","Camera","Line","MPEG"]
    let family = group < groups.count ? groups[group] : group == 15 ? "Soft mode":"Unassigned"
    var names: [String] = []
    switch group {
    case 0: names = ["Cassette ID","Tape length","Timer date","Timer start/stop","Playback/record start time","Playback/record start track","Tag number / Genre","Topic/page header","Text header","Text","Tag time","Tag track","Teletext information","Key","Zone end time","Zone end control"]
    case 1: names = ["Total time","Remaining time","Chapter total","Timecode","Binary group","Cassette number","Catalogue ID","ISRC","Text header","Text","Start time","Start track","Reel ID low","Reel ID high","End time","End track"]
    case 2,3,4: names = ["Total time","Remaining time",group == 2 ? "Chapter number":group == 3 ? "Part number":"Recording date/time","Timecode","Binary group","Reserved","Reserved","Reserved","Text header","Text","Start time","Start track","Reserved","Reserved","End time","End track"]
    case 5,6: names = ["Source","Source control","Recording date","Recording time","Binary group","Closed caption","Transparent data",group == 5 ? "Reserved":"Teletext","Text header","Text","Start time","Start track",group == 5 ? "Reserved":"Marine/mountain",group == 5 ? "Reserved":"Longitude/latitude","End time","End track"]
    case 7: names = ["Consumer Camera 1","Consumer Camera 2","Reserved","Lens","Gain","Pedestal","Gamma","Detail","Text header","Text","Reserved","Preset","Flare","Shading","Knee","Shutter"]
    case 8: names = ["Header","Y","Cr","Cb","Reserved","Reserved","Reserved","Reserved","Text header","Text","Start time","Start track","Reserved","Reserved","End time","End track"]
    case 9: names = ["Source","Source control","Recording date","Recording time","Binary group","Stream","Reserved","Extended track number","Text header","Text","Service start time","Service start track","Reserved","Reserved","Service end time","Service end track"]
    default: break
    }
    let name = group == 7 ? ["Consumer Camera 1","Consumer Camera 2","Reserved","Lens","Gain","Pedestal","Gamma","Detail","Camera Text Header","Camera Text","Reserved","Camera Preset","Flare","Shading","Knee","Shutter"][low] : names.isEmpty ? (h == 0xf0 ? "Maker code":h >= 0xf1 ? "Manufacturer option":"Unassigned") : family + " " + names[low]
    var evidence = "PRIMARY_STANDARD: IEC 61834-4:1998/AMD1:2010, replacement Table 1; " + DVIEC61834.reference(h)
    if (0xa0...0xef).contains(h) { evidence = "PRIMARY_STANDARD: amended Table 1 leaves A0–EF unassigned; no payload semantics assigned." }
    if h == 0xff { evidence += "; amended allocation is OPTION; unchanged base §12.16 defines all-FF NO INFO. Payload interpretation retains this discrepancy." }
    return Entry(header:h,group:family,name:name,allocation:allocation,evidence:evidence,confidence:.normativeConfirmed)
  }

  // Coordinates and stable report IDs are compatibility facts, sorted by
  // physical location. Display labels/prose are independently generated below.
  private struct Geometry {
    let pack: UInt8
    let byte: Int
    let mask: UInt8
    let shift: Int
    let width: Int
    let aggregate: Bool
    let id: String
    let confidence: DVMetadataConfidence
    let reference: String
  }
  private static let geometry: [Geometry] = [
    Geometry(pack: 0x00, byte: 1, mask: 0x03, shift: 0, width: 2, aggregate: false, id: "00.memory_type_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 1, mask: 0x1C, shift: 2, width: 3, aggregate: false, id: "00.multi_bytes_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 1, mask: 0x60, shift: 5, width: 2, aggregate: false, id: "00.fixed_pc1_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 1, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "00.mic_event_reliability_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "00.last_bank_size_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "00.space0_size_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "00.space1_bank_count_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "00.tape_thickness_tenths_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x00, byte: 4, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "00.tape_thickness_units_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.1, printed p.11; MIC main area"),
    Geometry(pack: 0x01, byte: 1, mask: 0x01, shift: 0, width: 1, aggregate: false, id: "01.fixed_pc1_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12; MIC main area"),
    Geometry(pack: 0x01, byte: 1, mask: 0xFE, shift: 1, width: 7, aggregate: false, id: "01.length_low_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12; MIC main area"),
    Geometry(pack: 0x01, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "01.length_middle_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12; MIC main area"),
    Geometry(pack: 0x01, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "01.length_high_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12; MIC main area"),
    Geometry(pack: 0x01, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "01.fixed_pc4_raw", confidence: .normativeConfirmed, reference: "PRIMARY_STANDARD: IEC 61834-4:1998 §3.2, printed p.12; MIC main area"),
    Geometry(pack: 0x08, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "08.tdp_low_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 2, mask: 0x01, shift: 0, width: 1, aggregate: false, id: "08.tdp_high_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 2, mask: 0x0E, shift: 1, width: 3, aggregate: false, id: "08.option_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "08.text_type_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "08.text_code_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 4, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "08.menu_topic_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x08, byte: 4, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "08.menu_area_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 1, mask: 0x01, shift: 0, width: 1, aggregate: false, id: "0B.blank_flag_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 1, mask: 0xFE, shift: 1, width: 7, aggregate: false, id: "0B.atn_low_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "0B.atn_middle_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "0B.atn_high_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "0B.tag_id_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 4, mask: 0x10, shift: 4, width: 1, aggregate: false, id: "0B.fixed_pc4_bit4_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 4, mask: 0x20, shift: 5, width: 1, aggregate: false, id: "0B.hold_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 4, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "0B.temporary_true_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x0B, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "0B.text_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x13, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "13.frames", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x13, byte: 1, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "13.drop_frame_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x13, byte: 1, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "13.color_frame_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x13, byte: 2, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "13.seconds", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x13, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "13.pc2_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x13, byte: 3, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "13.minutes", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x13, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "13.pc3_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x13, byte: 4, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "13.hours", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x13, byte: 4, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "13.pc4_high_flags_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x14, byte: 1, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "14.binary_group_1", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 1, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "14.binary_group_2", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "14.binary_group_3", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "14.binary_group_4", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 3, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "14.binary_group_5", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 3, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "14.binary_group_6", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "14.binary_group_7", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x14, byte: 4, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "14.binary_group_8", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x18, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "18.tdp_low_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x18, byte: 2, mask: 0x01, shift: 0, width: 1, aggregate: false, id: "18.tdp_high_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x18, byte: 2, mask: 0x0E, shift: 1, width: 3, aggregate: false, id: "18.option_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x18, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "18.text_type_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x18, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "18.text_code_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x18, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "18.pc4_uninterpreted_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "42.minute_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "42.record_mode_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 2, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "42.hour_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 2, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "42.weekday_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "42.day_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 3, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "42.year_high_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "42.month_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x42, byte: 4, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "42.year_low_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x50, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "50.af_size_code", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 1, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "50.reserved_pc1_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 1, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "50.lf_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "50.audio_mode_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 2, mask: 0x10, shift: 4, width: 1, aggregate: false, id: "50.pair_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 2, mask: 0x60, shift: 5, width: 2, aggregate: false, id: "50.channels_per_block_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "50.stereo_mode_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "50.stype_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 3, mask: 0x20, shift: 5, width: 1, aggregate: false, id: "50.system_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 3, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "50.multi_language_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "50.reserved_pc3_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 4, mask: 0x07, shift: 0, width: 3, aggregate: false, id: "50.quantization_code", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 4, mask: 0x38, shift: 3, width: 3, aggregate: false, id: "50.sampling_code", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 4, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "50.emphasis_time_constant_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x50, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "50.emphasis_off_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x51, byte: 1, mask: 0x03, shift: 0, width: 2, aggregate: false, id: "51.ss_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 1, mask: 0x0C, shift: 2, width: 2, aggregate: false, id: "51.cmp_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 1, mask: 0x30, shift: 4, width: 2, aggregate: false, id: "51.isr_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "51.cgms_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 2, mask: 0x07, shift: 0, width: 3, aggregate: false, id: "51.insert_channel_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 2, mask: 0x38, shift: 3, width: 3, aggregate: false, id: "51.record_mode_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 2, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "51.record_end_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "51.record_start_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 3, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "51.speed_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "51.direction_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 4, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "51.genre_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x51, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "51.reserved_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "52.timezone_bcd_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: true, id: "52.timezone_byte_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x52, byte: 1, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "52.half_hour_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 1, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "52.daylight_saving_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 2, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "52.day", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x52, byte: 2, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "52.date_reserved_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "52.month", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x52, byte: 3, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "52.weekday_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x52, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "52.year_two_digits", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x53, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "53.frames_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x53, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "53.pc1_high_flags_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x53, byte: 2, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "53.seconds", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x53, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "53.pc2_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x53, byte: 3, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "53.minutes", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x53, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "53.pc3_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x53, byte: 4, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "53.hours", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x53, byte: 4, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "53.pc4_high_flags_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x54, byte: 1, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "54.binary_group_1", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 1, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "54.binary_group_2", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "54.binary_group_3", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "54.binary_group_4", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 3, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "54.binary_group_5", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 3, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "54.binary_group_6", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "54.binary_group_7", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x54, byte: 4, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "54.binary_group_8", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 1, mask: 0x07, shift: 0, width: 3, aggregate: false, id: "55.main_type_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 1, mask: 0x38, shift: 3, width: 3, aggregate: false, id: "55.main_language_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "55.fixed_pc1_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 2, mask: 0x07, shift: 0, width: 3, aggregate: false, id: "55.second_type_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 2, mask: 0x38, shift: 3, width: 3, aggregate: false, id: "55.second_language_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 2, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "55.fixed_pc2_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "55.fixed_pc3_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x55, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "55.fixed_pc4_raw", confidence: .provisional, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x56, byte: 1, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "56.data_type_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x56, byte: 1, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "56.data_low_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x56, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "56.data_middle1_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x56, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "56.data_middle2_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x56, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "56.data_high_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x60, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "60.tv_channel_low_byte", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "60.tv_channel_high_digit", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 2, mask: 0x30, shift: 4, width: 2, aggregate: false, id: "60.color_frame_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 2, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "60.color_validity_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "60.black_white_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "60.stype_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 3, mask: 0x20, shift: 5, width: 1, aggregate: false, id: "60.system_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 3, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "60.source_code_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x60, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "60.tuner_category_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x61, byte: 1, mask: 0x03, shift: 0, width: 2, aggregate: false, id: "61.ss_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 1, mask: 0x0C, shift: 2, width: 2, aggregate: false, id: "61.cmp_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 1, mask: 0x30, shift: 4, width: 2, aggregate: false, id: "61.isr_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "61.cgms_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 2, mask: 0x07, shift: 0, width: 3, aggregate: false, id: "61.display_code", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 2, mask: 0x08, shift: 3, width: 1, aggregate: false, id: "61.reserved_pc2_bit3_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 2, mask: 0x30, shift: 4, width: 2, aggregate: false, id: "61.record_mode_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 2, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "61.reserved_pc2_bit6_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "61.record_start_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x03, shift: 0, width: 2, aggregate: false, id: "61.broadcast_system_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x04, shift: 2, width: 1, aggregate: false, id: "61.still_camera_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x08, shift: 3, width: 1, aggregate: false, id: "61.still_field_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x10, shift: 4, width: 1, aggregate: false, id: "61.interlaced_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x20, shift: 5, width: 1, aggregate: false, id: "61.frame_change_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "61.first_second_field_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "61.frame_field_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 4, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "61.genre_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x61, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "61.reserved_pc4_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "62.timezone_bcd_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: true, id: "62.timezone_byte_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x62, byte: 1, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "62.half_hour_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 1, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "62.daylight_saving_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 2, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "62.day", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x62, byte: 2, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "62.date_reserved_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "62.month", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x62, byte: 3, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "62.weekday_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x62, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "62.year_two_digits", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x63, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "63.frames_raw", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x63, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "63.pc1_high_flags_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x63, byte: 2, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "63.seconds", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x63, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "63.pc2_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x63, byte: 3, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "63.minutes", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x63, byte: 3, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "63.pc3_high_flag_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x63, byte: 4, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "63.hours", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x63, byte: 4, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "63.pc4_high_flags_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x64, byte: 1, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "64.binary_group_1", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 1, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "64.binary_group_2", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "64.binary_group_3", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "64.binary_group_4", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 3, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "64.binary_group_5", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 3, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "64.binary_group_6", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "64.binary_group_7", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x64, byte: 4, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "64.binary_group_8", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x65, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "65.field_1_byte_1", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x65, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "65.field_1_byte_2", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x65, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "65.field_2_byte_1", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x65, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "65.field_2_byte_2", confidence: .implementationCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp"),
    Geometry(pack: 0x66, byte: 1, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "66.data_type_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x66, byte: 1, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "66.data_low_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x66, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "66.data_middle1_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x66, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "66.data_middle2_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x66, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "66.data_high_raw", confidence: .conflictingEvidence, reference: "Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x70, byte: 1, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "70.iris_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "70.fixed_high_bits_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 2, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "70.automatic_gain_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "70.auto_exposure_mode_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 3, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "70.white_balance_setting_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 3, mask: 0xE0, shift: 5, width: 3, aggregate: false, id: "70.white_balance_mode_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 4, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "70.focus_position_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x70, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "70.focus_mode_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 1, mask: 0x1F, shift: 0, width: 5, aggregate: false, id: "71.vertical_pan_speed_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 1, mask: 0x20, shift: 5, width: 1, aggregate: false, id: "71.vertical_pan_direction_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 1, mask: 0xC0, shift: 6, width: 2, aggregate: false, id: "71.fixed_high_bits_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 2, mask: 0x3F, shift: 0, width: 6, aggregate: false, id: "71.horizontal_pan_speed_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 2, mask: 0x40, shift: 6, width: 1, aggregate: false, id: "71.horizontal_pan_direction_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 2, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "71.image_stabilizer_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "71.focal_length_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 4, mask: 0x0F, shift: 0, width: 4, aggregate: false, id: "71.electric_zoom_tenths_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 4, mask: 0x70, shift: 4, width: 3, aggregate: false, id: "71.electric_zoom_units_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x71, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "71.electric_zoom_enable_raw", confidence: .independentlyCorroborated, reference: "MediaInfoLib dd11d797, File_DvDif.cpp; JohnstonJ/video-tools b6a12951, DV pack layouts"),
    Geometry(pack: 0x7F, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "7F.professional_upper_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x7F, byte: 2, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "7F.professional_lower_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x7F, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "7F.consumer_low_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x7F, byte: 4, mask: 0x7F, shift: 0, width: 7, aggregate: false, id: "7F.consumer_high_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
    Geometry(pack: 0x7F, byte: 4, mask: 0x80, shift: 7, width: 1, aggregate: false, id: "7F.fixed_high_bit_raw", confidence: .implementationCorroborated, reference: "JohnstonJ/video-tools b6a12951, DV pack layouts; Manufacturer reference EP1668434A1; candidate geometry"),
  ]
  private static let reconciliationGeometry: [Geometry] = [
    Geometry(pack: 0x68, byte: 1, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "68.tdp_low_raw", confidence: .provisional, reference: reconciliationReference),
    Geometry(pack: 0x68, byte: 2, mask: 0x01, shift: 0, width: 1, aggregate: false, id: "68.tdp_high_raw", confidence: .provisional, reference: reconciliationReference),
    Geometry(pack: 0x68, byte: 2, mask: 0x0E, shift: 1, width: 3, aggregate: false, id: "68.option_raw", confidence: .provisional, reference: reconciliationReference),
    Geometry(pack: 0x68, byte: 2, mask: 0xF0, shift: 4, width: 4, aggregate: false, id: "68.text_type_raw", confidence: .provisional, reference: reconciliationReference),
    Geometry(pack: 0x68, byte: 3, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "68.text_code_raw", confidence: .provisional, reference: reconciliationReference),
    Geometry(pack: 0x68, byte: 4, mask: 0xFF, shift: 0, width: 8, aggregate: false, id: "68.pc4_uninterpreted_raw", confidence: .provisional, reference: reconciliationReference),
  ]
  public static let components: [Component] = (geometry + reconciliationGeometry).map { g in
    var qualification = "Bit location only; physical meaning requires a separately qualified rule."
    switch g.confidence {
    case .provisional: qualification += " Candidate layout; the applicable final standard was not verified."
    case .conflictingEvidence: qualification += " Sources disagree; retain the observed bits without selecting an interpretation."
    default: qualification += " Implementation evidence does not establish full standard or device qualification."
    }
    switch g.pack {
    case 0x00, 0x01: qualification += " MIC definition only. MIC was not acquired; a DIF occurrence does not establish cassette identity, capacity or remaining tape."
    case 0x66: qualification += " The patent payload diagram uses header 0x67 while its supported-pack list gives 0x66; this disagreement is not resolved."
    case 0x13: qualification += " Timecode flag meaning depends on 525/60 versus 625/50 and companion context."
    case 0x14, 0x54, 0x64: qualification += " User-bit meaning requires its selector or companion pack."
    case 0x50, 0x51: qualification += " Consumer layout; do not apply it as a professional-audio layout."
    case 0x60, 0x61: qualification += " A system or display code alone cannot identify the full video profile."
    case 0x70, 0x71: qualification += " This raw field does not independently qualify a physical-unit conversion or sentinel."
    default: break
    }
    return Component(id: g.id, pack: g.pack,
      name: "PC\(g.byte) bits \(g.shift + g.width - 1):\(g.shift)" + (g.aggregate ? " aggregate" : ""),
      byte: g.byte, mask: g.mask, shift: g.shift, width: g.width, aggregate: g.aggregate,
      confidence: g.confidence, reference: g.reference, qualifier: qualification)
  }
}
