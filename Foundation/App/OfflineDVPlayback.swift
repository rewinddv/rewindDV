import AVFoundation
import AppKit
import AudioToolbox
import Combine
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import OSLog

#if canImport(RewindDVMonitorCore)
  import RewindDVMonitorCore
#endif

enum OfflineDVPlaybackState: Equatable {
  case idle
  case loading
  case paused
  case playing
  case ended
  case failed(String)

  var title: String {
    switch self {
    case .idle: "Choose a raw DV file"
    case .loading: "Loading raw DV"
    case .paused: "Paused"
    case .playing: "Playing offline DV"
    case .ended: "Playback complete"
    case .failed: "Unable to play this file"
    }
  }

  var detail: String? {
    guard case .failed(let message) = self else { return nil }
    return message
  }
}

struct OfflineDVDecodedAudioFormat: Equatable, Sendable {
  let sampleRate: Double
  let channelCount: Int
}

enum OfflineDVSourceAudioStatus: Equatable, Sendable {
  case unverified
  case perFrame
  case verifying
  case verified(sampleRate: Int, frameCount: UInt64)
  case conflicting
  case unavailable(String)
}

@MainActor
final class OfflineDVPlaybackPresentation: ObservableObject {
  // Only clock/meter views observe this. Never invalidate the entire workspace
  // or reconfigure its video layer for every presented frame.
  @Published private var revision = 0
}

@MainActor
final class OfflineDVPlaybackModel: ObservableObject {
  let presentation = OfflineDVPlaybackPresentation()
  // Session-owned, not view-owned: navigating away or closing a file must not
  // re-arm the automatic picker. Cancel consumes the one-time invitation too.
  private var initialFilePickerConsumed = false

  func consumeInitialFilePickerRequest() -> Bool {
    guard !initialFilePickerConsumed else { return false }
    initialFilePickerConsumed = true
    return !hasLoadedFile && !isLoading
  }

  @Published private(set) var state: OfflineDVPlaybackState = .idle
  @Published private(set) var sourceURL: URL?
  var recordedClock: DVTechnicalSpecifications.Row? { metadata.recordedClock }
  var recordedClockFrameOrdinal: UInt64? { metadata.recordedClockFrameOrdinal }
  @Published private(set) var sourceFileAudit: DVSourceFileAudit?
  @Published private(set) var sourceFileAuditStatus = "No file selected"
  private var sourceFileAuditTask: Task<Void, Never>?
  @Published private(set) var technicalSpecifications: DVTechnicalSpecifications?
  @Published private(set) var appleGeometry: DVAppleGeometry?
  private(set) var appleGeometryFrameOrdinal: UInt64?
  @Published private(set) var technicalSpecificationsStatus = "No file selected"
  private var technicalSpecificationsTask: Task<Void, Never>?
  // Index progress belongs to the timeline subtree, not the whole workspace.
  private(set) var durationSeconds = 0.0
  private(set) var currentTimeSeconds = 0.0
  private(set) var currentFrameOrdinal = 0
  @Published private(set) var frameCounterIsEstimated = true
  private(set) var sourceTimecodeText: String?
  @Published private(set) var viewingMode: DVViewingMode = .standard
  @Published private(set) var extremeZebras = false
  @Published private(set) var zoom: CGFloat = 1
  @Published private(set) var displayAspect: DVDisplayAspect = .standard
  @Published private(set) var zoomCenter = CGPoint(x: 0.5, y: 0.5)
  let navigatorLayer = AVSampleBufferDisplayLayer()

  func setDisplayAspect(_ aspect: DVDisplayAspect) {
    guard aspect != displayAspect else { return }
    displayAspect = aspect
    // Layer geometry only: no decode, seek, queue flush or clock/audio restart.
  }

  func setZoom(_ value: CGFloat) {
    guard [1, 2, 4, 8].contains(value), value != zoom else { return }
    zoom = value
    setZoomCenter(zoomCenter)
    // Geometry only. The navigator already shares the timed picture, including
    // the held paused frame. Never seek, flush audio, or restart the clock here.
  }

  func setZoomCenter(_ point: CGPoint) {
    let edge = 0.5 / zoom
    zoomCenter = CGPoint(x: min(1-edge, max(edge, point.x)),
      y: min(1-edge, max(edge, point.y)))
  }

  func setExtremeZebras(_ enabled: Bool) {
    guard extremeZebras != enabled else { return }
    extremeZebras = enabled
    refreshPausedPicture()
  }

  func setViewingMode(_ mode: DVViewingMode) {
    guard mode != viewingMode else { return }
    viewingMode = mode
    refreshPausedPicture()
  }

  private func refreshPausedPicture() {
    // A playing pump samples the latest controls per frame, with no task queue
    // of obsolete settings. Only a stationary picture needs to be read again.
    if inspection != nil, state != .playing {
      startRenderSession(at: currentTimeSeconds, autoplay: false)
    }
  }
  @Published private(set) var decodedAudioFormat: OfflineDVDecodedAudioFormat?
  @Published private(set) var decodedAudioHasConflict = false
  @Published private(set) var sourceAudioStatus: OfflineDVSourceAudioStatus = .unverified
  private(set) var meterPresentation = OfflineDVMonitorMeter.Presentation.silence
  private(set) var latestEnqueuedVideoTimeSeconds: Double?
  private(set) var latestIngestedPCMEndTimeSeconds: Double?
  @Published private(set) var videoDescription = "No file selected"
  @Published private(set) var audioDescription = "No decoded PCM"

  let displayLayer = AVSampleBufferDisplayLayer()

  var hasLoadedFile: Bool { inspection != nil }
  var sourceTimeline: DVPlaybackTimeline? { inspection?.timeline }
  var isLoading: Bool { state == .loading }
  var canPlay: Bool {
    switch state {
    case .paused, .ended: true
    default: false
    }
  }
  var canPause: Bool { state == .playing }
  var displayAspectRatio: CGFloat { CGFloat(displayAspect.ratio) }
  var rasterHeight: Int { inspection?.timeline.frame(currentFrameOrdinal).isPAL == true ? 576 : 480 }
  var frameCounterDescription: String {
    "\(frameCounterIsEstimated ? "Estimated frame" : "Source frame") \(currentFrameOrdinal)"
  }

  var sourceAudioDescription: String {
    switch sourceAudioStatus {
    case .unverified: "Source audio unverified — playback muted"
    case .perFrame: "Audio checked per source frame; unavailable audio leaves a timed gap"
    case .verifying: "Verifying every raw DV frame — playback muted"
    case .verified(let sampleRate, let frameCount):
      "Raw DV verified at \(Self.rateText(Double(sampleRate))) across \(frameCount.formatted()) frames"
    case .conflicting: "Raw DV contains mixed or conflicting audio rates — playback muted"
    case .unavailable(let reason): "Source audio unavailable — playback muted (\(reason))"
    }
  }

