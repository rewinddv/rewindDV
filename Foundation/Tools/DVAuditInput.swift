// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Read-only regular-file access for offline audit tools; never follows a final symlink.
import Foundation
import CryptoKit
import Darwin

final class DVAuditInput {
  private let handle: FileHandle
  let byteCount: Int64

  init(_ url: URL, maximumBytes: Int64? = nil) throws {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open audit input", errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, maximumBytes.map({ info.st_size <= $0 }) ?? true else {
      _ = Darwin.close(fd)
      throw DVIngestError.invalidEvidence("Audit input must be a regular file within the size limit")
    }
    byteCount = info.st_size
    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func close() { try? handle.close() }

  func readExactly(_ count: Int) throws -> Data? {
    guard count >= 0, count <= 1_048_576 else {
      throw DVIngestError.invalidEvidence("Audit read exceeds bounded chunk size")
    }
    if count == 0 { return Data() }
    var result = Data()
    while result.count < count {
      guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
        if result.isEmpty { return nil }
        throw DVIngestError.invalidEvidence("Truncated audit input")
      }
      result.append(part)
    }
    return result
  }

  static func boundedMetadata(_ url: URL) throws -> Data {
    let input = try DVAuditInput(url, maximumBytes: 1_048_576)
    defer { input.close() }
    let data = try input.readExactly(Int(input.byteCount)) ?? Data()
    guard try input.readExactly(1) == nil else {
      throw DVIngestError.invalidEvidence("Metadata grew during audit")
    }
    return data
  }

  static func hash(_ url: URL) throws -> String {
    let input = try DVAuditInput(url)
    defer { input.close() }
    var remaining = input.byteCount, hash = SHA256()
    while remaining > 0 {
      let size = Int(min(remaining, 1_048_576))
      guard let data = try input.readExactly(size) else {
        throw DVIngestError.invalidEvidence("Input shrank during hash")
      }
      hash.update(data: data); remaining -= Int64(size)
    }
    guard try input.readExactly(1) == nil else {
      throw DVIngestError.invalidEvidence("Input grew during hash")
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
