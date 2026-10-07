// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Local, same-user command channel. The app remains the sole owner of models,
/// receive state and the driver connection. One command occupies one socket.
struct RewindDVCommand: Codable, Sendable {
  let name: String
  let arguments: [String: String]
}

private enum CommandFailure: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    if case .invalid(let message) = self { message } else { nil }
  }
}

@MainActor
final class RewindDVCommandBridge {
  private var server: RewindDVLocalCommandServer?

  func start(model: RewindDVModel, playback: OfflineDVPlaybackModel,
             surgery: SurgeryModel, live: LiveMonitorModel,
             wholeTape: WholeTapeCaptureModel, installer: SystemExtensionInstaller,
             tapeMap: TapeEvidenceMapModel, recovery: GentleRecoveryModel,
             multiPass: MultiPassModel,
             forensicPrefix: ForensicPrefixModel,
             requestActivation: @escaping @MainActor () -> Void) {
    guard server == nil else { return }
    let service = RewindDVLocalCommandServer()
    do {
      try service.start { command in
        try Self.execute(command, model: model, playback: playback,
                         surgery: surgery, live: live, wholeTape: wholeTape,
                         installer: installer, tapeMap: tapeMap, recovery: recovery,
                         multiPass: multiPass,
                         forensicPrefix: forensicPrefix, requestActivation: requestActivation)
      }
      server = service
    } catch {
      // The GUI still works if a local command socket cannot be created.
      NSLog("RewindDV command channel unavailable: %@", error.localizedDescription)
    }
  }

  func stop() { server?.stop(); server = nil }

  private static func required(_ key: String, from command: RewindDVCommand) throws -> String {
    guard let value = command.arguments[key], !value.isEmpty else {
      throw CommandFailure.invalid("Missing \(key)")
    }
    return value
  }

