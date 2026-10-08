// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded, read-only assembly. Every repetition keeps its own observations.
/// A complete byte queue is not proof of intact text, picture or tape history.
public enum DVIECSequences {
  public struct Observation: Codable, Equatable, Sendable {
    public let bytes: [UInt8]
    public let location: DVMetadataLocation?
    public let qualified: Bool
    public init(_ bytes: [UInt8], location: DVMetadataLocation? = nil, qualified: Bool = true) {
      self.bytes = bytes; self.location = location; self.qualified = qualified
    }
  }
  public struct Component: Codable, Equatable, Sendable {
    public let header: UInt8
    public let expectedSamples: Int?
    public let samples: [UInt8]
    public let padding: [UInt8]
    public let status: String
  }
  public struct Sequence: Codable, Equatable, Sendable {
    public let kind: String
    public let observations: [Observation]
    public let payload: [UInt8]
    public let expectedCount: Int
    public let countUnit: String
    public let status: String
    public let reference: String
    public var characterSets: [String:UInt8]? = nil
    public var components: [Component]? = nil
  }
  public enum ChromaPlan: Sendable { case paired, alternating, unknown }

  /// The caller supplies an ordered queue from one recording area. Invalid or
  /// truncated observations interrupt it; they are never skipped to fill a hole.
  public static func assemble(_ input: [Observation], chroma: ChromaPlan = .unknown) -> [Sequence] {
    guard input.count <= 1800 else { return [] }
    var result: [Sequence] = [], i = 0
    while i < input.count {
      let start = input[i], p = start.bytes
      guard p.count == 5, start.qualified else { i += 1; continue }
      let text = p[0] < 0xa0 && p[0]&15 == 8
      guard text || p[0] == 0x80 else { i += 1; continue }
      var observations = [start], j = i+1
      let teletext = (p[0] == 0x68 || p[0] == 0x98) && p[2]>>4 == 10
      let expected = text ? Int(p[1]) | Int(p[2]&1)<<8 : Int(p[3]) | Int(p[4]&7)<<8
      let following = teletext ? UInt8(0x67):p[0]+1
      // Teletext INFO is optional immediately before the payload queue.
      if teletext, j < input.count, input[j].qualified, input[j].bytes.count == 5, input[j].bytes[0] == 0x0c {
        observations.append(input[j]); j += 1
      }
      var data: [Observation] = []
      while j < input.count, input[j].qualified, input[j].bytes.count == 5 {
        let h = input[j].bytes[0]
        guard text ? h == following : (0x81...0x83).contains(h) else { break }
        if text && data.count == expected { break }
        data.append(input[j]); j += 1
      }
      observations += data
      let payload = data.flatMap { Array($0.bytes.dropFirst()) }
      var sequence = Sequence(kind: text ? (teletext ? "teletext":"text"):"line", observations:observations,
        payload:payload, expectedCount:expected, countUnit:text ? "packs":"samples",
        status:text ? (data.count == expected ? "complete byte queue":"incomplete byte queue"):"sample counts require component assessment",
        reference:DVIEC61834.reference(p[0]))
      if text {
        sequence.characterSets = DVIEC61834.characterSets(code:p[3],option:(p[2]>>1)&7)
      } else {
        let q = p[4]>>6
        let width = q < 3 ? [2,4,8][Int(q)]:0
        let first = data.first?.bytes[0]
        var plan: [UInt8:Int] = [:]
        if first == 0x81 { plan[0x81] = expected }
        else if first == 0x82 || first == 0x83 {
          switch chroma {
          case .paired: if expected%2 == 0 { plan = [0x82:expected/2,0x83:expected/2] }
          case .alternating: plan[first!] = expected
          case .unknown: break
          }
        }
        let observedHeaders = Set(data.map { $0.bytes[0] })
        sequence.components = Set(plan.keys).union(observedHeaders).sorted().map { h in
          let raw = data.filter { $0.bytes[0] == h }.flatMap { Array($0.bytes.dropFirst()) }
          let unpacked: [UInt8] = width == 0 ? []:raw.flatMap { b in
            stride(from:0,to:8,by:width).map { (b>>$0)&UInt8((1<<width)-1) }
          }
          guard let count = plan[h], width != 0, expected > 0 else {
            return Component(header:h,expectedSamples:nil,samples:unpacked,padding:[],status:"unresolved quantization or component allocation")
          }
          let samples = Array(unpacked.prefix(count)), padding = Array(unpacked.dropFirst(count))
          let expectedPacks = (count*width+31)/32
          let packCount = data.filter { $0.bytes[0] == h }.count
          let status = samples.count < count ? "incomplete":packCount != expectedPacks ? "excess packs":padding.allSatisfy { $0 == UInt8((UInt16(1)<<width)-1) } ? "complete":"invalid padding"
          return Component(header:h,expectedSamples:count,samples:samples,padding:padding,status:status)
        }
      }
      result.append(sequence)
      i = max(i+1,j)
    }
    return result
  }

