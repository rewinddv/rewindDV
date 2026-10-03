import Testing

@testable import RewindDVMonitorCore

@Test func pictureSearchRequiresLivePreviewSupportAndNeverRunsDuringIngest() {
  for ingest in [false, true] {
    for supported in [false, true] {
      for busy in [false, true] {
        let p = WorkspaceCapabilities(source: .deck, deckSelected: true, busy: busy,
          requiresSupervisedStop: true, fastForwardSupported: true,
          liveMonitoring: true, ingestActive: ingest,
          shuttleForwardSupported: supported, shuttleReverseSupported: supported)
        #expect(p.allows(.shuttleForward) == (!ingest && supported && !busy))
        #expect(p.allows(.shuttleReverse) == (!ingest && supported && !busy))
        #expect(p.allows(.play) == (!ingest && !busy))
        #expect(p.allows(.stop) == !busy)
        #expect(!p.allows(.rewind) && !p.allows(.fastForward))
      }
    }
  }
  let stopped = WorkspaceCapabilities(source: .deck, deckSelected: true,
    shuttleForwardSupported: true, shuttleReverseSupported: true)
  #expect(!stopped.allows(.shuttleForward) && !stopped.allows(.shuttleReverse))
  let file = WorkspaceCapabilities(source: .file, fileReady: true,
    liveMonitoring: true, shuttleForwardSupported: true, shuttleReverseSupported: true)
  #expect(!file.allows(.shuttleForward) && !file.allows(.shuttleReverse))
}

@Test func deckControlOnlyExposesQualifiedCommands() {
  let ready = WorkspaceCapabilities(source: .deck, deckSelected: true)
  for action in MonitorAction.allCases {
    #expect(ready.allows(action) == [.play, .stop, .rewind].contains(action))
  }
}

@Test func fastForwardRequiresSupportAndNeverBypassesStopOrLockout() {
  for supported in [false, true] {
    for busy in [false, true] {
      for locked in [false, true] {
        for stop in [false, true] {
          let policy = WorkspaceCapabilities(source: .deck, deckSelected: true,
            busy: busy, lockedOut: locked, requiresSupervisedStop: stop,
            fastForwardSupported: supported)
          #expect(policy.allows(.fastForward) == (supported && !busy && !locked && !stop))
        }
      }
    }
  }
  #expect(!WorkspaceCapabilities(source: .file, fileReady: true, fastForwardSupported: true).allows(.fastForward))
  #expect(!WorkspaceCapabilities(source: .deck, fastForwardSupported: true).allows(.fastForward))
}

@Test func singleClickDeckControlRetainsSelectionBusyAndLockoutGates() {
  for selected in [false, true] {
    for busy in [false, true] {
      for locked in [false, true] {
        let policy = WorkspaceCapabilities(
          source: .deck, deckSelected: selected, busy: busy, lockedOut: locked)
        #expect(policy.allows(.play) == (selected && !busy && !locked))
        #expect(policy.allows(.stop) == (selected && !busy && !locked))
        #expect(policy.allows(.rewind) == (selected && !busy && !locked))
        #expect(!policy.allows(.capture))
      }
    }
  }
}

@Test func fileControlsNeverBecomeDeckCommands() {
  let file = WorkspaceCapabilities(source: .file, fileReady: true, filePlaying: true)
  #expect(file.allows(.pause))
  #expect(!file.allows(.stop))
  #expect(file.allows(.stepForward))
  #expect(!file.allows(.play))
  #expect(!file.allows(.rewind))
  #expect(!file.allows(.capture))
  let empty = WorkspaceCapabilities(source: .file, deckSelected: true)
  #expect(MonitorAction.allCases.allSatisfy { !empty.allows($0) })
}

