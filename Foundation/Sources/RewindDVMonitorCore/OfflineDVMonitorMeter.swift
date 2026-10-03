import Foundation

/// Presentation-only measurements of decoded monitor PCM. Meter state never
/// participates in capture, verification, archival evidence, or deck control.
public enum OfflineDVMonitorMeter {
  public static let maximumChannels = 4
  public static let analysisFloorDBFS = -96.0
  public static let displayFloorDBFS = -60.0
  public static let peakHoldSeconds = 1.25
  public static let clipHoldSeconds = 1.25
  public static let releaseDecibelsPerSecond = 96.0
  public static let analysisWindowSeconds = 0.005
  public static let staleAfterSeconds = 0.100
  public static let retainedPastSeconds = 1.500
  public static let retainedFutureSeconds = 0.500

  /// Every displayed row is an exact one-dBFS threshold, inclusive of both rails.
  public static let segmentValuesDBFS = Array(-60...0).map(Double.init)
  public static let scaleLabelValuesDBFS = [0, -3, -6, -12, -18, -24, -36, -48, -60].map(
    Double.init)

  public static func scaleLabelText(forDBFS value: Double) -> String {
    guard let index = segmentIndex(forDBFS: value) else { return "" }
    return String(Int(segmentValuesDBFS[index]))
  }

  /// Screen-space mapping: 0 dBFS is 0 and -60 dBFS is 1.
  public static func verticalFraction(forDBFS decibels: Double) -> Double {
    guard decibels.isFinite else { return 1 }
    let clamped = min(0, max(displayFloorDBFS, decibels))
    return -clamped / -displayFloorDBFS
  }

  public static func segmentIndex(forDBFS decibels: Double) -> Int? {
    guard decibels.isFinite,
      decibels.rounded(.towardZero) == decibels,
      decibels >= displayFloorDBFS,
      decibels <= 0
    else { return nil }
    return Int(decibels - displayFloorDBFS)
  }

  /// Screen-space center: 0 dBFS is 0 and -60 dBFS is 1.
  public static func segmentCenterFraction(forDBFS decibels: Double) -> Double? {
    guard let index = segmentIndex(forDBFS: decibels) else { return nil }
    return Double(segmentValuesDBFS.count - 1 - index) / Double(segmentValuesDBFS.count - 1)
  }

  public struct Channel: Equatable, Sendable {
    public let peakDBFS: Double
    public let rmsDBFS: Double
    public let isClipping: Bool

    public init(peakDBFS: Double, rmsDBFS: Double, isClipping: Bool) {
      self.peakDBFS = peakDBFS
      self.rmsDBFS = rmsDBFS
      self.isClipping = isClipping
    }

    public static let silence = Channel(
      peakDBFS: analysisFloorDBFS,
      rmsDBFS: analysisFloorDBFS,
      isClipping: false
    )
  }

  public struct Levels: Equatable, Sendable {
    public let channels: [Channel]

    public init(channels: [Channel]) {
      self.channels = Array(channels.prefix(maximumChannels))
    }

    public static let silence = Levels(channels: [])
  }

  public struct PresentedChannel: Equatable, Sendable {
    public let active: Bool
    public let peakDBFS: Double
    public let rmsDBFS: Double
    public let heldPeakDBFS: Double
    public let isClipping: Bool

    public init(
      active: Bool,
      peakDBFS: Double,
      rmsDBFS: Double,
      heldPeakDBFS: Double,
      isClipping: Bool
    ) {
      self.active = active
      self.peakDBFS = peakDBFS
      self.rmsDBFS = rmsDBFS
      self.heldPeakDBFS = heldPeakDBFS
      self.isClipping = isClipping
    }

    public static let inactive = PresentedChannel(
      active: false,
      peakDBFS: analysisFloorDBFS,
      rmsDBFS: analysisFloorDBFS,
      heldPeakDBFS: analysisFloorDBFS,
      isClipping: false
    )
  }

  public struct Presentation: Equatable, Sendable {
    public let channels: [PresentedChannel]

