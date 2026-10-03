import Foundation
import Testing

@testable import RewindDVMonitorCore

@Suite("Offline DV monitor meter")
struct OfflineDVMonitorMeterTests {
  @Test("Threshold geometry is exact and finite-safe")
  func thresholdGeometry() {
    #expect(OfflineDVMonitorMeter.segmentValuesDBFS == Array(-60...0).map(Double.init))
    #expect(OfflineDVMonitorMeter.segmentValuesDBFS.count == 61)
    #expect(OfflineDVMonitorMeter.verticalFraction(forDBFS: -60) == 1)
    #expect(OfflineDVMonitorMeter.verticalFraction(forDBFS: 0) == 0)
    #expect(OfflineDVMonitorMeter.verticalFraction(forDBFS: -.infinity) == 1)
    #expect(OfflineDVMonitorMeter.verticalFraction(forDBFS: .nan) == 1)
    #expect(OfflineDVMonitorMeter.segmentIndex(forDBFS: -60) == 0)
    #expect(OfflineDVMonitorMeter.segmentIndex(forDBFS: 0) == 60)
    #expect(OfflineDVMonitorMeter.segmentIndex(forDBFS: -3.5) == nil)
    #expect(OfflineDVMonitorMeter.segmentIndex(forDBFS: .nan) == nil)
  }

