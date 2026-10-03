// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Publishes a verified regular file without replacing an existing destination.
/// APFS gets its native atomic exclusive rename. Filesystems that do not
/// implement RENAME_EXCL (including exFAT) get an exclusive descriptor-based
/// copy, durable close/readback proof, and only then removal of the partial.
enum DVPortablePublication {
  static func promoteExclusive(
    directoryFD: Int32, from: String, to: String,
    expectedBytes: UInt64, expectedSHA256: String,
    forcePortableCopy: Bool = false
  ) throws {
    guard validName(from), validName(to), from != to else {
      throw DVIngestError.invalidEvidence("publication names are invalid")
    }
    if !forcePortableCopy {
      if renameatx_np(directoryFD, from, directoryFD, to, UInt32(RENAME_EXCL)) == 0 {
        return
      }
      let code = errno
      guard code == ENOTSUP else {
        if code == EEXIST { throw DVIngestError.destinationExists(to) }
        throw DVIngestError.fileOperation("exclusive publication of \(to)", code)
      }
    }

    let sourceFD = openat(directoryFD, from, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard sourceFD >= 0 else { throw DVIngestError.fileOperation("open partial \(to)", errno) }
    defer { Darwin.close(sourceFD) }
    var sourceInfo = stat()
    guard fstat(sourceFD, &sourceInfo) == 0,
      sourceInfo.st_mode & S_IFMT == S_IFREG,
      sourceInfo.st_size >= 0, UInt64(sourceInfo.st_size) == expectedBytes else {
      throw DVIngestError.invalidEvidence("partial \(to) size or type changed before publication")
    }

    let destinationFD = openat(directoryFD, to,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard destinationFD >= 0 else {
      if errno == EEXIST { throw DVIngestError.destinationExists(to) }
      throw DVIngestError.fileOperation("create exclusive final \(to)", errno)
    }
    var openedDestinationInfo = stat()
    guard fstat(destinationFD, &openedDestinationInfo) == 0,
      openedDestinationInfo.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(destinationFD)
      throw DVIngestError.invalidEvidence("new final \(to) is not a regular file")
    }
    var destinationOpen = true
    func closeDestination() {
      if destinationOpen { Darwin.close(destinationFD); destinationOpen = false }
    }
    do {
      guard fcopyfile(sourceFD, destinationFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
        throw DVIngestError.fileOperation("copy verified partial \(to)", errno)
      }
      guard fsync(destinationFD) == 0 else {
        throw DVIngestError.fileOperation("sync copied final \(to)", errno)
      }
      var destinationInfo = stat()
      guard fstat(destinationFD, &destinationInfo) == 0,
        destinationInfo.st_mode & S_IFMT == S_IFREG,
        destinationInfo.st_size >= 0, UInt64(destinationInfo.st_size) == expectedBytes else {
        throw DVIngestError.invalidEvidence("copied final \(to) size or type mismatch")
      }
      guard lseek(destinationFD, 0, SEEK_SET) == 0 else {
        throw DVIngestError.fileOperation("rewind copied final \(to)", errno)
      }
      var digest = SHA256(), copiedBytes: UInt64 = 0
      while true {
        var buffer = Data(count: 1_048_576)
        let amount: Int = try buffer.withUnsafeMutableBytes { region in
          let value = Darwin.read(destinationFD, region.baseAddress!, region.count)
          if value < 0 { throw DVIngestError.fileOperation("reread copied final \(to)", errno) }
          return value
        }
        if amount == 0 { break }
        buffer.removeSubrange(amount..<buffer.count)
        digest.update(data: buffer)
        let (updated, overflow) = copiedBytes.addingReportingOverflow(UInt64(amount))
        guard !overflow else { throw DVIngestError.invalidEvidence("copied final byte count overflow") }
        copiedBytes = updated
      }
      var finalDestinationInfo = stat(), destinationPathInfo = stat(), sourcePathInfo = stat()
      guard fstat(destinationFD, &finalDestinationInfo) == 0,
        fstatat(directoryFD, to, &destinationPathInfo, AT_SYMLINK_NOFOLLOW) == 0,
        fstatat(directoryFD, from, &sourcePathInfo, AT_SYMLINK_NOFOLLOW) == 0,
        finalDestinationInfo.st_dev == destinationInfo.st_dev,
        finalDestinationInfo.st_ino == destinationInfo.st_ino,
        finalDestinationInfo.st_size == destinationInfo.st_size,
        destinationPathInfo.st_mode & S_IFMT == S_IFREG,
        destinationPathInfo.st_dev == destinationInfo.st_dev,
        destinationPathInfo.st_ino == destinationInfo.st_ino,
        sourcePathInfo.st_mode & S_IFMT == S_IFREG,
        sourcePathInfo.st_dev == sourceInfo.st_dev,
        sourcePathInfo.st_ino == sourceInfo.st_ino else {
        throw DVIngestError.invalidEvidence("publication path identity changed during copy")
      }
      let copiedSHA = digest.finalize().map { String(format: "%02x", $0) }.joined()
      guard copiedBytes == expectedBytes, copiedSHA == expectedSHA256 else {
        throw DVIngestError.invalidEvidence("copied final \(to) hash mismatch")
      }
      closeDestination()
    } catch {
      closeDestination()
      var pathInfo = stat()
      if fstatat(directoryFD, to, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
        pathInfo.st_dev == openedDestinationInfo.st_dev,
        pathInfo.st_ino == openedDestinationInfo.st_ino {
        _ = unlinkat(directoryFD, to, 0)
      }
      throw error
    }
    closeDestination()
    guard unlinkat(directoryFD, from, 0) == 0 else {
      throw DVIngestError.fileOperation("remove published partial \(to)", errno)
    }
  }

  /// A completion marker whose directory barrier fails must not remain visible
  /// as proof of success. Retaining a `.partial` is preferred where supported;
  /// removal is the portable fail-closed fallback.
  static func withdrawCompletionMarkerBestEffort(
    directoryFD: Int32, from: String, to: String
  ) {
    guard validName(from), validName(to), from != to else { return }
    if renameatx_np(directoryFD, from, directoryFD, to, UInt32(RENAME_EXCL)) != 0 {
      _ = unlinkat(directoryFD, from, 0)
    }
    _ = fsync(directoryFD)
  }

  private static func validName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/")
  }
}