  /// ID decoding only at an established teletext packet boundary. Part 4 does
  /// not supply the referenced systems' packet lengths or character decoders.
  public struct TeletextID: Codable, Equatable, Sendable {
    public let raw: UInt8
    public let system: UInt8
    public let secondField: Bool
    public let lineCode: UInt8
    public let lineNumber: Int?
    public let status: String
  }
  public static func teletextID(_ byte: UInt8, isPAL: Bool) -> TeletextID {
    let line = byte&31, second = byte&32 != 0
    let number = line <= (isPAL ? 17:12) ? (isPAL ? (second ? 318:6):(second ? 272:10))+Int(line):nil
    return .init(raw:byte,system:byte>>6,secondField:second,lineCode:line,lineNumber:number,
      status:line == 31 ? "terminate":byte>>6 == 2 || number == nil ? "reserved":"interpreted")
  }

  /// §11.1 reduced quantization levels, expressed on the 8-bit scale. Zero is
  /// below black, not an invented calibrated analogue level.
  public static func level(_ sample: UInt8, bits: Int) -> Int? {
    guard [2,4,8].contains(bits), Int(sample) < 1<<bits else { return nil }
    return bits == 8 ? Int(sample):sample == 0 ? nil:Int(sample) << (8-bits)
  }

  static func inspect(_ report: DVPackSemanticReport, isPAL: Bool) -> [Sequence] {
    guard report.format == "IEC 61834 consumer DV" else { return [] }
    // A valid section TF does not establish each subcode sync ID. Reuse the
    // structural assessment; absent or invalid IDs interrupt assembly without
    // removing the underlying pack observations from the semantic report.
    let validSubcodeIDs = Set((report.structuralMetadata ?? [])
      .filter { $0.id.hasPrefix("sync-") }
      .flatMap(\.locations)
      .filter { $0.section == 1 && $0.transmission == "valid" }
      .map(\.localByteOffset))
    var areas: [String:[Observation]] = [:]
    for pack in report.packs {
      let raw = pack.rawHex.split(separator:" ").compactMap { UInt8($0,radix:16) }
      guard raw.count == 5 else { continue }
      for loc in pack.locations ?? [] {
        let area = loc.section == 3 ? "audio-\(loc.sequence < (isPAL ? 6:5) ? 0:1)":"section-\(loc.section)"
        let scope = loc.section == 1 ? "subcode-frame":loc.section == 2 ? "vaux-frame":"aaux-frame"
        let applicable = DVPackCatalog.permitsSDObservation(raw[0],context:scope)
        let syncQualified = loc.section != 1 || (loc.localByteOffset >= 3 && validSubcodeIDs.contains(loc.localByteOffset - 3))
        areas[area,default:[]].append(.init(raw,location:loc,qualified:loc.transmission == "valid" && applicable && syncQualified))
      }
    }
    // Chroma interpretation requires an agreed SD source, not just PAL/NTSC size.
    let sourceTypes = report.packs.filter { $0.typeHex == "0x60" }.flatMap(\.fields).filter { $0.id == "STYPE" }
    let sd = !sourceTypes.isEmpty && sourceTypes.allSatisfy { $0.status == "interpreted" && $0.rawValue == 0 }
    return areas.keys.sorted().flatMap { area in
      let queue = areas[area]!.sorted { a,b in
        let x = a.location!, y = b.location!
        return (x.sequence,x.block,x.localByteOffset) < (y.sequence,y.block,y.localByteOffset)
      }
      let chroma: ChromaPlan = sd ? (isPAL ? .alternating:.paired):.unknown
      // Inventory/report input may omit a rejected extent. A sorted queue is
      // not evidence that every intervening slot was observed. Keep those gaps
      // as assembly boundaries, using local coordinates even for live samples.
      var sequences: [Sequence] = [], run: [Observation] = []
      for observation in queue {
        if let previous = run.last, !consecutive(previous.location!, observation.location!) {
          sequences += assemble(run, chroma: chroma)
          run.removeAll(keepingCapacity: true)
        }
        run.append(observation)
      }
      return sequences + assemble(run, chroma: chroma)
    }
  }

  private static func consecutive(_ a: DVMetadataLocation, _ b: DVMetadataLocation) -> Bool {
    guard a.section == b.section, a.frameOrdinal == b.frameOrdinal else { return false }
    let slots: Int, blocks: Int
    switch a.section {
    case 1: slots = 6; blocks = 2
    case 2: slots = 15; blocks = 3
    case 3: slots = 1; blocks = 9
    default: return false
    }
    guard (0..<slots).contains(a.slot), (0..<slots).contains(b.slot),
      Int(a.block) < blocks, Int(b.block) < blocks else { return false }
    let first = (Int(a.sequence) * blocks + Int(a.block)) * slots + a.slot
    let second = (Int(b.sequence) * blocks + Int(b.block)) * slots + b.slot
    return second == first + 1
  }
}