  private let videoRenderer: AVSampleBufferVideoRenderer
  private let audioRenderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private var inspection: AssetInspection?
  private var sessionID = UUID()
  private(set) var renderGeneration: UInt64 = 0
  // Read-only, non-published diagnostics for presentation regression checks.
  private(set) var lastQueuedViewingMode: DVViewingMode = .standard
  private(set) var lastQueuedExtremeZebras = false
  private var activeLease: SecurityScopedURLLease?
  private var loadTask: Task<Void, Never>?
  private var indexTask: Task<Void, Never>?
  private var indexProgressTask: Task<Void, Never>?
  @Published private(set) var isIndexing = false
  private var verificationTask: Task<Void, Never>?
  private var playbackTask: Task<Void, Never>?
  private var clockTask: Task<Void, Never>?
  private var playbackPumpIsActive = false
  private var scrubFrameInFlight = false
  private var pendingScrubTime: Double?
  private var interactiveScrubbing = false
  // DV is intra-frame. Retain its native decoder across seeks instead of
  // paying VideoToolbox session creation for every scrubbed frame. Replaced
  // at a file-session boundary; stale readers retain only their old decoder.
  private var frameDecoder = LiveDVFrameDecoder()
  private var meter = OfflineDVMonitorMeter.State()
  let metadata = PlaybackDVMetadata()
  private var metadataWindow: [(time: Double, ordinal: UInt64, bytes: Data, pixelBuffer: CVPixelBuffer, clock: DVTechnicalSpecifications.Row?)] = []
  private var sourceTimecodeWindow: [TimedSourceTimecode] = []
  private var requestedFrameOrdinal = 0
  private var presentationClockRunning = false

  init(muteAudio: Bool = false) {
    videoRenderer = displayLayer.sampleBufferRenderer
    synchronizer.addRenderer(videoRenderer)
    synchronizer.addRenderer(navigatorLayer.sampleBufferRenderer)
    synchronizer.addRenderer(audioRenderer)
    synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    audioRenderer.isMuted = muteAudio
  }

  deinit {
    loadTask?.cancel()
    indexTask?.cancel()
    indexProgressTask?.cancel()
    verificationTask?.cancel()
    playbackTask?.cancel()
    clockTask?.cancel()
  }

  func open(url: URL) {
    zoom = 1
    displayAspect = .standard
    zoomCenter = CGPoint(x: 0.5, y: 0.5)
    initialFilePickerConsumed = true // Includes drag/drop and completed captures.
    beginNewSession(removeDisplayedImage: true)
    let id = sessionID
    let lease = SecurityScopedURLLease(url: url)
    activeLease = lease
    sourceURL = url
    sourceAudioStatus = .perFrame
    videoDescription = "Inspecting \(url.lastPathComponent)"
    audioDescription = "Awaiting decoded PCM — muted"
    state = .loading
    technicalSpecificationsStatus = "Reading source technical specifications…"
    technicalSpecificationsTask = Task { [weak self, lease] in
      let read = Task.detached(priority: .utility) { [weak self] in
        _ = lease
        try Task.checkCancellation()
        return try DVTechnicalSpecifications.read(url: url, searchRecordedClock: false) { [weak self] initial in
          Task { @MainActor [weak self] in
            guard let self, self.sessionID == id, self.technicalSpecifications == nil else { return }
            self.technicalSpecifications = initial
            self.technicalSpecificationsStatus = "Source specifications loaded"
          }
        }
      }
      do {
        let specs = try await withTaskCancellationHandler {
          try await read.value
        } onCancel: { read.cancel() }
        guard let self, self.sessionID == id, !Task.isCancelled else { return }
        self.technicalSpecifications = specs
        self.technicalSpecificationsStatus = "Source technical specifications"
      } catch {
        guard let self, self.sessionID == id, !Task.isCancelled else { return }
        self.technicalSpecificationsStatus = "Technical specifications unavailable: \(error.localizedDescription)"
      }
    }

    sourceFileAuditStatus = "Not assessed — choose Assess whole file"

    loadTask = Task { [weak self, lease] in
      _ = lease
      do {
        let loaded = try await AssetInspection.load(url: url)
        try Task.checkCancellation()
        guard let self, self.sessionID == id else { return }
        self.inspection = loaded
        self.frameCounterIsEstimated = loaded.timeline.isPreviewEstimate
        self.appleGeometry = loaded.appleGeometry
        self.displayAspect = .initial(reportedRatio: Double(loaded.displayAspectRatio))
        self.durationSeconds = loaded.durationSeconds
        self.videoDescription = loaded.videoDescription
        self.decodedAudioFormat = loaded.decodedAudioFormat
        self.audioDescription = loaded.decodedAudioDescription
        self.reconcileAudioTruth()
        self.startClock(for: id)
        self.startRenderSession(at: 0, autoplay: false)
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.sessionID == id else { return }
        self.fail(error)
      }
    }
  }

  /// Expensive source forensics is an explicit assessment, never file-open work.
  func assessWholeFile() {
    guard hasLoadedFile, !isIndexing, let url = sourceURL, let lease = activeLease,
      sourceFileAuditTask == nil else { return }
    let id = sessionID
    sourceFileAuditStatus = "Assessing source audio counts and error flags…"
    sourceFileAuditTask = Task { [weak self, lease] in
      let scan = Task.detached(priority: .utility) { _ = lease; return try DVSourceFileAudit.read(url: url) }
      defer { if self?.sessionID == id { self?.sourceFileAuditTask = nil } }
      do {
        let audit = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        guard let self, self.sessionID == id, !Task.isCancelled else { return }
        self.sourceFileAudit = audit
        self.sourceFileAuditStatus = "Whole-file source audit complete"
      } catch {
        guard let self, self.sessionID == id, !Task.isCancelled else { return }
        self.sourceFileAuditStatus = "Unavailable — source audit failed: \(error.localizedDescription)"
      }
    }

  }

  /// Exact mixed-system coordinates are an explicit analysis request. Ordinary
  /// playback reads only the requested source frame, with provisional timing.
  func buildExactTimeline() {
    guard let loaded = inspection, let lease = activeLease, !isIndexing,
      !loaded.timeline.isComplete else { return }
    setScrubbing(false)
    startRenderSession(at: 0, autoplay: false)
    startIndexing(loaded, lease: lease, sessionID: sessionID)
  }

