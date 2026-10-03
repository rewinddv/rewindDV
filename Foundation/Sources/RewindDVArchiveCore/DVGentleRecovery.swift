// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation

/// Plan-scoped wear accounting, not a measurement of physical tape wear.
/// A reservation is durable before motion and is never refunded or replayed.
public enum DVGentleRecovery {
  public struct Budget: Codable, Equatable, Sendable {
    public let maximumAttempts: Int
    public let attemptsPerTarget: Int
    public let passSeconds: Int
    public let stopAllowanceSeconds: Int
    public let totalReservedSeconds: Int
    public let cooldownSeconds: Int
    public init(maximumAttempts: Int = 3, attemptsPerTarget: Int = 2, passSeconds: Int = 20,
      stopAllowanceSeconds: Int = 10, totalReservedSeconds: Int = 300, cooldownSeconds: Int = 60) {
      self.maximumAttempts = maximumAttempts; self.attemptsPerTarget = attemptsPerTarget
      self.passSeconds = passSeconds; self.stopAllowanceSeconds = stopAllowanceSeconds
      self.totalReservedSeconds = totalReservedSeconds; self.cooldownSeconds = cooldownSeconds
    }
    func validate() throws {
      guard (1...20).contains(maximumAttempts), (1...maximumAttempts).contains(attemptsPerTarget),
        (1...300).contains(passSeconds), (5...60).contains(stopAllowanceSeconds),
        (passSeconds + stopAllowanceSeconds...7200).contains(totalReservedSeconds),
        (10...3600).contains(cooldownSeconds) else { throw failure("invalid wear budget") }
    }
  }
  public struct Target: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let first: UInt64
    public let endExclusive: UInt64
    public let reason: String
    public init(first: UInt64, endExclusive: UInt64, reason: String) {
      self.first = first; self.endExclusive = endExclusive; self.reason = reason
      id = "frames-\(first)-\(endExclusive)"
    }
  }
  public struct Plan: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let source: DVReviewedRangeExporter.Snapshot
    public let mapSHA256: String
    public let tapeLabel: String
    public let budget: Budget
    public let targets: [Target]
    public init(source: DVReviewedRangeExporter.Snapshot, mapSHA256: String, tapeLabel: String,
      budget: Budget, targets: [Target]) throws {
      version = 1; id = UUID(); self.source = source; self.mapSHA256 = mapSHA256
      self.tapeLabel = tapeLabel; self.budget = budget; self.targets = targets
      try validate()
    }
    func validate() throws {
      try budget.validate()
      guard version == 1, source.schemaVersion == 1, hash(mapSHA256), hash(source.sourceSHA256), source.frameCount > 0,
        [120_000, 144_000].contains(source.frameByteCount),
        source.frameByteCount == (source.videoSystem == .ntsc525_60 ? 120_000 : 144_000),
        source.sourceByteCount / UInt64(source.frameByteCount) == source.frameCount,
        source.sourceByteCount % UInt64(source.frameByteCount) == 0,
        !tapeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tapeLabel.utf8.count <= 256,
        !targets.isEmpty, targets.count <= 64 else { throw failure("invalid source-bound recovery plan") }
      var end: UInt64 = 0
      for target in targets {
        guard target.first >= end, target.first < target.endExclusive, target.endExclusive <= source.frameCount,
          target.id == "frames-\(target.first)-\(target.endExclusive)", !target.reason.isEmpty,
          target.reason.utf8.count <= 4096 else { throw failure("target ranges must be ordered, disjoint and source-bound") }
        end = target.endExclusive
      }
    }
  }
  public enum Phase: String, Codable, Sendable { case reserved, playIntent, completed, reconciledInterrupted }
  public struct Result: Codable, Equatable, Sendable {
    public let outcome: String
    public let observedSeconds: Int?
    public let verificationPath: String?
    public let verificationSHA256: String?
    public let nativeDVSHA256: String?
    public let completeFrames: UInt64
    public let note: String
    public init(outcome: String, observedSeconds: Int?, verificationPath: String? = nil,
      verificationSHA256: String? = nil, nativeDVSHA256: String? = nil, completeFrames: UInt64 = 0, note: String) {
      self.outcome = outcome; self.observedSeconds = observedSeconds; self.verificationPath = verificationPath
      self.verificationSHA256 = verificationSHA256; self.nativeDVSHA256 = nativeDVSHA256
      self.completeFrames = completeFrames; self.note = note
    }
  }
  public struct Attempt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let target: String
    public let route: String
    public let positioningSeconds: Int
    public let reservedSeconds: Int
    public let reservedAt: Date
    public var phase: Phase
    public var finishedAt: Date?
    public var result: Result?
    public var chargedSeconds: Int {
      max(reservedSeconds, positioningSeconds + (result?.observedSeconds ?? 0))
    }
  }
  public struct Snapshot: Sendable {
    public let plan: Plan
    public let attempts: [Attempt]
    public var chargedSeconds: Int { attempts.reduce(0) { $0 + $1.chargedSeconds } }
    public var unresolved: Attempt? { attempts.first { $0.phase == .reserved || $0.phase == .playIntent } }
    public var hasOverrun: Bool { attempts.contains { $0.chargedSeconds > $0.reservedSeconds } }
    public func refusal(target: String, positioningSeconds: Int, now: Date = Date()) -> String? {
      if unresolved != nil { return "Unresolved attempt: physically stop the deck and reconcile it. No resume or replay." }
      if attempts.contains(where: { $0.phase == .reconciledInterrupted }) { return "An interrupted pass has unknown motion duration. This plan is held; inspection is required before further recovery." }
      if hasOverrun { return "A pass exceeded its reserved allowance. This plan is held; no further tape motion is authorized." }
      if !plan.targets.contains(where: { $0.id == target }) { return "Unknown recovery target" }
      if !(0...3600).contains(positioningSeconds) { return "Positioning time must be 0–3600 seconds, including external winding/search." }
      if attempts.count >= plan.budget.maximumAttempts { return "Total attempt budget exhausted" }
      if attempts.filter({ $0.target == target }).count >= plan.budget.attemptsPerTarget { return "Target attempt budget exhausted" }
      let needed = positioningSeconds + plan.budget.passSeconds + plan.budget.stopAllowanceSeconds
      if chargedSeconds + needed > plan.budget.totalReservedSeconds { return "Tape-motion allowance exhausted" }
      if let last = attempts.last?.finishedAt, now.timeIntervalSince(last) < Double(plan.budget.cooldownSeconds) {
        return "Cooldown has not elapsed (or the system clock moved backward). Wait before another pass."
      }
      return nil
    }
  }
  static func failure(_ text: String) -> DVIngestError { .invalidEvidence("gentle recovery: " + text) }
  public static func isWithin(_ url: URL, directory: URL) -> Bool {
    // A new output does not exist yet. Foundation can canonicalize an existing
    // /private/tmp parent differently from that child's full path, so resolve
    // the nearest existing ancestor before restoring the missing components.
    func components(_ input: URL) -> [String] {
      var ancestor = input.standardizedFileURL
      var missing: [String] = []
      while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        missing.append(ancestor.lastPathComponent)
        ancestor.deleteLastPathComponent()
      }
      return ancestor.resolvingSymlinksInPath().standardizedFileURL.pathComponents + missing.reversed()
    }
    return components(url).starts(with: components(directory))
  }
  static func hash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
  static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Exclusive writer + hash-linked, exclusive-create checkpoints. Opening is
