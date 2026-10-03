import AVFoundation
import AppKit
import AudioToolbox
import Combine
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

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
  @Published private(set) var technicalSpecificationsStatus = "No file selected"
  private var technicalSpecificationsTask: Task<Void, Never>?
  @Published private(set) var durationSeconds = 0.0
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
  var isLoading: Bool { state == .loading }
  var canPlay: Bool {
    switch state {
    case .paused, .ended: true
    default: false
    }
  }
  var canPause: Bool { state == .playing }
  var displayAspectRatio: CGFloat { CGFloat(displayAspect.ratio) }
  var rasterHeight: Int { inspection?.rasterHeight ?? 480 }
  var frameCounterDescription: String {
    "\(frameCounterIsEstimated ? "Estimated frame" : "Source frame") \(currentFrameOrdinal)"
  }

  var sourceAudioDescription: String {
    switch sourceAudioStatus {
    case .unverified: "Source audio unverified — playback muted"
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
  private var verificationTask: Task<Void, Never>?
  private var playbackTask: Task<Void, Never>?
  private var clockTask: Task<Void, Never>?
  private var playbackPumpIsActive = false
  private var scrubFrameInFlight = false
  private var pendingScrubTime: Double?
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
    sourceAudioStatus = .verifying
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

    sourceFileAuditStatus = "Assessing source audio counts and error flags…"
    sourceFileAuditTask = Task { [weak self, lease] in
      let scan = Task.detached(priority: .utility) { _ = lease; return try DVSourceFileAudit.read(url: url) }
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

    verificationTask = Task { [weak self, lease] in
      let scan = Task.detached(priority: .utility) {
        _ = lease
        return try SourceAudioVerifier.verify(url: url)
      }
      let result: SourceAudioVerification
      do {
        result = try await withTaskCancellationHandler {
          try await scan.value
        } onCancel: {
          scan.cancel()
        }
      } catch is CancellationError {
        return
      } catch {
        result = .unavailable(error.localizedDescription)
      }
      guard let self, self.sessionID == id else { return }
      self.acceptSourceAudioVerification(result)
    }

    loadTask = Task { [weak self, lease] in
      _ = lease
      do {
        let loaded = try await AssetInspection.load(url: url)
        try Task.checkCancellation()
        guard let self, self.sessionID == id else { return }
        self.inspection = loaded
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

  func stepFrames(_ delta: Int) {
    guard let inspection, delta != 0 else { return }
    if state == .playing { updateClockSnapshot() }
    let base = state == .playing ? currentFrameOrdinal : requestedFrameOrdinal
    let frame = min(max(0, base + delta), inspection.estimatedFrameCount - 1)
    startRenderSession(at: Double(frame) * inspection.frameDurationSeconds, autoplay: false)
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
    sessionID = UUID()
    metadata.clearRecordedClock()
    sourceFileAuditTask?.cancel(); sourceFileAuditTask = nil
    sourceFileAudit = nil; sourceFileAuditStatus = "No file selected"
    technicalSpecificationsTask?.cancel()
    technicalSpecificationsTask = nil
    technicalSpecifications = nil
    appleGeometry = nil
    technicalSpecificationsStatus = "No file selected"
    frameDecoder = LiveDVFrameDecoder()
    renderGeneration &+= 1
    loadTask?.cancel()
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
    currentFrameOrdinal = min(
      max(0, Int(floor(relative / effectiveFrameDuration(inspection) + 0.000_001))),
      max(0, inspection.estimatedFrameCount - 1))
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
    let targetFrame = min(
      max(0, Int(floor(clampedTime(seconds) / inspection.frameDurationSeconds + 0.000_001))),
      inspection.estimatedFrameCount - 1)
    let relativeStart = Double(targetFrame) * inspection.frameDurationSeconds
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
    metadata.reset()
    currentTimeSeconds = relativeStart
    currentFrameOrdinal = targetFrame
    // The renderer retains its last picture through flush. Retain that picture's
    // source timecode too, until a decoded replacement (including missing TC) arrives.
    let nextState: OfflineDVPlaybackState = autoplay ? .playing : .paused
    if state != nextState { state = nextState }
    let includeAudibleAudio = audioMayPlay

    playbackTask = Task { [weak self] in
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
          self.videoRenderer.flush(removingDisplayedImage: false) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
          self.navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: false) { continuation.resume() }
        }
        try Task.checkCancellation()
        guard self.sessionID == id, self.renderGeneration == generation else { return }
        let readers = RenderReaders(inspectionDecoder: self.frameDecoder)
        defer { Task { await readers.cancel() } }
        try await readers.prepare(
          inspection: inspection,
          relativeStart: relativeStart,
          includeAudio: inspection.audioTrackID != nil && autoplay)
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
    var audioDone = inspection.audioTrackID == nil || !autoplay
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
              let ordinal = UInt64(max(0, (time / inspection.frameDurationSeconds).rounded()))
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
          pendingAudioSample = try await readers.nextAudio()?.sample
          try Task.checkCancellation()
          guard self.sessionID == id, self.renderGeneration == generation else { return }
          if pendingAudioSample != nil {
            firstAudioSeen = true
            progressed = true
          } else {
            audioDone = true
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
        objectWillChange.send()
        return
      }

      if !progressed {
        try await Task.sleep(for: .milliseconds(5))
      } else {
        await Task.yield()
      }
    }

    guard firstVideoQueued else { throw OfflineDVPlaybackError.noDecodedVideo }
    if inspection.audioTrackID != nil, !firstAudioSeen {
      throw OfflineDVPlaybackError.noDecodedAudio
    }
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
    // AVFoundation source sample bytes are exact. A durable file-byte offset
    // is not claimed from a presentation timestamp or an assumed container.
    acceptRecordedClock(frame.clock, ordinal: frame.ordinal, association: "playback-clock-associated source sample; display association unverified")
    metadata.offer(frame.bytes, ordinal: frame.ordinal, paused: paused)
  }

  private func samplePausedMetadata() {
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
      metadata.offer(frame.bytes, ordinal: frame.ordinal, paused: true, presentationConfirmed: true)
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
    metadata.offer(frame.bytes, ordinal: frame.ordinal, paused: true, selectionConfirmed: true)
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
      evidence: "Frame \(ordinal) · " + association + ". " + clock.evidence)
    metadata.setRecordedClock(next, ordinal: ordinal)
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
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM format changed — playback muted"
      audioRenderer.flush()
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
    if case .formatChanged = report.resetReason {
      decodedAudioHasConflict = true
      audioDescription = "Decoded PCM format changed — playback muted"
      audioRenderer.flush()
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
    guard !decodedAudioHasConflict,
      let decodedAudioFormat,
      case .verified(let rate, _) = sourceAudioStatus
    else { return false }
    return abs(decodedAudioFormat.sampleRate - Double(rate)) < 0.5
  }

  private func acceptSourceAudioVerification(_ result: SourceAudioVerification) {
    let shouldResumeAudibly = state == .playing && !audioMayPlay
    switch result {
    case .verified(let sampleRate, let frameCount):
      sourceAudioStatus = .verified(sampleRate: sampleRate, frameCount: frameCount)
    case .conflicting:
      sourceAudioStatus = .conflicting
    case .unavailable(let reason):
      sourceAudioStatus = .unavailable(reason)
    }
    reconcileAudioTruth()
    if shouldResumeAudibly, audioMayPlay {
      // The initial session was deliberately video-only while raw source audio
      // was unverified. Restart at the presented clock so newly verified audio
      // begins on a clean renderer boundary instead of joining mid-buffer.
      startRenderSession(at: currentTimeSeconds, autoplay: true)
    }
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
    inspection.frameDurationSeconds
  }

  private func fail(_ error: Error) {
    synchronizer.rate = 0
    playbackTask?.cancel()
    playbackPumpIsActive = false
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

private actor RenderReaders {
  private let inspectionDecoder: LiveDVFrameDecoder
  init(inspectionDecoder: LiveDVFrameDecoder) { self.inspectionDecoder = inspectionDecoder }
  // Compile the shared Metal pipeline before starting the presentation clock,
  // not on the first mid-playback toggle. Standard remains available if Metal
  // cannot initialize; an explicit inspection request reports that error.
  private var pictureProcessor: Result<DVMetalFieldProcessor, Error>?
  private var inspectionSourceFormat: CMVideoFormatDescription?
  private var reader: AVAssetReader?
  private var videoOutput: AVAssetReaderTrackOutput?
  private var audioOutput: AVAssetReaderTrackOutput?

  func prepare(inspection: AssetInspection, relativeStart: Double, includeAudio: Bool) async throws
  {
    try Task.checkCancellation()
    pictureProcessor = Result { try DVMetalFieldProcessor() }
    guard
      let videoTrack = try await inspection.asset.loadTrack(withTrackID: inspection.videoTrackID)
    else {
      throw OfflineDVPlaybackError.noVideoTrack
    }
    inspectionSourceFormat = try await videoTrack.load(.formatDescriptions).first
    let reader = try AVAssetReader(asset: inspection.asset)
    self.reader = reader
    let frame = Int64((relativeStart / inspection.frameDurationSeconds).rounded())
    let start = CMTimeAdd(
      inspection.timelineStart, CMTimeMultiply(inspection.frameDuration, multiplier: Int32(frame)))
    reader.timeRange = CMTimeRange(
      start: start, end: CMTimeAdd(inspection.timelineStart, inspection.duration))
    let video = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: nil)
    video.alwaysCopiesSampleData = false
    guard reader.canAdd(video) else { throw OfflineDVPlaybackError.readerConfiguration }
    reader.add(video)
    videoOutput = video
    if includeAudio, let trackID = inspection.audioTrackID,
      let track = try await inspection.asset.loadTrack(withTrackID: trackID)
    {
      let audio = AVAssetReaderTrackOutput(
        track: track, outputSettings: OfflineDVPlaybackModel.pcmOutputSettings)
      audio.alwaysCopiesSampleData = false
      guard reader.canAdd(audio) else { throw OfflineDVPlaybackError.readerConfiguration }
      reader.add(audio)
      audioOutput = audio
    }
    guard reader.startReading() else {
      throw reader.error ?? OfflineDVPlaybackError.readerDidNotStart
    }
  }

  func nextVideo(viewingMode: DVViewingMode, extremeZebras: Bool) async throws -> DecodedPacket? {
    try Task.checkCancellation()
    var next = videoOutput?.copyNextSampleBuffer()
    do {
      // Match the existing compressed-source reader: AVFoundation can emit
      // zero-byte range-start timing markers before the actual DV sample.
      for _ in 0..<8 {
        guard let sample = next, CMSampleBufferGetTotalSampleSize(sample) == 0 else { break }
        try Task.checkCancellation()
        next = videoOutput?.copyNextSampleBuffer()
      }
    }
    guard let sample = next else {
      try checkCompletion()
      return nil
    }
    do {
      guard let block = CMSampleBufferGetDataBuffer(sample) else {
        throw DVMetalFieldProcessor.Failure("The native reader returned no compressed DV data.")
      }
      guard let format = CMSampleBufferGetFormatDescription(sample) ?? inspectionSourceFormat else {
        throw DVMetalFieldProcessor.Failure("The native reader returned no DV format metadata.")
      }
      let count = CMBlockBufferGetDataLength(block)
      guard count == 120_000 || count == 144_000 else { throw LiveDVDecodeError.malformedFrame }
      var bytes = Data(count: count)
      let copied = bytes.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
      }
      guard copied == noErr else { throw LiveDVDecodeError.nativeFailure("read native DV sample", copied) }
      let text = OfflineDVPlaybackModel.validatedSourceTimecode(from: sample)
      // One persistent both-fields decoder for every display policy. Standard
      // hands its tagged native YCbCr image to Apple's compositor unchanged;
      // inspection produces a display-only derivative, never a source edit.
      let decoded = try await inspectionDecoder.decode(bytes, ordinal: 0, timecode: text,
        sourceFormat: DVInspectionSourceFormat(value: format))
      try Task.checkCancellation()
      guard let pictureProcessor else { throw OfflineDVPlaybackError.readerConfiguration }
      let pixel = viewingMode == .standard && !extremeZebras
        ? decoded.pixelBuffer
        : try pictureProcessor.get().process(decoded.pixelBuffer,
          mode: viewingMode, extremeZebras: extremeZebras)
      var description: CMVideoFormatDescription?
      guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel, formatDescriptionOut: &description) == noErr,
        let description else { throw LiveDVDecodeError.noDecodedImage }
      var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
      var presented: CMSampleBuffer?
      guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel, formatDescription: description, sampleTiming: &timing,
        sampleBufferOut: &presented) == noErr, let presented else { throw LiveDVDecodeError.noDecodedImage }
      return DecodedPacket(sample: presented, sourceTimecode: text, sourceBytes: bytes, sourceClock: DVTechnicalSpecifications.frameRecordedClock(bytes))
    }
  }

  func nextAudio() throws -> DecodedPacket? {
    try Task.checkCancellation()
    guard let sample = audioOutput?.copyNextSampleBuffer() else {
      try checkCompletion()
      return nil
    }
    return DecodedPacket(sample: sample, sourceTimecode: nil)
  }

  func checkCompletion() throws {
    if let reader, reader.status != .reading && reader.status != .completed {
      throw reader.error ?? OfflineDVPlaybackError.readerDidNotComplete
    }
  }

  func cancel() {
    reader?.cancelReading()
  }
}

