// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
    // Idle admission, duplicate clicks, cancellation/drain and the next start.
    do {
      let bridge = DriverBridge(), live = LiveMonitorModel(muteAudio: true)
      var ready = 0
      live.start(bridge: bridge, deck: deck, expectedRoute: route, onReceiving: { ready += 1 })
      live.start(bridge: bridge, deck: deck, expectedRoute: route)
      await until { live.receiverReady }
      let observed1 = await bridge.starts
      precondition(ready == 1 && observed1 == 1)
      await live.stopAndWait()
      precondition(!live.busy && !live.active && live.completeFrames == 42)
      live.start(bridge: bridge, deck: deck, expectedRoute: route)
      await until { live.receiverReady }
      await live.stopAndWait()
      let observed2 = await bridge.starts
      let observed3 = await bridge.ends
      precondition(observed2 == 2 && observed3 == 2)
      print("PASS: idle admits once; duplicate ignored; cancel drains; subsequent start succeeds")
    }
    for scenario in ["complete", "long-join", "query-failure", "cancel", "route-change", "source-change"] {
      let model = RewindDVModel(), live = LiveMonitorModel(muteAudio: true)
      model.selectedDeck = deck; model.selectedRoute = route
      let query = Barrier(), boundary = Barrier()
      model.joinBoundary = boundary
      await model.bridge.holdInspection(query, fail: scenario == "query-failure")
      let observer = Task { await model.observeExternalTransport(live: live, deck: deck, route: route) }
      await until { await query.entered }
      model.startIngest(live: live, deck: deck, route: route, destination: destination)
      precondition(model.isBusy && live.busy && live.waitingForAdmission)
      model.startIngest(live: live, deck: deck, route: route, destination: destination)
      let observed4 = await model.bridge.starts
      precondition(observed4 == 0)
      if scenario == "cancel" { live.stop() }
      if scenario == "route-change" { model.selectedRoute = nil }
      if scenario == "source-change" { model.monitorSource = .file }
      await query.release()
      await until { await boundary.entered }
      await observer.value
      // The old observer has fully ended, and the foreground start is held
      // precisely between join and bridge admission. A restart must stay out.
      await model.observeExternalTransport(live: live, deck: deck, route: route)
      let observed5 = await model.bridge.inspections
      precondition(observed5 == 1)
      let observed6 = await model.bridge.starts
      precondition(observed6 == 0)
      if scenario == "long-join" { AdmissionFixtureClock.offset = .seconds(31) }
      await boundary.release()
      if scenario == "complete" || scenario == "query-failure" || scenario == "long-join" {
        await until { live.receiverReady }
        let observed7 = await model.bridge.starts
        precondition(!model.isBusy && model.plays == 1 && observed7 == 1)
        await live.stopAndWait()
        let observed8 = await model.bridge.ends
        precondition(observed8 == 1)
      } else {
        await until { !live.busy }
        let observed9 = await model.bridge.starts
        precondition(!model.isBusy && model.plays == 0 && observed9 == 0)
        let observed10 = await model.bridge.ends
        precondition(observed10 == 0 && !live.hasReceiveSession)
      }
      AdmissionFixtureClock.offset = .zero
      print("PASS: joined inspection \(scenario); restart excluded at boundary; exactly one or zero submissions")
    }
    // An already-issued real command is never stolen; its existing STOP
    // obligation survives a direct bridge rejection as well as model exclusion.
    do {
      let model = RewindDVModel(), live = LiveMonitorModel(muteAudio: true)
      model.selectedDeck = deck; model.selectedRoute = route
      model.isBusy = true; model.requiresSupervisedStop = true
      model.startIngest(live: live, deck: deck, route: route, destination: destination)
      precondition(!live.busy && model.isBusy && model.requiresSupervisedStop)
      await model.bridge.configure(command: true)
      live.start(bridge: model.bridge, deck: deck, expectedRoute: route, existingStopObligation: true)
      await until { !live.busy }
      precondition(model.requiresSupervisedStop && live.startRejection?.existingStopObligation == true)
      let observed11 = await model.bridge.ends
      let observed12 = await model.bridge.starts
      precondition(observed11 == 0 && observed12 == 0)
      print("PASS: real command exclusion and prior model STOP obligation preserved")
    }
    do {
      let bridge = DriverBridge(), live = LiveMonitorModel(muteAudio: true)
      await bridge.configure(terminal: 3)
      live.start(bridge: bridge, deck: deck, expectedRoute: route)
      await until { !live.busy && !live.active }
      precondition(live.receiverFailedWithoutTapeStopProof && live.tapeStopNeedsAttention)
      await bridge.configure(reject: true)
      live.start(bridge: bridge, deck: deck, ingestParent: destination, expectedRoute: route)
      await until { !live.busy }
      precondition(live.receiverFailedWithoutTapeStopProof && live.tapeStopNeedsAttention)
      precondition(live.completeFrames == 0 && !live.hasReceiveSession && live.flightURL == nil)
      let observed13 = await bridge.ends
      precondition(observed13 == 1)
      var otherBytes = bytes; otherBytes[40] = 2
      live.confirmReceiverTapeStopped(on: try FoundationRoute(data: otherBytes))
      precondition(live.receiverFailedWithoutTapeStopProof, "A different route cannot release STOP uncertainty")
      live.confirmReceiverTapeStopped(on: route)
      precondition(!live.receiverFailedWithoutTapeStopProof && !live.tapeStopNeedsAttention)
      await bridge.configure(terminal: 3)
      live.start(bridge: bridge, deck: deck, expectedRoute: route)
      await until { !live.busy && !live.active }
      precondition(live.receiverFailedWithoutTapeStopProof, "A new receive failure must retain a fresh obligation")
      print("PASS: prior receiver STOP uncertainty survives rejection; only matching proof clears; new failure re-arms")
    }
    print("CAPTURE_ADMISSION_OFFLINE_PASS; no real driver, command or capture files")

    do {
      let bridge = DriverBridge(), live = LiveMonitorModel(muteAudio: true)
      await bridge.configure(acquiredFailure: true)
      live.start(bridge: bridge, deck: deck, expectedRoute: route)
      await until { !live.busy && !live.active }
      let ends = await bridge.ends
      precondition(ends == 1 && live.flightURL != nil && live.hasReceiveSession)
      precondition(!live.hasCurrentPreview && live.receiverFailedWithoutTapeStopProof)
      print("PASS: failure after acquisition cleans only its owned session once and retains STOP uncertainty")
    }
