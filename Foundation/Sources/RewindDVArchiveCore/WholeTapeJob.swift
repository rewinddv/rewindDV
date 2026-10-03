// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Darwin

/// Pure staged-job contract. Events never send commands. Inferred transport
/// boundaries remain distinct from operator observations and absolute BOT/EOT.
public struct WholeTapeJob: Codable, Equatable, Sendable {
  public enum Stage: String, Codable, Sendable {
    case created, preflight, rewinding, awaitingStart, startConfirmed
    case receiveReady, awaitingDV, capturing, draining, verifying
    case operatorBoundedVerified, transportBoundedVerified, recoveryBoundedVerified, interrupted
  }
  public enum Event: String, Codable, Sendable {
    case preflightPassed, rewindIntent, windStopped, operatorConfirmedStart
    case receiverReady, playIntent, receivedDV, signalGap, transportStopped
    case operatorConfirmedEnd, receiveDrained, verificationPassed
    case inferredStart, inferredEnd
    case operatorPositionedRecoveryStart, supervisedRecoveryEnd
    case cancel, watchdogExpired, routeChanged, processRestart, failure
  }
  public struct Entry: Codable, Equatable, Sendable {
    public let event: Event
    /// Hash of the raw observation/receipt, not a human-readable assertion.
    public let evidenceSHA256: String
    public let routeIdentity: String
    public let completeFrames: UInt64
    public init(event: Event, evidenceSHA256: String, routeIdentity: String, completeFrames: UInt64 = 0) {
      self.event = event; self.evidenceSHA256 = evidenceSHA256
      self.routeIdentity = routeIdentity; self.completeFrames = completeFrames
    }
  }
  public let jobID: UUID
  /// Full route serialized by the adapter, including generation and incarnation.
  public let routeIdentity: String
  public private(set) var stage: Stage = .created
  public private(set) var receivedFrames: UInt64 = 0
  public private(set) var manualStopRequired = false
  public private(set) var entries: [Entry] = []
  /// Optional for compatibility. Automation fields above remain historical.
  public private(set) var accounting: WholeTapeJobEvidence?
  public var currentSummary: WholeTapeJobSummary { .init(job: self) }

  public mutating func account(_ update: WholeTapeJobEvidence.Update) throws {
    guard update.jobID == jobID, update.routeIdentity == routeIdentity else {
      throw Self.invalid("accounting job/route mismatch")
    }
    var next = accounting ?? WholeTapeJobEvidence()
    try next.apply(update, terminal: isTerminal)
    accounting = next
  }