  private func startIndexing(_ loaded: AssetInspection, lease: SecurityScopedURLLease, sessionID id: UUID) {
    let initialTimeline = loaded.timeline
    guard !initialTimeline.isComplete else { return }
    isIndexing = true
    indexProgressTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.sessionID == id else { return }
        let duration = loaded.durationSeconds
        if self.durationSeconds != duration {
          self.durationSeconds = duration
          self.presentation.objectWillChange.send()
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
    indexTask = Task { [weak self, lease] in
      let scan = Task.detached(priority: .utility) {
        _ = lease
        do {
          try initialTimeline.verifyUnchanged(url: loaded.url)
          _ = try DVPlaybackTimeline.read(url: loaded.url,
            inspect: { _, _, _ in try loaded.index.yieldToScrubbing() },
            progress: { loaded.index.update($0) })
          try initialTimeline.verifyUnchanged(url: loaded.url)
        } catch {
          loaded.index.stop(reason: error.localizedDescription)
          throw error
        }
      }
      do {
        try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        try Task.checkCancellation()
        guard let self, self.sessionID == id else { return }
        self.indexProgressTask?.cancel(); self.indexProgressTask = nil
        self.isIndexing = false
        self.frameCounterIsEstimated = false
        self.durationSeconds = loaded.durationSeconds
        self.videoDescription = loaded.videoDescription
        self.presentation.objectWillChange.send()
        self.startRenderSession(at: self.currentTimeSeconds, autoplay: false)
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.sessionID == id else { return }
        self.indexProgressTask?.cancel(); self.indexProgressTask = nil
        self.isIndexing = false
        self.fail(error)
      }
    }
  }

  func play() {
    guard inspection != nil else { return }
    if state == .ended {
      startRenderSession(at: 0, autoplay: true)
    } else if state == .paused {
      startRenderSession(at: currentTimeSeconds, autoplay: true)
    }
  }

  func pause() {
    guard state == .playing else { return }
    updateClockSnapshot()
    // Cancel decode and flush future pictures, rather than letting an async
    // timebase stop race the already queued frames. Re-present one exact frame.
    startRenderSession(at: currentTimeSeconds, autoplay: false)
  }

  /// Stops offline playback and presents the first decoded frame. It never
  /// sends a command to a deck or changes the source file.
  func stop() {
    guard inspection != nil else { return }
    startRenderSession(at: 0, autoplay: false)
  }

  func seek(to seconds: Double) {
    guard inspection != nil, seconds.isFinite else { return }
    let target = clampedTime(seconds)
    if scrubFrameInFlight {
      // Bounded latest-wins queue: never starve decoding by canceling every mouse event.
      pendingScrubTime = target
      return
    }
    startRenderSession(at: target, autoplay: false, scrubbing: true)
  }

  /// Mouse-drag pictures take priority over background I/O and detailed packs.
  /// The final displayed frame gets its full inspector when the gesture ends.
  func setScrubbing(_ active: Bool) {
    guard interactiveScrubbing != active else { return }
    interactiveScrubbing = active
    inspection?.index.setScrubbing(active)
    if active { metadata.reset() }
    if !active { samplePausedMetadata() }
  }

  func stepFrames(_ delta: Int) {
    guard let inspection, delta != 0 else { return }
    if state == .playing { updateClockSnapshot() }
    let base = state == .playing ? currentFrameOrdinal : requestedFrameOrdinal
    let frame = min(max(0, base + delta), inspection.estimatedFrameCount - 1)
    startRenderSession(at: inspection.timeline.frame(frame).seconds, autoplay: false)
  }

  /// Freezes the offline renderer without releasing the selected file. This is
  /// suitable for a workspace-tab switch; `close()` owns scope release.
  func suspendPresentation() {
    if state == .playing { pause() }
  }

  func close() {
    defer { presentation.objectWillChange.send() }
    beginNewSession(removeDisplayedImage: true)
    sourceURL = nil
    inspection = nil
    activeLease = nil
    durationSeconds = 0
    currentTimeSeconds = 0
    currentFrameOrdinal = 0
    frameCounterIsEstimated = true
    sourceTimecodeText = nil
    decodedAudioFormat = nil
    decodedAudioHasConflict = false
    sourceAudioStatus = .unverified
    videoDescription = "No file selected"
    audioDescription = "No decoded PCM"
    state = .idle
  }

  private func beginNewSession(removeDisplayedImage: Bool) {
    inspection?.index.setScrubbing(false)
    interactiveScrubbing = false
    sessionID = UUID()
    metadata.clearRecordedClock()
    sourceFileAuditTask?.cancel(); sourceFileAuditTask = nil
    sourceFileAudit = nil; sourceFileAuditStatus = "No file selected"
    technicalSpecificationsTask?.cancel()
    technicalSpecificationsTask = nil
    technicalSpecifications = nil
    appleGeometry = nil
    appleGeometryFrameOrdinal = nil
    technicalSpecificationsStatus = "No file selected"
    frameDecoder = LiveDVFrameDecoder()
    renderGeneration &+= 1
    loadTask?.cancel()
    indexTask?.cancel(); indexTask = nil
    indexProgressTask?.cancel(); indexProgressTask = nil
    isIndexing = false
    verificationTask?.cancel()
    playbackTask?.cancel()
    clockTask?.cancel()
    loadTask = nil
    verificationTask = nil
    playbackTask = nil
    clockTask = nil
    playbackPumpIsActive = false
    scrubFrameInFlight = false
    pendingScrubTime = nil
    presentationClockRunning = false
    synchronizer.rate = 0
    videoRenderer.flush(removingDisplayedImage: removeDisplayedImage, completionHandler: nil)
    navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: removeDisplayedImage, completionHandler: nil)
    audioRenderer.flush()
    meter.reset()
    meterPresentation = .silence
    latestEnqueuedVideoTimeSeconds = nil
    latestIngestedPCMEndTimeSeconds = nil
    sourceTimecodeWindow.removeAll(keepingCapacity: true)
    metadataWindow.removeAll(keepingCapacity: true)
    metadata.reset()
    sourceTimecodeText = nil
    decodedAudioHasConflict = false
    inspection = nil
    activeLease = nil
  }

  private func startClock(for id: UUID) {
    clockTask?.cancel()
    clockTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.sessionID == id, self.inspection != nil else { return }
        self.updateClockSnapshot()
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
  }

  private func updateClockSnapshot() {
    // A stopped synchronizer applies time changes asynchronously. Never allow
    // an old clock observation to overwrite the pending seek/frame selection.
    guard let inspection else { return }
    if state != .playing {
      samplePausedMetadata()
      return
    }
    guard presentationClockRunning else { return }
    let absolute = CMTimeGetSeconds(synchronizer.currentTime())
    guard absolute.isFinite else { return }
    let relative = clampedTime(absolute - inspection.timelineStartSeconds)
    currentTimeSeconds = relative
    currentFrameOrdinal = inspection.timeline.frame(at: relative).ordinal
    updateSourceTimecode(at: relative, frameDuration: effectiveFrameDuration(inspection))
    sampleMetadata(at: relative, frameDuration: effectiveFrameDuration(inspection), paused: false)
    meterPresentation = meter.presentation(at: relative)
    presentation.objectWillChange.send()
  }

