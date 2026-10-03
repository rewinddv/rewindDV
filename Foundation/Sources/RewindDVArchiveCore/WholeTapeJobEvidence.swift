// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Accounting only. None of these values confer transport or receive authority.
public struct WholeTapeJobEvidence: Codable, Equatable, Sendable {
  public struct Capture: Codable, Equatable, Sendable {
    public let id: UUID
    public let relativeDirectory: String
    public init(id: UUID = UUID(), relativeDirectory: String) {
      self.id = id; self.relativeDirectory = relativeDirectory
    }
  }
  public struct Stop: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
      case requested, accepted, deviceObserved, operatorConfirmed
    }
    public let kind: Kind
    public let receiptSHA256: [String]
    public init(_ kind: Kind, receipts: [String]) { self.kind = kind; receiptSHA256 = receipts }
  }
  public struct Verification: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case dv, hdv }
    public let format: Format
    public let passed: Bool
    public let reportSHA256: String
    public let completeDVFrames: UInt64?
    public let transportPackets: UInt64?
    public let transportBytes: UInt64?
    public let needsLossReview: Bool
    public init(format: Format, passed: Bool, reportSHA256: String,
                completeDVFrames: UInt64? = nil, transportPackets: UInt64? = nil,
                transportBytes: UInt64? = nil, needsLossReview: Bool) {
      self.format = format; self.passed = passed; self.reportSHA256 = reportSHA256
      self.completeDVFrames = completeDVFrames; self.transportPackets = transportPackets
      self.transportBytes = transportBytes; self.needsLossReview = needsLossReview
    }
  }
  public struct Update: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let routeIdentity: String
    /// Binding is written once, before any final accounting for this capture.
    public var bindCapture: Capture?
    public var captureID: UUID?
    public var stop: Stop?
    public var receiveClosed = false
    public var verification: Verification?
    public init(jobID: UUID, routeIdentity: String) {
      self.jobID = jobID; self.routeIdentity = routeIdentity
    }
  }
  public private(set) var capture: Capture?
  public private(set) var stops: [Stop] = []
  public private(set) var receiveClosed = false
  public private(set) var verification: Verification?

  public var stopped: Bool { stops.contains { [.deviceObserved, .operatorConfirmed].contains($0.kind) } }

  mutating func apply(_ update: Update, terminal: Bool) throws {
    func invalid(_ message: String) -> DVIngestError { .invalidEvidence("whole-tape accounting: " + message) }
    func hash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    if let binding = update.bindCapture {
      guard update.captureID == nil, update.stop == nil, !update.receiveClosed, update.verification == nil,
        !binding.relativeDirectory.isEmpty, binding.relativeDirectory != ".", binding.relativeDirectory != "..",
        !binding.relativeDirectory.contains("/") else { throw invalid("invalid capture binding") }
      if let capture { guard capture == binding else { throw invalid("capture already bound") } }
      else { guard !terminal else { throw invalid("cannot bind a new capture after termination") }; capture = binding }
    }
    if update.receiveClosed || update.verification != nil {
      guard let capture, update.captureID == capture.id else { throw invalid("capture/session mismatch") }
    } else if let id = update.captureID, id != capture?.id { throw invalid("capture/session mismatch") }
    if let stop = update.stop {
      guard stop.receiptSHA256.count == (stop.kind == .deviceObserved ? 2 : 1),
        Set(stop.receiptSHA256).count == stop.receiptSHA256.count,
        stop.receiptSHA256.allSatisfy(hash) else { throw invalid("missing independent STOP evidence") }
      // Each evidence class is bounded to its first receipt(s). Later delivery
      // cannot erase a proof or append equivalent polling indefinitely.
      if !stops.contains(where: { $0.kind == stop.kind }) {
        stops.append(stop); stops.sort { $0.kind.rawValue < $1.kind.rawValue }
      }
    }
    if let result = update.verification {
      guard hash(result.reportSHA256),
        result.format == .dv ? (result.transportPackets == nil && result.transportBytes == nil && (!result.passed || result.completeDVFrames != nil))
          : (result.completeDVFrames == nil && (!result.passed || (result.transportPackets != nil && result.transportBytes != nil))),
        result.passed || (result.completeDVFrames == nil && result.transportPackets == nil && result.transportBytes == nil)
      else { throw invalid("invalid verification accounting") }
      if let prior = verification, prior.passed {
        if result.passed && result != prior { throw invalid("conflicting final verification") }
      } else { verification = result }
    }
    receiveClosed = receiveClosed || update.receiveClosed
  }
}

public struct WholeTapeJobSummary: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let automationStage: WholeTapeJob.Stage
  public let historicalProgressFrames: UInt64
  public let historicalStopRequired: Bool
  public let evidence: WholeTapeJobEvidence?
  public let journalWarning: String?
  public let text: String

  init(job: WholeTapeJob, journalWarning: String? = nil) {
    jobID = job.jobID; automationStage = job.stage
    historicalProgressFrames = job.receivedFrames; historicalStopRequired = job.manualStopRequired
    evidence = job.accounting
    self.journalWarning = journalWarning
    var parts = [job.stage == .interrupted ? "Job interrupted — not a whole-tape completion." : "Job state: \(job.stage.rawValue)."]
    if let evidence, evidence.stopped {
      let kinds = evidence.stops.map(\.kind)
      parts.append(kinds.contains(.operatorConfirmed)
        ? "Physical STOP confirmed by operator." : "STOP confirmed by two device observations.")
      if kinds.contains(.operatorConfirmed) && kinds.contains(.deviceObserved) { parts.append("Device STOP observations also retained.") }
    } else if job.entries.contains(where: { $0.event == .transportStopped }) && !job.manualStopRequired {
      parts.append("Device STOP recorded in the automation journal.")
    } else if evidence?.stops.contains(where: { $0.kind == .accepted }) == true {
      parts.append("STOP accepted; stopped transport remains unconfirmed.")
    } else if job.manualStopRequired { parts.append("STOP remains unconfirmed in this journal.") }
    else { parts.append("No unresolved motion intent recorded.") }
    if let result = evidence?.verification, result.passed {
      if let frames = result.completeDVFrames {
        parts.append("\(frames) complete DV frames; saved bytes verified.")
        if frames == 0 { parts.append("Zero complete frames does not establish a blank tape.") }
      } else { parts.append("\(result.transportPackets!) HDV transport packets (\(result.transportBytes!) bytes); saved bytes verified.") }
      if result.needsLossReview { parts.append("Capture continuity/quality warnings retained; review required.") }
    } else { parts.append(evidence?.verification == nil ? "Final saved-data verification not recorded." : "Saved-data verification incomplete or failed; final count unknown.") }
    if evidence?.receiveClosed == true { parts.append("Reception closed.") }
    else { parts.append("Reception closure not recorded by final accounting.") }
    if let journalWarning { parts.append(journalWarning) }
    text = parts.joined(separator: " ")
  }
}