  public init(routeIdentity: String) throws {
    guard !routeIdentity.isEmpty else { throw Self.invalid("missing route identity") }
    self.jobID = UUID(); self.routeIdentity = routeIdentity
  }
  public mutating func record(_ entry: Entry) throws {
    guard !isTerminal else {
      throw Self.invalid("terminal job cannot resume or replay commands")
    }
    guard Self.isHash(entry.evidenceSHA256) else { throw Self.invalid("missing evidence digest") }
    if [.cancel, .watchdogExpired, .routeChanged, .processRestart, .failure].contains(entry.event) {
      stage = .interrupted; entries.append(entry); return
    }
    guard entry.routeIdentity == routeIdentity else { throw Self.invalid("route mismatch; interruption required") }
    let next: Stage
    switch (stage, entry.event) {
    case (.created, .preflightPassed): next = .preflight
    case (.preflight, .rewindIntent): next = .rewinding
    case (.preflight, .operatorPositionedRecoveryStart): next = .startConfirmed
    case (.rewinding, .windStopped): next = .awaitingStart
    case (.awaitingStart, .operatorConfirmedStart): next = .startConfirmed
    case (.awaitingStart, .inferredStart): next = .startConfirmed
    case (.startConfirmed, .receiverReady): next = .receiveReady
    case (.receiveReady, .playIntent): next = .awaitingDV
    case (.awaitingDV, .receivedDV), (.capturing, .receivedDV):
      guard entry.completeFrames > receivedFrames else { throw Self.invalid("DV progress must increase") }
      next = .capturing
    case (.awaitingDV, .signalGap), (.capturing, .signalGap): next = stage
    case (.awaitingDV, .transportStopped), (.capturing, .transportStopped):
      guard manualStopRequired else { throw Self.invalid("duplicate stop observation") }
      next = stage
    case (.capturing, .operatorConfirmedEnd): next = .draining
    case (.awaitingDV, .inferredEnd), (.capturing, .inferredEnd):
      guard !manualStopRequired else { throw Self.invalid("inferred end needs stopped transport evidence") }
      next = .draining
    case (.awaitingDV, .supervisedRecoveryEnd), (.capturing, .supervisedRecoveryEnd):
      guard !manualStopRequired, entries.contains(where: { $0.event == .operatorPositionedRecoveryStart }) else {
        throw Self.invalid("recovery end requires stopped proof and recovery admission")
      }
      next = .draining
    case (.draining, .receiveDrained):
      guard entry.completeFrames >= receivedFrames else { throw Self.invalid("drain cannot discard received frames") }
      next = .verifying
    case (.verifying, .verificationPassed):
      let inferred = entries.contains { $0.event == .inferredEnd }
      let recovery = entries.contains { $0.event == .supervisedRecoveryEnd }
      guard entry.completeFrames == receivedFrames && (receivedFrames > 0 || inferred || recovery) && !manualStopRequired else { throw Self.invalid("verification count mismatch or tape stop unproved") }
      next = recovery ? .recoveryBoundedVerified : inferred ? .transportBoundedVerified : .operatorBoundedVerified
    default: throw Self.invalid("invalid or repeated stage event")
    }
    if [.rewindIntent, .playIntent].contains(entry.event) { manualStopRequired = true }
    // Drained receive and a user end observation do not prove a stopped mechanism.
    if [.windStopped, .transportStopped].contains(entry.event) { manualStopRequired = false }
    if [.receivedDV, .receiveDrained].contains(entry.event) { receivedFrames = entry.completeFrames }
    stage = next; entries.append(entry)
  }
  public var isTerminal: Bool {
    [.operatorBoundedVerified, .transportBoundedVerified, .recoveryBoundedVerified, .interrupted].contains(stage)
  }
  fileprivate static func isHash(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  fileprivate static func invalid(_ message: String) -> DVIngestError { .invalidEvidence("whole-tape job: " + message) }
}

/// Each checkpoint is exclusive-create + file fsync + directory fsync, with a
/// predecessor digest. A write failure poisons this writer; it cannot retry an
/// uncertain intent. Loading returns an interrupted snapshot, never an executor.
public final class WholeTapeJobJournal {
  private struct Checkpoint: Codable {
    let version: Int
    let sequence: Int
    let previousSHA256: String?
    let job: WholeTapeJob
    var accountingUpdate: WholeTapeJobEvidence.Update? = nil
  }
  public let directory: URL
  public private(set) var job: WholeTapeJob
  private var sequence = 0
  private var previousSHA256: String?
  private var poisoned = false

