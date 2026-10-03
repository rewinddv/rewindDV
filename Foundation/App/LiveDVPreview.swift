// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine
import Foundation

/// Preview is lossy by design under UI backpressure. The receive owner must
/// preserve raw data independently BEFORE offering a complete frame here.
@MainActor final class LiveDVPreview: ObservableObject {
  let metadata = LiveDVMetadata()
  @Published private(set) var sourceTimecode: String?
  @Published private(set) var latestSubmittedOrdinal: UInt64?
  @Published private(set) var skippedPreviewFrames: UInt64 = 0
  @Published private(set) var queueSkippedFrames: UInt64 = 0
  @Published private(set) var rendererSkippedFrames: UInt64 = 0
  private(set) var retiredEpochSkips: UInt64 = 0
  private(set) var videoAdmissionSkips: UInt64 = 0
  @Published private(set) var videoTimelineResets: UInt64 = 0
  @Published private(set) var discardedPresentationSchedules: UInt64 = 0
  @Published private(set) var error: String?
  @Published private(set) var failedVideoFrames: UInt64 = 0
  @Published private(set) var signalState: LiveSignalPresentation.State = .inactive
  @Published private(set) var isReceiving = false
  @Published private(set) var hasImage = false
  @Published private(set) var presentedAspectRatio: Double?
  @Published private(set) var appleGeometry: DVAppleGeometry?
  private(set) var appleGeometryOrdinal: UInt64?
  private var geometrySampleTime: ContinuousClock.Instant?
  var appleGeometryStatus: String {
    guard appleGeometry != nil, let geometrySampleTime else { return "Unavailable — no Apple geometry observation" }
    if !isReceiving { return "Stopped — last decoded geometry, not current" }
    return ContinuousClock.now - geometrySampleTime > .seconds(2)
      ? "Stale — no recent decoded geometry" : "Sampled decoded geometry"
  }

  /// Bounded preview-side observation BEFORE applyGeometry mutates display tags.
  /// No decode, disk IO, receive wait, or effect on archival bytes.
  private func observeAppleGeometry(_ decoded: LiveDVDecodedFrame, force: Bool = false) {
    let now = ContinuousClock.now
    guard force || geometrySampleTime.map({ now - $0 >= .milliseconds(500) }) != false else { return }
    geometrySampleTime = now
    let next = DVAppleGeometry.inspect(imageBuffer: decoded.pixelBuffer)
    appleGeometryOrdinal = decoded.sourceOrdinal
    if appleGeometry != next { appleGeometry = next }
  }
  @Published private(set) var rasterHeight = 480
  @Published var aspect: LiveDisplayAspect = .source
  @Published var viewingMode: DVViewingMode = .standard
  @Published private(set) var extremeZebras = false
  @Published private(set) var zoom: CGFloat = 1
  @Published private(set) var zoomCenter = CGPoint(x: 0.5, y: 0.5)
  @Published private(set) var sourceWidescreen: Bool?
  let displayLayer = AVSampleBufferDisplayLayer()
  let navigatorLayer = AVSampleBufferDisplayLayer()
  lazy var audio = LiveAudioMonitor(video: displayLayer.sampleBufferRenderer, muteAudio: muteAudio)
  var displayAspectRatio: Double { aspect.ratio(widescreen: sourceWidescreen) }
  var displayAspect: DVDisplayAspect { displayAspectRatio > 1.5 ? .widescreen : .standard }

  func setDisplayAspect(_ value: DVDisplayAspect) {
    aspect = value == .widescreen ? .anamorphic : .standard
    // Geometry only; never interrupt receive, audio, or the presentation clock.
  }

  func setZoom(_ value: CGFloat) {
    guard [1, 2, 4, 8].contains(value), value != zoom else { return }
    zoom = value
    setZoomCenter(zoomCenter)
  }

  func setZoomCenter(_ point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    let edge = 0.5 / zoom
    zoomCenter = CGPoint(x: min(1-edge, max(edge, point.x)), y: min(1-edge, max(edge, point.y)))
  }

