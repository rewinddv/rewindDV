// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded presentation delivery, not archival storage. Status coalesces without
/// evicting media. Only actual frame-capacity exhaustion discards old frames.
/// All mutable state is protected by lock; no callback or I/O runs under it.
public final class LiveFrameMailbox<Frame: Sendable, Status: Sendable>: @unchecked Sendable {
  public struct Delivery: Sendable {
    public let status: Status?
    public let frames: [Frame]
    public let failure: String?
  }
  private let lock = NSLock()
  private let capacity: Int
  private var status: Status?
  private var frames: [Frame] = []
  private var failure: String?
  private var changed = false
  private var dropped: UInt64 = 0
  public init(capacity: Int = 16) {
    precondition(capacity > 0)
    self.capacity = capacity
  }
  public var skippedFrames: UInt64 { lock.withLock { dropped } }
  public func publish(status: Status, frames incoming: [Frame]) {
    lock.withLock {
      guard failure == nil else { return }
      self.status = status
      for frame in incoming {
        if frames.count == capacity { frames.removeFirst(); dropped &+= 1 }
        frames.append(frame)
      }
      changed = true
    }
  }
  public func fail(_ message: String) {
    lock.withLock {
      if failure == nil { failure = message }
      changed = true
    }
  }
  public func take() -> Delivery? {
    lock.withLock {
      guard changed else { return nil }
      let result = Delivery(status: status, frames: frames, failure: failure)
      frames.removeAll(keepingCapacity: true)
      changed = false
      return result
    }
  }
}