  public init(parentDirectory: URL, routeIdentity: String) throws {
    job = try WholeTapeJob(routeIdentity: routeIdentity)
    directory = parentDirectory.appendingPathComponent(job.jobID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try persist(job)
    let parent = Darwin.open(parentDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard parent >= 0 else { throw WholeTapeJob.invalid("journal parent unavailable") }
    defer { Darwin.close(parent) }
    guard Darwin.fsync(parent) == 0 else { throw WholeTapeJob.invalid("journal parent sync failed") }
  }
  public func record(_ entry: WholeTapeJob.Entry) throws {
    guard !poisoned else { throw WholeTapeJob.invalid("journal requires recovery after uncertain write") }
    var next = job
    try next.record(entry)
    try persist(next)
    job = next
  }
  public func account(_ update: WholeTapeJobEvidence.Update) throws {
    guard !poisoned else { throw WholeTapeJob.invalid("journal requires recovery after uncertain write") }
    var next = job
    try next.account(update)
    guard next != job else { return } // Duplicate delivery does not write.
    try persist(next, update: update)
    job = next
  }
  private func persist(_ next: WholeTapeJob, update: WholeTapeJobEvidence.Update? = nil) throws {
    do {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let bytes = try encoder.encode(Checkpoint(version: update == nil ? 1 : 2, sequence: sequence,
        previousSHA256: previousSHA256, job: next, accountingUpdate: update))
      let url = directory.appendingPathComponent(String(format: "%08d.json", sequence))
      let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard fd >= 0 else { throw WholeTapeJob.invalid("checkpoint exclusive creation failed") }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
      let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard parent >= 0 else { throw WholeTapeJob.invalid("checkpoint directory unavailable") }
      defer { Darwin.close(parent) }
      guard Darwin.fsync(parent) == 0 else { throw WholeTapeJob.invalid("checkpoint directory sync failed") }
      previousSHA256 = Self.digest(bytes); sequence += 1
    } catch { poisoned = true; throw error }
  }
  public static func recover(from directory: URL) throws -> WholeTapeJob {
    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try replay(urls, directory: directory)
  }
  /// A torn final write may be displayed as incomplete, never as a completed
  /// update. The verified prefix is read in place; no file is repaired or removed.
  /// Identity, chain and semantic failures still fail closed.
  public static func readSummary(from directory: URL) throws -> WholeTapeJobSummary {
    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard urls.count > 1, let tail = urls.last,
      tail.lastPathComponent == String(format: "%08d.json", urls.count - 1),
      try tail.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink != true,
      try tail.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      return try replay(urls, directory: directory).currentSummary
    }
    let bytes = try Data(contentsOf: tail)
    if (try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])) == nil {
      return WholeTapeJobSummary(job: try replay(Array(urls.dropLast()), directory: directory),
        journalWarning: "Final journal checkpoint is unreadable/incomplete; showing only the verified earlier history. Later accounting is unknown.")
    }
    return try replay(urls, directory: directory).currentSummary
  }
  private static func replay(_ urls: [URL], directory: URL) throws -> WholeTapeJob {
    guard !urls.isEmpty else { throw WholeTapeJob.invalid("empty journal") }
    var last: WholeTapeJob?, predecessor: String?
    for (index, url) in urls.enumerated() {
      guard url.lastPathComponent == String(format: "%08d.json", index),
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw WholeTapeJob.invalid("unexpected checkpoint or symbolic link")
      }
      let bytes = try Data(contentsOf: url)
      let value = try JSONDecoder().decode(Checkpoint.self, from: bytes)
      guard value.version == (value.accountingUpdate == nil ? 1 : 2), value.sequence == index, value.previousSHA256 == predecessor,
        value.job.jobID.uuidString == directory.lastPathComponent else {
        throw WholeTapeJob.invalid("checkpoint chain mismatch")
      }
      if var prior = last {
        if let update = value.accountingUpdate {
          try prior.account(update)
        } else {
          guard value.job.entries.count == prior.entries.count + 1, let entry = value.job.entries.last else {
            throw WholeTapeJob.invalid("checkpoint event count mismatch")
          }
          try prior.record(entry)
        }
        guard prior == value.job else { throw WholeTapeJob.invalid("checkpoint state does not match replay") }
      } else {
        guard value.job.stage == .created, value.job.entries.isEmpty, value.job.accounting == nil, value.accountingUpdate == nil,
          value.job.receivedFrames == 0, !value.job.manualStopRequired,
          !value.job.routeIdentity.isEmpty else { throw WholeTapeJob.invalid("invalid initial checkpoint") }
      }
      last = value.job; predecessor = digest(bytes)
    }
    guard var result = last else { throw WholeTapeJob.invalid("missing job") }
    if !result.isTerminal {
      try result.record(.init(event: .processRestart, evidenceSHA256: predecessor!, routeIdentity: result.routeIdentity))
    }
    return result
  }
  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