private struct AssetInspection: Sendable {
  let appleGeometry: DVAppleGeometry
  let asset: AVURLAsset
  let videoTrackID: CMPersistentTrackID
  let audioTrackID: CMPersistentTrackID?
  let timelineStartSeconds: Double
  let timelineStart: CMTime
  let duration: CMTime
  let frameDuration: CMTime
  let durationSeconds: Double
  let frameDurationSeconds: Double
  let estimatedFrameCount: Int
  let displayAspectRatio: CGFloat
  let rasterHeight: Int
  let videoDescription: String
  let decodedAudioFormat: OfflineDVDecodedAudioFormat?
  let decodedAudioDescription: String

  static func load(url: URL) async throws -> AssetInspection {
    let asset = AVURLAsset(url: url)
    guard try await asset.load(.isPlayable) else { throw OfflineDVPlaybackError.notPlayable }
    guard let video = try await asset.loadTracks(withMediaType: .video).first else {
      throw OfflineDVPlaybackError.noVideoTrack
    }
    let audio = try await asset.loadTracks(withMediaType: .audio).first
    let timeRange = try await video.load(.timeRange)
    let duration = CMTimeGetSeconds(timeRange.duration)
    let start = CMTimeGetSeconds(timeRange.start)
    guard duration.isFinite, duration > 0, start.isFinite else {
      throw OfflineDVPlaybackError.invalidDuration
    }
    let frameRate = try await video.load(.nominalFrameRate)
    guard frameRate.isFinite, frameRate > 0 else { throw OfflineDVPlaybackError.invalidFrameRate }
    // Raw DV's track-level minFrameDuration may be invalid even when each
    // native sample has exact 1001/30000 or 1/25 timing. Read sample timing,
    // never reconstruct NTSC cadence from the rounded nominalFrameRate Float.
    let frameDuration = try nativeFrameDuration(asset: asset, track: video)
    guard frameDuration.isNumeric, CMTimeGetSeconds(frameDuration) > 0 else {
      throw OfflineDVPlaybackError.invalidFrameRate
    }
    let size = try await video.load(.naturalSize)
    guard let format = try await video.load(.formatDescriptions).first else {
      throw OfflineDVPlaybackError.noVideoFormat
    }
    let pixelAspect = pixelAspectRatio(from: format) ?? 1
    let aspect =
      size.width > 0 && size.height > 0
      ? (size.width / size.height) * pixelAspect : (4.0 / 3.0)
    let fieldCount =
      (CMFormatDescriptionGetExtension(
        format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber)?.intValue
    let fieldText: String
    switch fieldCount {
    case 2: fieldText = "2 fields/frame (native decoder presentation)"
    case 1: fieldText = "1 field/frame"
    default: fieldText = "field structure unknown"
    }
    let rateText = String(format: "%.3f", frameRate)

    let decodedFormat = audio.flatMap { try? firstDecodedAudioFormat(asset: asset, track: $0) }
    let playableAudioTrack = decodedFormat == nil ? nil : audio
    return AssetInspection(
      appleGeometry: DVAppleGeometry.inspect(format: format),
      asset: asset,
      videoTrackID: video.trackID,
      audioTrackID: playableAudioTrack?.trackID,
      timelineStartSeconds: start,
      timelineStart: timeRange.start,
      duration: timeRange.duration,
      frameDuration: frameDuration,
      durationSeconds: duration,
      frameDurationSeconds: CMTimeGetSeconds(frameDuration),
      estimatedFrameCount: max(1, Int((duration / CMTimeGetSeconds(frameDuration)).rounded())),
      displayAspectRatio: aspect,
      rasterHeight: Int(CMVideoFormatDescriptionGetDimensions(format).height),
      videoDescription: "\(Int(size.width)) × \(Int(size.height)) • \(rateText) fps • \(fieldText)",
      decodedAudioFormat: decodedFormat,
      decodedAudioDescription: decodedFormat.map(OfflineDVPlaybackModel.description(for:))
        ?? (audio == nil
          ? "No audio track — video-only playback" : "Audio could not be decoded safely — muted"))
  }

  private static func firstDecodedAudioFormat(asset: AVAsset, track: AVAssetTrack) throws
    -> OfflineDVDecodedAudioFormat?
  {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: OfflineDVPlaybackModel.pcmOutputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw OfflineDVPlaybackError.readerConfiguration }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? OfflineDVPlaybackError.readerDidNotStart
    }
    defer { reader.cancelReading() }
    guard let sample = output.copyNextSampleBuffer() else { return nil }
    return try OfflineDVPlaybackModel.decodedPCM(from: sample).format
  }

  private static func nativeFrameDuration(asset: AVAsset, track: AVAssetTrack) throws -> CMTime {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { throw OfflineDVPlaybackError.readerConfiguration }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? OfflineDVPlaybackError.readerDidNotStart
    }
    defer { reader.cancelReading() }
    var firstPTS: CMTime?
    for _ in 0..<8 {
      guard let sample = output.copyNextSampleBuffer() else { break }
      guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
      let duration = CMSampleBufferGetDuration(sample)
      if duration.isNumeric, CMTimeGetSeconds(duration) > 0 { return duration }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      if let firstPTS, pts.isNumeric, CMTimeCompare(pts, firstPTS) > 0 {
        return CMTimeSubtract(pts, firstPTS)
      }
      if pts.isNumeric { firstPTS = pts }
    }
    throw OfflineDVPlaybackError.invalidFrameRate
  }

  private static func pixelAspectRatio(from format: CMFormatDescription) -> CGFloat? {
    guard
      let dictionary = CMFormatDescriptionGetExtension(
        format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
        as? [CFString: NSNumber],
      let horizontal = dictionary[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing]?
        .doubleValue,
      let vertical = dictionary[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing]?
        .doubleValue,
      horizontal.isFinite, vertical.isFinite, horizontal > 0, vertical > 0
    else { return nil }
    return CGFloat(horizontal / vertical)
  }
}