  private static func fileURL(_ key: String, from command: RewindDVCommand) throws -> URL {
    let path = try required(key, from: command)
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw CommandFailure.invalid("\(key) must be an absolute local path")
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  private static func readyForDeck(_ model: RewindDVModel, _ live: LiveMonitorModel,
                                   _ wholeTape: WholeTapeCaptureModel,
                                   _ installer: SystemExtensionInstaller,
                                   transportAction: Bool = false) throws -> (DiscoveredDeck, FoundationRoute) {
    guard !RewindDVRuntimeOptions.hardwareDisabled,
          !model.isBusy, !model.wholeTapeActive, !model.controlLockedOut,
          (!model.requiresSupervisedStop || transportAction), !installer.isInFlight,
          !live.busy, !live.lockedOut, !wholeTape.active,
          let deck = model.selectedDeck, let route = model.selectedRoute,
          !model.refreshFailed else {
      throw CommandFailure.invalid("Deck command unavailable: driver, route or operation is not ready")
    }
    return (deck, route)
  }

  private static func execute(_ command: RewindDVCommand, model: RewindDVModel,
                              playback: OfflineDVPlaybackModel, surgery: SurgeryModel,
                              live: LiveMonitorModel, wholeTape: WholeTapeCaptureModel,
                              installer: SystemExtensionInstaller,
                              tapeMap: TapeEvidenceMapModel, recovery: GentleRecoveryModel,
                              multiPass: MultiPassModel,
                              forensicPrefix: ForensicPrefixModel,
                              requestActivation: @MainActor () -> Void) throws -> [String: Any] {
    // External commands must honor the same operation locks as the GUI.
    let group = command.name.split(separator: ".").first.map(String.init) ?? ""
    let isObservation = command.name.hasSuffix(".status") || command.name == "playback.metadata"
    let isCancellation = command.name.hasSuffix(".cancel")
    if ["archive", "playback", "surgery", "map", "recovery", "multi_pass", "forensic_prefix"].contains(group),
       !isObservation, !isCancellation {
      guard !model.navigationLocked, !installer.isInFlight, !live.active,
            !live.busy, !wholeTape.active else {
        throw CommandFailure.invalid("Offline operation unavailable while capture, deck work or activation is active")
      }
      if group == "map" || group == "recovery" {
        guard !multiPass.busy, !forensicPrefix.busy else {
          throw CommandFailure.invalid("Analysis is locked by another offline operation")
        }
      } else if group == "multi_pass" {
        guard !tapeMap.busy, !forensicPrefix.busy else {
          throw CommandFailure.invalid("Multi-pass work is locked by another offline operation")
        }
      } else if group == "forensic_prefix" {
        guard !tapeMap.busy, !multiPass.busy else {
          throw CommandFailure.invalid("Prefix recovery is locked by another offline operation")
        }
      }
    }
    switch command.name {
    case "status":
      return ["page": (model.page ?? .capture).accessibilityID,
              "source": model.monitorSource.rawValue,
              "driverReady": model.latestDriverSnapshot != nil && !model.refreshFailed,
              "deck": model.selectedDeck?.name ?? NSNull(),
              "decks": model.driverSnapshot?.decks.map {
                ["guid": String($0.guid), "name": $0.name,
                 "operational": $0.isOperational] as [String: Any]
              } ?? [],
              "lockedOut": model.controlLockedOut || live.lockedOut,
              "captureActive": wholeTape.active || live.active || live.busy,
              "captureStatus": wholeTape.active ? wholeTape.status : live.detail,
              "captureFolder": wholeTape.evidenceURL?.path ?? live.flightURL?.path ?? NSNull(),
              "playback": playbackState(playback), "surgery": surgeryState(surgery),
              "map": mapState(tapeMap), "recovery": recoveryState(recovery),
              "multiPass": multiPassState(multiPass)]
    case "app.navigate":
      guard !model.navigationLocked, !installer.isInFlight, !live.active, !live.busy else {
        throw CommandFailure.invalid("Navigation is locked by an active operation")
      }
      let pages: [String: WorkspacePage] = ["workspace": .capture, "archives": .archives,
                                             "device-inspector": .inspector, "diagnostics": .diagnostics]
      guard let page = pages[try required("page", from: command)] else {
        throw CommandFailure.invalid("Unknown page")
      }
      model.page = page
      return ["page": page.accessibilityID]
    case "archive.verify":
      guard !model.isBusy, !model.navigationLocked else { throw CommandFailure.invalid("Archive verifier is busy") }
      let url = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CommandFailure.invalid("Archive folder is inaccessible to the app")
      }
      model.page = .archives; model.verifyArchive(url)
      return archiveState(model)
    case "archive.metadata":
      guard !model.isBusy, !model.navigationLocked else { throw CommandFailure.invalid("Metadata inspector is busy") }
      let url = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CommandFailure.invalid("DV source is inaccessible to the app")
      }
      model.page = .archives; model.analyzeNativeDV(url)
      return archiveState(model)
    case "archive.status": return archiveState(model)
    case "playback.open":
      guard !model.navigationLocked, !live.active, !live.busy else {
        throw CommandFailure.invalid("Playback unavailable while capture or deck work is active")
      }
      let url = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CommandFailure.invalid("Source is unreadable by the app. Open it in the GUI once to grant sandbox access.")
      }
      model.monitorSource = .file
      playback.open(url: url)
      return playbackState(playback)
    case "playback.status": return playbackState(playback)
    case "playback.play":
      guard playback.canPlay else { throw CommandFailure.invalid("No paused file is ready") }
      playback.play(); return playbackState(playback)
    case "playback.pause":
      guard playback.canPause else { throw CommandFailure.invalid("Playback is not running") }
      playback.pause(); return playbackState(playback)
    case "playback.stop": playback.stop(); return playbackState(playback)
    case "playback.close": playback.close(); return playbackState(playback)
    case "playback.seek":
      let raw = try required("seconds", from: command)
      guard let seconds = Double(raw), seconds.isFinite, seconds >= 0, playback.hasLoadedFile else {
        throw CommandFailure.invalid("Seek needs a loaded file and nonnegative finite seconds")
      }
      playback.seek(to: seconds); return playbackState(playback)
    case "playback.step":
      let raw = try required("frames", from: command)
      guard let count = Int(raw), count != 0, (-100_000...100_000).contains(count),
            playback.hasLoadedFile else {
        throw CommandFailure.invalid("Step needs a loaded file and 1…100000 signed frames")
      }
      playback.stepFrames(count); return playbackState(playback)
    case "playback.exact_timeline":
      guard playback.hasLoadedFile, !playback.isIndexing else {
        throw CommandFailure.invalid("A file must be loaded and not already indexing")
      }
      playback.buildExactTimeline(); return playbackState(playback)
    case "playback.assess":
      guard playback.hasLoadedFile, !playback.isIndexing else {
        throw CommandFailure.invalid("A file must be loaded and not indexing")
      }
      playback.assessWholeFile(); return playbackState(playback)
    case "playback.metadata":
      let includeEvidence = command.arguments["evidence"] == "true"
      return ["playback": playbackState(playback),
              "metadataStatus": playback.metadata.presentationStatus,
              "selectedFrameOrdinalIsEstimated": playback.metadata.ordinalIsEstimated,
              "technicalSpecifications": playback.metadata.specifications?.sections.map { section in
                ["section": section.title, "rows": section.rows.map {
                  includeEvidence ? ["label": $0.label, "value": $0.value, "evidence": $0.evidence]
                    : ["label": $0.label, "value": $0.value]
                }] as [String: Any]
              } ?? []]
    case "playback.view":
      guard playback.hasLoadedFile else { throw CommandFailure.invalid("No loaded file") }
      if let raw = command.arguments["mode"] {
        let modes: [String: DVViewingMode] = ["standard": .standard, "weave": .weave,
                                               "top": .top, "bottom": .bottom, "blend": .blend]
        guard let mode = modes[raw] else { throw CommandFailure.invalid("Unknown view mode") }
        playback.setViewingMode(mode)
      }
      if let raw = command.arguments["aspect"] {
        guard let aspect = DVDisplayAspect(rawValue: raw) else {
          throw CommandFailure.invalid("Aspect must be 4:3 or 16:9")
        }
        playback.setDisplayAspect(aspect)
      }
      if let raw = command.arguments["zoom"] {
        guard let value = Int(raw), [1, 2, 4, 8].contains(value) else {
          throw CommandFailure.invalid("Zoom must be 1, 2, 4 or 8")
        }
        playback.setZoom(CGFloat(value))
      }
      if let raw = command.arguments["zebras"] {
        guard raw == "true" || raw == "false" else {
          throw CommandFailure.invalid("Zebras must be true or false")
        }
        playback.setExtremeZebras(raw == "true")
      }
      return ["mode": playback.viewingMode.rawValue, "aspect": playback.displayAspect.rawValue,
              "zoom": Int(playback.zoom), "zebras": playback.extremeZebras]
    case "surgery.open":
      guard !model.navigationLocked, !live.active, !live.busy, !surgery.busy else {
        throw CommandFailure.invalid("Surgery unavailable during another operation")
      }
      let url = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CommandFailure.invalid("Source is unreadable by the app. Open it in the GUI once to grant sandbox access.")
      }
      model.monitorSource = .surgery
      surgery.open(url)
      return surgeryState(surgery)
    case "surgery.status": return surgeryState(surgery)
    case "surgery.range":
      guard let clip = surgery.clip, !surgery.busy,
            let first = Int(try required("first", from: command)),
            let end = Int(try required("end", from: command)),
            first >= 0, first < end, end <= clip.timeline.frameCount else {
        throw CommandFailure.invalid("Range needs analyzed clip and valid [first,end) source frames")
      }
      surgery.select(first: first, end: end)
      surgery.splitScenes = command.arguments["splitScenes"] == "true"
      return surgeryState(surgery)
    case "surgery.select":
      guard let clip = surgery.clip, !surgery.busy,
            let index = Int(try required("segment", from: command)),
            clip.segments.contains(where: { $0.id == index }) else {
        throw CommandFailure.invalid("Select needs a valid analyzed segment")
      }
      surgery.toggleSegment(index); return surgeryState(surgery)
    case "surgery.select_all":
      guard surgery.clip != nil, !surgery.busy else { throw CommandFailure.invalid("No analyzed clip") }
      surgery.selectAllSegments(command.arguments["selected"] != "false")
      return surgeryState(surgery)
    case "surgery.export":
      guard surgery.clip != nil, !surgery.busy else { throw CommandFailure.invalid("No analyzed clip") }
      let merged = command.arguments["merged"] == "true"
      if merged {
        guard surgery.mergeIssue == nil else { throw CommandFailure.invalid(surgery.mergeIssue ?? "Invalid merge") }
      } else {
        guard !surgery.ranges.isEmpty else { throw CommandFailure.invalid("Empty export range") }
      }
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Destination is unwritable by the app. Choose it in the GUI once to grant sandbox access.")
      }
      surgery.export(to: parent, merged: merged); return surgeryState(surgery)
    case "surgery.cancel": surgery.cancel(); return surgeryState(surgery)
    case "map.create":
      guard !model.navigationLocked, !live.active, !live.busy, !tapeMap.busy else {
        throw CommandFailure.invalid("Tape map creation unavailable during another operation")
      }
      let source = try fileURL("source", from: command)
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isReadableFile(atPath: source.path),
            FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Source or destination is inaccessible to the app; grant it through the GUI")
      }
      model.page = .archives
      tapeMap.create(source: source, parent: parent)
      return mapState(tapeMap)
    case "map.open":
      guard !tapeMap.busy else { throw CommandFailure.invalid("Tape map is busy") }
      let directory = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: directory.path) else {
        throw CommandFailure.invalid("Map folder is inaccessible to the app")
      }
      model.page = .archives
      tapeMap.open(directory); return mapState(tapeMap)
    case "map.status": return mapState(tapeMap)
    case "map.connect_source":
      guard tapeMap.reader != nil, !tapeMap.busy else { throw CommandFailure.invalid("Open a map first") }
      let url = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw CommandFailure.invalid("Original DV is inaccessible to the app")
      }
      tapeMap.connectSource(url); return mapState(tapeMap)
    case "map.jump":
      guard let count = tapeMap.receipt?.frameLedgerRecordCount,
            let frame = UInt64(try required("frame", from: command)), frame < count,
            !tapeMap.busy else { throw CommandFailure.invalid("Frame outside the open map") }
      tapeMap.jump(to: frame); return mapState(tapeMap)
    case "map.page":
      guard !tapeMap.busy, let reader = tapeMap.reader,
            let number = UInt64(try required("number", from: command)),
            number < reader.binding.pageCount else { throw CommandFailure.invalid("Unknown map page") }
      tapeMap.loadPage(number); return mapState(tapeMap)
    case "map.find_issue":
      guard !tapeMap.busy, tapeMap.reader != nil else { throw CommandFailure.invalid("Open a map first") }
      let direction = try required("direction", from: command)
      guard direction == "next" || direction == "previous" else {
        throw CommandFailure.invalid("Direction must be next or previous")
      }
      let code: DVTapeEvidenceMapExporter.IssueCode?
      if let raw = command.arguments["code"] {
        guard let parsed = DVTapeEvidenceMapExporter.IssueCode(rawValue: raw) else {
          throw CommandFailure.invalid("Unknown issue code")
        }
        code = parsed
      } else { code = nil }
      tapeMap.findIssue(forward: direction == "next", code: code); return mapState(tapeMap)
    case "map.export_reports":
      guard tapeMap.canExportReports else { throw CommandFailure.invalid("Verify the original DV against the map first") }
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Destination is inaccessible to the app")
      }
      tapeMap.exportReports(parent: parent); return mapState(tapeMap)
    case "map.import_external_report":
      guard !tapeMap.busy else { throw CommandFailure.invalid("Map is busy") }
      let source = try fileURL("source", from: command)
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isReadableFile(atPath: source.path),
            FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Report or destination is inaccessible to the app")
      }
      tapeMap.importExternalReport(source, parent: parent); return mapState(tapeMap)
    case "map.review_open":
      guard !tapeMap.busy, tapeMap.reader != nil else { throw CommandFailure.invalid("Open a map first") }
      let directory = try fileURL("path", from: command)
      let create = command.arguments["create"] == "true"
      let access = create ? try fileURL("access", from: command) : directory
      guard create ? FileManager.default.isWritableFile(atPath: access.path)
                   : FileManager.default.isReadableFile(atPath: directory.path) else {
        throw CommandFailure.invalid("Review queue location is inaccessible to the app")
      }
      tapeMap.connectReview(at: directory, create: create, access: access)
      return mapState(tapeMap)
    case "map.review_add":
      guard !tapeMap.busy, tapeMap.reviewJournal != nil, tapeMap.selection != nil else {
        throw CommandFailure.invalid("Select a map frame and open a review queue first")
      }
      tapeMap.addSelectedForReview(note: command.arguments["note"] ?? "")
      return mapState(tapeMap)
    case "map.review_update":
      guard !tapeMap.busy, tapeMap.reviewJournal != nil,
            let id = try? required("id", from: command),
            let event = tapeMap.reviewEvents.first(where: { $0.item.id == id }),
            let state = DVRecoveryReviewJournal.ReviewState(rawValue: try required("state", from: command)) else {
        throw CommandFailure.invalid("Review item must be on the visible queue page")
      }
      tapeMap.updateReview(event.item, state: state, note: command.arguments["note"] ?? "")
      return mapState(tapeMap)
    case "map.review_page":
      guard !tapeMap.busy, tapeMap.reviewJournal != nil,
            tapeMap.reviewItemCount > 0,
            let number = UInt64(try required("number", from: command)),
            number < (tapeMap.reviewItemCount - 1) / 256 + 1 else {
        throw CommandFailure.invalid("Unknown review queue page")
      }
      tapeMap.loadReviewPage(number); return mapState(tapeMap)
    case "map.scenes_analyze":
      guard tapeMap.canExportReports else { throw CommandFailure.invalid("Verify the original DV first") }
      tapeMap.analyzeScenes(); return mapState(tapeMap)
    case "map.scenes_decide":
      guard !tapeMap.busy, let plan = tapeMap.scenePlan,
            let frame = UInt64(try required("frame", from: command)),
            plan.boundaries.contains(where: { $0.frame == frame }),
            let decision = DVSceneSegmentation.Decision(rawValue: try required("decision", from: command)) else {
        throw CommandFailure.invalid("Unknown scene boundary or decision")
      }
      tapeMap.decideScene(frame, decision: decision, note: command.arguments["note"])
      return mapState(tapeMap)
    case "map.scenes_publish":
      guard !tapeMap.busy, let plan = tapeMap.scenePlan else {
        throw CommandFailure.invalid("Analyze scenes first")
      }
      let exportDV = command.arguments["exportDV"] == "true"
      guard !exportDV || plan.pendingCount == 0 else {
        throw CommandFailure.invalid("Review every proposed boundary before exporting DV")
      }
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Destination is inaccessible to the app")
      }
      tapeMap.publishScenes(parent: parent, exportDV: exportDV); return mapState(tapeMap)
    case "map.cancel": tapeMap.cancel(); return mapState(tapeMap)
    case "recovery.create":
      guard tapeMap.canExportReports, let receipt = tapeMap.receipt,
            let binding = tapeMap.reader?.binding, let mapDirectory = tapeMap.directory,
            !recovery.busy else {
        throw CommandFailure.invalid("Open a map and verify its original DV first")
      }
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: parent.path),
            !DVGentleRecovery.isWithin(parent, directory: mapDirectory) else {
        throw CommandFailure.invalid("Plan destination must be outside the map and writable by the app")
      }
      func integer(_ key: String, default fallback: Int) throws -> Int {
        guard let raw = command.arguments[key] else { return fallback }
        guard let value = Int(raw) else { throw CommandFailure.invalid("Invalid \(key)") }
        return value
      }
      let first = UInt64(try required("first", from: command))
      let end = UInt64(try required("end", from: command))
      guard let first, let end else { throw CommandFailure.invalid("Invalid frame range") }
      let budget = DVGentleRecovery.Budget(
        maximumAttempts: try integer("maximumAttempts", default: 3),
        attemptsPerTarget: try integer("attemptsPerTarget", default: 2),
        passSeconds: try integer("passSeconds", default: 20),
        totalReservedSeconds: try integer("totalSeconds", default: 300),
        cooldownSeconds: try integer("cooldownSeconds", default: 60))
      let plan = try DVGentleRecovery.Plan(source: receipt.sourceSnapshot,
        mapSHA256: binding.mapReceiptSHA256, tapeLabel: try required("tape", from: command),
        budget: budget, targets: [.init(first: first, endExclusive: end,
                                       reason: "Operator-selected file-frame review region")])
      let output = parent.appendingPathComponent("rewindDV-Recovery-\(plan.id)")
      recovery.open(directory: output, plan: plan, source: receipt.sourceSnapshot,
                    mapSHA: binding.mapReceiptSHA256, accessRoot: parent)
      return recoveryState(recovery)
    case "recovery.open":
      guard let receipt = tapeMap.receipt, let binding = tapeMap.reader?.binding,
            !recovery.busy else { throw CommandFailure.invalid("Open the matching map first") }
      let directory = try fileURL("path", from: command)
      guard FileManager.default.isReadableFile(atPath: directory.path) else {
        throw CommandFailure.invalid("Recovery plan is inaccessible to the app")
      }
      recovery.open(directory: directory, plan: nil, source: receipt.sourceSnapshot,
                    mapSHA: binding.mapReceiptSHA256, accessRoot: directory)
      return recoveryState(recovery)
    case "recovery.refresh": recovery.refresh(); return recoveryState(recovery)
    case "recovery.status": return recoveryState(recovery)
    case "forensic_prefix.recover":
      guard !model.navigationLocked, !live.active, !live.busy, !wholeTape.active,
            !forensicPrefix.busy else { throw CommandFailure.invalid("Recovery unavailable while capture or deck work is active") }
      let source = try fileURL("source", from: command)
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isReadableFile(atPath: source.path),
            FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Source or destination is inaccessible to the app")
      }
      model.page = .archives
      forensicPrefix.recover(source: source, parent: parent)
      return forensicPrefixState(forensicPrefix)
    case "forensic_prefix.status": return forensicPrefixState(forensicPrefix)
    case "forensic_prefix.cancel": forensicPrefix.cancel(); return forensicPrefixState(forensicPrefix)
    case "multi_pass.base":
      guard let input = tapeMap.multiPassInput, !multiPass.busy else {
        throw CommandFailure.invalid("Open a map and verify its original DV first")
      }
      multiPass.reset(base: input); return multiPassState(multiPass)
    case "multi_pass.add":
      guard !multiPass.busy, !multiPass.bindings.isEmpty else {
        throw CommandFailure.invalid("Select a verified base first")
      }
      let map = try fileURL("map", from: command)
      let source = try fileURL("source", from: command)
      guard FileManager.default.isReadableFile(atPath: map.path),
            FileManager.default.isReadableFile(atPath: source.path) else {
        throw CommandFailure.invalid("Donor map or source is inaccessible to the app")
      }
      multiPass.add(mapURL: map, sourceURL: source); return multiPassState(multiPass)
    case "multi_pass.compare":
      guard !multiPass.busy, multiPass.bindings.count >= 2 else {
        throw CommandFailure.invalid("Two verified passes are required")
      }
      multiPass.compare(); return multiPassState(multiPass)
    case "multi_pass.status": return multiPassState(multiPass)
    case "multi_pass.choose":
      guard !multiPass.busy, let plan = multiPass.plan,
            let frame = UInt64(try required("frame", from: command)),
            plan.reviews.contains(where: { $0.baseFrame == frame }) else {
        throw CommandFailure.invalid("Unknown reviewed base frame")
      }
      let candidate = try required("candidate", from: command)
      guard candidate == "original" || plan.candidates.contains(where: {
        $0.id == candidate && $0.baseFrame == frame && $0.eligible
      }) else { throw CommandFailure.invalid("Candidate is not eligible for this base frame") }
      multiPass.choose(frame: frame, candidate: candidate)
      return multiPassState(multiPass)
    case "multi_pass.originals":
      guard !multiPass.busy, multiPass.plan != nil else { throw CommandFailure.invalid("No comparison plan") }
      multiPass.keepOriginals(); return multiPassState(multiPass)
    case "multi_pass.note":
      guard !multiPass.busy, let plan = multiPass.plan,
            let frame = UInt64(try required("frame", from: command)),
            plan.reviews.contains(where: { $0.baseFrame == frame }) else {
        throw CommandFailure.invalid("Unknown reviewed base frame")
      }
      multiPass.note(frame: frame, text: try required("text", from: command))
      return multiPassState(multiPass)
    case "multi_pass.publish":
      guard !multiPass.busy, let plan = multiPass.plan else { throw CommandFailure.invalid("Compare passes first") }
      let exportDV = command.arguments["exportDV"] == "true"
      guard !exportDV || plan.pending == 0 else {
        throw CommandFailure.invalid("Review every eligible choice before exporting DV")
      }
      let parent = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: parent.path) else {
        throw CommandFailure.invalid("Destination is inaccessible to the app")
      }
      multiPass.publish(parent: parent, exportDV: exportDV)
      return multiPassState(multiPass)
    case "multi_pass.cancel": multiPass.cancel(); return multiPassState(multiPass)
    case "driver.refresh":
      guard !RewindDVRuntimeOptions.hardwareDisabled, !model.navigationLocked,
            !live.active, !live.busy else { throw CommandFailure.invalid("Driver refresh unavailable") }
      model.refreshDriver(); return ["accepted": true, "status": model.refreshFeedback]
    case "driver.activate":
      guard !RewindDVRuntimeOptions.hardwareDisabled, !model.navigationLocked,
            !live.active, !live.busy, !installer.isInFlight else {
        throw CommandFailure.invalid("Driver activation request is unavailable")
      }
      requestActivation()
      return ["submitted": true, "approval": "Confirm activation in the RewindDV app and macOS"]
    case "deck.inspect":
      _ = try readyForDeck(model, live, wholeTape, installer)
      model.inspectDevice(); return ["submitted": true]
    case "deck.capabilities":
      _ = try readyForDeck(model, live, wholeTape, installer)
      model.probeCapabilities(); return ["submitted": true]
    case "deck.select":
      guard !model.navigationLocked, !live.active, !live.busy,
            let guid = UInt64(try required("guid", from: command)),
            model.driverSnapshot?.decks.contains(where: { $0.guid == guid && $0.isOperational }) == true else {
        throw CommandFailure.invalid("Unknown or unavailable deck GUID")
      }
      model.selectedDeckID = guid; return ["selectedDeckGUID": String(guid)]
    case "deck.command":
      let (deck, route) = try readyForDeck(model, live, wholeTape, installer, transportAction: true)
      let value = try required("action", from: command)
      let actions: [String: DeckCommand] = ["play": .play, "stop": .stop,
                                           "rewind": .rewind, "fast_forward": .fastForward,
                                           "shuttle_forward": .shuttleForward,
                                           "shuttle_reverse": .shuttleReverse]
      guard let action = actions[value],
            WorkspaceCapabilities(source: .deck, fileReady: false, filePlaying: false,
              deckSelected: true, busy: false, lockedOut: false,
              requiresSupervisedStop: model.requiresSupervisedStop, fastForwardSupported: model.fastForwardAvailable,
              liveMonitoring: live.active, ingestActive: live.ingestRequested,
              shuttleForwardSupported: model.capabilityReport?.permits(.shuttleForward, on: route) == true,
              shuttleReverseSupported: model.capabilityReport?.permits(.shuttleReverse, on: route) == true)
              .allows(action.monitorAction) else {
        throw CommandFailure.invalid("Deck action not permitted by current capability or operation state")
      }
      model.monitorSource = .deck
      switch action {
      case .play:
        guard !live.busy, !live.ingestRequested else { throw CommandFailure.invalid("PLAY unavailable during ingest") }
        if live.active {
          model.send(.play, duringLiveMonitoring: true,
            onAccepted: { live.observeCaptureTransportPlaying(bridge: model.bridge, deck: deck, route: route) })
        } else {
          model.send(.play, onAccepted: {
            live.start(bridge: model.bridge, deck: deck, expectedRoute: route)
            live.observeCaptureTransportPlaying(bridge: model.bridge, deck: deck, route: route)
          })
        }
      case .stop:
        guard !live.awaitingTapeStop else { throw CommandFailure.invalid("Tape STOP is already pending") }
        live.cancelPendingIngestPlay()
        model.send(.stop, beforeSubmission: { await live.prepareForOperatorStop() },
          onAccepted: {
            live.stopAfterTapeResponse(bridge: model.bridge, deck: deck, route: route) {
              model.wholeTapeStopObserved()
            }
          })
      default: model.send(action, duringLiveMonitoring: live.active)
      }
      return ["submitted": true, "action": value]
    case "capture.start":
      let (deck, route) = try readyForDeck(model, live, wholeTape, installer)
      guard !live.active else { throw CommandFailure.invalid("Receive is already active") }
      let destination = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: destination.path) else {
        throw CommandFailure.invalid("Destination is unwritable by the app. Choose it in the GUI once to grant sandbox access.")
      }
      model.monitorSource = .deck
      model.startIngest(live: live, deck: deck, route: route, destination: destination)
      return ["accepted": true, "route": String(route.guid), "status": live.ingestDetail]
    case "capture.whole_tape":
      _ = try readyForDeck(model, live, wholeTape, installer)
      let destination = try fileURL("destination", from: command)
      guard FileManager.default.isWritableFile(atPath: destination.path) else {
        throw CommandFailure.invalid("Destination is unwritable by the app. Choose it in the GUI once to grant sandbox access.")
      }
      model.monitorSource = .deck
      wholeTape.start(model: model, live: live, destination: destination)
      return ["accepted": true, "status": wholeTape.status]
    case "capture.stop":
      if wholeTape.active {
        guard wholeTape.canRequestStop else { throw CommandFailure.invalid("Automated capture is finalizing") }
        wholeTape.requestStop(); return ["accepted": true, "status": wholeTape.status]
      }
      guard let deck = model.selectedDeck, let route = model.selectedRoute,
            live.active || live.busy, !live.awaitingTapeStop else {
        throw CommandFailure.invalid("No active capture can be stopped")
      }
      live.cancelPendingIngestPlay()
      model.send(.stop, beforeSubmission: { await live.prepareForOperatorStop() },
        onAccepted: {
          live.stopAfterTapeResponse(bridge: model.bridge, deck: deck, route: route) {
            model.wholeTapeStopObserved()
          }
        })
      return ["accepted": true, "status": live.detail]
    default: throw CommandFailure.invalid("Unknown command: \(command.name)")
    }
  }

  private static func playbackState(_ model: OfflineDVPlaybackModel) -> [String: Any] {
    ["state": String(describing: model.state), "source": model.sourceURL?.path ?? NSNull(),
     "seconds": model.currentTimeSeconds, "durationSeconds": model.durationSeconds,
     "durationIsEstimated": model.frameCounterIsEstimated,
     "estimatedFrame": model.currentFrameOrdinal, "sourceTimecode": model.sourceTimecodeText ?? NSNull(),
     "isIndexing": model.isIndexing, "audit": model.sourceFileAuditStatus,
     "metadataStatus": model.metadata.presentationStatus,
     "video": model.videoDescription, "audio": model.audioDescription]
  }

  private static func archiveState(_ model: RewindDVModel) -> [String: Any] {
    ["busy": model.isBusy, "error": model.analysisError ?? NSNull(),
     "archiveSource": model.archiveSource?.path ?? NSNull(),
     "archive": model.archiveVerification.map {
       ["lifecycle": $0.lifecycle.rawValue, "byteIntegrity": $0.byteIntegrity.rawValue,
        "acquisitionOutcome": $0.acquisitionOutcome.rawValue,
        "acknowledgedExtents": $0.acknowledgedExtentCount,
        "acknowledgedBytes": $0.acknowledgedByteCount, "orphanBytes": $0.orphanByteCount,
        "transportSHA256": $0.transportSHA256] as [String: Any]
     } ?? NSNull(),
     "metadataSource": model.metadataSource?.path ?? NSNull(),
     "metadata": model.metadata.map {
       ["sourceBytes": $0.sourceByteCount, "sourceSHA256": $0.sourceSHA256,
        "completeFrames": $0.completeFrameCount,
        "audioEpochCount": $0.audioSampleRateEpochs.count,
        "unclassifiedExtentCount": $0.unclassifiedExtents.count] as [String: Any]
     } ?? NSNull()]
  }

  private static func surgeryState(_ model: SurgeryModel) -> [String: Any] {
    ["source": model.sourceURL?.path ?? NSNull(), "busy": model.busy,
     "progress": model.progress, "status": model.status, "error": model.error ?? NSNull(),
     "first": model.first, "end": model.end,
     "segmentCount": model.clip?.segments.count ?? 0,
     "selectedSegmentIDs": model.selectedSegments.sorted(),
     "segments": model.clip?.segments.map { ["id": $0.id, "first": $0.first, "end": $0.end] } ?? [],
     "exportedURL": model.exportedURL?.path ?? NSNull()]
  }

  private static func mapState(_ model: TapeEvidenceMapModel) -> [String: Any] {
    ["busy": model.busy, "directory": model.directory?.path ?? NSNull(),
     "message": model.message, "sourceMessage": model.sourceMessage,
     "reportMessage": model.reportMessage, "reportDirectory": model.reportDirectory?.path ?? NSNull(),
     "sceneMessage": model.sceneMessage, "sceneDirectory": model.sceneDirectory?.path ?? NSNull(),
     "selectedFrame": model.selection?.frameOrdinal ?? NSNull(),
     "selectedFrameSHA256": model.selection?.frameSHA256 ?? NSNull(),
     "pageNumber": model.page?.pageNumber ?? NSNull(),
     "frameCount": model.receipt?.frameLedgerRecordCount ?? NSNull(),
     "reviewDirectory": model.reviewDirectory?.path ?? NSNull(),
     "reviewMessage": model.reviewMessage, "reviewRevision": model.reviewRevision,
     "reviewItemCount": model.reviewItemCount, "reviewPageNumber": model.reviewPageNumber,
     "reviewItems": model.reviewEvents.map {
       ["id": $0.item.id, "first": $0.item.firstFrameOrdinal,
        "end": $0.item.endFrameOrdinalExclusive, "state": $0.state.rawValue,
        "summary": $0.item.summary, "note": $0.operatorNote ?? NSNull()] as [String: Any]
     },
     "sceneBoundaries": model.scenePlan?.boundaries.map {
       ["frame": $0.frame, "decision": $0.decision.rawValue, "note": $0.note] as [String: Any]
     } ?? []]
  }

  private static func multiPassState(_ model: MultiPassModel) -> [String: Any] {
    ["busy": model.busy, "message": model.message,
     "passes": model.bindings.count, "progress": model.progress ?? NSNull(),
     "pending": model.plan?.pending ?? NSNull(),
     "output": model.output?.path ?? NSNull(),
     "reviews": model.plan?.reviews.map {
       ["frame": $0.baseFrame, "choice": $0.choice ?? NSNull(), "note": $0.note] as [String: Any]
     } ?? [],
     "candidates": model.plan?.candidates.map {
       ["id": $0.id, "baseFrame": $0.baseFrame, "donorPass": $0.donorPass,
        "donorFrame": $0.donorFrame, "eligible": $0.eligible] as [String: Any]
     } ?? []]
  }

  private static func forensicPrefixState(_ model: ForensicPrefixModel) -> [String: Any] {
    ["busy": model.busy, "message": model.message, "fraction": model.fraction,
     "output": model.output?.path ?? NSNull()]
  }

  private static func recoveryState(_ model: GentleRecoveryModel) -> [String: Any] {
    ["busy": model.busy, "message": model.message,
     "directory": model.journal?.directory.path ?? NSNull(),
     "tape": model.snapshot?.plan.tapeLabel ?? NSNull(),
     "chargedSeconds": model.snapshot?.chargedSeconds ?? NSNull(),
     "unresolved": model.snapshot?.unresolved != nil,
     "targets": model.snapshot?.plan.targets.map {
       ["id": $0.id, "first": $0.first, "end": $0.endExclusive,
        "reason": $0.reason] as [String: Any]
     } ?? [],
     "attempts": model.snapshot?.attempts.map {
       ["id": $0.id.uuidString, "target": $0.target, "phase": $0.phase.rawValue,
        "chargedSeconds": $0.chargedSeconds] as [String: Any]
     } ?? []]
  }
}