  func setExtremeZebras(_ enabled: Bool) {
    guard extremeZebras != enabled else { return }
    extremeZebras = enabled
    Task { await refreshHeldGeometry() }
  }
  private let decoder = LiveDVFrameDecoder()
  private var epoch = UUID()
  private var task: Task<Void, Never>?
  private var audioPrimed = false
  private var videoPresentationEpoch: UInt64 = 0
  // Small receive bursts must not collapse into one frame. Only sustained
  // presentation overload discards the oldest waiting frame (raw is retained).
  private var pending: [Frame] = []
  // Cover the bounded 500ms scheduling horizon (15 NTSC / 13 PAL frames),
  // including cold-start backlog. Still bounded; no archive ownership here.
  private let pendingCapacity = 16
  private var latestOffered: LivePreservedFrame?
  private let muteAudio: Bool
  private let permitsVideoSubmission: @MainActor () -> Bool
  private let beforeDecode: (@MainActor (UInt64) async -> Void)?
  private var clockTask: Task<Void, Never>?
  private var timedFacts: [(CMTime, String?, UInt64)] = []
  private var audioObservation: AnyCancellable?
  private var signal = LiveSignalPresentation()
  private var signalClock = ContinuousClock.now
  // Aggregates only; emitted by the existing coarse flight snapshots, never
  // per-frame file IO. Admission skips do not count native deadline misses.
  private(set) var decodedFrames: UInt64 = 0
  private(set) var firstDecodeMilliseconds: Double?
  private(set) var maximumDecodeMilliseconds = 0.0
  private(set) var lateVideoSubmissions: UInt64 = 0
  private(set) var minimumVideoLeadMilliseconds: Double?
  private(set) var nativeVideoMetrics: String = "unavailable"
  private var metricsPending = false

  func requestNativeVideoMetrics() {
    guard !metricsPending else { return }
    metricsPending = true
    let id = epoch
    Task { [weak self] in
      guard let self else { return }
      let metrics = await self.displayLayer.sampleBufferRenderer.videoPerformanceMetrics
      self.metricsPending = false
      guard self.epoch == id else { return }
      if let metrics {
        self.nativeVideoMetrics = "scope:renderer_lifetime,total:\(metrics.totalNumberOfFrames),dropped:\(metrics.numberOfDroppedFrames),corrupted:\(metrics.numberOfCorruptedFrames),delay_seconds:\(metrics.totalAccumulatedFrameDelay)"
      } else { self.nativeVideoMetrics = "unavailable" }
    }
  }

  var timingDiagnostics: String {
    "video_decoded_frames=\(decodedFrames); first_decode_ms=\(firstDecodeMilliseconds.map(String.init(describing:)) ?? "unknown"); max_decode_ms=\(maximumDecodeMilliseconds); late_video_submissions=\(lateVideoSubmissions); min_video_lead_ms=\(minimumVideoLeadMilliseconds.map(String.init(describing:)) ?? "unknown"); native_video_metrics=\(nativeVideoMetrics); video_retired_epoch_skips=\(retiredEpochSkips); video_admission_skips=\(videoAdmissionSkips); " + audio.timingDiagnostics
  }