  private func startRenderSession(at seconds: Double, autoplay: Bool, scrubbing: Bool = false) {
    guard let inspection else { return }
    defer { presentation.objectWillChange.send() }
    scrubFrameInFlight = scrubbing
    pendingScrubTime = nil
    let id = sessionID
    // A reader range beginning exactly at the exclusive duration has no frame.
    // Clamp transport requests to the last source-frame interval instead.
    let selected = inspection.timeline.frame(at: clampedTime(seconds))
    let targetFrame = selected.ordinal
    let relativeStart = selected.seconds
    requestedFrameOrdinal = targetFrame
    renderGeneration &+= 1
    let generation = renderGeneration
    playbackTask?.cancel()
    playbackTask = nil
    playbackPumpIsActive = false
    presentationClockRunning = false
    synchronizer.rate = 0
    audioRenderer.flush()
    synchronizer.setRate(0, time: absoluteTime(for: relativeStart, inspection: inspection))
    meter.seek(to: relativeStart)
    meterPresentation = .silence
    latestEnqueuedVideoTimeSeconds = nil
    latestIngestedPCMEndTimeSeconds = nil
    sourceTimecodeWindow.removeAll(keepingCapacity: true)
    metadataWindow.removeAll(keepingCapacity: true)
    if !interactiveScrubbing || metadata.report != nil { metadata.reset() }
    currentTimeSeconds = relativeStart
    currentFrameOrdinal = targetFrame
    // The renderer retains its last picture through flush. Retain that picture's
    // source timecode too, until a decoded replacement (including missing TC) arrives.
    let nextState: OfflineDVPlaybackState = autoplay ? .playing : .paused
    if state != nextState { state = nextState }
    let includeAudibleAudio = audioMayPlay

    playbackTask = Task(priority: .userInitiated) { [weak self] in
      guard let self, self.sessionID == id, self.renderGeneration == generation else { return }
      self.playbackPumpIsActive = true
      defer {
        if self.sessionID == id, self.renderGeneration == generation {
          self.playbackPumpIsActive = false
          self.scrubFrameInFlight = false
          if let next = self.pendingScrubTime {
            self.pendingScrubTime = nil
            self.startRenderSession(at: next, autoplay: false, scrubbing: true)
          }
        }
      }
      do {
        // Await the renderer's flush boundary before publishing a new generation.
        await withCheckedContinuation { continuation in
          // Both views share the same generation. Flush them concurrently;
          // two serialized display boundaries add avoidable latency per seek.
          let completion = RendererFlushCompletion(continuation)
          self.videoRenderer.flush(removingDisplayedImage: false) { completion.finish() }
          self.navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: false) { completion.finish() }
        }
        try Task.checkCancellation()
        guard self.sessionID == id, self.renderGeneration == generation else { return }
        let readers = RenderReaders(inspectionDecoder: self.frameDecoder)
        defer { Task { await readers.cancel() } }
        try await readers.prepare(
          inspection: inspection,
          relativeStart: relativeStart,
          includeAudio: inspection.hasAudio && autoplay)
        try await self.pump(
          readers: readers,
          inspection: inspection,
          relativeStart: relativeStart,
          autoplay: autoplay,
          enqueueAudio: includeAudibleAudio,
          sessionID: id,
          renderGeneration: generation)
      } catch is CancellationError {
        return
      } catch {
        guard self.sessionID == id, self.renderGeneration == generation else { return }
        self.fail(error)
      }
    }
  }

  private func pump(
    readers: RenderReaders,
    inspection: AssetInspection,
    relativeStart: Double,
    autoplay: Bool,
    enqueueAudio: Bool,
    sessionID id: UUID,
    renderGeneration generation: UInt64
  ) async throws {
    var videoDone = false
    var audioDone = !inspection.hasAudio || !autoplay
    var firstVideoQueued = false
    var firstAudioSeen = false
    var pendingAudioSample: CMSampleBuffer?
    var lastQueuedVideoEnd = inspection.timelineStartSeconds + relativeStart
    var clockStarted = false
    // Short bounded picture lead keeps display controls responsive. Audio has
    // its own larger cushion; changing picture policy never flushes that audio.
    let videoHighWaterSeconds = 0.15
    let audioFutureSeconds = OfflineDVMonitorMeter.retainedFutureSeconds

    while !videoDone || !audioDone {
      try Task.checkCancellation()
      guard self.sessionID == id, self.renderGeneration == generation else {
        throw CancellationError()
      }
      if videoRenderer.status == .failed {
        throw videoRenderer.error ?? OfflineDVPlaybackError.rendererFailed
      }
      if audioRenderer.status == .failed {
        throw audioRenderer.error ?? OfflineDVPlaybackError.rendererFailed
      }

      let now =
        clockStarted
        ? CMTimeGetSeconds(synchronizer.currentTime())
        : inspection.timelineStartSeconds + relativeStart
      let videoLead = now.isFinite ? lastQueuedVideoEnd - now : 0
      var progressed = false
      if videoLead < videoHighWaterSeconds, videoRenderer.isReadyForMoreMediaData, !videoDone {
        let mode = viewingMode
        let zebras = extremeZebras
        if let packet = try await readers.nextVideo(viewingMode: mode, extremeZebras: zebras) {
          try Task.checkCancellation()
          guard self.sessionID == id, self.renderGeneration == generation else { return }
          let sample = packet.sample
          recordSourceTimecode(
            text: packet.sourceTimecode,
            decodedSample: sample,
            inspection: inspection,
            sessionID: id,
            renderGeneration: generation)
          videoRenderer.enqueue(sample)
          if let bytes = packet.sourceBytes {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - inspection.timelineStartSeconds
            if time.isFinite, time >= 0 {
              let ordinal = UInt64(inspection.timeline.frame(at: time).ordinal)
              if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                metadataWindow.append((time, ordinal, bytes, pixelBuffer, packet.sourceClock))
              }
              if metadataWindow.count > 32 { metadataWindow.removeFirst(metadataWindow.count - 32) }
            }
          }
          lastQueuedViewingMode = mode
          lastQueuedExtremeZebras = zebras
          // Same immutable sample and presentation clock, without another decode.
          // Navigator backpressure must never stall full-size video or audio.
          // Keep the navigator primed even at 1x, so showing it cannot require
          // another read/decode or a playback restart. Backpressure is bounded.
          if navigatorLayer.sampleBufferRenderer.isReadyForMoreMediaData {
            navigatorLayer.sampleBufferRenderer.enqueue(sample)
          }
          let videoTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
          if videoTime.isFinite {
            latestEnqueuedVideoTimeSeconds = max(0, videoTime - inspection.timelineStartSeconds)
          }
          firstVideoQueued = true
          lastQueuedVideoEnd = max(lastQueuedVideoEnd, Self.sampleEndSeconds(sample))
          progressed = true
        } else {
          videoDone = true
        }
      }

      if !audioDone {
        if pendingAudioSample == nil {
          let audioRead = try await readers.nextAudio()
          switch audioRead {
          case .sample(let sample): pendingAudioSample = sample
          case .gap: firstAudioSeen = true; progressed = true
          case .end: audioDone = true
          }
          try Task.checkCancellation()
          guard self.sessionID == id, self.renderGeneration == generation else { return }
          if pendingAudioSample != nil {
            firstAudioSeen = true
            progressed = true
          }
        }
        if let sample = pendingAudioSample {
          guard
            let timing = Self.boundedAudioTiming(
              sample, maximumDuration: audioFutureSeconds)
          else {
            decodedAudioHasConflict = true
            audioDescription = "Decoded PCM timing exceeded the bounded monitor horizon — muted"
            audioRenderer.flush()
            meter.reset()
            meterPresentation = .silence
            latestIngestedPCMEndTimeSeconds = nil
            pendingAudioSample = nil
            audioDone = true
            progressed = true
            continue
          }
          let fullSampleFitsMeter = timing.end <= now + audioFutureSeconds
          let rendererCanAccept = !enqueueAudio || audioRenderer.isReadyForMoreMediaData
          if fullSampleFitsMeter, rendererCanAccept {
            firstAudioSeen = true
            let sampleMayPlay = ingestMeter(sample, inspection: inspection)
            if enqueueAudio, sampleMayPlay { audioRenderer.enqueue(sample) }
            pendingAudioSample = nil
            progressed = true
          }
        }
      }

      // Prime a short video/audio lead before starting, once per generation.
      // Do not repeatedly set a clock whose timebase update is asynchronous.
      if firstVideoQueued, !clockStarted, state == .playing, autoplay,
        lastQueuedVideoEnd - inspection.timelineStartSeconds - relativeStart >= 0.1 || videoDone,
        !enqueueAudio || firstAudioSeen || audioDone
      {
        synchronizer.setRate(
          1,
          time: absoluteTime(for: relativeStart, inspection: inspection))
        clockStarted = true
        presentationClockRunning = true
      } else if firstVideoQueued, !autoplay {
        synchronizer.setRate(
          0,
          time: absoluteTime(for: relativeStart, inspection: inspection))
        // A paused presentation needs only one decoded video frame. Do not
        // decode the tape into memory while the transport clock is stopped.
        updateSourceTimecode(at: relativeStart, frameDuration: inspection.frameDurationSeconds)
        presentation.objectWillChange.send()
        // Frame-dependent paused actions (such as range review) may now become
        // available. This is one notification per seek, never per playing frame.
        if !interactiveScrubbing { objectWillChange.send() }
        return
      }

      if !progressed {
        try await Task.sleep(for: .milliseconds(5))
      } else {
        await Task.yield()
      }
    }

    guard firstVideoQueued else { throw OfflineDVPlaybackError.noDecodedVideo }
    // Unusable source audio leaves a timed gap; it must not abort good video.
    try await readers.checkCompletion()

    while state == .playing, sessionID == id {
      try Task.checkCancellation()
      let now = CMTimeGetSeconds(synchronizer.currentTime())
      if now.isFinite, now + 0.001 >= lastQueuedVideoEnd { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard sessionID == id, renderGeneration == generation, state == .playing else { return }
    updateClockSnapshot()
    synchronizer.rate = 0
    currentTimeSeconds = durationSeconds
    currentFrameOrdinal = max(0, inspection.estimatedFrameCount - 1)
    updateSourceTimecode(
      at: durationSeconds,
      frameDuration: effectiveFrameDuration(inspection))
    samplePausedMetadata()
    state = .ended
    presentation.objectWillChange.send()
  }

  private func sampleMetadata(at time: Double, frameDuration: Double, paused: Bool) {
    metadataWindow.removeAll { $0.time < time - max(0.1, frameDuration * 2) }
    guard let frame = metadataWindow.last(where: { $0.time <= time + 0.000_001 }),
      time - frame.time < frameDuration + 0.000_001,
      frame.ordinal == UInt64(currentFrameOrdinal) else {
      metadata.clearRecordedClock()
      metadata.unavailable("Unavailable — no source sample near the playback clock")
      return
    }
    // The validated raw timeline binds each source ordinal to its byte offset.
    acceptRecordedClock(frame.clock, ordinal: frame.ordinal, association: "playback-clock-associated source sample; display association unverified")
    acceptGeometry(frame.pixelBuffer, ordinal: frame.ordinal)
    metadata.offer(frame.bytes, ordinal: frame.ordinal,
      byteOffset: inspection?.timeline.frame(Int(frame.ordinal)).byteOffset, geometry: appleGeometry,
      paused: paused, ordinalIsEstimated: frameCounterIsEstimated)
  }

  private func samplePausedMetadata() {
    guard !interactiveScrubbing else { return }
    guard videoRenderer.status != .failed else {
      metadata.unavailable("Unavailable — video renderer failed")
      return
    }
    if let displayed = videoRenderer.displayedPixelBuffer() {
      guard let frame = metadataWindow.last(where: { Self.sameDisplayedStorage($0.pixelBuffer, displayed) }) else {
        metadata.unavailable("Unavailable — displayed frame not associated with source")
        return
      }
      acceptRecordedClock(frame.clock, ordinal: frame.ordinal, association: "renderer-confirmed displayed source frame")
      acceptGeometry(frame.pixelBuffer, ordinal: frame.ordinal)
      metadata.offer(frame.bytes, ordinal: frame.ordinal,
        byteOffset: inspection?.timeline.frame(Int(frame.ordinal)).byteOffset, geometry: appleGeometry,
        paused: true, presentationConfirmed: true, ordinalIsEstimated: frameCounterIsEstimated)
      return
    }
    // copyDisplayedPixelBuffer is optional (also unavailable offscreen). A sole
    // completed paused decode can still identify the selected source frame,
    // but is explicitly not claimed as renderer-confirmed display evidence.
    guard !playbackPumpIsActive, pendingScrubTime == nil,
      (state == .ended || metadataWindow.count == 1), let frame = metadataWindow.last,
      frame.ordinal == UInt64(state == .ended ? currentFrameOrdinal : requestedFrameOrdinal),
      (state == .ended || abs(frame.time - currentTimeSeconds) < 0.000_001),
      latestEnqueuedVideoTimeSeconds == frame.time else {
      metadata.unavailable("Unavailable — paused source selection not yet complete")
      return
    }
    acceptRecordedClock(frame.clock, ordinal: frame.ordinal, association: "selected source frame; renderer association unavailable")
    acceptGeometry(frame.pixelBuffer, ordinal: frame.ordinal)
    metadata.offer(frame.bytes, ordinal: frame.ordinal,
        byteOffset: inspection?.timeline.frame(Int(frame.ordinal)).byteOffset, geometry: appleGeometry,
        paused: true, selectionConfirmed: true, ordinalIsEstimated: frameCounterIsEstimated)
  }

  /// Apple's renderer may return a different CVPixelBuffer wrapper for the
  /// same IOSurface. Compare retained storage identity, never picture likeness
  /// (two visually identical frames can have different recording clocks).
  private static func sameDisplayedStorage(_ source: CVPixelBuffer, _ displayed: CVPixelBuffer) -> Bool {
    if source === displayed { return true }
    guard CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(displayed),
      CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(displayed),
      CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(displayed),
      let a = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
      let b = CVPixelBufferGetIOSurface(displayed)?.takeUnretainedValue() else { return false }
    return IOSurfaceGetID(a) == IOSurfaceGetID(b)
  }

  var pausedMetadataAssociationDiagnostics: String {
    let displayed = videoRenderer.displayedPixelBuffer()
    return "rate=\(synchronizer.rate); candidates=\(metadataWindow.count); displayed=\(displayed != nil); shared_storage=\(displayed.map { d in metadataWindow.contains { Self.sameDisplayedStorage($0.pixelBuffer, d) } } ?? false)"
  }

  private func acceptRecordedClock(_ clock: DVTechnicalSpecifications.Row?, ordinal: UInt64, association: String) {
    guard let clock else { metadata.clearRecordedClock(); return }
    let next = DVTechnicalSpecifications.Row(label: clock.label, value: clock.value,
      evidence: "\(frameCounterIsEstimated ? "Estimated frame" : "Frame") \(ordinal) · " + association + ". " + clock.evidence)
    metadata.setRecordedClock(next, ordinal: ordinal)
  }

  private func acceptGeometry(_ pixel: CVPixelBuffer, ordinal: UInt64) {
    let geometry = DVAppleGeometry.inspect(imageBuffer: pixel)
    appleGeometryFrameOrdinal = ordinal
    if geometry != appleGeometry { appleGeometry = geometry }
  }

  private func recordSourceTimecode(
    text: String?,
    decodedSample: CMSampleBuffer,
    inspection: AssetInspection,
    sessionID id: UUID,
    renderGeneration generation: UInt64
  ) {
    guard sessionID == id, renderGeneration == generation else { return }
    let decodedTime = CMSampleBufferGetPresentationTimeStamp(decodedSample)
    guard decodedTime.isNumeric else { return }
    let decodedSeconds = CMTimeGetSeconds(decodedTime)
    guard decodedSeconds.isFinite else { return }

    let relativeTime = decodedSeconds - inspection.timelineStartSeconds
    guard relativeTime.isFinite, relativeTime >= -0.001,
      relativeTime <= durationSeconds + 0.001
    else { return }
    let record = TimedSourceTimecode(
      presentationTime: max(0, relativeTime),
      text: text)
    if let last = sourceTimecodeWindow.last,
      record.presentationTime + 0.000_001 < last.presentationTime
    {
      // An out-of-order decoder discontinuity invalidates the prior window.
      sourceTimecodeWindow.removeAll(keepingCapacity: true)
    } else if sourceTimecodeWindow.last?.presentationTime == record.presentationTime {
      sourceTimecodeWindow.removeLast()
    }
    sourceTimecodeWindow.append(record)
    if sourceTimecodeWindow.count > 32 {
      sourceTimecodeWindow.removeFirst(sourceTimecodeWindow.count - 32)
    }
    if !presentationClockRunning, sourceTimecodeWindow.count == 1 {
      sourceTimecodeText = record.text
      presentation.objectWillChange.send()
    }
    // Queuing a future picture must not independently advance the displayed
    // timecode. The clock snapshot publishes position, ordinal and TC together.
  }

  private func updateSourceTimecode(at playbackTime: Double, frameDuration: Double) {
    guard playbackTime.isFinite, frameDuration.isFinite, frameDuration > 0 else {
      sourceTimecodeText = nil
      return
    }
    let pastLimit = playbackTime - max(0.1, frameDuration * 2)
    sourceTimecodeWindow.removeAll { $0.presentationTime < pastLimit }
    let epsilon = 0.000_001
    guard
      let record = sourceTimecodeWindow.last(where: {
        $0.presentationTime <= playbackTime + frameDuration * epsilon
      }),
      playbackTime - record.presentationTime <= frameDuration * 1.5 + epsilon
    else {
      sourceTimecodeText = nil
      return
    }
    // A nil record is intentional and clears the preceding frame's display.
    sourceTimecodeText = record.text
  }

  nonisolated fileprivate static func validatedSourceTimecode(from sample: CMSampleBuffer)
    -> String?
  {
    guard CMSampleBufferDataIsReady(sample),
      let block = CMSampleBufferGetDataBuffer(sample)
    else { return nil }
    let byteCount = CMBlockBufferGetDataLength(block)
    guard byteCount == 120_000 || byteCount == 144_000 else { return nil }
    var data = Data(count: byteCount)
    let status = data.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
    }
    guard status == kCMBlockBufferNoErr else { return nil }
    return MonitorSourceTimecode.display(nativeDVFrame: data)
  }

  private func ingestMeter(_ sample: CMSampleBuffer, inspection: AssetInspection) -> Bool {
    let decoded: (format: OfflineDVDecodedAudioFormat, samples: [Int16])
    do {
      decoded = try Self.decodedPCM(from: sample)
    } catch {
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM became unsupported — playback muted"
      audioRenderer.flush()
      return false
    }
    if let existing = decodedAudioFormat, existing != decoded.format {
      decodedAudioFormat = decoded.format
      audioDescription = Self.description(for: decoded.format)
    } else if decodedAudioFormat == nil {
      decodedAudioFormat = decoded.format
      audioDescription = Self.description(for: decoded.format)
      reconcileAudioTruth()
    }
    let start =
      CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
      - inspection.timelineStartSeconds
    guard start.isFinite else {
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM timestamp became invalid — playback muted"
      audioRenderer.flush()
      return false
    }
    let playbackTime = currentPlaybackTime(inspection: inspection)
    let report: OfflineDVMonitorMeter.IngestReport
    do {
      report = try meter.ingestInterleavedPCM16(
        decoded.samples,
        channelCount: decoded.format.channelCount,
        sampleRate: decoded.format.sampleRate,
        startTime: start,
        playbackTime: playbackTime)
    } catch {
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM could not be metered safely — playback muted"
      audioRenderer.flush()
      return false
    }
    if report.discardedPastFrames > 0 || report.discardedFutureFrames > 0 {
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM fell outside the bounded meter horizon — playback muted"
      audioRenderer.flush()
      meter.reset()
      meterPresentation = .silence
      latestIngestedPCMEndTimeSeconds = nil
      return false
    }
    if report.acceptedFrames > 0 {
      latestIngestedPCMEndTimeSeconds =
        start
        + Double(report.discardedPastFrames + report.acceptedFrames) / decoded.format.sampleRate
    }
    return audioMayPlay
  }

  private var audioMayPlay: Bool {
    if sourceAudioStatus == .perFrame { return !decodedAudioHasConflict }
    guard !decodedAudioHasConflict,
      let decodedAudioFormat,
      case .verified(let rate, _) = sourceAudioStatus
    else { return false }
    return abs(decodedAudioFormat.sampleRate - Double(rate)) < 0.5
  }

  private func reconcileAudioTruth() {
    guard let decodedAudioFormat else { return }
    if case .verified(let sourceRate, _) = sourceAudioStatus,
      abs(decodedAudioFormat.sampleRate - Double(sourceRate)) >= 0.5
    {
      decodedAudioHasConflict = true
      audioDescription =
        "Decoded \(Self.rateText(decodedAudioFormat.sampleRate)) conflicts with raw DV \(Self.rateText(Double(sourceRate))) — muted"
      audioRenderer.flush()
    }
  }

  private func currentPlaybackTime(inspection: AssetInspection) -> Double {
    guard presentationClockRunning else { return currentTimeSeconds }
    let absolute = CMTimeGetSeconds(synchronizer.currentTime())
    guard absolute.isFinite else { return currentTimeSeconds }
    return min(durationSeconds, max(0, absolute - inspection.timelineStartSeconds))
  }

  private func absoluteTime(for relative: Double, inspection: AssetInspection) -> CMTime {
    CMTime(
      seconds: inspection.timelineStartSeconds + clampedTime(relative),
      preferredTimescale: 60_000)
  }

  private func clampedTime(_ seconds: Double) -> Double {
    min(durationSeconds, max(0, seconds))
  }

  private func effectiveFrameDuration(_ inspection: AssetInspection) -> Double {
    Double(inspection.timeline.frame(currentFrameOrdinal).durationTicks) / 30_000
  }

  private func fail(_ error: Error) {
    synchronizer.rate = 0
    playbackTask?.cancel()
    playbackPumpIsActive = false
    Logger(subsystem: "net.rewinddigital.RewindDV", category: "Playback").error("Playback failed: \(String(reflecting: error), privacy: .public)")
    state = .failed(error.localizedDescription)
  }

  nonisolated fileprivate static var pcmOutputSettings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  nonisolated fileprivate static func decodedPCM(from sample: CMSampleBuffer) throws
    -> (format: OfflineDVDecodedAudioFormat, samples: [Int16])
  {
    guard let description = CMSampleBufferGetFormatDescription(sample),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
      asbd.mFormatID == kAudioFormatLinearPCM,
      asbd.mBitsPerChannel == 16,
      asbd.mChannelsPerFrame == 1 || asbd.mChannelsPerFrame == 2 || asbd.mChannelsPerFrame == 4,
      asbd.mSampleRate.isFinite,
      asbd.mSampleRate >= 1,
      asbd.mSampleRate <= 768_000,
      asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
      asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
      asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
      let block = CMSampleBufferGetDataBuffer(sample)
    else { throw OfflineDVPlaybackError.unsupportedDecodedAudio }

    let byteCount = CMBlockBufferGetDataLength(block)
    let sampleStride = MemoryLayout<Int16>.size * Int(asbd.mChannelsPerFrame)
    guard byteCount > 0, byteCount <= 1 << 20, byteCount.isMultiple(of: sampleStride) else {
      throw OfflineDVPlaybackError.unsupportedDecodedAudio
    }
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = bytes.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
    }
    guard status == kCMBlockBufferNoErr else {
      throw OfflineDVPlaybackError.unsupportedDecodedAudio
    }
    let samples = bytes.withUnsafeBytes { raw in
      Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
    }
    return (
      OfflineDVDecodedAudioFormat(
        sampleRate: asbd.mSampleRate,
        channelCount: Int(asbd.mChannelsPerFrame)),
      samples
    )
  }

  private static func sampleEndSeconds(_ sample: CMSampleBuffer) -> Double {
    let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
    return start + (duration.isFinite && duration > 0 ? duration : 0)
  }

  private static func boundedAudioTiming(
    _ sample: CMSampleBuffer,
    maximumDuration: Double
  ) -> (start: Double, end: Double)? {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
    let sampleDuration = CMSampleBufferGetDuration(sample)
    guard presentationTime.isNumeric, sampleDuration.isNumeric else { return nil }
    let start = CMTimeGetSeconds(presentationTime)
    let duration = CMTimeGetSeconds(sampleDuration)
    let end = start + duration
    guard start.isFinite, duration.isFinite, duration > 0,
      duration <= maximumDuration, end.isFinite
    else { return nil }
    return (start, end)
  }

  nonisolated private static func rateText(_ rate: Double) -> String {
    "\(Int(rate.rounded()).formatted()) Hz"
  }

  nonisolated fileprivate static func description(for format: OfflineDVDecodedAudioFormat) -> String
  {
    "\(rateText(format.sampleRate)) • \(format.channelCount) channel\(format.channelCount == 1 ? "" : "s") • decoded PCM"
  }
}

