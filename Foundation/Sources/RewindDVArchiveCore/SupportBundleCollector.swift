// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Darwin

/// Bounded, read-only evidence collection. No hardware access, media payloads,
/// implicit home-directory scan, symlink traversal or transmission to a server.
public enum SupportBundleCollector {
  /// Shared by the app and standalone collector; capture diagnostics come first
  /// when the caller's aggregate byte budget cannot retain every root.
  public static func applicationRoots(in supportDirectory: URL) -> [URL] {
    ["LiveFlights", "AlphaSessions", "ControlFlights", "PassiveTransportFlights", "InspectorFlights"]
      .map { supportDirectory.appendingPathComponent($0) }
  }

  public static func relativePath(of file: URL, within root: URL) throws -> String {
    func canonical(_ url: URL) throws -> String {
      guard let path = realpath(url.path, nil) else { throw CocoaError(.fileReadUnknown) }
      defer { free(path) }
      return String(cString: path)
    }
    let prefix = try canonical(root) + "/"
    let path = try canonical(file)
    guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadNoPermission) }
    return String(path.dropFirst(prefix.count))
  }
  public struct Entry: Codable, Sendable {
    public let source: String
    public let exported: String?
    public let outcome: String
    public let sourceBytes: Int64?
    public let offset: Int64?
    public let bytes: Int?
    public let sha256: String?
  }
  public struct Manifest: Codable, Sendable {
    public let schema: String
    public let utc: String
    public let entries: [Entry]
    public let limitations: String
  }
  public struct Limits: Sendable {
    public var fileBytes = 8 * 1024 * 1024
    public var totalBytes = 128 * 1024 * 1024
    public var inspectedEntries = 20_000
    public init() {}
  }

  public static func collect(roots: [URL], into destination: URL,
                            limits: Limits = Limits()) throws -> Manifest {
    guard limits.fileBytes >= 2, limits.totalBytes >= 0, limits.inspectedEntries > 0 else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let fm = FileManager.default
    // Exclusive destination: never merge with or overwrite an existing bundle.
    guard mkdir(destination.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var entries: [Entry] = []
    var remaining = limits.totalBytes
    func note(_ url: URL, _ outcome: String) {
      entries.append(Entry(source: url.path, exported: nil, outcome: outcome,
        sourceBytes: nil, offset: nil, bytes: nil, sha256: nil))
    }
    for (rootIndex, root) in roots.enumerated() {
      // Independent enumeration budgets: a long inspection history must not
      // prevent a later receive/capture root from being visited at all.
      var inspected = 0
      // Also reject symlinks in ancestor components of the supplied root.
      guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
        note(root, "omitted: symbolic-link root or ancestor"); continue
      }
      guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        note(root, "unavailable: directory absent or inaccessible"); continue
      }
      guard let walker = fm.enumerator(at: root, includingPropertiesForKeys:
        [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles],
        errorHandler: { url, error in note(url, "enumeration error: \(error.localizedDescription)"); return true }) else {
        note(root, "unavailable: enumeration failed"); continue
      }
      var candidates: [(URL, Date)] = []
      for case let url as URL in walker {
        inspected += 1
        if inspected > limits.inspectedEntries { note(root, "omitted remaining entries: enumeration limit"); break }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
        if values?.isSymbolicLink == true { walker.skipDescendants(); note(url, "omitted: symbolic link"); continue }
        if values?.isDirectory == true { continue }
        // No .raw/.dv/.mov, screenshots, profiles, keys or arbitrary text files.
        guard ["json", "ndjson"].contains(url.pathExtension.lowercased()), values?.isRegularFile == true else { continue }
        candidates.append((url, values?.contentModificationDate ?? .distantPast))
      }
      // Recent first among enumerated candidates. A bounded directory walk is
      // not a guarantee that every newer file was visited; omissions are listed.
      candidates.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
      for (url, _) in candidates {
        if remaining <= 0 { note(url, "omitted: export byte budget exhausted"); continue }
        do {
          let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
          guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
          let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
          defer { try? input.close() }
          var st = stat()
          guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
          let size = st.st_size
          let count = Int(min(Int64(min(remaining, limits.fileBytes)), size))
          let relative = "root-\(rootIndex)/" + (try relativePath(of: url, within: root))
          let truncated = Int64(count) < size
          let ranges: [(Int64, Int, String)] = truncated
            ? [(0, count / 2, ".head"), (size - Int64(count - count / 2), count - count / 2, ".tail")]
            : [(0, count, "")]
          for (offset, length, suffix) in ranges {
            try input.seek(toOffset: UInt64(offset))
            let data = try input.read(upToCount: length) ?? Data()
            guard data.count == length else { throw CocoaError(.fileReadCorruptFile) }
            let outputName = relative + suffix
            let output = destination.appendingPathComponent(outputName)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
              attributes: [.posixPermissions: 0o700])
            try data.write(to: output, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            let reread = try Data(contentsOf: output)
            guard reread == data else { throw CocoaError(.fileReadCorruptFile) }
            entries.append(Entry(source: url.path, exported: outputName,
              outcome: truncated ? "partial: head/tail byte range; NOT a complete journal" : "copied snapshot",
              sourceBytes: size, offset: offset, bytes: data.count,
              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            remaining -= data.count
          }
          var after = stat()
          if fstat(fd, &after) != 0 || after.st_size != size || after.st_mtimespec.tv_sec != st.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != st.st_mtimespec.tv_nsec {
            note(url, "source changed during export; copied bytes are a snapshot, not a finalized original")
          }
        } catch { note(url, "copy failed: \(error.localizedDescription)") }
      }
    }
    let manifest = Manifest(schema: "rewinddv.support-bundle.v1", utc: Date().ISO8601Format(), entries: entries,
      limitations: "Only JSON/NDJSON from explicitly listed roots. Media, raw receive records, hidden files and symlinks excluded. Bounded export; omissions/errors/ranges listed. Paths, GUIDs, timestamps and tape metadata can be personal. No automatic upload. Snapshots do not prove hardware health or lossless acquisition. Keep original capture folders unchanged.")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    return manifest
  }
}