  private var signalSeconds: Double {
    let elapsed = signalClock.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  func observeReceivePackets(_ count: UInt64) {
    signal.observePackets(count, at: signalSeconds)
  }

  private func updateSignalState() {
    let next = signal.state(at: signalSeconds)
    if next != signalState { signalState = next }
  }

  init(muteAudio: Bool = false, permitsVideoSubmission: @escaping @MainActor () -> Bool = { true },
    beforeDecode: (@MainActor (UInt64) async -> Void)? = nil) {
    self.muteAudio = muteAudio
    self.permitsVideoSubmission = permitsVideoSubmission
    self.beforeDecode = beforeDecode
    audio.synchronizer.addRenderer(navigatorLayer.sampleBufferRenderer)
    audioObservation = audio.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }

  func refreshHeldGeometry() async {
    guard !isReceiving, let last = latestOffered else { return }
    await showFinalFrame(last)
  }

  private final class Frame {
    let bytes: Data
    let ordinal: UInt64
    let timecode: String?
    var presentationTime: CMTime?
    var audioEpoch: UInt64?
    init(bytes: Data, ordinal: UInt64, timecode: String?) {
      self.bytes = bytes; self.ordinal = ordinal; self.timecode = timecode
    }
  }

  /// Cold setup establishes the first A/V anchor. Thereafter each preserved
  /// frame offers audio at intake, independently of asynchronous video work.
  /// Audio timing is stored on the bounded video queue, not recomputed later.
  private func scheduleAudio(_ frame: Frame) {
    guard frame.presentationTime == nil else { return }
    frame.presentationTime = audio.offer(frame.bytes, ordinal: frame.ordinal)
    frame.audioEpoch = audio.presentationEpoch
  }

  private func primeAudioIfNeeded(_ first: Frame) {
    guard !audioPrimed else { return }
    scheduleAudio(first)
    audioPrimed = true
    // Frames arriving during first-use decode were bounded by pendingCapacity.
    for waiting in pending { scheduleAudio(waiting) }
  }

  private func prepareVideoPresentation(_ frame: Frame, epoch id: UUID) async -> CMTime? {
    guard epoch == id, !Task.isCancelled,
      frame.audioEpoch == audio.presentationEpoch else { return nil }
    if videoPresentationEpoch != audio.presentationEpoch {
      videoPresentationEpoch = audio.presentationEpoch
      videoTimelineResets &+= 1
      discardedPresentationSchedules &+= UInt64(timedFacts.count)
      timedFacts = []
      await displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
      await navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
    }
    guard epoch == id, !Task.isCancelled,
      frame.audioEpoch == audio.presentationEpoch else { return nil }
    return frame.presentationTime
  }

  func begin() async {
    metadata.begin()
    appleGeometry = nil; appleGeometryOrdinal = nil; geometrySampleTime = nil
    let id = UUID()
    epoch = id
    task?.cancel()
    task = nil
    pending = []
    audioPrimed = false
    latestOffered = nil
    hasImage = false
    isReceiving = false
    sourceTimecode = nil
    latestSubmittedOrdinal = nil
    error = nil
    failedVideoFrames = 0
    decodedFrames = 0; firstDecodeMilliseconds = nil; maximumDecodeMilliseconds = 0
    lateVideoSubmissions = 0; minimumVideoLeadMilliseconds = nil
    nativeVideoMetrics = "unavailable"
    signalClock = .now
    signal.begin(at: 0)
    updateSignalState()
    skippedPreviewFrames = 0
    queueSkippedFrames = 0; rendererSkippedFrames = 0
    retiredEpochSkips = 0; videoAdmissionSkips = 0
    videoTimelineResets = 0; discardedPresentationSchedules = 0
    await decoder.reset()
    guard epoch == id else { return }
    await navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    guard epoch == id else { return }
    await withCheckedContinuation { continuation in
      displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {
        continuation.resume()
      }
    }
    guard epoch == id else { return }
    audio.begin()
    videoPresentationEpoch = audio.presentationEpoch
    isReceiving = true
    timedFacts = []
    clockTask?.cancel()
    clockTask = Task { [weak self] in
      while let self, self.epoch == id, !Task.isCancelled {
        let now = self.audio.synchronizer.currentTime()
        self.updateSignalState()
        if self.pending.isEmpty && self.task == nil { self.audio.observeInputIdle() }
        while let first = self.timedFacts.first, first.0 <= now {
          self.timedFacts.removeFirst()
          self.sourceTimecode = first.1
          self.latestSubmittedOrdinal = first.2
        }
        do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
      }
    }
  }

  func end(retainingImage: Bool = false, finalFrame: LivePreservedFrame? = nil) async {
    metadata.end()
    // Finish with the newest complete preserved frame, never with an arbitrary
    // earlier queued picture. Retention is presentation-only, not tape status.
    audio.end()
    signal.end(); updateSignalState()
    clockTask?.cancel(); clockTask = nil; timedFacts = []
    if retainingImage, let last = finalFrame ?? latestOffered { await showFinalFrame(last) }
    let id = UUID()
    epoch = id
    task?.cancel()
    task = nil
    pending = []
    audioPrimed = false
    isReceiving = false
    if !retainingImage {
      sourceTimecode = nil
      latestSubmittedOrdinal = nil
      hasImage = false
    }
    await decoder.reset()
    guard epoch == id else { return }
    if !retainingImage {
      await displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
      await navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }
  }

  func offerPreservedFrame(_ bytes: Data, ordinal: UInt64, sourceTimecode: String?) {
    guard isReceiving else { return }
    metadata.offer(bytes, ordinal: ordinal)
    signal.observeFrame(at: signalSeconds)
    latestOffered = LivePreservedFrame(bytes: bytes, ordinal: ordinal, timecode: sourceTimecode)
    if pending.count == pendingCapacity {
      pending.removeFirst(); skippedPreviewFrames &+= 1; queueSkippedFrames &+= 1
    }
    let offered = Frame(bytes: bytes, ordinal: ordinal, timecode: sourceTimecode)
    if audioPrimed { scheduleAudio(offered) }
    pending.append(offered)
    guard task == nil else { return }
    let id = epoch
    task = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == id { self.task = nil } }
      while self.epoch == id, !Task.isCancelled, !self.pending.isEmpty {
        let frame = self.pending.removeFirst()
        do {
          // Decode before assigning the A/V deadline: first-use decoder/Metal
          // setup previously consumed the entire presentation lead. Archival
          // receive is independent of this bounded preview worker.
          let renderer = self.displayLayer.sampleBufferRenderer
          let decodeStart = ContinuousClock.now
          await self.beforeDecode?(frame.ordinal)
          guard self.epoch == id, !Task.isCancelled else { return }
          let decoded = try await self.decoder.decode(
            frame.bytes,
            ordinal: frame.ordinal, timecode: frame.timecode, viewingMode: self.viewingMode,
            extremeZebras: self.extremeZebras)
          guard self.epoch == id, !Task.isCancelled else { return }
          let decodeDuration = decodeStart.duration(to: .now).components
          let decodeMS = Double(decodeDuration.seconds) * 1000 + Double(decodeDuration.attoseconds) / 1e15
          if self.decodedFrames == 0 { self.firstDecodeMilliseconds = decodeMS }
          self.decodedFrames &+= 1
          self.maximumDecodeMilliseconds = max(self.maximumDecodeMilliseconds, decodeMS)
          // Native readiness may briefly be false while correctly scheduled
          // pictures await presentation. Immediate dropping regressed the paced
          // offline test, so retain its bounded, yielding admission wait.
          // Audio is still offered if this readiness check fails or times out.
          // An occupied renderer can be holding valid future-dated pictures.
          // Wait through this frame's bounded presentation horizon rather than
          // dropping at an unrelated 150ms timeout after increasing A/V lead.
          let scheduledLead = frame.presentationTime.map {
            CMTimeGetSeconds($0 - self.audio.synchronizer.currentTime())
          } ?? 0
          let readinessBudget = scheduledLead.isFinite ? min(0.5, max(0.15, scheduledLead + 0.04)) : 0.15
          let readyDeadline = ContinuousClock.now.advanced(by: .seconds(readinessBudget))
          while !renderer.isReadyForMoreMediaData, renderer.status != .failed,
            ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(2))
            guard self.epoch == id, !Task.isCancelled else { return }
          }
          guard renderer.status != .failed else {
            throw renderer.error ?? LiveDVDecodeError.noDecodedImage
          }
          self.primeAudioIfNeeded(frame)
          guard let pts = await self.prepareVideoPresentation(frame, epoch: id) else {
            guard self.epoch == id, !Task.isCancelled else { return }
            self.skippedPreviewFrames &+= 1; self.rendererSkippedFrames &+= 1
            self.retiredEpochSkips &+= 1
            continue // A retired audio epoch cannot publish a stale picture.
          }
          guard renderer.isReadyForMoreMediaData, self.permitsVideoSubmission() else {
            self.skippedPreviewFrames &+= 1
            self.rendererSkippedFrames &+= 1
            self.videoAdmissionSkips &+= 1
            self.signal.videoFailedToPresent()
            self.updateSignalState()
            continue
          }
          let widescreen = LiveDVMedia(frame: frame.bytes)?.widescreen
          if self.sourceWidescreen != widescreen { self.sourceWidescreen = widescreen }
          self.observeAppleGeometry(decoded)
          self.applyGeometry(decoded.pixelBuffer)
          var format: CMVideoFormatDescription?
          let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: decoded.pixelBuffer,
            formatDescriptionOut: &format)
          guard formatStatus == noErr, let format else {
            throw LiveDVDecodeError.nativeFailure("describe preview image", formatStatus)
          }
          let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(format,
            usePixelAspectRatio: true, useCleanAperture: true)
          let ratio = dimensions.width / dimensions.height
          if self.presentedAspectRatio != ratio { self.presentedAspectRatio = ratio }
          var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
          var sample: CMSampleBuffer?
          let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: decoded.pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
          guard status == noErr, let sample else {
            throw LiveDVDecodeError.nativeFailure("create preview image", status)
          }
          guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
              sample,
              createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first
          else {
            throw LiveDVDecodeError.noDecodedImage
          }
          first[kCMSampleAttachmentKey_DisplayImmediately as String] = false
          let leadMS = CMTimeGetSeconds(pts - self.audio.synchronizer.currentTime()) * 1000
          if leadMS.isFinite {
            self.minimumVideoLeadMilliseconds = min(self.minimumVideoLeadMilliseconds ?? leadMS, leadMS)
            if leadMS < 0 { self.lateVideoSubmissions &+= 1 }
          }
          renderer.enqueue(sample)
          // Optional thumbnail never gates the main preview or raw receive.
          if self.navigatorLayer.sampleBufferRenderer.isReadyForMoreMediaData {
            self.navigatorLayer.sampleBufferRenderer.enqueue(sample)
          }
          self.signal.videoSubmitted()
          self.updateSignalState()
          if !self.hasImage { self.hasImage = true }
          self.timedFacts.append((pts, decoded.timecode, decoded.sourceOrdinal))
          if self.timedFacts.count > 16 { self.timedFacts.removeFirst(self.timedFacts.count - 16) }
        } catch {
          guard self.epoch == id, !Task.isCancelled else { return }
          self.primeAudioIfNeeded(frame)
          self.error = String(describing: error)
          self.failedVideoFrames &+= 1
          self.skippedPreviewFrames &+= 1
          self.signal.videoFailedToPresent()
          self.updateSignalState()
          // No same-frame retries and no intake cancellation. DV frames are
          // independently decodable; reset for the next frame, keep the last
          // picture/timecode together, and keep playable audio queued.
          await self.decoder.reset()
          guard self.epoch == id, !Task.isCancelled else { return }
          if self.displayLayer.sampleBufferRenderer.status == .failed {
            self.discardedPresentationSchedules &+= UInt64(self.timedFacts.count)
            self.timedFacts = []
            await self.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
            await self.navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
          }
        }
      }
    }
  }

  private func applyGeometry(_ pixel: CVPixelBuffer) {
    let height = CVPixelBufferGetHeight(pixel)
    if rasterHeight != height { rasterHeight = height }
    // One owner of display aspect: MonitorVideoSurface stretches this full
    // square-pixel raster into the selected viewport. Do not also change PAR
    // on every incoming sample: that renegotiates native presentation geometry
    // while the SwiftUI viewport changes and can fit the picture a second time.
    // These are decoded preview attachments, never stored DV/source metadata.
    CVBufferRemoveAttachment(pixel, kCVImageBufferDisplayDimensionsKey)
    CVBufferSetAttachment(pixel, kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
              kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary,
      .shouldPropagate)
    CVBufferSetAttachment(pixel, kCVImageBufferCleanApertureKey,
      [kCVImageBufferCleanApertureWidthKey: CVPixelBufferGetWidth(pixel),
       kCVImageBufferCleanApertureHeightKey: height,
       kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
       kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary,
      .shouldPropagate)
  }

  func showFinalFrame(_ frame: LivePreservedFrame) async {
    epoch = UUID()
    task?.cancel(); task = nil; pending = []
    latestOffered = frame
    let id = epoch
    do {
      let decoded = try await decoder.decode(frame.bytes, ordinal: frame.ordinal, timecode: frame.timecode,
        viewingMode: viewingMode, extremeZebras: extremeZebras)
      guard epoch == id else { return }
      sourceWidescreen = LiveDVMedia(frame: frame.bytes)?.widescreen
      observeAppleGeometry(decoded, force: true)
      applyGeometry(decoded.pixelBuffer)
      await displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
      await navigatorLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
      guard epoch == id else { return }
      var format: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: decoded.pixelBuffer, formatDescriptionOut: &format)
      guard status == noErr, let format else { throw LiveDVDecodeError.noDecodedImage }
      let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(format,
        usePixelAspectRatio: true, useCleanAperture: true)
      presentedAspectRatio = dimensions.width / dimensions.height
      var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: decoded.pixelBuffer, formatDescription: format, sampleTiming: &timing,
        sampleBufferOut: &sample) == noErr, let sample else { throw LiveDVDecodeError.noDecodedImage }
      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
        let first = attachments.first else { throw LiveDVDecodeError.noDecodedImage }
      first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
      displayLayer.sampleBufferRenderer.enqueue(sample)
      navigatorLayer.sampleBufferRenderer.enqueue(sample)
      sourceTimecode = frame.timecode; latestSubmittedOrdinal = frame.ordinal; hasImage = true
    } catch { self.error = "Final preview: \(error)" }
  }
}