private struct TimedSourceTimecode {
  let presentationTime: Double
  let text: String?
}

// Read-only sample ownership is transferred from the reader actor to the main
// actor. Neither side mutates the buffer or its pixel attachments after return.
private struct DecodedPacket: @unchecked Sendable {
  let sample: CMSampleBuffer
  let sourceTimecode: String?
  var sourceBytes: Data? = nil
  var sourceClock: DVTechnicalSpecifications.Row? = nil
}

private enum AudioRead: @unchecked Sendable {
  case sample(CMSampleBuffer)
  case gap
  case end
}

private actor RenderReaders {
  private let inspectionDecoder: LiveDVFrameDecoder
  init(inspectionDecoder: LiveDVFrameDecoder) { self.inspectionDecoder = inspectionDecoder }
  private var inspection: AssetInspection?
  private var videoHandle: FileHandle?
  private var audioHandle: FileHandle?
  private var videoOrdinal = 0
  private var audioOrdinal = 0
  private var nextAudioTime: CMTime?
  private var previousAudioRate: Int?
  private var previousAudioPAL: Bool?

  func prepare(inspection: AssetInspection, relativeStart: Double, includeAudio: Bool) throws {
    try Task.checkCancellation()
    try inspection.timeline.verifyUnchanged(url: inspection.url)
    self.inspection = inspection
    videoOrdinal = inspection.timeline.frame(at: relativeStart).ordinal
    audioOrdinal = videoOrdinal
    videoHandle = try FileHandle(forReadingFrom: inspection.url)
    if includeAudio { audioHandle = try FileHandle(forReadingFrom: inspection.url) }
  }

  func nextVideo(viewingMode: DVViewingMode, extremeZebras: Bool) async throws -> DecodedPacket? {
    try Task.checkCancellation()
    guard let inspection, let videoHandle,
      try await inspection.index.waitForFrame(videoOrdinal) else { return nil }
    let frame = inspection.timeline.frame(videoOrdinal)
    let bytes = try autoreleasepool { try inspection.timeline.readFrame(videoOrdinal, from: videoHandle) }
    videoOrdinal += 1
    let text = MonitorSourceTimecode.display(nativeDVFrame: bytes)
    // The importer may describe only the first system in a raw file. Never
    // attach NTSC geometry/color metadata to a PAL frame (or the reverse).
    let sourceFormat = inspection.sourceFormat.flatMap {
      CMVideoFormatDescriptionGetDimensions($0.value).height == (frame.isPAL ? 576 : 480) ? $0 : nil
    }
    let decoded = try await inspectionDecoder.decode(bytes, ordinal: 0, timecode: text,
      viewingMode: viewingMode, sourceFormat: sourceFormat, extremeZebras: extremeZebras)
    try Task.checkCancellation()
    var format: CMVideoFormatDescription?
    let pixel = decoded.pixelBuffer
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format
    else { throw LiveDVDecodeError.noDecodedImage }
    var timing = CMSampleTimingInfo(duration: CMTime(value: frame.durationTicks, timescale: 30_000),
      presentationTimeStamp: CMTime(value: frame.startTick, timescale: 30_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample else { throw LiveDVDecodeError.noDecodedImage }
    return DecodedPacket(sample: sample, sourceTimecode: text, sourceBytes: bytes,
      sourceClock: DVTechnicalSpecifications.frameRecordedClock(bytes))
  }

  func nextAudio() async throws -> AudioRead {
    guard let inspection, let audioHandle,
      try await inspection.index.waitForFrame(audioOrdinal) else { return .end }
    do {
      try Task.checkCancellation()
      let frame = inspection.timeline.frame(audioOrdinal)
      audioOrdinal += 1
      let sample: CMSampleBuffer? = try autoreleasepool {
        let bytes = try inspection.timeline.readFrame(frame.ordinal, from: audioHandle)
        // The existing monitor decoder refuses conflicting/unsupported packs,
        // error-coded PCM and unavailable channels; none are filled with silence.
        guard let media = LiveDVMedia(frame: bytes), let audio = media.audio,
          stride(from: 0, to: bytes.count, by: 12_000).allSatisfy({ bytes[$0 + 5] & 0x80 == 0 }),
          let pcm = media.pcm16(frame: bytes) else { return nil }
        let sourceTime = CMTime(value: frame.startTick, timescale: 30_000)
        var time = sourceTime
        if let nextAudioTime, previousAudioRate == audio.sampleRate,
          previousAudioPAL == frame.isPAL,
          abs(CMTimeGetSeconds(CMTimeSubtract(nextAudioTime, sourceTime))) < 0.05 {
          time = nextAudioTime
        }
        // A system boundary can differ from the preceding declared PCM end
        // by a fraction of a sample. Preserve all samples without overlap.
        if let nextAudioTime, CMTimeCompare(time, nextAudioTime) < 0 {
          time = nextAudioTime
        }
        previousAudioRate = audio.sampleRate; previousAudioPAL = frame.isPAL
        nextAudioTime = CMTimeAdd(time, CMTime(value: Int64(audio.samplesPerChannel), timescale: Int32(audio.sampleRate)))
        return try Self.makePCM(pcm, rate: audio.sampleRate, channels: audio.channelCount, time: time)
      }
      if let sample { return .sample(sample) }
      nextAudioTime = nil
      return .gap
    }
  }

  private static func makePCM(_ pcm: [Int16], rate: Int, channels: Int, time: CMTime) throws -> CMSampleBuffer {
    let stride = channels * MemoryLayout<Int16>.size
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(stride), mFramesPerPacket: 1, mBytesPerFrame: UInt32(stride),
      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
      layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
      formatDescriptionOut: &format))
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: pcm.count * 2, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: pcm.count * 2, flags: 0, blockBufferOut: &block))
    guard let format, let block else { throw OfflineDVPlaybackError.unsupportedDecodedAudio }
    try pcm.withUnsafeBytes {
      try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: $0.count))
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var size = stride, sample: CMSampleBuffer?
    try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: format, sampleCount: pcm.count / channels, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
    guard let sample else { throw OfflineDVPlaybackError.unsupportedDecodedAudio }
    return sample
  }
  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw LiveDVDecodeError.nativeFailure("prepare source PCM", status) }
  }
  func checkCompletion() throws {
    if let inspection { try inspection.timeline.verifyUnchanged(url: inspection.url) }
  }
  func cancel() {
    try? videoHandle?.close(); videoHandle = nil
    try? audioHandle?.close(); audioHandle = nil
  }
}