    public init(channels: [PresentedChannel]) {
      let retained = Array(channels.prefix(maximumChannels))
      self.channels =
        retained + Array(repeating: .inactive, count: maximumChannels - retained.count)
    }

    public static let silence = Presentation(channels: [])

    public func channel(at index: Int) -> PresentedChannel {
      channels.indices.contains(index) ? channels[index] : .inactive
    }
  }

  public struct PCMFormat: Equatable, Sendable {
    public let channelCount: Int
    public let sampleRate: Double

    public init(channelCount: Int, sampleRate: Double) {
      self.channelCount = channelCount
      self.sampleRate = sampleRate
    }
  }

  public enum InputError: Error, Equatable, Sendable {
    case unsupportedChannelCount(Int)
    case invalidSampleRate(Double)
    case nonFrameAlignedSampleCount(sampleCount: Int, channelCount: Int)
    case nonFiniteTime
    case timeRangeOverflow
    case overlappingOrOutOfOrderSource(previousEndTime: Double, incomingStartTime: Double)
    case excessivelyFragmentedTimeline(maximumWindows: Int)
  }

  public enum ResetReason: Equatable, Sendable {
    case formatChanged(previous: PCMFormat, current: PCMFormat)
    case playbackMovedBackward(previous: Double, current: Double)
    case explicitDiscontinuity
  }

  public struct IngestReport: Equatable, Sendable {
    public let acceptedFrames: Int
    public let discardedPastFrames: Int
    public let discardedFutureFrames: Int
    public let resetReason: ResetReason?

    public init(
      acceptedFrames: Int,
      discardedPastFrames: Int,
      discardedFutureFrames: Int,
      resetReason: ResetReason?
    ) {
      self.acceptedFrames = acceptedFrames
      self.discardedPastFrames = discardedPastFrames
      self.discardedFutureFrames = discardedFutureFrames
      self.resetReason = resetReason
    }
  }

  /// Computes per-channel sample peak and RMS with the signed PCM16 scale
  /// denominator of 32768. Clipping remains an independent rail indicator,
  /// so +32767 clips even though its numerical level is just below 0 dBFS.
  public static func levels(forInterleavedPCM16 samples: [Int16], channelCount: Int) throws
    -> Levels
  {
    try validateChannelCount(channelCount)
    guard samples.count.isMultiple(of: channelCount) else {
      throw InputError.nonFrameAlignedSampleCount(
        sampleCount: samples.count, channelCount: channelCount)
    }
    guard !samples.isEmpty else {
      return Levels(channels: Array(repeating: .silence, count: channelCount))
    }

    var accumulators = Array(repeating: Accumulator(), count: channelCount)
    for (sampleIndex, sample) in samples.enumerated() {
      accumulators[sampleIndex % channelCount].append(sample)
    }
    return Levels(channels: accumulators.map(\.channel))
  }

  public static func segmentIsLit(thresholdDBFS: Double, peakDBFS: Double, active: Bool) -> Bool {
    active && thresholdDBFS.isFinite && peakDBFS.isFinite && peakDBFS >= thresholdDBFS
  }

  /// Bounded, source-timestamped state for a playback meter. Ingest may be a
  /// little ahead of playback, but presentation only analyzes frames at or
  /// behind the requested playback time.
  public struct State: Sendable {
    private var windows: [PCMWindow] = []
    private var format: PCMFormat?
    private var lastPlaybackTime: Double?
    private var sourceTimeOrigin: Double?
    private var sourceFrameCursor = 0
    public private(set) var currentPresentation: Presentation = .silence

    public init() {}

