import Foundation
import Testing
@testable import RewindDVMonitorCore

@Test func statusOnlyEventsCannotEvictMedia() async {
  // The exact RevC error: its async stream stored batches, not wake tokens.
  let old = AsyncStream<[Int]>.makeStream(bufferingPolicy: .bufferingNewest(2))
  old.continuation.yield([0])
  old.continuation.yield([])
  if case .dropped(let frames) = old.continuation.yield([]) { #expect(frames == [0]) }
  else { Issue.record("RevC reproduction did not evict its media batch") }
  old.continuation.finish()

  let mailbox = LiveFrameMailbox<Int, Int>()
  mailbox.publish(status: 0, frames: [0])
  for tick in 1...1000 { mailbox.publish(status: tick, frames: []) }
  let delivery = mailbox.take()
  #expect(delivery?.frames == [0])
  #expect(delivery?.status == 1000)
  #expect(mailbox.skippedFrames == 0)
  #expect(mailbox.take() == nil)
}

@Test func pollingAndSlowConsumerRetainEveryFrameInOrder() {
  let mailbox = LiveFrameMailbox<Int, Int>()
  var delivered: [Int] = []
  // 125 Hz poller, ~31 Hz frames, consumer every 56 ms. Status is coalesced;
  // media is not. Deterministic virtual time rather than scheduler luck.
  for tick in 0..<4000 {
    mailbox.publish(status: tick, frames: tick % 4 == 0 ? [tick / 4] : [])
    if tick % 7 == 6 { delivered += mailbox.take()?.frames ?? [] }
  }
  delivered += mailbox.take()?.frames ?? []
  #expect(delivered == Array(0..<1000))
  #expect(mailbox.skippedFrames == 0)
}

@Test func overloadIsBoundedAndFailureCannotBeOverwritten() {
  let mailbox = LiveFrameMailbox<Int, Int>(capacity: 16)
  mailbox.publish(status: 1, frames: Array(0..<100))
  #expect(mailbox.skippedFrames == 84)
  mailbox.fail("original receive failure")
  mailbox.publish(status: 2, frames: [100])
  mailbox.fail("later failure")
  let delivery = mailbox.take()
  #expect(delivery?.frames == Array(84..<100))
  #expect(delivery?.status == 1)
  #expect(delivery?.failure == "original receive failure")
}
