// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

enum LivePumpEvent: Sendable {
  case batch(LiveReceiveBatch)
  case failure(String)
}

/// Only presentation delivery is lossy. DriverBridge has retained immutable raw
/// copies before yielding here; disk durability and ACK may still be pending.
/// Preview is never verification. Join this pump before retiring receive.
final class LiveReceivePump: Sendable {
  let notifications: AsyncStream<Void>
  private let task: Task<Void, Never>
  private let mailbox = LiveFrameMailbox<LivePreservedFrame, LiveReceiveBatch>()

  convenience init(bridge: DriverBridge) {
    self.init(readBatch: { try await bridge.readLiveBatch() })
  }

  /// The injected reader is also used by the hardware-free end-to-end regression.
  init(readBatch: @escaping @Sendable () async throws -> LiveReceiveBatch) {
    let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    notifications = channel.stream
    let mailbox = mailbox
    task = Task.detached(priority: .userInitiated) {
      defer { channel.continuation.finish() }
      var lastNotification = ContinuousClock.now
      var priorState: UInt32?
      do {
        while !Task.isCancelled {
          let batch = try await readBatch()
          mailbox.publish(status: batch.replacingFrames([]), frames: batch.frames)
          let now = ContinuousClock.now
          if !batch.frames.isEmpty || batch.status.state != priorState ||
            now - lastNotification >= .milliseconds(250) {
            // Tokens may coalesce; the mailbox, not the token, owns every frame.
            if case .terminated = channel.continuation.yield(()) { return }
            lastNotification = now
          }
          priorState = batch.status.state
          if batch.status.state >= 2 { break }
          if batch.drained { try await Task.sleep(for: .milliseconds(8)) }
          else { await Task.yield() }
        }
      } catch is CancellationError {
      } catch {
        mailbox.fail(error.localizedDescription)
        channel.continuation.yield(())
      }
    }
  }

  var skippedDeliveryFrames: UInt64 { mailbox.skippedFrames }
  func take() -> LivePumpEvent? {
    guard let delivery = mailbox.take() else { return nil }
    if let failure = delivery.failure { return .failure(failure) }
    guard let status = delivery.status else { return nil }
    return .batch(status.replacingFrames(delivery.frames))
  }
  func cancelAndJoin() async {
    task.cancel()
    await task.value
  }
}
