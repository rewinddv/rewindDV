import AVFoundation
// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

struct MonitorVideoSurface: NSViewRepresentable {
  let displayLayer: AVSampleBufferDisplayLayer
  var inspectionMode = false
  var overrideDisplayAspect = false
  var zoom: CGFloat = 1
  var center = CGPoint(x: 0.5, y: 0.5)

  func makeNSView(context: Context) -> MonitorVideoHostView {
    let view = MonitorVideoHostView(displayLayer: displayLayer)
    view.inspectionMode = inspectionMode
    view.overrideDisplayAspect = overrideDisplayAspect
    view.setZoom(zoom, center: center)
    return view
  }

  func updateNSView(_ view: MonitorVideoHostView, context: Context) {
    view.install(displayLayer)
    view.inspectionMode = inspectionMode
    view.overrideDisplayAspect = overrideDisplayAspect
    view.setZoom(zoom, center: center)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MonitorVideoHostView, context: Context) -> CGSize? {
    guard let width = proposal.width, let height = proposal.height,
      width.isFinite, height.isFinite else { return nil }
    // Accept the aspect-fitted viewport exactly, not a prior NSView fitting size.
    return CGSize(width: max(0, width), height: max(0, height))
  }

  static func dismantleNSView(_ view: MonitorVideoHostView, coordinator: ()) {
    view.detach()
  }
}

/// AppKit owns the backing layer; AVFoundation owns a separate video sublayer.
/// Explicit layout avoids relying on AppKit to manage a foreign backing layer.
@MainActor final class MonitorVideoHostView: NSView {
  private(set) var videoLayer: AVSampleBufferDisplayLayer?
  private var zoom: CGFloat = 1
  private var center = CGPoint(x: 0.5, y: 0.5)
  func setZoom(_ value: CGFloat, center: CGPoint) {
    let nextZoom: CGFloat = [1, 2, 4, 8].contains(value) ? value : 1
    let edge = 0.5 / nextZoom
    let nextCenter = CGPoint(x: min(1-edge, max(edge, center.x)),
      y: min(1-edge, max(edge, center.y)))
    guard zoom != nextZoom || self.center != nextCenter else { return }
    zoom = nextZoom
    self.center = nextCenter
    updateVideoGeometry()
  }
  var inspectionMode = false {
    didSet { if oldValue != inspectionMode { updateVideoGeometry() } }
  }
  var overrideDisplayAspect = false {
    didSet { if oldValue != overrideDisplayAspect { updateVideoGeometry() } }
  }

  init(displayLayer: AVSampleBufferDisplayLayer) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true
    setAccessibilityElement(false)
    install(displayLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Programmatic video host only") }

  func install(_ displayLayer: AVSampleBufferDisplayLayer) {
    if videoLayer !== displayLayer {
      detach()
      videoLayer = displayLayer
    }
    guard let layer else { return }
    if displayLayer.superlayer !== layer { layer.addSublayer(displayLayer) }
    updateVideoGeometry()
  }

  func detach() {
    // An old view's teardown must not detach a layer rehosted by a newer view.
    if videoLayer?.superlayer === layer { videoLayer?.removeFromSuperlayer() }
    videoLayer = nil
  }

  override func layout() {
    super.layout()
    if let videoLayer { install(videoLayer) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let videoLayer { install(videoLayer) }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateVideoGeometry()
  }

  private func updateVideoGeometry() {
    guard let videoLayer, videoLayer.superlayer === layer else { return }
    let frame = CGRect(
      x: bounds.midX - center.x * bounds.width * zoom,
      y: bounds.midY - (1-center.y) * bounds.height * zoom,
      width: bounds.width * zoom, height: bounds.height * zoom)
    let scale = window?.backingScaleFactor ?? 1
    let filter: CALayerContentsFilter = inspectionMode ? .nearest : .linear
    // The SwiftUI surface already fits the selected display aspect inside the
    // fixed monitor. Resize must override the sample's PAR here, otherwise a
    // second resizeAspect pass would letterbox it back to the original shape.
    let gravity: AVLayerVideoGravity = overrideDisplayAspect ? .resize : .resizeAspect
    guard videoLayer.frame != frame || videoLayer.contentsScale != scale
      || videoLayer.videoGravity != gravity
      || videoLayer.magnificationFilter != filter || videoLayer.minificationFilter != filter
    else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.videoGravity = gravity
    videoLayer.frame = frame
    videoLayer.contentsScale = scale
    videoLayer.magnificationFilter = filter
    videoLayer.minificationFilter = filter
    CATransaction.commit()
  }
}