  @Test("PCM16 rails retain signed asymmetry while both clip")
  func pcm16Rails() throws {
    let positive = try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [.max], channelCount: 1)
    let negative = try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [.min], channelCount: 1)
    let positiveRailDBFS = 20 * log10(32_767.0 / 32_768.0)
    #expect(abs(positive.channels[0].peakDBFS - positiveRailDBFS) < 1e-12)
    #expect(negative.channels[0].peakDBFS == 0)
    #expect(abs(positive.channels[0].rmsDBFS - positiveRailDBFS) < 1e-12)
    #expect(negative.channels[0].rmsDBFS == 0)
    #expect(positive.channels[0].isClipping)
    #expect(negative.channels[0].isClipping)
  }

  @Test("Positive and negative half scale are exactly equal")
  func symmetricHalfScale() throws {
    let positive = try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [16_384], channelCount: 1)
    let negative = try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [-16_384], channelCount: 1)
    let halfScaleDBFS = -6.020599913279624
    #expect(abs(positive.channels[0].peakDBFS - halfScaleDBFS) < 1e-12)
    #expect(abs(negative.channels[0].peakDBFS - halfScaleDBFS) < 1e-12)
    #expect(positive.channels[0].peakDBFS == negative.channels[0].peakDBFS)
    #expect(positive.channels[0].rmsDBFS == negative.channels[0].rmsDBFS)
    #expect(!positive.channels[0].isClipping)
    #expect(!negative.channels[0].isClipping)
  }

  @Test("Quarter-cycle half-scale sine has independent RMS")
  func sineRMS() throws {
    let levels = try OfflineDVMonitorMeter.levels(
      forInterleavedPCM16: [16_384, 0, -16_384, 0],
      channelCount: 1
    )
    #expect(abs(levels.channels[0].peakDBFS - -6.020599913279624) < 1e-12)
    #expect(abs(levels.channels[0].rmsDBFS - -9.030899869919436) < 1e-12)
    #expect(!levels.channels[0].isClipping)
  }

  @Test("Peak and RMS remain distinct")
  func peakAndRMS() throws {
    let positiveRailDBFS = 20 * log10(32_767.0 / 32_768.0)
    let levels = try OfflineDVMonitorMeter.levels(
      forInterleavedPCM16: [.max, 0, 0, 0],
      channelCount: 1
    )
    #expect(abs(levels.channels[0].peakDBFS - positiveRailDBFS) < 1e-12)
    #expect(abs(levels.channels[0].rmsDBFS - (positiveRailDBFS - 6.020599913279624)) < 1e-12)
  }

  @Test(arguments: [1, 2, 4])
  func supportedChannelLayouts(channelCount: Int) throws {
    let samples = Array(repeating: Int16(8_192), count: channelCount * 8)
    let levels = try OfflineDVMonitorMeter.levels(
      forInterleavedPCM16: samples,
      channelCount: channelCount
    )
    #expect(levels.channels.count == channelCount)
  }

  @Test("Malformed formats fail without trapping")
  func malformedInput() {
    #expect(throws: OfflineDVMonitorMeter.InputError.unsupportedChannelCount(3)) {
      try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [0, 0, 0], channelCount: 3)
    }
    #expect(
      throws: OfflineDVMonitorMeter.InputError.nonFrameAlignedSampleCount(
        sampleCount: 3, channelCount: 2)
    ) {
      try OfflineDVMonitorMeter.levels(forInterleavedPCM16: [0, 0, 0], channelCount: 2)
    }
    var state = OfflineDVMonitorMeter.State()
    do {
      try state.ingestInterleavedPCM16(
        [0], channelCount: 1, sampleRate: .nan, startTime: 0, playbackTime: 0)
      Issue.record("Expected NaN sample rate to be rejected")
    } catch let error as OfflineDVMonitorMeter.InputError {
      guard case .invalidSampleRate(let value) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(value.isNaN)
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
    #expect(throws: OfflineDVMonitorMeter.InputError.nonFiniteTime) {
      try state.ingestInterleavedPCM16(
        [0], channelCount: 1, sampleRate: 48_000, startTime: .infinity, playbackTime: 0)
    }
  }

  @Test("Future samples cannot light the meter early")
  func noAheadOfPlaybackPeak() throws {
    var samples = Array(repeating: Int16(0), count: 480)
    samples[479] = .max
    var state = OfflineDVMonitorMeter.State()
    _ = try state.ingestInterleavedPCM16(
      samples,
      channelCount: 1,
      sampleRate: 48_000,
      startTime: 10,
      playbackTime: 10
    )

    let beforePeak = state.presentation(at: 10.005)
    #expect(beforePeak.channel(at: 0).peakDBFS == OfflineDVMonitorMeter.analysisFloorDBFS)
    #expect(!beforePeak.channel(at: 0).isClipping)

    let atPeak = state.presentation(at: 10 + 479.0 / 48_000.0)
    #expect(abs(atPeak.channel(at: 0).peakDBFS - 20 * log10(32_767.0 / 32_768.0)) < 1e-12)
    #expect(atPeak.channel(at: 0).isClipping)
  }

  @Test("Hold and release use playback time and pause naturally freezes")
  func holdAndRelease() throws {
    var state = OfflineDVMonitorMeter.State()
    var samples = Array(repeating: Int16(0), count: 51)
    samples[0] = .max
    _ = try state.ingestInterleavedPCM16(
      samples,
      channelCount: 1,
      sampleRate: 100,
      startTime: 0,
      playbackTime: 0
    )

    let initial = state.presentation(at: 0)
    let paused = state.presentation(at: 0)
    let positiveRailDBFS = 20 * log10(32_767.0 / 32_768.0)
    #expect(initial == paused)
    #expect(abs(initial.channel(at: 0).peakDBFS - positiveRailDBFS) < 1e-12)

    let released = state.presentation(at: 0.5)
    #expect(abs(released.channel(at: 0).peakDBFS - (positiveRailDBFS - 48)) < 1e-12)
    #expect(abs(released.channel(at: 0).heldPeakDBFS - positiveRailDBFS) < 1e-12)

    let expired = state.presentation(at: 1.3)
    #expect(expired.channel(at: 0).heldPeakDBFS == OfflineDVMonitorMeter.analysisFloorDBFS)
    #expect(!expired.channel(at: 0).isClipping)
  }

  @Test("Stale source becomes inactive silence")
  func staleSource() throws {
    var state = OfflineDVMonitorMeter.State()
    _ = try state.ingestInterleavedPCM16(
      [1_000], channelCount: 1, sampleRate: 100, startTime: 0, playbackTime: 0)
    #expect(state.presentation(at: 0).channel(at: 0).active)
    #expect(!state.presentation(at: 0.2).channel(at: 0).active)
  }

  @Test("Seek and backward discontinuity clear hold state")
  func discontinuities() throws {
    var state = OfflineDVMonitorMeter.State()
    _ = try state.ingestInterleavedPCM16(
      [.max], channelCount: 1, sampleRate: 100, startTime: 1, playbackTime: 1)
    #expect(state.presentation(at: 1).channel(at: 0).isClipping)

    state.seek(to: 1.01)
    #expect(!state.presentation(at: 1.01).channel(at: 0).active)

    _ = try state.ingestInterleavedPCM16(
      [.max], channelCount: 1, sampleRate: 100, startTime: 2, playbackTime: 2)
    #expect(state.presentation(at: 2).channel(at: 0).isClipping)
    #expect(!state.presentation(at: 1.5).channel(at: 0).active)
  }

  @Test("Format changes reset and report the conflict")
  func formatChange() throws {
    var state = OfflineDVMonitorMeter.State()
    _ = try state.ingestInterleavedPCM16(
      [.max], channelCount: 1, sampleRate: 48_000, startTime: 0, playbackTime: 0)
    let report = try state.ingestInterleavedPCM16(
      [0, 0],
      channelCount: 2,
      sampleRate: 48_000,
      startTime: 0,
      playbackTime: 0
    )
    #expect(
      report.resetReason
        == .formatChanged(
          previous: .init(channelCount: 1, sampleRate: 48_000),
          current: .init(channelCount: 2, sampleRate: 48_000)
        ))
    let presentation = state.presentation(at: 0)
    #expect(presentation.channel(at: 0).active)
    #expect(presentation.channel(at: 1).active)
    #expect(!presentation.channel(at: 2).active)
  }

  @Test("Huge decoded spans retain only the bounded playback neighborhood")
  func boundedIngest() throws {
    let frames = 48_000 * 10
    var state = OfflineDVMonitorMeter.State()
    let report = try state.ingestInterleavedPCM16(
      Array(repeating: 0, count: frames),
      channelCount: 1,
      sampleRate: 48_000,
      startTime: 0,
      playbackTime: 5
    )
    #expect(report.acceptedFrames <= 48_000 * 2 + 1)
    #expect(report.discardedPastFrames > 0)
    #expect(report.discardedFutureFrames > 0)
  }

  @Test("One-sample 48 kHz chunks equal one buffer without losing hold history")
  func oneSampleFragmentationMatchesWholeBuffer() throws {
    let sampleRate = 48_000.0
    let frameCount = 12_000
    var samples = Array(repeating: Int16(0), count: frameCount)
    samples[0] = .min
    samples[4_799] = 16_384

    let finalTime = Double(frameCount - 1) / sampleRate
    var whole = OfflineDVMonitorMeter.State()
    _ = try whole.ingestInterleavedPCM16(
      samples,
      channelCount: 1,
      sampleRate: sampleRate,
      startTime: 0,
      playbackTime: finalTime
    )

    var fragmented = OfflineDVMonitorMeter.State()
    for frame in samples.indices {
      let frameTime = Double(frame) / sampleRate
      _ = try fragmented.ingestInterleavedPCM16(
        [samples[frame]],
        channelCount: 1,
        sampleRate: sampleRate,
        startTime: frameTime,
        playbackTime: frameTime
      )
    }

    #expect(fragmented.presentation(at: finalTime) == whole.presentation(at: finalTime))
  }

  @Test("Partial overlap fails closed and clears prior holds")
  func partialOverlapFailsClosed() throws {
    var state = OfflineDVMonitorMeter.State()
    _ = try state.ingestInterleavedPCM16(
      Array(repeating: .max, count: 480),
      channelCount: 1,
      sampleRate: 48_000,
      startTime: 0,
      playbackTime: 0
    )

    do {
      _ = try state.ingestInterleavedPCM16(
        [0],
        channelCount: 1,
        sampleRate: 48_000,
        startTime: 0.005,
        playbackTime: 0.005
      )
      Issue.record("Expected overlapping source to be rejected")
    } catch let error as OfflineDVMonitorMeter.InputError {
      guard case .overlappingOrOutOfOrderSource(let previousEnd, let incomingStart) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(abs(previousEnd - 0.010) < 1e-12)
      #expect(incomingStart == 0.005)
    }
    #expect(!state.presentation(at: 0.005).channel(at: 0).active)
  }

  @Test("Discontinuous fragmentation fails closed instead of evicting history")
  func excessiveFragmentationFailsClosed() throws {
    var state = OfflineDVMonitorMeter.State()
    var rejected = false
    for frame in 0..<405 {
      do {
        _ = try state.ingestInterleavedPCM16(
          [1],
          channelCount: 1,
          sampleRate: 48_000,
          startTime: Double(frame * 2) / 48_000.0,
          playbackTime: 0
        )
      } catch let error as OfflineDVMonitorMeter.InputError {
        guard case .excessivelyFragmentedTimeline(maximumWindows: 404) = error else {
          Issue.record("Unexpected error: \(error)")
          return
        }
        rejected = true
        break
      }
    }
    #expect(rejected)
    #expect(!state.presentation(at: 0).channel(at: 0).active)
  }
}
