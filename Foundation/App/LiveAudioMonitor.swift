// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine

/// One native presentation clock for live video, PCM and meters. Raw receive
/// ownership and storage never depend on a renderer being ready.
@MainActor final class LiveAudioMonitor: ObservableObject {
  @Published private(set) var detail = "Awaiting source audio"
  let synchronizer = AVSampleBufferRenderSynchronizer()
  private let renderer = AVSampleBufferAudioRenderer()
  private var meter = OfflineDVMonitorMeter.State()
  private var timeline = LivePresentationTimeline()
  private(set) var frameAccounting = LiveAudioFrameAccounting()
  private var nextAudioTime: Double?
  private var format: LiveDVMedia.Audio?
  private var stopped = true
  private(set) var skippedAudioFrames: UInt64 = 0
  private(set) var resynchronizations: UInt64 = 0
  private(set) var inputResumeResets: UInt64 = 0
  private(set) var timingResets: UInt64 = 0
  private(set) var sourceTimelineResets: UInt64 = 0
  private(set) var sourceAudioOffsetResets: UInt64 = 0
  private(set) var lastResynchronization = "none"
  private(set) var presentationEpoch: UInt64 = 0
  var deliveryGapFrames: UInt64 { frameAccounting.omittedBeforeAudio }
  var inputInterruptions: UInt64 { timeline.interruptions }
  private(set) var sampleConstructionFailures: UInt64 = 0
  private(set) var rendererFailureFrames: UInt64 = 0
  private(set) var timing = LiveAudioTiming()
  private(set) var formatChanges: UInt64 = 0
  private(set) var maximumPreparationMilliseconds = 0.0
  var timingDiagnostics: String {
    timing.diagnostics + "; audio_format_changes=\(formatChanges); audio_max_preparation_ms=\(maximumPreparationMilliseconds); audio_last_reset=\(lastResynchronization); audio_input_resume_resets=\(inputResumeResets); audio_timing_resets=\(timingResets); audio_source_timeline_resets=\(sourceTimelineResets); audio_source_offset_resets=\(sourceAudioOffsetResets); presentation_target_lead_ms=\(LivePresentationTimeline.presentationLead * 1000)"
  }

  init(video: AVSampleBufferVideoRenderer, muteAudio: Bool = false) {
    synchronizer.addRenderer(video)
    synchronizer.addRenderer(renderer)
    synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    renderer.isMuted = muteAudio
  }

  var presentation: OfflineDVMonitorMeter.Presentation {
    guard !stopped else { return .silence }
    return meter.presentation(at: CMTimeGetSeconds(synchronizer.currentTime()))
  }

  func begin() {
    presentationEpoch &+= 1
    renderer.flush()
    meter.reset()
    timeline = LivePresentationTimeline()
    frameAccounting = LiveAudioFrameAccounting()
    timing = LiveAudioTiming(); formatChanges = 0; maximumPreparationMilliseconds = 0
    nextAudioTime = nil
    format = nil
    skippedAudioFrames = 0
    sampleConstructionFailures = 0; rendererFailureFrames = 0
    resynchronizations = 0
    inputResumeResets = 0; timingResets = 0; sourceTimelineResets = 0; sourceAudioOffsetResets = 0
    lastResynchronization = "none"
    stopped = false
    detail = "Awaiting source audio"
    synchronizer.setRate(1, time: .zero)
  }

  func end() {
    stopped = true
    synchronizer.setRate(0, time: synchronizer.currentTime())
    renderer.flush()
    meter.reset()
    detail = "Audio monitor stopped"
  }

