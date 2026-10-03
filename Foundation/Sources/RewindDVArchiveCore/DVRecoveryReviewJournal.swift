// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// A recoverable, append-only operator review sidecar. It is deliberately
/// separate from capture and tape-map evidence and has no hardware or merge
/// execution surface.
public actor DVRecoveryReviewJournal {
  public static let manifestFileName = "review.json"
  public static let eventLedgerFileName = "review-events.ndjson"
  public static let eventsPerPage: UInt64 = 256

  public enum ReviewState: String, Codable, Equatable, Sendable {
    case unreviewed
    case deferred
    case reviewed
    case flaggedForOperatorDecision = "flagged_for_operator_decision"
  }

  public struct Manifest: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let evidenceBinding: DVTapeEvidenceLedgerReader.Binding
    public let eventLedgerFile: String
    public let reviewAuthority: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case evidenceBinding = "evidence_binding"
      case eventLedgerFile = "event_ledger_file"
      case reviewAuthority = "review_authority"
    }
  }

  public struct Item: Codable, Equatable, Sendable {
    public let id: String
    public let sourceSHA256: String
    public let mapReceiptSHA256: String
    public let frameLedgerSHA256: String
    public let firstFrameOrdinal: UInt64
    public let endFrameOrdinalExclusive: UInt64
    public let sourceByteOffset: UInt64
    public let sourceByteEndExclusive: UInt64
    public let issueCodes: [DVTapeEvidenceMapExporter.IssueCode]
    public let summary: String
    public let anchorFrameSHA256: String?
    public let rawPackProvenance: [DVTapeDefectInspector.RawPackProvenance]

    private enum CodingKeys: String, CodingKey {
      case id, summary
      case sourceSHA256 = "source_sha256"
      case mapReceiptSHA256 = "map_receipt_sha256"
      case frameLedgerSHA256 = "frame_ledger_sha256"
      case firstFrameOrdinal = "first_frame_ordinal"
      case endFrameOrdinalExclusive = "end_frame_ordinal_exclusive"
      case sourceByteOffset = "source_byte_offset"
      case sourceByteEndExclusive = "source_byte_end_exclusive"
      case issueCodes = "issue_codes"
      case anchorFrameSHA256 = "anchor_frame_sha256"
      case rawPackProvenance = "raw_pack_provenance"
    }
  }

  public struct Event: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let revision: UInt64
    public let item: Item
    public let state: ReviewState
    public let operatorNote: String?
    public let actionAuthority: String

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case revision, item, state
      case operatorNote = "operator_note"
      case actionAuthority = "action_authority"
    }
  }

  public struct EventPage: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let pageNumber: UInt64
    public let firstRevision: UInt64
    public let endRevisionExclusive: UInt64
    public let pageSHA256: String
    public let events: [Event]

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case pageNumber = "page_number"
      case firstRevision = "first_revision"
      case endRevisionExclusive = "end_revision_exclusive"
      case pageSHA256 = "page_sha256"
      case events
    }
  }

  public struct CurrentItemsPage: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let pageNumber: UInt64
    public let totalCurrentItemCount: UInt64
    public let itemsPerPage: UInt64
    /// Latest revision for each stable item, ordered by frame range then ID.
    public let latestEvents: [Event]

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case pageNumber = "page_number"
      case totalCurrentItemCount = "total_current_item_count"
      case itemsPerPage = "items_per_page"
      case latestEvents = "latest_events"
    }
  }

  public nonisolated let manifest: Manifest
  public nonisolated var evidenceBinding: DVTapeEvidenceLedgerReader.Binding {
    manifest.evidenceBinding
  }
  private let directoryURL: URL
  private let directoryFD: Int32
  private let directoryStatus: stat
  private let eventFD: Int32
  private let manifestSHA256: String
  private let manifestByteCount: UInt64
  private var eventStatus: stat
  private var pageIndexes: [EventPageIndex]
  private var currentItemIndexes: [String: CurrentItemIndex]
  private var currentItemOrder: [String]
  private var latestRevision: UInt64
  private var uncertainAfterWriteFailure = false

  public static func create(
    at directory: URL,
    evidenceMapDirectory: URL,
    binding: DVTapeEvidenceLedgerReader.Binding
  ) throws -> DVRecoveryReviewJournal {
    try rejectEvidenceMapDescendant(directory, evidenceMapDirectory: evidenceMapDirectory)
    return try DVRecoveryReviewJournal(directory: directory, binding: binding, create: true)
  }

  public static func open(
    at directory: URL,
    evidenceMapDirectory: URL,
    expectedBinding: DVTapeEvidenceLedgerReader.Binding
  ) throws -> DVRecoveryReviewJournal {
    try rejectEvidenceMapDescendant(directory, evidenceMapDirectory: evidenceMapDirectory)
    return try DVRecoveryReviewJournal(directory: directory, binding: expectedBinding, create: false)
  }

  private init(
    directory: URL,
    binding: DVTapeEvidenceLedgerReader.Binding,
    create: Bool
  ) throws {
    try Self.validate(binding)
    let directoryFD: Int32
    if create {
      directoryFD = try Self.createDirectory(directory)
    } else {
      directoryFD = Darwin.open(
        directory.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard directoryFD >= 0 else {
        throw DVIngestError.fileOperation("open recovery review sidecar", errno)
      }
    }
    var keepDirectory = false
    defer { if !keepDirectory { Darwin.close(directoryFD) } }
    var directoryStatus = stat()
    guard fstat(directoryFD, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR else {
      throw DVIngestError.invalidEvidence("recovery review sidecar is not a directory")
    }
    let expectedManifest = Manifest(
      schemaVersion: 1, evidenceBinding: binding,
      eventLedgerFile: Self.eventLedgerFileName,
      reviewAuthority:
        "operator_review_state_only; no_hardware_recapture_replacement_alignment_deletion_or_merge_authority")
    let manifest: Manifest
    let manifestData: Data
    let eventFD: Int32
    if create {
      manifestData = try Self.encode(expectedManifest) + Data([10])
      try Self.writeExclusive(directoryFD: directoryFD, name: Self.manifestFileName,
        data: manifestData)
      eventFD = openat(directoryFD, Self.eventLedgerFileName,
        O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard eventFD >= 0 else {
        throw DVIngestError.fileOperation("create recovery review event ledger", errno)
      }
      guard fsync(directoryFD) == 0 else {
        let code = errno
        Darwin.close(eventFD)
        throw DVIngestError.fileOperation("synchronize recovery review sidecar", code)
      }
      manifest = expectedManifest
    } else {
      manifestData = try Self.readRegularFile(
        directoryFD: directoryFD, name: Self.manifestFileName, maximumByteCount: 2_097_152)
      do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) }
      catch { throw DVIngestError.invalidEvidence("recovery review manifest JSON is invalid") }
      guard manifest == expectedManifest else {
        throw DVIngestError.invalidEvidence("recovery review manifest is not bound to this tape map")
      }
      eventFD = openat(directoryFD, Self.eventLedgerFileName,
        O_RDWR | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard eventFD >= 0 else {
        throw DVIngestError.fileOperation("open recovery review event ledger", errno)
      }
    }
    var keepEvent = false
    defer { if !keepEvent { Darwin.close(eventFD) } }
    var eventStatus = stat()
    guard fstat(eventFD, &eventStatus) == 0,
      eventStatus.st_mode & S_IFMT == S_IFREG, eventStatus.st_size >= 0 else {
      throw DVIngestError.invalidEvidence("recovery review event ledger is not a regular file")
    }
    // Actor isolation protects one instance only. Keep one writer for this
    // inode across instances/processes before reading the revision authority.
    // Closing eventFD (including failed initialization) releases the lock.
    guard flock(eventFD, LOCK_EX | LOCK_NB) == 0 else {
      throw DVIngestError.fileOperation("acquire exclusive recovery review writer", errno)
    }
    let scan = try Self.scanEvents(fd: eventFD, binding: binding)
    guard fstat(directoryFD, &directoryStatus) == 0 else {
      throw DVIngestError.fileOperation("bind recovery review sidecar directory", errno)
    }
    self.manifest = manifest
    self.directoryURL = directory
    self.directoryFD = directoryFD
    self.directoryStatus = directoryStatus
    self.eventFD = eventFD
    self.manifestSHA256 = Self.hex(SHA256.hash(data: manifestData))
    self.manifestByteCount = UInt64(manifestData.count)
    self.eventStatus = eventStatus
    self.pageIndexes = scan.indexes
    self.currentItemIndexes = scan.currentItems
    self.currentItemOrder = scan.currentItems.values.sorted(by: Self.itemIndexLess).map(\.itemID)
    self.latestRevision = scan.latestRevision
    keepDirectory = true
    keepEvent = true
  }

  deinit {
    Darwin.close(eventFD)
    Darwin.close(directoryFD)
  }

  public func status() throws -> (latestRevision: UInt64, pageCount: UInt64) {
    try requireCurrentFiles()
    return (latestRevision, UInt64(pageIndexes.count))
  }

  public func currentItemCount() throws -> UInt64 {
    try requireCurrentFiles()
    return UInt64(currentItemIndexes.count)
  }

  public func currentItemsPage(_ pageNumber: UInt64) throws -> CurrentItemsPage {
    try Task.checkCancellation()
    let pageCount = currentItemOrder.isEmpty ? 0
      : (currentItemOrder.count - 1) / Int(Self.eventsPerPage) + 1
    guard pageNumber < UInt64(pageCount), pageNumber <= UInt64(Int.max) else {
      throw DVIngestError.invalidEvidence("current recovery review page number is outside the queue")
    }
    try requireCurrentFiles()
    let start = Int(pageNumber) * Int(Self.eventsPerPage)
    let end = min(start + Int(Self.eventsPerPage), currentItemOrder.count)
    var events: [Event] = []
    events.reserveCapacity(end - start)
    for itemID in currentItemOrder[start..<end] {
      guard let index = currentItemIndexes[itemID] else {
        throw DVIngestError.invalidEvidence("current recovery review sparse index is inconsistent")
      }
      let data = try Self.preadExactly(fd: eventFD, offset: index.byteOffset,
        count: Int(index.byteCount))
      guard Self.hex(SHA256.hash(data: data)) == index.sha256,
        data.last == 10 else {
        throw DVIngestError.invalidEvidence("current recovery review item hash mismatch")
      }
      let event: Event
      do { event = try JSONDecoder().decode(Event.self, from: Data(data.dropLast())) }
      catch { throw DVIngestError.invalidEvidence("current recovery review item JSON is invalid") }
      try Self.validate(event, expectedRevision: index.revision, binding: evidenceBinding)
      events.append(event)
    }
    try requireCurrentFiles()
    return CurrentItemsPage(schemaVersion: 1, pageNumber: pageNumber,
      totalCurrentItemCount: UInt64(currentItemOrder.count), itemsPerPage: Self.eventsPerPage,
      latestEvents: events)
  }

  public nonisolated static func makeItem(
    from model: DVTapeDefectInspector.Model,
    issueCodes: [DVTapeEvidenceMapExporter.IssueCode]? = nil,
    summary: String
  ) throws -> Item {
    let selected = issueCodes ?? model.issues.map(\.code)
    let available = Set(model.issues.map(\.code))
    guard !selected.isEmpty, Set(selected).count == selected.count,
      selected.allSatisfy({ available.contains($0) }) else {
      throw DVIngestError.invalidEvidence("review item issue selection is empty, duplicate, or absent from the inspected frame")
    }
    let draft = Item(
      id: "", sourceSHA256: model.sourceSHA256,
      mapReceiptSHA256: model.mapReceiptSHA256,
      frameLedgerSHA256: model.frameLedgerSHA256,
      firstFrameOrdinal: model.frameOrdinal,
      endFrameOrdinalExclusive: try add(model.frameOrdinal, 1, "review item frame end"),
      sourceByteOffset: model.sourceByteOffset,
      sourceByteEndExclusive: model.sourceByteEndExclusive,
      issueCodes: selected.sorted { $0.rawValue < $1.rawValue },
      summary: summary, anchorFrameSHA256: model.frameSHA256,
      rawPackProvenance: model.rawPackProvenance)
    return try withStableID(draft)
  }

  public nonisolated static func makeRangeItem(
    binding: DVTapeEvidenceLedgerReader.Binding,
    firstFrameOrdinal: UInt64,
    endFrameOrdinalExclusive: UInt64,
    issueCodes: [DVTapeEvidenceMapExporter.IssueCode],
    summary: String
  ) throws -> Item {
    let snapshot = binding.mapReceipt.sourceSnapshot
    let start = try multiply(firstFrameOrdinal, UInt64(snapshot.frameByteCount),
      "review range byte start")
    let end = try multiply(endFrameOrdinalExclusive, UInt64(snapshot.frameByteCount),
      "review range byte end")
    let draft = Item(
      id: "", sourceSHA256: snapshot.sourceSHA256,
      mapReceiptSHA256: binding.mapReceiptSHA256,
      frameLedgerSHA256: binding.mapReceipt.frameLedgerSHA256,
      firstFrameOrdinal: firstFrameOrdinal,
      endFrameOrdinalExclusive: endFrameOrdinalExclusive,
      sourceByteOffset: start, sourceByteEndExclusive: end,
      issueCodes: issueCodes.sorted { $0.rawValue < $1.rawValue },
      summary: summary, anchorFrameSHA256: nil, rawPackProvenance: [])
    return try withStableID(draft)
  }

  public func append(
    item: Item,
    state: ReviewState,
    operatorNote: String? = nil,
    expectedRevision: UInt64
  ) throws -> Event {
    guard !uncertainAfterWriteFailure else {
      throw DVIngestError.invalidEvidence(
        "recovery review journal write durability is uncertain; reopen before continuing")
    }
    try Task.checkCancellation()
    try Self.validate(item, binding: evidenceBinding)
    guard expectedRevision == latestRevision else {
      throw DVIngestError.invalidEvidence("recovery review revision changed; reload before appending")
    }
    if let operatorNote {
      guard operatorNote.utf8.count <= 4_096 else {
        throw DVIngestError.invalidEvidence("recovery review operator note exceeds bounded size")
      }
    }
    let revision = try Self.add(latestRevision, 1, "recovery review revision")
    let event = Event(
      schemaVersion: 1, revision: revision, item: item, state: state,
      operatorNote: operatorNote,
      actionAuthority:
        "review_state_only; this event cannot initiate capture_control_replacement_or_merge")
    let line = try Self.encode(event) + Data([10])
    guard line.count <= 65_536 else {
      throw DVIngestError.invalidEvidence("recovery review event exceeds bounded line size")
    }
    try requireCurrentFiles()
    if let previous = currentItemIndexes[item.id] {
      let previousData = try Self.preadExactly(fd: eventFD, offset: previous.byteOffset,
        count: Int(previous.byteCount))
      guard Self.hex(SHA256.hash(data: previousData)) == previous.sha256,
        previousData.last == 10,
        let previousEvent = try? JSONDecoder().decode(Event.self, from: Data(previousData.dropLast())) else {
        throw DVIngestError.invalidEvidence("current recovery review item changed")
      }
      guard previousEvent.item != item || previousEvent.state != state
        || previousEvent.operatorNote != operatorNote else {
        throw DVIngestError.invalidEvidence("duplicate recovery review state event refused")
      }
    }
    // Final cancellation point. A write that starts is driven to fsync or an
    // explicit uncertain lockout; it is never silently retried.
    try Task.checkCancellation()
    do {
      try Self.appendAll(fd: eventFD, data: line)
      guard fsync(eventFD) == 0, fsync(directoryFD) == 0 else {
        throw DVIngestError.fileOperation("synchronize recovery review event", errno)
      }
      latestRevision = revision
      try updateIndex(with: line, revision: revision)
      let isNewItem = currentItemIndexes[item.id] == nil
      let currentIndex = CurrentItemIndex(
        itemID: item.id, firstFrameOrdinal: item.firstFrameOrdinal,
        endFrameOrdinalExclusive: item.endFrameOrdinalExclusive,
        revision: revision, byteOffset: UInt64(eventStatus.st_size),
        byteCount: UInt64(line.count), sha256: Self.hex(SHA256.hash(data: line)))
      currentItemIndexes[item.id] = currentIndex
      if isNewItem {
        let insertion = currentItemOrder.firstIndex {
          guard let existing = currentItemIndexes[$0] else { return false }
          return Self.itemIndexLess(currentIndex, existing)
        } ?? currentItemOrder.endIndex
        currentItemOrder.insert(item.id, at: insertion)
      }
      guard fstat(eventFD, &eventStatus) == 0 else {
        throw DVIngestError.fileOperation("reinspect recovery review event ledger", errno)
      }
      return event
    } catch {
      uncertainAfterWriteFailure = true
      throw error
    }
  }

  public func eventsPage(_ pageNumber: UInt64) throws -> EventPage {
    try Task.checkCancellation()
    guard pageNumber < UInt64(pageIndexes.count), pageNumber <= UInt64(Int.max) else {
      throw DVIngestError.invalidEvidence("recovery review page number is outside the journal")
    }
    try requireCurrentFiles()
    let index = pageIndexes[Int(pageNumber)]
    let data = try Self.preadExactly(fd: eventFD, offset: index.byteOffset,
      count: Int(index.byteCount))
    guard Self.hex(SHA256.hash(data: data)) == index.sha256 else {
      throw DVIngestError.invalidEvidence("recovery review selected page hash mismatch")
    }
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true else {
      throw DVIngestError.invalidEvidence("recovery review page is incomplete")
    }
    var events: [Event] = []
    for (position, line) in lines.dropLast().enumerated() {
      let event: Event
      do { event = try JSONDecoder().decode(Event.self, from: Data(line)) }
      catch { throw DVIngestError.invalidEvidence("recovery review page JSON is invalid") }
      let expected = try Self.add(index.firstRevision, UInt64(position), "review page revision")
      try Self.validate(event, expectedRevision: expected, binding: evidenceBinding)
      events.append(event)
    }
    guard UInt64(events.count) == index.endRevisionExclusive - index.firstRevision else {
      throw DVIngestError.invalidEvidence("recovery review page event count mismatch")
    }
    try requireCurrentFiles()
    return EventPage(schemaVersion: 1, pageNumber: pageNumber,
      firstRevision: index.firstRevision,
      endRevisionExclusive: index.endRevisionExclusive,
      pageSHA256: index.sha256, events: events)
  }

  private struct EventPageIndex {
    let firstRevision: UInt64
    let endRevisionExclusive: UInt64
    let byteOffset: UInt64
    let byteCount: UInt64
    let sha256: String
  }

  private struct CurrentItemIndex {
    let itemID: String
    let firstFrameOrdinal: UInt64
    let endFrameOrdinalExclusive: UInt64
    let revision: UInt64
    let byteOffset: UInt64
    let byteCount: UInt64
    let sha256: String
  }

  private static func itemIndexLess(_ lhs: CurrentItemIndex, _ rhs: CurrentItemIndex) -> Bool {
    if lhs.firstFrameOrdinal != rhs.firstFrameOrdinal {
      return lhs.firstFrameOrdinal < rhs.firstFrameOrdinal
    }
    if lhs.endFrameOrdinalExclusive != rhs.endFrameOrdinalExclusive {
      return lhs.endFrameOrdinalExclusive < rhs.endFrameOrdinalExclusive
    }
    return lhs.itemID < rhs.itemID
  }

  private struct ScanResult {
    let indexes: [EventPageIndex]
    let latestRevision: UInt64
    let currentItems: [String: CurrentItemIndex]
  }

  private func updateIndex(with line: Data, revision: UInt64) throws {
    if pageIndexes.isEmpty || pageIndexes.last!.endRevisionExclusive - pageIndexes.last!.firstRevision == Self.eventsPerPage {
      let offset = UInt64(eventStatus.st_size)
      pageIndexes.append(EventPageIndex(firstRevision: revision,
        endRevisionExclusive: revision + 1, byteOffset: offset,
        byteCount: UInt64(line.count), sha256: Self.hex(SHA256.hash(data: line))))
      return
    }
    let last = pageIndexes.removeLast()
    guard last.byteCount <= 16_777_216 else {
      throw DVIngestError.invalidEvidence("recovery review page exceeds bounded size")
    }
    var data = try Self.preadExactly(fd: eventFD, offset: last.byteOffset,
      count: Int(last.byteCount))
    data.append(line)
    pageIndexes.append(EventPageIndex(firstRevision: last.firstRevision,
      endRevisionExclusive: revision + 1, byteOffset: last.byteOffset,
      byteCount: UInt64(data.count), sha256: Self.hex(SHA256.hash(data: data))))
  }

  private func requireCurrentFiles() throws {
    var heldDirectory = stat(), pathDirectory = stat(), heldEvent = stat(), pathEvent = stat()
    guard fstat(directoryFD, &heldDirectory) == 0,
      lstat(directoryURL.path, &pathDirectory) == 0,
      fstat(eventFD, &heldEvent) == 0,
      fstatat(directoryFD, Self.eventLedgerFileName, &pathEvent, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw DVIngestError.fileOperation("reinspect recovery review sidecar", errno)
    }
    guard Self.sameIdentity(heldDirectory, directoryStatus),
      pathDirectory.st_mode & S_IFMT == S_IFDIR,
      pathDirectory.st_dev == directoryStatus.st_dev,
      pathDirectory.st_ino == directoryStatus.st_ino,
      Self.sameIdentity(heldEvent, eventStatus),
      pathEvent.st_mode & S_IFMT == S_IFREG,
      pathEvent.st_dev == eventStatus.st_dev,
      pathEvent.st_ino == eventStatus.st_ino else {
      throw DVIngestError.invalidEvidence("recovery review sidecar identity or metadata changed")
    }
    let manifestData = try Self.readRegularFile(directoryFD: directoryFD,
      name: Self.manifestFileName, maximumByteCount: 2_097_152)
    guard UInt64(manifestData.count) == manifestByteCount,
      Self.hex(SHA256.hash(data: manifestData)) == manifestSHA256 else {
      throw DVIngestError.invalidEvidence("recovery review manifest bytes changed")
    }
    let current: Manifest
    do { current = try JSONDecoder().decode(Manifest.self, from: manifestData) }
    catch { throw DVIngestError.invalidEvidence("recovery review manifest changed or is invalid") }
    guard current == manifest else {
      throw DVIngestError.invalidEvidence("recovery review evidence binding changed")
    }
  }

  private static func scanEvents(
    fd: Int32,
    binding: DVTapeEvidenceLedgerReader.Binding
  ) throws -> ScanResult {
    guard lseek(fd, 0, SEEK_SET) == 0 else {
      throw DVIngestError.fileOperation("rewind recovery review ledger", errno)
    }
    var indexes: [EventPageIndex] = []
    var revision: UInt64 = 0
    var pageFirst: UInt64 = 1
    var pageOffset: UInt64 = 0
    var pageBytes: UInt64 = 0
    var pageHash = SHA256()
    var eventByteOffset: UInt64 = 0
    var currentItems: [String: CurrentItemIndex] = [:]
    _ = try scanLines(fd: fd, maximumLineBytes: 65_536) { line, rawLine in
      let event: Event
      do { event = try JSONDecoder().decode(Event.self, from: line) }
      catch { throw DVIngestError.invalidEvidence("recovery review event JSON is invalid") }
      revision = try add(revision, 1, "recovery review revision")
      try validate(event, expectedRevision: revision, binding: binding)
      currentItems[event.item.id] = CurrentItemIndex(
        itemID: event.item.id,
        firstFrameOrdinal: event.item.firstFrameOrdinal,
        endFrameOrdinalExclusive: event.item.endFrameOrdinalExclusive,
        revision: revision, byteOffset: eventByteOffset,
        byteCount: UInt64(rawLine.count), sha256: hex(SHA256.hash(data: rawLine)))
      eventByteOffset = try add(eventByteOffset, UInt64(rawLine.count),
        "recovery review event offset")
      pageHash.update(data: rawLine)
      pageBytes = try add(pageBytes, UInt64(rawLine.count), "recovery review page bytes")
      if revision - pageFirst + 1 == eventsPerPage {
        indexes.append(EventPageIndex(firstRevision: pageFirst,
          endRevisionExclusive: revision + 1, byteOffset: pageOffset,
          byteCount: pageBytes, sha256: hex(pageHash.finalize())))
        pageOffset = try add(pageOffset, pageBytes, "recovery review page offset")
        pageFirst = revision + 1
        pageBytes = 0
        pageHash = SHA256()
      }
    }
    if pageBytes > 0 {
      indexes.append(EventPageIndex(firstRevision: pageFirst,
        endRevisionExclusive: revision + 1, byteOffset: pageOffset,
        byteCount: pageBytes, sha256: hex(pageHash.finalize())))
    }
    return ScanResult(indexes: indexes, latestRevision: revision, currentItems: currentItems)
  }

  private static func validate(_ binding: DVTapeEvidenceLedgerReader.Binding) throws {
    guard binding.schemaVersion == 1, binding.mapReceipt.schemaVersion == 1,
      binding.mapReceipt.completionState == "complete",
      isSHA256(binding.mapReceiptSHA256),
      isSHA256(binding.mapReceipt.sourceSnapshot.sourceSHA256),
      isSHA256(binding.mapReceipt.frameLedgerSHA256),
      binding.recordsPerPage == DVTapeEvidenceLedgerReader.recordsPerPage else {
      throw DVIngestError.invalidEvidence("recovery review evidence binding is invalid")
    }
  }

  private static func validate(
    _ event: Event,
    expectedRevision: UInt64,
    binding: DVTapeEvidenceLedgerReader.Binding
  ) throws {
    guard event.schemaVersion == 1, event.revision == expectedRevision,
      event.actionAuthority == "review_state_only; this event cannot initiate capture_control_replacement_or_merge",
      event.operatorNote?.utf8.count ?? 0 <= 4_096 else {
      throw DVIngestError.invalidEvidence("recovery review event schema or revision is invalid")
    }
    try validate(event.item, binding: binding)
  }

  private static func validate(
    _ item: Item,
    binding: DVTapeEvidenceLedgerReader.Binding
  ) throws {
    let snapshot = binding.mapReceipt.sourceSnapshot
    let start = try multiply(item.firstFrameOrdinal, UInt64(snapshot.frameByteCount),
      "review item byte start")
    let end = try multiply(item.endFrameOrdinalExclusive, UInt64(snapshot.frameByteCount),
      "review item byte end")
    let expectedID = try stableID(item)
    guard item.sourceSHA256 == snapshot.sourceSHA256,
      item.mapReceiptSHA256 == binding.mapReceiptSHA256,
      item.frameLedgerSHA256 == binding.mapReceipt.frameLedgerSHA256,
      item.firstFrameOrdinal < item.endFrameOrdinalExclusive,
      item.endFrameOrdinalExclusive <= snapshot.frameCount,
      item.sourceByteOffset == start, item.sourceByteEndExclusive == end,
      !item.issueCodes.isEmpty,
      Set(item.issueCodes).count == item.issueCodes.count,
      item.issueCodes == item.issueCodes.sorted(by: { $0.rawValue < $1.rawValue }),
      !item.summary.isEmpty, item.summary.utf8.count <= 1_024,
      item.rawPackProvenance.count <= 1_800,
      item.anchorFrameSHA256.map(isSHA256) ?? true,
      item.id == expectedID else {
      throw DVIngestError.invalidEvidence("recovery review item binding, bounds, or identity is invalid")
    }
    if item.endFrameOrdinalExclusive - item.firstFrameOrdinal > 1 {
      guard item.anchorFrameSHA256 == nil, item.rawPackProvenance.isEmpty else {
        throw DVIngestError.invalidEvidence("range review item cannot claim one-frame provenance")
      }
    }
    var packIDs = Set<String>()
    for pack in item.rawPackProvenance {
      guard packIDs.insert(pack.id).inserted else {
        throw DVIngestError.invalidEvidence("recovery review item has duplicate raw pack IDs")
      }
      var offsets = Set<UInt64>()
      for offset in pack.sourceByteOffsets {
        guard offsets.insert(offset).inserted, offset >= start,
          try add(offset, 5, "review raw pack end") <= end else {
          throw DVIngestError.invalidEvidence("recovery review raw pack offset is invalid")
        }
      }
    }
  }

  private static func withStableID(_ item: Item) throws -> Item {
    Item(id: try stableID(item), sourceSHA256: item.sourceSHA256,
      mapReceiptSHA256: item.mapReceiptSHA256,
      frameLedgerSHA256: item.frameLedgerSHA256,
      firstFrameOrdinal: item.firstFrameOrdinal,
      endFrameOrdinalExclusive: item.endFrameOrdinalExclusive,
      sourceByteOffset: item.sourceByteOffset,
      sourceByteEndExclusive: item.sourceByteEndExclusive,
      issueCodes: item.issueCodes, summary: item.summary,
      anchorFrameSHA256: item.anchorFrameSHA256,
      rawPackProvenance: item.rawPackProvenance)
  }

  private static func stableID(_ item: Item) throws -> String {
    struct Identity: Encodable {
      let sourceSHA256: String
      let mapReceiptSHA256: String
      let frameLedgerSHA256: String
      let firstFrameOrdinal: UInt64
      let endFrameOrdinalExclusive: UInt64
      let sourceByteOffset: UInt64
      let sourceByteEndExclusive: UInt64
      let issueCodes: [DVTapeEvidenceMapExporter.IssueCode]
      let anchorFrameSHA256: String?
      let rawPackProvenance: [DVTapeDefectInspector.RawPackProvenance]
    }
    let value = Identity(sourceSHA256: item.sourceSHA256,
      mapReceiptSHA256: item.mapReceiptSHA256,
      frameLedgerSHA256: item.frameLedgerSHA256,
      firstFrameOrdinal: item.firstFrameOrdinal,
      endFrameOrdinalExclusive: item.endFrameOrdinalExclusive,
      sourceByteOffset: item.sourceByteOffset,
      sourceByteEndExclusive: item.sourceByteEndExclusive,
      issueCodes: item.issueCodes,
      anchorFrameSHA256: item.anchorFrameSHA256,
      rawPackProvenance: item.rawPackProvenance)
    return hex(SHA256.hash(data: try encode(value)))
  }

  private static func rejectEvidenceMapDescendant(
    _ sidecar: URL,
    evidenceMapDirectory: URL
  ) throws {
    let sidecarPath = sidecar.standardizedFileURL.path
    let mapPath = evidenceMapDirectory.standardizedFileURL.path
    guard sidecarPath != mapPath, !sidecarPath.hasPrefix(mapPath + "/") else {
      throw DVIngestError.invalidEvidence("recovery review sidecar must be separate from immutable tape-map evidence")
    }
  }

  private static func createDirectory(_ url: URL) throws -> Int32 {
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else {
      throw DVIngestError.invalidEvidence("recovery review sidecar name is invalid")
    }
    let parent = Darwin.open(url.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw DVIngestError.fileOperation("open review sidecar parent", errno) }
    defer { Darwin.close(parent) }
    guard mkdirat(parent, name, 0o700) == 0 else {
      if errno == EEXIST { throw DVIngestError.destinationExists(url.path) }
      throw DVIngestError.fileOperation("create recovery review sidecar", errno)
    }
    let child = openat(parent, name,
      O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw DVIngestError.fileOperation("open new review sidecar", errno) }
    guard fsync(parent) == 0 else {
      let code = errno
      Darwin.close(child)
      throw DVIngestError.fileOperation("synchronize review sidecar parent", code)
    }
    return child
  }

  private static func writeExclusive(directoryFD: Int32, name: String, data: Data) throws {
    let fd = openat(directoryFD, name,
      O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DVIngestError.fileOperation("create recovery review metadata", errno) }
    defer { Darwin.close(fd) }
    try appendAll(fd: fd, data: data)
    guard fsync(fd) == 0 else {
      throw DVIngestError.fileOperation("synchronize recovery review metadata", errno)
    }
  }

  private static func appendAll(fd: Int32, data: Data) throws {
    var written = 0
    while written < data.count {
      let amount: Int = try data.withUnsafeBytes { bytes in
        let value = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
        if value < 0 { throw DVIngestError.fileOperation("write recovery review data", errno) }
        return value
      }
      guard amount > 0 else { throw DVIngestError.invalidEvidence("recovery review write made no progress") }
      written += amount
    }
  }

  private static func readRegularFile(
    directoryFD: Int32, name: String, maximumByteCount: UInt64
  ) throws -> Data {
    let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVIngestError.fileOperation("open recovery review metadata", errno) }
    defer { Darwin.close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0, UInt64(status.st_size) <= maximumByteCount,
      status.st_size <= Int.max else {
      throw DVIngestError.invalidEvidence("recovery review metadata is not a bounded regular file")
    }
    return try preadExactly(fd: fd, offset: 0, count: Int(status.st_size))
  }

  private static func scanLines(
    fd: Int32, maximumLineBytes: Int,
    _ body: (Data, Data) throws -> Void
  ) throws -> UInt64 {
    var line = Data()
    var total: UInt64 = 0
    while true {
      try Task.checkCancellation()
      var buffer = Data(count: 65_536)
      let amount: Int = try buffer.withUnsafeMutableBytes { bytes in
        let value = Darwin.read(fd, bytes.baseAddress!, bytes.count)
        if value < 0 { throw DVIngestError.fileOperation("read recovery review ledger", errno) }
        return value
      }
      if amount == 0 { break }
      buffer.removeSubrange(amount..<buffer.count)
      total = try add(total, UInt64(amount), "recovery review ledger bytes")
      for byte in buffer {
        line.append(byte)
        guard line.count <= maximumLineBytes else {
          throw DVIngestError.invalidEvidence("recovery review event line exceeds bounded size")
        }
        if byte == 10 {
          guard line.count > 1 else { throw DVIngestError.invalidEvidence("recovery review ledger has an empty event") }
          var content = line
          content.removeLast()
          try body(content, line)
          line.removeAll(keepingCapacity: true)
        }
      }
    }
    guard line.isEmpty else { throw DVIngestError.invalidEvidence("recovery review final event is incomplete") }
    return total
  }

  private static func preadExactly(fd: Int32, offset: UInt64, count: Int) throws -> Data {
    guard offset <= UInt64(Int64.max), count >= 0 else {
      throw DVIngestError.invalidEvidence("recovery review read bounds are invalid")
    }
    var result = Data(count: count)
    var filled = 0
    while filled < count {
      try Task.checkCancellation()
      let amount: Int = try result.withUnsafeMutableBytes { bytes in
        let value = Darwin.pread(fd, bytes.baseAddress!.advanced(by: filled), count - filled,
          off_t(offset) + off_t(filled))
        if value < 0 { throw DVIngestError.fileOperation("read recovery review page", errno) }
        return value
      }
      guard amount > 0 else { throw DVIngestError.invalidEvidence("recovery review page is truncated") }
      filled += amount
    }
    return result
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
      && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func add(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func multiply(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { throw DVIngestError.invalidEvidence("\(label) overflow") }
    return value
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
