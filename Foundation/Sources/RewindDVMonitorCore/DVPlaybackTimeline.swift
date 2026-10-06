// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Read-only playback coordinates. Runs retain format changes, never picture
/// bytes. Both systems have exact integer cadence in a 30,000 Hz timeline.
/// Source timecode is independent and is not used to infer missing pictures.
public struct DVPlaybackTimeline: Sendable {
  public struct Run: Sendable, Equatable {
    public let firstFrame: Int
    public let byteOffset: UInt64
    public let startTick: Int64
    public let isPAL: Bool
    public var frameCount: Int
    public var frameBytes: Int { isPAL ? 144_000 : 120_000 }
    public var frameTicks: Int64 { isPAL ? 1200 : 1001 }
  }
  public struct Frame: Sendable {
    public let ordinal: Int
    public let byteOffset: UInt64
    public let byteCount: Int
    public let startTick: Int64
    public let durationTicks: Int64
    public var seconds: Double { Double(startTick) / 30_000 }
    public var isPAL: Bool { byteCount == 144_000 }
  }
  public struct Failure: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
  }
  public let runs: [Run]
  public let frameCount: Int
  public let durationTicks: Int64
  private let identity: Identity
  public var durationSeconds: Double { Double(durationTicks) / 30_000 }
  public var byteCount: UInt64 { identity.size }

  private struct Identity: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    let device: UInt64
    init(_ url: URL) throws {
      let a = try FileManager.default.attributesOfItem(atPath: url.path)
      guard a[.type] as? FileAttributeType == .typeRegular,
        let size = a[.size] as? NSNumber, let modified = a[.modificationDate] as? Date,
        let inode = a[.systemFileNumber] as? NSNumber, let device = a[.systemNumber] as? NSNumber
      else { throw Failure(reason: "Playback requires a readable regular DV file.") }
      self.size = size.uint64Value; self.modified = modified
      self.inode = inode.uint64Value; self.device = device.uint64Value
    }
  }

  public static func read(url: URL, inspect: ((Data, Int, UInt64) throws -> Void)? = nil) throws -> Self {
    let identity = try Identity(url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var runs: [Run] = [], offset: UInt64 = 0, ordinal = 0, tick: Int64 = 0
    while offset < identity.size {
      try Task.checkCancellation()
      try autoreleasepool {
        let header = try handle.read(upToCount: 80) ?? Data()
        guard header.count == 80, header[0] >> 5 == 0,
          header[1] >> 4 == 0, header[2] == 0 else {
          throw Failure(reason: "Invalid DV frame boundary at byte \(offset). Original bytes are unchanged.")
        }
        let pal = header[3] & 0x80 != 0, count = pal ? 144_000 : 120_000
        let bytes = header + (try handle.read(upToCount: count - 80) ?? Data())
        try validate(bytes, at: offset)
        try inspect?(bytes, ordinal, offset)
        if runs.last?.isPAL == pal { runs[runs.count - 1].frameCount += 1 }
        else { runs.append(Run(firstFrame: ordinal, byteOffset: offset,
          startTick: tick, isPAL: pal, frameCount: 1)) }
        ordinal += 1; offset += UInt64(count); tick += pal ? 1200 : 1001
      }
    }
    guard ordinal > 0 else { throw Failure(reason: "The selected DV file is empty.") }
    guard identity == (try Identity(url)) else {
      throw Failure(reason: "The source changed while its playback timeline was being read. Reopen the finished capture.")
    }
    return Self(runs: runs, frameCount: ordinal, durationTicks: tick, identity: identity)
  }

  public func verifyUnchanged(url: URL) throws {
    guard identity == (try Identity(url)) else {
      throw Failure(reason: "The source file changed. Reopen it to rebuild the playback timeline.")
    }
  }

  public func frame(_ ordinal: Int) -> Frame {
    let ordinal = min(max(0, ordinal), frameCount - 1)
    let run = runs[lastRun { $0.firstFrame <= ordinal }]
    let relative = ordinal - run.firstFrame
    return Frame(ordinal: ordinal,
      byteOffset: run.byteOffset + UInt64(relative) * UInt64(run.frameBytes),
      byteCount: run.frameBytes, startTick: run.startTick + Int64(relative) * run.frameTicks,
      durationTicks: run.frameTicks)
  }

  public func frame(at seconds: Double) -> Frame {
    let clamped = seconds.isFinite ? min(durationSeconds, max(0, seconds)) : 0
    let tick = Int64(floor(clamped * 30_000 + 0.000_01))
    let run = runs[lastRun { $0.startTick <= tick }]
    return frame(run.firstFrame + min(run.frameCount - 1, Int((tick - run.startTick) / run.frameTicks)))
  }

  private func lastRun(where predicate: (Run) -> Bool) -> Int {
    var low = 0, high = runs.count
    while low < high {
      let mid = low + (high - low) / 2
      if predicate(runs[mid]) { low = mid + 1 } else { high = mid }
    }
    return max(0, low - 1)
  }

  public func readFrame(_ ordinal: Int, from handle: FileHandle) throws -> Data {
    try Task.checkCancellation()
    let item = frame(ordinal)
    try handle.seek(toOffset: item.byteOffset)
    let bytes = try handle.read(upToCount: item.byteCount) ?? Data()
    try Self.validate(bytes, at: item.byteOffset)
    guard bytes.count == item.byteCount else {
      throw Failure(reason: "DV system changed at byte \(item.byteOffset). Reopen the source.")
    }
    return bytes
  }

  /// Ordered DIF identity checks protect positional sample/audio reads. Damaged
  /// picture/audio contents are retained; a broken boundary is not guessed past.
  public static func validate(_ frame: Data, at offset: UInt64) throws {
    let valid = frame.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
      guard p.count == 120_000 || p.count == 144_000,
        (p[3] & 0x80 != 0) == (p.count == 144_000) else { return false }
      for i in 0..<(p.count / 80) {
        let local = i % 150, sequence = i / 150, at = i * 80
        let section: Int, number: Int
        if local == 0 { section = 0; number = 0 }
        else if local < 3 { section = 1; number = local - 1 }
        else if local < 6 { section = 2; number = local - 3 }
        else if (local - 6) % 16 == 0 { section = 3; number = (local - 6) / 16 }
        else { section = 4; number = local - 7 - (local - 6) / 16 }
        guard Int(p[at] >> 5) == section, Int(p[at + 1] >> 4) == sequence,
          Int(p[at + 2]) == number,
          section != 0 || (p[at + 3] & 0x80 != 0) == (p.count == 144_000)
        else { return false }
      }
      return true
    }
    guard valid else {
      throw Failure(reason: "Incomplete or unordered DV frame at byte \(offset). Original bytes are unchanged; no frame boundary was guessed.")
    }
  }
}