    /// Consecutive chunks may contain any positive frame count. A start
    /// timestamp within half a sample of the preceding exclusive end is
    /// snapped to the stable source sample grid and coalesced. A true
    /// overlap/out-of-order chunk, or too many discontinuous fragments,
    /// clears state and throws rather than silently shortening meter holds.
    @discardableResult
    public mutating func ingestInterleavedPCM16(
      _ samples: [Int16],
      channelCount: Int,
      sampleRate: Double,
      startTime: Double,
      playbackTime: Double
    ) throws -> IngestReport {
      try Self.validateInput(
        samples: samples,
        channelCount: channelCount,
        sampleRate: sampleRate,
        startTime: startTime,
        playbackTime: playbackTime
      )

      let incomingFormat = PCMFormat(channelCount: channelCount, sampleRate: sampleRate)
      var resetReason = synchronize(to: playbackTime)
      if let format, format != incomingFormat {
        clearHistory(keepingPlaybackTime: playbackTime)
        resetReason = .formatChanged(previous: format, current: incomingFormat)
      }
      format = incomingFormat

      let totalFrames = samples.count / channelCount
      guard totalFrames > 0 else {
        return IngestReport(
          acceptedFrames: 0,
          discardedPastFrames: 0,
          discardedFutureFrames: 0,
          resetReason: resetReason
        )
      }

      let continuityTolerance = 0.5 / sampleRate
      var effectiveStartTime = startTime
      var nextSourceTimeOrigin = startTime
      var nextSourceFrameCursor = totalFrames
      if let sourceTimeOrigin {
        let previousEnd = sourceTimeOrigin + Double(sourceFrameCursor) / sampleRate
        guard startTime >= previousEnd - continuityTolerance else {
          clearHistory(keepingPlaybackTime: playbackTime)
          throw InputError.overlappingOrOutOfOrderSource(
            previousEndTime: previousEnd,
            incomingStartTime: startTime
          )
        }
        if abs(startTime - previousEnd) <= continuityTolerance {
          let advancedCursor = sourceFrameCursor.addingReportingOverflow(totalFrames)
          guard !advancedCursor.overflow else { throw InputError.timeRangeOverflow }
          effectiveStartTime = previousEnd
          nextSourceTimeOrigin = sourceTimeOrigin
          nextSourceFrameCursor = advancedCursor.partialValue
        }
      }

      let duration = Double(totalFrames) / sampleRate
      let endTime = effectiveStartTime + duration
      guard endTime.isFinite else { throw InputError.timeRangeOverflow }

      let pastCutoff = playbackTime - retainedPastSeconds
      let futureCutoff = playbackTime + retainedFutureSeconds
      let firstFrame = clampedFrameIndex(
        ((pastCutoff - effectiveStartTime) * sampleRate).rounded(.down),
        upperBound: totalFrames
      )
      let lastFrame = clampedFrameIndex(
        ((futureCutoff - effectiveStartTime) * sampleRate).rounded(.up),
        upperBound: totalFrames
      )
      let retainedRange = min(firstFrame, lastFrame)..<max(firstFrame, lastFrame)
      let discardedPast = retainedRange.lowerBound
      let discardedFuture = totalFrames - retainedRange.upperBound

      if !retainedRange.isEmpty {
        let framesPerWindow = max(1, Int((analysisWindowSeconds * sampleRate).rounded(.down)))
        var frame = retainedRange.lowerBound
        while frame < retainedRange.upperBound {
          let frameTime = effectiveStartTime + Double(frame) / sampleRate
          if let last = windows.last,
            last.channelCount == channelCount,
            last.sampleRate == sampleRate,
            last.frameCount < framesPerWindow,
            abs(last.endTime - frameTime) <= continuityTolerance
          {
            let appendedFrameCount = min(
              framesPerWindow - last.frameCount,
              retainedRange.upperBound - frame
            )
            let appendedSampleRange =
              (frame * channelCount)..<((frame + appendedFrameCount) * channelCount)
            let combinedSamples = last.samples + samples[appendedSampleRange]
            windows[windows.count - 1] = try PCMWindow(
              startTime: last.startTime,
              sampleRate: sampleRate,
              channelCount: channelCount,
              samples: combinedSamples
            )
            frame += appendedFrameCount
          } else {
            let windowEnd = min(frame + framesPerWindow, retainedRange.upperBound)
            let sampleRange = (frame * channelCount)..<(windowEnd * channelCount)
            windows.append(
              try PCMWindow(
                startTime: frameTime,
                sampleRate: sampleRate,
                channelCount: channelCount,
                samples: Array(samples[sampleRange])
              ))
            frame = windowEnd
          }
        }
      }

      prune(around: playbackTime)
      let maximumWindowCount = Self.maximumWindowCount
      guard windows.count <= maximumWindowCount else {
        clearHistory(keepingPlaybackTime: playbackTime)
        throw InputError.excessivelyFragmentedTimeline(maximumWindows: maximumWindowCount)
      }
      sourceTimeOrigin = nextSourceTimeOrigin
      sourceFrameCursor = nextSourceFrameCursor
      return IngestReport(
        acceptedFrames: retainedRange.count,
        discardedPastFrames: discardedPast,
        discardedFutureFrames: discardedFuture,
        resetReason: resetReason
      )
    }