private enum SourceAudioVerification: Sendable {
  case verified(sampleRate: Int, frameCount: UInt64)
  case conflicting
  case unavailable(String)
}

private enum SourceAudioVerifier {
  private static let ntscFrameBytes = 120_000
  private static let palFrameBytes = 144_000

  static func verify(url: URL) throws -> SourceAudioVerification {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
      return .unavailable("not a non-empty regular file")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let probe = try read(upTo: palFrameBytes, from: handle)
    try Task.checkCancellation()
    let probeManifest = DVCaptureMetadataEpochAnalyzer.analyze(data: probe)
    guard let first = probeManifest.frames.first,
      first.fileByteOffset == 0,
      first.byteCount == UInt64(ntscFrameBytes) || first.byteCount == UInt64(palFrameBytes)
    else { return .unavailable("raw DV frame alignment could not be verified") }
    let frameBytes = Int(first.byteCount)
    guard fileSize.isMultiple(of: frameBytes) else {
      return .unavailable("the source ends with an incomplete DV frame")
    }

    try handle.seek(toOffset: 0)
    var establishedRate: Int?
    var frameCount: UInt64 = 0
    while frameCount < UInt64(fileSize / frameBytes) {
      try Task.checkCancellation()
      let frame = try read(upTo: frameBytes, from: handle)
      guard frame.count == frameBytes else {
        return .unavailable("the source changed or became unreadable during verification")
      }
      let manifest = DVCaptureMetadataEpochAnalyzer.analyze(data: frame)
      guard manifest.frames.count == 1,
        manifest.unclassifiedExtents.isEmpty,
        let metadata = manifest.frames.first,
        metadata.fileByteOffset == 0,
        metadata.byteCount == UInt64(frameBytes)
      else {
        return .unavailable("a raw DV frame has absent or malformed audio metadata")
      }
      let rate: Int
      switch metadata.audioSampleRate {
      case .known32000Hz: rate = 32_000
      case .known44100Hz: rate = 44_100
      case .known48000Hz: rate = 48_000
      case .conflicting: return .conflicting
      case .absent, .malformed:
        return .unavailable("a raw DV frame has absent or malformed audio metadata")
      }
      if let establishedRate, establishedRate != rate { return .conflicting }
      establishedRate = rate
      frameCount += 1
    }
    guard let establishedRate, frameCount > 0 else {
      return .unavailable("no complete DV frames were verified")
    }
    return .verified(sampleRate: establishedRate, frameCount: frameCount)
  }

  private static func read(upTo byteCount: Int, from handle: FileHandle) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
      try Task.checkCancellation()
      guard let chunk = try handle.read(upToCount: byteCount - result.count), !chunk.isEmpty else {
        break
      }
      result.append(chunk)
    }
    return result
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