  /// Returns this frame's presentation time even if its audio is unknown/muted.
  func offer(_ bytes: Data, ordinal: UInt64) -> CMTime {
    guard !stopped else { return synchronizer.currentTime() }
    let now = CMTimeGetSeconds(synchronizer.currentTime())
    let media = LiveDVMedia(frame: bytes)
    let pal = media?.isPAL ?? (bytes.count == 144_000)
    let schedule = timeline.schedule(ordinal: ordinal, pal: pal, now: now)
    let time = schedule.seconds
    if let reason = schedule.resetReason {
      if reason == "preview_input_resumed" { inputResumeResets &+= 1 }
      else if reason == "source_timeline_reset" { sourceTimelineResets &+= 1 }
      else { timingResets &+= 1 }
      presentationEpoch &+= 1
      lastResynchronization = reason
      renderer.flush(); meter.reset(); nextAudioTime = nil
      timing.resetQueue()
      resynchronizations &+= 1
    }
    let pts = CMTime(seconds: time, preferredTimescale: 600000)
    let audio = media?.audio
    let pcm = media?.pcm16(frame: bytes)
    let source: LiveAudioFrameAccounting.SourceAudio = audio == nil ? .unknownFormat :
      (pcm == nil ? .unavailablePCM : .usable)
    if frameAccounting.observe(ordinal: ordinal, source: source) { nextAudioTime = nil }
    guard let audio, let pcm else {
      // Leave a correctly timed hole, without flushing preceding good PCM or
      // meter windows. Unknown/unusable source audio is not delivery loss.
      nextAudioTime = nil
      detail = audio == nil ? "Source audio format unknown or unsupported; raw DV retained" :
        "Source frame has no usable PCM; queued good audio retained"
      return pts
    }
    if format?.sampleRate != audio.sampleRate || format?.channelCount != audio.channelCount {
      if format != nil { formatChanges &+= 1 }
      renderer.flush(); meter.reset(); nextAudioTime = nil
      timing.resetQueue()
    }
    format = audio
    guard renderer.status != .failed else {
      rendererFailureFrames &+= 1
      renderer.flush(); meter.reset(); nextAudioTime = nil
      timing.resetQueue()
      detail = "Native audio renderer failed; reset for the next frame; raw DV retained"
      return pts
    }
    guard renderer.isReadyForMoreMediaData, renderer.status != .failed else {
      skippedAudioFrames &+= 1
      // A brief full renderer must not throw away already queued good audio.
      // Leave a presentation gap for this frame, then resume on source time.
      nextAudioTime = nil
      detail = "Audio monitor backpressure — raw DV preserved independently"
      return pts
    }
    var audioTime = nextAudioTime ?? time
    if abs(audioTime - time) > 0.050 {
      sourceAudioOffsetResets &+= 1
      lastResynchronization = "source_audio_video_offset_seconds=\(audioTime - time)"
      renderer.flush(); meter.reset(); audioTime = time
      timing.resetQueue()
      resynchronizations &+= 1
    }
    do {
      // Meter all four source channels. Speaker monitoring is the first stereo
      // pair, explicitly labeled; no implicit four-channel downmix.
      let speakerPCM: [Int16] = audio.channelCount == 2 ? pcm :
        stride(from: 0, to: pcm.count, by: 4).flatMap { [pcm[$0], pcm[$0 + 1]] }
      let sample = try Self.makePCM(speakerPCM, rate: audio.sampleRate, time: audioTime)
      try meter.ingestInterleavedPCM16(pcm, channelCount: audio.channelCount,
        sampleRate: Double(audio.sampleRate), startTime: audioTime, playbackTime: now)
      renderer.enqueue(sample)
      let submittedAt = CMTimeGetSeconds(synchronizer.currentTime())
      maximumPreparationMilliseconds = max(maximumPreparationMilliseconds, (submittedAt - now) * 1000)
      timing.observe(now: submittedAt, start: audioTime,
        duration: Double(audio.samplesPerChannel) / Double(audio.sampleRate))
      nextAudioTime = audioTime + Double(audio.samplesPerChannel) / Double(audio.sampleRate)
      let description = "\(audio.sampleRate.formatted()) Hz · \(audio.channelCount) source channels · monitoring 1–2"
      if detail != description { detail = description }
    } catch {
      sampleConstructionFailures &+= 1
      nextAudioTime = nil
      detail = "Audio monitor failed: \(error.localizedDescription)"
    }
    return pts
  }

  func observeInputIdle() {
    guard !stopped else { return }
    if timeline.observeIdle(now: CMTimeGetSeconds(synchronizer.currentTime())) {
      detail = "Waiting for preview input; last picture retained. Not a packet-loss diagnosis."
    }
  }

  private static func makePCM(_ pcm: [Int16], rate: Int, time: Double) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate),
      mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
      mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
      extensions: nil, formatDescriptionOut: &format))
    var block: CMBlockBuffer?
    try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: pcm.count * 2, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: pcm.count * 2, flags: 0, blockBufferOut: &block))
    guard let block, let format else { throw LiveDVDecodeError.malformedFrame }
    try pcm.withUnsafeBytes {
      try check(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: $0.count))
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
      presentationTimeStamp: CMTime(seconds: time, preferredTimescale: Int32(rate)), decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
      dataBuffer: block, formatDescription: format, sampleCount: pcm.count / 2,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
    guard let sample else { throw LiveDVDecodeError.malformedFrame }
    return sample
  }

  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw LiveDVDecodeError.nativeFailure("live PCM", status) }
  }
}
