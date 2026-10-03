// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Presentation only: never a reason to stop RX, infer tape motion or alter raw bytes.
public struct LiveSignalPresentation: Sendable {
  public enum State: Equatable, Sendable {
    case waitingForSignal, noPackets, noCompleteFrames, videoRecovering, presenting, inactive
    public var message: String? {
      switch self {
      case .waitingForSignal: "Waiting for DV signal"
      case .noPackets: "No incoming FireWire packets"
      case .noCompleteFrames: "Waiting for complete DV frames"
      case .videoRecovering: "Recovering live picture"
      case .presenting, .inactive: nil
      }
    }
  }
  private var active = false
  private var lastPacketCount: UInt64 = 0
  private var lastPacketTime: Double = 0
  private var lastFrameTime: Double?
  private var began: Double = 0
  private var videoFailed = false
  public init() {}
  public mutating func begin(at now: Double) {
    self = Self(); active = true; began = now; lastPacketTime = now; videoFailed = true
  }
  public mutating func observePackets(_ count: UInt64, at now: Double) {
    if count != lastPacketCount { lastPacketCount = count; lastPacketTime = now }
  }
  public mutating func observeFrame(at now: Double) { lastFrameTime = now }
  public mutating func videoFailedToPresent() { videoFailed = true }
  public mutating func videoSubmitted() { videoFailed = false }
  public mutating func end() { active = false }
  public func state(at now: Double) -> State {
    guard active else { return .inactive }
    if now - lastPacketTime >= 1 { return .noPackets }
    if now - (lastFrameTime ?? began) >= 1 { return .noCompleteFrames }
    if lastFrameTime == nil { return .waitingForSignal }
    return videoFailed ? .videoRecovering : .presenting
  }
}