    /// Computes the snapshot for the actual synchronizer time. A backward
    /// time jump is treated as a seek and clears pre-seek holds immediately.
    public mutating func presentation(at playbackTime: Double) -> Presentation {
      guard playbackTime.isFinite else {
        reset()
        return .silence
      }
      if synchronize(to: playbackTime) != nil {
        return .silence
      }
      prune(around: playbackTime)

      let events = windows.compactMap { $0.event(at: playbackTime) }
      guard let newest = events.last,
        playbackTime - newest.time <= staleAfterSeconds
      else {
        currentPresentation = .silence
        return currentPresentation
      }

      let activeChannels = newest.levels.channels.count
      var channels: [PresentedChannel] = []
      for channelIndex in 0..<maximumChannels {
        guard channelIndex < activeChannels else {
          channels.append(.inactive)
          continue
        }

        let channelEvents = events.compactMap { event -> (Double, Channel)? in
          guard event.levels.channels.indices.contains(channelIndex) else { return nil }
          return (event.time, event.levels.channels[channelIndex])
        }
        let current = newest.levels.channels[channelIndex]
        let releasedPeak = channelEvents.reduce(analysisFloorDBFS) { result, event in
          let decayed = event.1.peakDBFS - releaseDecibelsPerSecond * max(0, playbackTime - event.0)
          return max(result, max(analysisFloorDBFS, decayed))
        }
        let holdStart = playbackTime - peakHoldSeconds
        let heldPeak =
          channelEvents.lazy
          .filter { $0.0 >= holdStart }
          .map { $0.1.peakDBFS }
          .max() ?? analysisFloorDBFS
        let clipStart = playbackTime - clipHoldSeconds
        let clipping = channelEvents.contains { $0.0 >= clipStart && $0.1.isClipping }

        channels.append(
          PresentedChannel(
            active: true,
            peakDBFS: releasedPeak,
            rmsDBFS: current.rmsDBFS,
            heldPeakDBFS: heldPeak,
            isClipping: clipping
          ))
      }

      currentPresentation = Presentation(channels: channels)
      return currentPresentation
    }

    /// Explicit seek/discontinuity boundary. Old peak and clip holds cannot
    /// cross it, even when the new time is numerically close to the old time.
    public mutating func seek(to playbackTime: Double) {
      clearHistory(keepingPlaybackTime: playbackTime.isFinite ? playbackTime : nil)
    }

    public mutating func reset() {
      windows.removeAll(keepingCapacity: true)
      format = nil
      lastPlaybackTime = nil
      sourceTimeOrigin = nil
      sourceFrameCursor = 0
      currentPresentation = .silence
    }

    private mutating func synchronize(to playbackTime: Double) -> ResetReason? {
      defer { lastPlaybackTime = playbackTime }
      guard let previous = lastPlaybackTime,
        playbackTime + (1.0 / 1_000_000.0) < previous
      else { return nil }
      clearHistory(keepingPlaybackTime: playbackTime)
      return .playbackMovedBackward(previous: previous, current: playbackTime)
    }

    private mutating func clearHistory(keepingPlaybackTime playbackTime: Double?) {
      windows.removeAll(keepingCapacity: true)
      format = nil
      lastPlaybackTime = playbackTime
      sourceTimeOrigin = nil
      sourceFrameCursor = 0
      currentPresentation = .silence
    }

    private mutating func prune(around playbackTime: Double) {
      let lowerBound = playbackTime - retainedPastSeconds
      let upperBound = playbackTime + retainedFutureSeconds
      windows.removeAll { $0.endTime < lowerBound || $0.startTime > upperBound }
    }