private final class RewindDVLocalCommandServer: @unchecked Sendable {
  typealias Handler = @MainActor @Sendable (RewindDVCommand) throws -> [String: Any]
  private let queue = DispatchQueue(label: "net.rewinddigital.RewindDV.commands")
  private let clientQueue = DispatchQueue(label: "net.rewinddigital.RewindDV.command-clients",
                                          attributes: .concurrent)
  private var clients: Set<Int32> = []
  private var source: DispatchSourceRead?
  private var descriptor: Int32 = -1
  private var path: String?
  private var handler: Handler?

  static var socketPath: String {
    var buffer = [CChar](repeating: 0, count: 1024)
    _ = confstr(Int32(_CS_DARWIN_USER_TEMP_DIR), &buffer, buffer.count)
    return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                  as: UTF8.self) + "rewinddv-\(getuid()).sock"
  }

  func start(handler: @escaping Handler) throws {
    guard descriptor == -1 else { return }
    let location = Self.socketPath
    var address = sockaddr_un()
    guard location.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw CommandFailure.invalid("Command socket path is too long")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var ownsDescriptor = true
    defer { if ownsDescriptor { Darwin.close(fd) } }
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = location.withCString { pointer in
      withUnsafeMutablePointer(to: &address.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
          strcpy($0, pointer)
        }
      }
    }
    address.sun_family = sa_family_t(AF_UNIX)
    var previous = stat()
    if lstat(location, &previous) == 0 {
      // Never steal a running server or replace an unrelated filesystem node.
      guard previous.st_uid == getuid(), previous.st_mode & S_IFMT == S_IFSOCK else {
        throw CommandFailure.invalid("Command socket path is occupied")
      }
      let probe = socket(AF_UNIX, SOCK_STREAM, 0)
      if probe >= 0 {
        let active = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        } == 0
        Darwin.close(probe)
        guard !active else { throw CommandFailure.invalid("Another RewindDV command server is running") }
      }
      unlink(location)
    }
    descriptor = fd; path = location; self.handler = handler
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(location, 0o600) == 0, listen(fd, 8) == 0 else {
      let failure = errno
      if bound == 0 { unlink(location) }
      descriptor = -1; path = nil; self.handler = nil
      throw POSIXError(.init(rawValue: failure) ?? .EIO)
    }
    let dispatch = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    dispatch.setEventHandler { [weak self] in self?.acceptReady() }
    dispatch.setCancelHandler { Darwin.close(fd) }
    source = dispatch; ownsDescriptor = false; dispatch.resume()
  }

  func stop() {
    let activeSource = source
    source = nil
    queue.sync {
      // Serialize teardown with acceptReady, which reads these two fields.
      if let activeSource { activeSource.cancel() }
      else if descriptor >= 0 { Darwin.close(descriptor) }
      descriptor = -1
      handler = nil
      for client in clients { shutdown(client, SHUT_RDWR) }
    }
    if let path { unlink(path) }
    path = nil
  }

  private func acceptReady() {
    guard descriptor >= 0 else { return }
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    // Commands are same-user only, regardless of filesystem mode or name.
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
      Darwin.close(client); return
    }
    guard clients.count < 8, let handler else { Darwin.close(client); return }
    clients.insert(client)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    clientQueue.async { self.readRequest(from: client, handler: handler) }
  }

  private func readRequest(from client: Int32, handler: @escaping Handler) {
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while received.count < 65_536 {
      let count = recv(client, &chunk, chunk.count, 0)
      if count <= 0 { break }
      received.append(contentsOf: chunk.prefix(count))
      if received.last == 10 { break }
    }
    guard received.count <= 65_536, received.last == 10,
          let command = try? JSONDecoder().decode(RewindDVCommand.self, from: received) else {
      let data = try? JSONSerialization.data(withJSONObject:
        ["ok": false, "error": "Invalid or oversized command"])
      finish(data: data, client: client)
      return
    }
    Task { @MainActor in
      guard self.queue.sync(execute: { self.descriptor >= 0 && self.clients.contains(client) }) else {
        self.finish(data: nil, client: client)
        return
      }
      let response: [String: Any]
      do { response = ["ok": true, "result": try handler(command)] }
      catch { response = ["ok": false, "error": error.localizedDescription] }
      let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
      self.finish(data: data, client: client)
    }
  }

  private func finish(data: Data?, client: Int32) {
    clientQueue.async {
      if let data { self.writeResponse(data, to: client) }
      self.queue.async {
        self.clients.remove(client)
        Darwin.close(client)
      }
    }
  }

  private func writeResponse(_ data: Data, to client: Int32) {
    let bytes = [UInt8](data) + [10]
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        let count = send(client, base.advanced(by: offset), raw.count - offset, 0)
        if count <= 0 { return }
        offset += count
      }
    }
  }
}

private extension DeckCommand {
  var monitorAction: MonitorAction {
    switch self {
    case .play: .play
    case .stop: .stop
    case .rewind: .rewind
    case .fastForward: .fastForward
    case .shuttleForward: .shuttleForward
    case .shuttleReverse: .shuttleReverse
    }
  }
}