/// read/reconcile only; persisted intent never grants a fresh execution permit.
public actor DVGentleRecoveryJournal {
  public nonisolated let plan: DVGentleRecovery.Plan
  public nonisolated let directory: URL
  private struct Checkpoint: Codable {
    let revision: Int
    let previous: String
    let attempts: [DVGentleRecovery.Attempt]
  }
  private let fd: Int32
  private let identity: stat
  private let manifestHash: String
  private var attempts: [DVGentleRecovery.Attempt]
  private var revision: Int
  private var previous: String
  private var poisoned = false
  private var issuedInThisSession = Set<UUID>()
  private var ownedInThisSession = Set<UUID>()

  public init(directory: URL, creating: DVGentleRecovery.Plan? = nil,
    expectedSource: DVReviewedRangeExporter.Snapshot, expectedMapSHA256: String) throws {
    if let creating {
      try creating.validate()
      guard creating.source == expectedSource, creating.mapSHA256 == expectedMapSHA256 else { throw DVGentleRecovery.failure("plan source mismatch") }
      guard mkdir(directory.path, 0o700) == 0 else { throw DVGentleRecovery.failure("destination already exists or is unavailable") }
    }
    let opened = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0 else { throw DVGentleRecovery.failure("cannot open plan folder") }
    var keep = false
    defer { if !keep { Darwin.close(opened) } }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { throw DVGentleRecovery.failure("plan already has a writer") }
    var st = stat(); guard fstat(opened, &st) == 0 else { throw DVGentleRecovery.failure("plan identity unavailable") }
    if let creating {
      try Self.write(opened, "plan.json", DVGentleRecovery.encode(creating))
      let parent = Darwin.open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else { throw DVGentleRecovery.failure("parent unavailable") }
      defer { Darwin.close(parent) }
      guard fsync(parent) == 0 else { throw DVGentleRecovery.failure("parent durability barrier failed") }
    }
    let manifest = try Self.read(opened, "plan.json")
    let plan = try JSONDecoder().decode(DVGentleRecovery.Plan.self, from: manifest)
    try plan.validate()
    guard plan.source == expectedSource, plan.mapSHA256 == expectedMapSHA256 else { throw DVGentleRecovery.failure("plan belongs to another master/map") }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "plan.json" }.sorted()
    guard names.count <= 100 else { throw DVGentleRecovery.failure("checkpoint budget exceeded") }
    var prior = DVGentleRecovery.digest(manifest), loaded: [DVGentleRecovery.Attempt] = []
    for (index, name) in names.enumerated() {
      guard name == Self.name(index) else { throw DVGentleRecovery.failure("unexpected or missing checkpoint") }
      let data = try Self.read(opened, name), checkpoint = try JSONDecoder().decode(Checkpoint.self, from: data)
      guard checkpoint.revision == index, checkpoint.previous == prior else { throw DVGentleRecovery.failure("checkpoint chain mismatch") }
      try Self.validateTransition(from: loaded, to: checkpoint.attempts, plan: plan)
      loaded = checkpoint.attempts; prior = DVGentleRecovery.digest(data)
    }
    self.plan = plan; self.directory = directory; fd = opened; identity = st
    manifestHash = DVGentleRecovery.digest(manifest); previous = prior; revision = names.count; attempts = loaded
    keep = true
  }
  deinit { Darwin.close(fd) }
  public func snapshot() throws -> DVGentleRecovery.Snapshot { try verify(); return .init(plan: plan, attempts: attempts) }

  public func reserve(target: String, route: String, positioningSeconds: Int, confirmedTapeAndPosition: Bool,
    now: Date = Date()) throws -> DVGentleRecovery.Attempt {
    try verify()
    guard confirmedTapeAndPosition, !route.isEmpty, route.utf8.count <= 1024, now.timeIntervalSince1970.isFinite else {
      throw DVGentleRecovery.failure("fresh physical tape/position confirmation and full route required")
    }
    if let reason = DVGentleRecovery.Snapshot(plan: plan, attempts: attempts).refusal(target: target, positioningSeconds: positioningSeconds, now: now) {
      throw DVGentleRecovery.failure(reason)
    }
    let attempt = DVGentleRecovery.Attempt(id: UUID(), target: target, route: route, positioningSeconds: positioningSeconds,
      reservedSeconds: positioningSeconds + plan.budget.passSeconds + plan.budget.stopAllowanceSeconds,
      reservedAt: now, phase: .reserved, finishedAt: nil, result: nil)
    try persist(attempts + [attempt]); issuedInThisSession.insert(attempt.id); ownedInThisSession.insert(attempt.id); return attempt
  }
  public func recordPlayIntent(_ id: UUID, route: String) throws {
    guard issuedInThisSession.contains(id), let last = attempts.last, last.id == id, last.phase == .reserved,
      last.route == route else { throw DVGentleRecovery.failure("consumed, stale-route or restored attempt cannot PLAY") }
    var next = attempts; next[next.count - 1].phase = .playIntent
    try persist(next); issuedInThisSession.remove(id)
  }
  public func finish(_ id: UUID, result: DVGentleRecovery.Result, physicalStopConfirmed: Bool, now: Date = Date()) throws {
    guard physicalStopConfirmed, ownedInThisSession.contains(id), let last = attempts.last, last.id == id,
      last.phase == .reserved || last.phase == .playIntent else { throw DVGentleRecovery.failure("fresh stopped proof required to finish an active attempt") }
    var next = attempts; next[next.count - 1].phase = .completed; next[next.count - 1].result = result
    next[next.count - 1].finishedAt = now
    try persist(next); issuedInThisSession.remove(id); ownedInThisSession.remove(id)
  }
  public func reconcileInterrupted(operatorConfirmedStopped: Bool, note: String, now: Date = Date()) throws {
    guard operatorConfirmedStopped, let last = attempts.last,
      last.phase == .reserved || last.phase == .playIntent else { throw DVGentleRecovery.failure("no unresolved attempt or no physical STOP confirmation") }
    // Duration is unknown after a crash. Hold further passes rather than assume
    // the original reserved allowance covered unobserved tape motion.
    var next = attempts; next[next.count - 1].phase = .reconciledInterrupted
    next[next.count - 1].finishedAt = now
    next[next.count - 1].result = .init(outcome: "interrupted_duration_unknown", observedSeconds: nil,
      note: note + " Unobserved motion duration; plan held, no automatic resume.")
    try persist(next); issuedInThisSession.remove(last.id); ownedInThisSession.remove(last.id)
  }
  private func persist(_ next: [DVGentleRecovery.Attempt]) throws {
    try verify(); try Self.validateTransition(from: attempts, to: next, plan: plan)
    guard revision < 100 else { throw DVGentleRecovery.failure("checkpoint budget exhausted") }
    let data = try DVGentleRecovery.encode(Checkpoint(revision: revision, previous: previous, attempts: next))
    do {
      try Self.write(fd, Self.name(revision), data)
      guard try Self.read(fd, Self.name(revision)) == data else { throw DVGentleRecovery.failure("checkpoint reread mismatch") }
      attempts = next; previous = DVGentleRecovery.digest(data); revision += 1
    } catch { poisoned = true; throw error }
  }
  private func verify() throws {
    guard !poisoned else { throw DVGentleRecovery.failure("uncertain journal write; close and inspect before further actions") }
    var path = stat()
    guard lstat(directory.path, &path) == 0, path.st_mode & S_IFMT == S_IFDIR,
      path.st_dev == identity.st_dev, path.st_ino == identity.st_ino,
      DVGentleRecovery.digest(try Self.read(fd, "plan.json")) == manifestHash else { throw DVGentleRecovery.failure("plan identity changed") }
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "plan.json" }.sorted()
    guard names == (0..<revision).map(Self.name) else { throw DVGentleRecovery.failure("checkpoint set changed") }
    var prior = manifestHash
    for i in 0..<revision {
      let data = try Self.read(fd, Self.name(i)), cp = try JSONDecoder().decode(Checkpoint.self, from: data)
      guard cp.revision == i, cp.previous == prior else { throw DVGentleRecovery.failure("checkpoint changed") }
      prior = DVGentleRecovery.digest(data)
    }
    guard prior == previous else { throw DVGentleRecovery.failure("checkpoint head changed") }
  }
  private static func validateTransition(from old: [DVGentleRecovery.Attempt], to new: [DVGentleRecovery.Attempt], plan: DVGentleRecovery.Plan) throws {
    guard new.count <= plan.budget.maximumAttempts, Set(new.map(\.id)).count == new.count else { throw DVGentleRecovery.failure("invalid attempt history") }
    // Validate untrusted decoded values before any addition or accounting.
    guard new.allSatisfy({ attempt in
      (0...3600).contains(attempt.positioningSeconds) && (1...3960).contains(attempt.reservedSeconds) &&
      attempt.reservedAt.timeIntervalSince1970.isFinite &&
      (attempt.result?.observedSeconds.map { (0...86_400).contains($0) } ?? true)
    }) else { throw DVGentleRecovery.failure("invalid accounting values") }
    if new.count == old.count + 1, let added = new.last {
      guard Array(new.dropLast()) == old, added.phase == .reserved, added.result == nil, added.finishedAt == nil,
        !added.route.isEmpty, added.route.utf8.count <= 1024,
        added.reservedSeconds == added.positioningSeconds + plan.budget.passSeconds + plan.budget.stopAllowanceSeconds,
        DVGentleRecovery.Snapshot(plan: plan, attempts: old).refusal(target: added.target, positioningSeconds: added.positioningSeconds, now: added.reservedAt) == nil else {
        throw DVGentleRecovery.failure("invalid reservation transition")
      }
    } else if new.count == old.count, let a = old.last, let b = new.last {
      guard Array(new.dropLast()) == Array(old.dropLast()), a.id == b.id, a.target == b.target, a.route == b.route,
        a.reservedAt == b.reservedAt, a.positioningSeconds == b.positioningSeconds, a.reservedSeconds == b.reservedSeconds else {
        throw DVGentleRecovery.failure("attempt identity mutated")
      }
      if a.phase == .reserved && b.phase == .playIntent {
        guard b.result == nil && b.finishedAt == nil else { throw DVGentleRecovery.failure("premature result") }
      } else {
        guard [.reserved, .playIntent].contains(a.phase), [.completed, .reconciledInterrupted].contains(b.phase),
          let result = b.result, let finished = b.finishedAt, finished >= b.reservedAt,
          result.note.utf8.count <= 4096, result.outcome.utf8.count <= 128,
          finished.timeIntervalSince1970.isFinite,
          result.observedSeconds.map({ (0...86_400).contains($0) }) ?? (b.phase == .reconciledInterrupted),
          result.verificationSHA256.map(DVGentleRecovery.hash) ?? true,
          result.nativeDVSHA256.map(DVGentleRecovery.hash) ?? true else { throw DVGentleRecovery.failure("invalid terminal result") }
      }
    } else { throw DVGentleRecovery.failure("invalid checkpoint transition") }
  }
  private static func name(_ index: Int) -> String { String(format: "%04d.json", index) }
  private static func read(_ directory: Int32, _ name: String) throws -> Data {
    let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw DVGentleRecovery.failure("cannot read checkpoint") }
    defer { Darwin.close(fd) }
    var st = stat(); guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= 1_048_576 else { throw DVGentleRecovery.failure("invalid checkpoint file") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    guard let bytes = try file.read(upToCount: Int(st.st_size) + 1), bytes.count == Int(st.st_size) else { throw DVGentleRecovery.failure("checkpoint changed during read") }
    var after = stat(), path = stat()
    guard fstat(fd, &after) == 0, fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
      after.st_dev == path.st_dev, after.st_ino == path.st_ino, after.st_size == st.st_size,
      after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec else {
      throw DVGentleRecovery.failure("checkpoint identity changed during read")
    }
    return bytes
  }
  private static func write(_ directory: Int32, _ name: String, _ data: Data) throws {
    guard data.count <= 1_048_576 else { throw DVGentleRecovery.failure("checkpoint exceeds budget") }
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DVGentleRecovery.failure("checkpoint exclusive creation failed") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    try file.write(contentsOf: data); try file.synchronize(); try file.close()
    guard fsync(directory) == 0 else { throw DVGentleRecovery.failure("checkpoint directory durability failed") }
  }
}