    private static let maximumWindowCount =
      Int(
        ((retainedPastSeconds + retainedFutureSeconds) / analysisWindowSeconds).rounded(.up)
      ) + 4

    private static func validateInput(
      samples: [Int16],
      channelCount: Int,
      sampleRate: Double,
      startTime: Double,
      playbackTime: Double
    ) throws {
      try validateChannelCount(channelCount)
      guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000 else {
        throw InputError.invalidSampleRate(sampleRate)
      }
      guard samples.count.isMultiple(of: channelCount) else {
        throw InputError.nonFrameAlignedSampleCount(
          sampleCount: samples.count,
          channelCount: channelCount
        )
      }
      guard startTime.isFinite, playbackTime.isFinite else { throw InputError.nonFiniteTime }
    }
  }

  private struct TimedLevels: Sendable {
    let time: Double
    let levels: Levels
  }

  private struct PCMWindow: Sendable {
    let startTime: Double
    let sampleRate: Double
    let channelCount: Int
    let samples: [Int16]
    let fullLevels: Levels

    init(startTime: Double, sampleRate: Double, channelCount: Int, samples: [Int16]) throws {
      self.startTime = startTime
      self.sampleRate = sampleRate
      self.channelCount = channelCount
      self.samples = samples
      fullLevels = try OfflineDVMonitorMeter.levels(
        forInterleavedPCM16: samples,
        channelCount: channelCount
      )
    }

    var frameCount: Int { samples.count / channelCount }
    var endTime: Double { startTime + Double(frameCount) / sampleRate }

    func event(at playbackTime: Double) -> TimedLevels? {
      guard playbackTime >= startTime, frameCount > 0 else { return nil }
      let lastFrameTime = startTime + Double(frameCount - 1) / sampleRate
      if playbackTime >= lastFrameTime {
        return TimedLevels(time: lastFrameTime, levels: fullLevels)
      }
      let elapsedFrames = ((playbackTime - startTime) * sampleRate).rounded(.down)
      let playedFrames = min(
        frameCount, max(0, clampedFrameIndex(elapsedFrames, upperBound: frameCount) + 1))
      guard playedFrames > 0 else { return nil }
      let playedSamples = Array(samples.prefix(playedFrames * channelCount))
      guard
        let levels = try? OfflineDVMonitorMeter.levels(
          forInterleavedPCM16: playedSamples,
          channelCount: channelCount
        )
      else { return nil }
      // A frame is presented at its source timestamp. `endTime` is the
      // exclusive range end and would extend hold/release by one frame.
      let eventTime = startTime + Double(playedFrames - 1) / sampleRate
      return TimedLevels(time: min(playbackTime, eventTime), levels: levels)
    }
  }

  private struct Accumulator {
    var peak = 0.0
    var squares = 0.0
    var count = 0
    var clipping = false

    mutating func append(_ sample: Int16) {
      let linear = abs(Double(sample) / 32_768.0)
      peak = max(peak, linear)
      squares += linear * linear
      count += 1
      clipping = clipping || sample == .min || sample == .max
    }

    var channel: Channel {
      guard count > 0 else { return .silence }
      return Channel(
        peakDBFS: decibels(peak),
        rmsDBFS: decibels((squares / Double(count)).squareRoot()),
        isClipping: clipping
      )
    }
  }

  private static func validateChannelCount(_ channelCount: Int) throws {
    guard channelCount == 1 || channelCount == 2 || channelCount == 4 else {
      throw InputError.unsupportedChannelCount(channelCount)
    }
  }

  private static func decibels(_ linear: Double) -> Double {
    guard linear.isFinite, linear > 0 else { return analysisFloorDBFS }
    return max(analysisFloorDBFS, min(0, 20 * log10(linear)))
  }

  private static func clampedFrameIndex(_ value: Double, upperBound: Int) -> Int {
    guard value.isFinite else { return value.sign == .minus ? 0 : upperBound }
    if value <= 0 { return 0 }
    if value >= Double(upperBound) { return upperBound }
    return Int(value)
  }
}