/// One scanner publishes immutable validated prefixes. Readers can wait for
/// lookahead without mistaking the temporary prefix end for end of file.
private final class RendererFlushCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining = 2
  private let continuation: CheckedContinuation<Void, Never>
  init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
  func finish() {
    let complete = lock.withLock { remaining -= 1; return remaining == 0 }
    if complete { continuation.resume() }
  }
}

private final class PlaybackIndex: @unchecked Sendable {
  private let lock = NSLock()
  private var value: DVPlaybackTimeline
  private var failure: String?
  private var scrubbing = false
  init(_ timeline: DVPlaybackTimeline) { value = timeline }
  var snapshot: DVPlaybackTimeline { lock.withLock { value } }
  func update(_ timeline: DVPlaybackTimeline) { lock.withLock { value = timeline } }
  func stop(reason: String) { lock.withLock { failure = reason } }
  func setScrubbing(_ active: Bool) { lock.withLock { scrubbing = active } }
  func yieldToScrubbing() throws {
    while lock.withLock({ scrubbing }) {
      try Task.checkCancellation()
      Thread.sleep(forTimeInterval: 0.002)
    }
  }
  func waitForFrame(_ ordinal: Int) async throws -> Bool {
    while true {
      try Task.checkCancellation()
      let (timeline, error) = lock.withLock { (value, failure) }
      if let error { throw DVPlaybackTimeline.Failure(reason: error) }
      if ordinal < timeline.frameCount { return true }
    if timeline.isComplete || timeline.isPreviewEstimate { return false }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private struct AssetInspection: Sendable {
  let url: URL
  let index: PlaybackIndex
  var timeline: DVPlaybackTimeline { index.snapshot }
  let sourceFormat: DVInspectionSourceFormat?
  var appleGeometry: DVAppleGeometry? { sourceFormat.map { DVAppleGeometry.inspect(format: $0.value) } }
  var timelineStartSeconds: Double { 0 }
  var timelineStart: CMTime { .zero }
  var duration: CMTime { CMTime(value: timeline.durationTicks, timescale: 30_000) }
  var frameDuration: CMTime { CMTime(value: timeline.frame(0).durationTicks, timescale: 30_000) }
  var durationSeconds: Double { timeline.durationSeconds }
  var frameDurationSeconds: Double { CMTimeGetSeconds(frameDuration) }
  var estimatedFrameCount: Int { timeline.frameCount }
  var displayAspectRatio: CGFloat { CGFloat(appleGeometry?.displayRatio ?? 4.0 / 3.0) }
  var hasAudio: Bool { true } // Frame-local qualification decides whether PCM can be emitted.
  var decodedAudioFormat: OfflineDVDecodedAudioFormat? { nil }
  var decodedAudioDescription: String { "Source PCM checked per frame" }
  var videoDescription: String {
    if timeline.isPreviewEstimate { return "Frame-local playback • whole-file timeline not assessed" }
    if !timeline.isComplete { return "Ready to play • indexing remaining source frames…" }
    let systems = Set(timeline.runs.map(\.isPAL))
    if systems.count > 1 { return "NTSC / PAL • \(timeline.runs.count) format runs • exact source-frame timeline" }
    return systems.contains(true) ? "720 × 576 • 25 fps • PAL" : "720 × 480 • 29.970 fps • NTSC"
  }

  static func load(url: URL) async throws -> AssetInspection {
    let scan = Task.detached(priority: .userInitiated) { try DVPlaybackTimeline.preview(url: url) }
    let timeline = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    try Task.checkCancellation()
    // Optional native metadata only. Apple’s raw importer is never authority
    // for mixed-system frame boundaries, duration, seeking or decoded audio.
    let asset = AVURLAsset(url: url)
    let track = try? await asset.loadTracks(withMediaType: .video).first
    let format = try? await track?.load(.formatDescriptions).first
    return Self(url: url, index: PlaybackIndex(timeline), sourceFormat: format.map { DVInspectionSourceFormat(value: $0) })
  }
}

private final class SecurityScopedURLLease: @unchecked Sendable {
  private let url: URL
  private let didStart: Bool

  init(url: URL) {
    self.url = url
    didStart = url.startAccessingSecurityScopedResource()
  }

  deinit {
    if didStart { url.stopAccessingSecurityScopedResource() }
  }
}

private enum OfflineDVPlaybackError: LocalizedError {
  case notPlayable
  case noVideoTrack
  case noVideoFormat
  case invalidDuration
  case invalidFrameRate
  case readerConfiguration
  case readerDidNotStart
  case readerDidNotComplete
  case noDecodedVideo
  case noDecodedAudio
  case unsupportedDecodedAudio
  case rendererFailed

  var errorDescription: String? {
    switch self {
    case .notPlayable: "AVFoundation could not play this raw DV file."
    case .noVideoTrack: "The selected file has no readable video track."
    case .noVideoFormat: "AVFoundation did not expose a video format."
    case .invalidDuration: "The selected file has no finite playback duration."
    case .invalidFrameRate: "The selected file has no valid source-frame cadence."
    case .readerConfiguration: "AVFoundation could not configure the offline reader."
    case .readerDidNotStart: "AVFoundation could not start the offline reader."
    case .readerDidNotComplete: "AVFoundation stopped before playback completed."
    case .noDecodedVideo: "AVFoundation did not produce a decoded video frame."
    case .noDecodedAudio: "AVFoundation exposed audio but did not produce decoded PCM."
    case .unsupportedDecodedAudio: "Decoded audio was not bounded interleaved PCM16."
    case .rendererFailed: "The native sample-buffer renderer failed."
    }
  }
}