@Test func acceptedMotionAllowsOnlyFreshSingleClickStop() {
  for selected in [false, true] {
    for busy in [false, true] {
      for locked in [false, true] {
        let policy = WorkspaceCapabilities(
          source: .deck, deckSelected: selected,
          busy: busy, lockedOut: locked, requiresSupervisedStop: true)
        for action in MonitorAction.allCases {
          #expect(
            policy.allows(action) == (action == .stop && selected && !busy && !locked))
        }
      }
    }
  }
}

@Test func filePermissionDoesNotDependOnOldDeckLockout() {
  let file = WorkspaceCapabilities(source: .file, fileReady: true, lockedOut: true)
  #expect(file.allows(.play))
  #expect(!WorkspaceCapabilities(source: .file, fileReady: true, busy: true).allows(.play))
}

@Test func counterIsNotInventedTapeTimecode() {
  #expect(MonitorCounter.elapsed(seconds: 3_661.125) == "01:01:01.125")
  #expect(MonitorCounter.elapsed(seconds: .nan) == "--:--:--.---")
  #expect(MonitorCounter.elapsed(seconds: .infinity) == "--:--:--.---")
  #expect(MonitorCounter.elapsed(seconds: -1) == "--:--:--.---")
}

@Test func captureElapsedStartsAtQualifiedPlayAndStopsAtObservedMechanicalStop() {
  var state = CaptureElapsedState()
  #expect(state.display(atUptimeNanoseconds: 9_000_000_000) == nil)
  state.observeCompleteDVFrame(byteCount: 120_000)
  #expect(state.display(atUptimeNanoseconds: 9_000_000_000) == nil)
  state.begin(atUptimeNanoseconds: 10_000_000_000)
  #expect(state.display(atUptimeNanoseconds: 10_000_000_000) == "00:00:00:00")
  #expect(state.display(atUptimeNanoseconds: 13_500_000_000) == "00:00:03:15")
  state.stop(atUptimeNanoseconds: 14_250_000_000)
  #expect(state.display(atUptimeNanoseconds: 99_000_000_000) == "00:00:04:07")
  #expect(!state.isRunning)
}

@Test func captureElapsedWithholdsOnlyUnprovenOrConflictingFrameField() {
  var unknown = CaptureElapsedState()
  unknown.begin(atUptimeNanoseconds: 0)
  #expect(unknown.display(atUptimeNanoseconds: 3_500_000_000) == "00:00:03:--")
  unknown.observeCompleteDVFrame(byteCount: 144_000)
  #expect(unknown.display(atUptimeNanoseconds: 3_500_000_000) == "00:00:03:12")
  unknown.observeCompleteDVFrame(byteCount: 120_000)
  #expect(unknown.conflictingSystems)
  #expect(unknown.display(atUptimeNanoseconds: 3_500_000_000) == "00:00:03:--")
}

@Test func captureElapsedRestartsForEveryPlayAndIsIndependentOfFrameArrival() {
  var state = CaptureElapsedState()
  state.begin(atUptimeNanoseconds: 20)
  state.begin(atUptimeNanoseconds: 40)
  #expect(state.startedAtUptimeNanoseconds == 40)
  #expect(state.elapsedNanoseconds(atUptimeNanoseconds: 1_000_000_040) == 1_000_000_000)
  state.observeCompleteDVFrame(byteCount: 1)
  #expect(state.system == nil)
  state.stop(atUptimeNanoseconds: 10)
  #expect(state.elapsedNanoseconds(atUptimeNanoseconds: .max) == 0)
  state.stop(atUptimeNanoseconds: 90)
  #expect(state.stoppedAtUptimeNanoseconds == 40)

  state.observeCompleteDVFrame(byteCount: 120_000)
  state.begin(atUptimeNanoseconds: 100)
  #expect(state.startedAtUptimeNanoseconds == 100)
  #expect(state.stoppedAtUptimeNanoseconds == nil)
  #expect(state.system == .ntsc525_60)

  state.resetInterval()
  #expect(!state.hasStarted)
  #expect(state.display(atUptimeNanoseconds: .max) == nil)
  #expect(state.system == .ntsc525_60)
}
