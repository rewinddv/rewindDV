// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import Foundation
struct MeterBank: View {
  let presentation: OfflineDVMonitorMeter.Presentation
  // Optional offscreen layout instrumentation; absent in the shipping workspace.
  var observeRailFrame: ((Int, CGRect) -> Void)? = nil
  private let height: CGFloat = 244
  var body: some View {
    VStack(spacing: 9) {
      HStack(alignment: .top, spacing: 6) {
        ZStack(alignment: .topLeading) {
          ForEach(OfflineDVMonitorMeter.scaleLabelValuesDBFS, id: \.self) { mark in
            Text(String(Int(mark))).font(.system(size: 9, design: .monospaced))
              .frame(width: 26, height: 12, alignment: .trailing)
              .position(
                x: 13, y: 2 + (height - 4) * OfflineDVMonitorMeter.verticalFraction(forDBFS: mark))
          }
        }.frame(width: 28, height: height).foregroundStyle(.secondary).padding(.top, 19)
        ForEach(0..<4) { index in
          let channel = presentation.channel(at: index)
          VStack(spacing: 7) {
            Text(channel.isClipping ? "CLIP" : "\(index + 1)")
              .font(.system(size: 9, weight: .bold, design: .monospaced))
              .foregroundStyle(channel.isClipping ? .red : .secondary).frame(height: 12)
            MeterRail(channel: channel).frame(width: 24, height: height)
              .background {
                if let observeRailFrame {
                  GeometryReader { geometry in
                    Color.clear.onAppear { observeRailFrame(index, geometry.frame(in: .named("meter-bank"))) }
                      .onChange(of: geometry.frame(in: .named("meter-bank"))) { _, frame in observeRailFrame(index, frame) }
                  }
                }
              }
            Text(readout(channel.peakDBFS, active: channel.active)).font(
              .system(size: 9, design: .monospaced))
            Text(readout(channel.rmsDBFS, active: channel.active)).font(
              .system(size: 9, design: .monospaced))
          }
          // Reserve the full numeric/CLIP width even when idle displays a dash.
          // Intrinsic Text widths must never move a channel's rail horizontally.
          .frame(width: 32)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Audio channel \(index + 1)")
          .accessibilityValue(
            channel.active
              ? "Peak \(readout(channel.peakDBFS, active: true)) dBFS, RMS \(readout(channel.rmsDBFS, active: true)) dBFS\(channel.isClipping ? ", sample clipping" : "")"
              : "No current PCM measurements")
        }
      }
      HStack {
        Text("dBFS")
        Spacer()
        Text("Peak / RMS")
      }.font(.caption2).foregroundStyle(.secondary)
    }.frame(width: 180, alignment: .leading).coordinateSpace(name: "meter-bank").transaction { $0.animation = nil }
  }
  private func readout(_ value: Double, active: Bool) -> String {
    guard active, value.isFinite else { return "—" }
    return value <= OfflineDVMonitorMeter.analysisFloorDBFS ? "≤−96" : String(format: "%.1f", value)
  }
}

private struct MeterRail: View {
  let channel: OfflineDVMonitorMeter.PresentedChannel
  var body: some View {
    Canvas { context, size in
      func y(_ db: Double) -> CGFloat {
        2 + (size.height - 4) * OfflineDVMonitorMeter.verticalFraction(forDBFS: db)
      }
      for threshold in OfflineDVMonitorMeter.segmentValuesDBFS {
        let lit = OfflineDVMonitorMeter.segmentIsLit(
          thresholdDBFS: threshold, peakDBFS: channel.peakDBFS, active: channel.active)
        let color: Color = threshold >= -3 ? .red : threshold >= -12 ? .orange : .mint
        let rect = CGRect(x: 3, y: y(threshold) - 1.3, width: size.width - 6, height: 2.6)
        context.fill(
          Path(roundedRect: rect, cornerRadius: 0.7),
          with: .color(lit ? color : .secondary.opacity(0.16)))
      }
      if channel.active {
        if channel.rmsDBFS.isFinite && channel.rmsDBFS >= -60 {
          context.fill(
            Path(CGRect(x: 0, y: y(channel.rmsDBFS) - 0.5, width: size.width, height: 1)),
            with: .color(.white))
        }
        if channel.heldPeakDBFS.isFinite && channel.heldPeakDBFS >= -60 {
          context.fill(
            Path(CGRect(x: 0, y: y(channel.heldPeakDBFS) - 1, width: size.width, height: 2)),
            with: .color(.orange))
        }
      }
    }
    .accessibilityHidden(true)
  }
}
