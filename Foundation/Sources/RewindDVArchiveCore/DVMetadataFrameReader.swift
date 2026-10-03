// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Offline, bounded-memory access to a single frame. No persistent file handle,
/// capture-path work, source modification, or inference across format changes.
public enum DVMetadataFrameReader {
  public static func read(url: URL, ordinal: UInt64) throws -> DVMetadataInventory {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let length = try input.seekToEnd()
    var offset: UInt64 = 0, index: UInt64 = 0
    while offset < length {
      try Task.checkCancellation()
      try input.seek(toOffset: offset)
      guard let header = try input.read(upToCount: 80), header.count == 80,
        header[0] >> 5 == 0, header[1] >> 4 == 0, header[2] == 0 else {
        throw DVIngestError.invalidEvidence("Invalid DV frame header at byte \(offset); no resynchronization or guessed frame numbering")
      }
      let count: UInt64 = header[3] & 0x80 == 0 ? 120_000 : 144_000
      guard count <= length - offset else {
        throw DVIngestError.invalidEvidence("Incomplete DV frame at byte \(offset); original bytes are unchanged")
      }
      // Validate every traversed frame's structure; a plausible header alone
      // must not assign a later frame an unproven ordinal.
      guard let tail = try input.read(upToCount: Int(count) - 80), tail.count == Int(count) - 80 else {
        throw DVIngestError.invalidEvidence("Source changed or frame read was incomplete")
      }
      let inventory = try DVMetadataInventory.inspect(frame: header + tail, ordinal: index, byteOffset: offset)
      if index == ordinal { return inventory }
      offset += count
      index += 1
    }
    throw DVIngestError.invalidEvidence("Frame \(ordinal) is outside this file (frame numbering starts at zero)")
  }
}
