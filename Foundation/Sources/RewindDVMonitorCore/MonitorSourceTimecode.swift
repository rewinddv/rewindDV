// Presentation adapter for raw DV subcode observations. BCD masks and source
// system limits retained from RewindDV b3063ff DVMetadataExtractor.decodeTimecode.
import Foundation

public enum MonitorSourceTimecode {
  /// Bounded playback-only extraction with the archival analyzer's complete
  /// frame/section-count checks, without hashing a frame or constructing an
  /// audio-epoch manifest at video cadence. No bytes or packs are repaired.
  public static func display(nativeDVFrame data: Data) -> String? {
    guard data.count == 120_000 || data.count == 144_000 else { return nil }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
      let sequences = data.count / 12_000
      guard bytes[0] >> 5 == 0, bytes[1] >> 4 == 0, bytes[2] == 0 else { return nil }
      var counts = [Int](repeating: 0, count: sequences * 5)
      var packs: [[UInt8]] = []
      packs.reserveCapacity(sequences * 12)
      for offset in stride(from: 0, to: bytes.count, by: 80) {
        let section = Int(bytes[offset] >> 5)
        let sequence = Int(bytes[offset + 1] >> 4)
        guard section < 5, sequence < sequences else { return nil }
        // A second frame start would be two fragments, not one complete frame.
        guard offset == 0 || section != 0 || sequence != 0 || bytes[offset + 2] != 0
        else { return nil }
        counts[sequence * 5 + section] += 1
        if section == 1 {
          for slot in stride(from: 6, through: 46, by: 8) where bytes[offset + slot] == 0x13 {
            packs.append(Array(bytes[(offset + slot)..<(offset + slot + 5)]))
          }
        }
      }
      let expected = [1, 2, 3, 9, 135]
      for sequence in 0..<sequences {
        for section in 0..<5 where counts[sequence * 5 + section] != expected[section] {
          return nil
        }
      }
      return display(packs: packs, isPAL: sequences == 12)
    }
  }

  /// No extrapolation, voting, invented source-system rate, or clock substitution.
  /// Conflicting/malformed observations remain unknown. Color-frame/BGF bits do
  /// not change the displayed timecode; the drop-frame bit does.
  public static func display(packs: [[UInt8]], isPAL: Bool) -> String? {
    guard !packs.isEmpty else { return nil }
    var unique = Set<String>()
    for raw in packs {
      guard raw.count == 5, raw[0] == 0x13,
        let f = bcd(raw[1] & 0x3f), let s = bcd(raw[2] & 0x7f),
        let m = bcd(raw[3] & 0x7f), let h = bcd(raw[4] & 0x3f),
        f < (isPAL ? 25 : 30), s < 60, m < 60, h < 24
      else { return nil }
      let drop = !isPAL && raw[1] & 0x40 != 0
      // Drop-frame numbering omits 00/01 at most minute boundaries.
      guard !(drop && m % 10 != 0 && s == 0 && f < 2) else { return nil }
      unique.insert(String(format: "%02d:%02d:%02d%@%02d", h, m, s, drop ? ";" : ":", f))
    }
    return unique.count == 1 ? unique.first : nil
  }

  private static func bcd(_ value: UInt8) -> Int? {
    let tens = Int(value >> 4)
    let units = Int(value & 0xf)
    return tens < 10 && units < 10 ? tens * 10 + units : nil
  }
}
