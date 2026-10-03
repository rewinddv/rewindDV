// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

public enum CaptureDirectory {
  public enum Kind: Sendable { case manual, wholeTape, wholeTapePayload }
  public static func name(kind: Kind, date: Date, timeZone: TimeZone = .current) -> String {
    if kind == .wholeTapePayload { return "Capture" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    // ':' is prohibited on exFAT and Windows. Local time; collision-safe below.
    formatter.dateFormat = "yyyy-MM-dd 'at' HH-mm-ss"
    return (kind == .manual ? "Manual Capture — " : "WholeTape Capture — ") + formatter.string(from: date)
  }
  /// mkdir is the exclusive claim. Never merge into or overwrite an existing
  /// destination (including a symlink), even on same-second or DST collisions.
  public static func create(parent: URL, kind: Kind, date: Date = Date(),
                            timeZone: TimeZone = .current) throws -> URL {
    let base = name(kind: kind, date: date, timeZone: timeZone)
    for attempt in 1...999 {
      let component = base + (attempt == 1 ? "" : String(format: "-%03d", attempt))
      let url = parent.appendingPathComponent(component, isDirectory: true)
      if mkdir(url.path, 0o700) == 0 { return url }
      let error = errno
      guard error == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
  }
}
