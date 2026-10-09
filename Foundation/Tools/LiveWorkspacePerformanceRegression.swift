// OFFLINE ONLY: actual workspace and preview; no RewindDVApp, bridge or deck operation.
import AppKit
import SwiftUI
import Foundation
@main struct LiveWorkspacePerformanceRegression {
 @MainActor static func main() {
  let app = NSApplication.shared
  // Inspection needs AppKit event dispatch, in addition to layout/display work.
  app.setActivationPolicy(.regular)
  Task { @MainActor in
    do { try await replay() } catch { print("OFFLINE_REPLAY_ERROR: \(error)"); exit(1) }
    app.terminate(nil)
  }
  app.run()
 }
 @MainActor static func replay() async throws {
  precondition(CommandLine.arguments.count >= 3 && CommandLine.arguments.contains("--ui-automation-no-driver"), "Offline workspace replay requires hardware-disabled options")
  _ = NSApplication.shared
  let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
  precondition(data.count > 0 && data.count.isMultiple(of: 120000), "Provide complete saved NTSC DV frames")
  let count = min(360,data.count/120000)
  let frames = (0..<count).map { data.subdata(in: ($0*120000)..<(($0+1)*120000)) }
  let live = LiveMonitorModel(muteAudio: true)
  let root = UnifiedMonitorWorkspace(model: RewindDVModel(),installer: SystemExtensionInstaller(),playback: OfflineDVPlaybackModel(muteAudio: true),live: live,wholeTape: WholeTapeCaptureModel(),surgery: SurgeryModel())
  let host = NSHostingView(rootView: root)
  let window = NSWindow(contentRect: NSRect(x: 30,y: 30,width: 1320,height: 810),styleMask: [.titled,.resizable],backing: .buffered,defer: false)
  window.title = "rewindDV OFFLINE workspace replay — saved DV, no deck access"
  window.contentView = host;window.makeKeyAndOrderFront(nil);NSApplication.shared.activate()
  try await Task.sleep(for: .seconds(1))
  await live.beginOfflineWorkspaceReplay()
  let start = ContinuousClock.now
  var maximumOffer = 0.0, maximumArrivalLate = 0.0
  for (i,frame) in frames.enumerated() {
   let deadline = start.advanced(by: .nanoseconds(Int64(i)*33366667))
   try await ContinuousClock().sleep(until: deadline)
   let arrival = deadline.duration(to: .now).components
   maximumArrivalLate = max(maximumArrivalLate,Double(arrival.seconds)*1000+Double(arrival.attoseconds)/1e15)
   let t = ContinuousClock.now
   live.observeOfflineWorkspaceFrame(frame,ordinal: UInt64(i),publish: i%8==0)
   let elapsed = t.duration(to: .now).components
   maximumOffer = max(maximumOffer,Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
  }
  let deadline = ContinuousClock.now.advanced(by: .seconds(4))
  while live.preview.latestSubmittedOrdinal != UInt64(count-1),ContinuousClock.now < deadline {try await Task.sleep(for: .milliseconds(10))}
  print("WORKSPACE frames=\(count) latest=\(String(describing: live.preview.latestSubmittedOrdinal)) max_offer_ms=\(maximumOffer) max_arrival_late_ms=\(maximumArrivalLate) queue_skips=\(live.preview.queueSkippedFrames) renderer_skips=\(live.preview.rendererSkippedFrames) resyncs=\(live.preview.audio.resynchronizations); \(live.preview.timingDiagnostics)")
  let preview = live.preview
  precondition(preview.decodedFrames == UInt64(count) && preview.latestSubmittedOrdinal == UInt64(count-1), "Every saved frame must be decoded and the tail presented")
  precondition(preview.queueSkippedFrames == 0 && preview.rendererSkippedFrames == 0, "Workspace must keep up with paced input")
  precondition(preview.audio.resynchronizations == 0 && preview.failedVideoFrames == 0, "UI work must not reset A/V or fail decoding")
  precondition(preview.lateVideoSubmissions == 0, "Workspace must meet native video deadlines")
  print("OFFLINE_NATIVE_WORKSPACE_REALTIME_PASS — synthetic paced delivery, not hardware qualification")
  await live.endOfflineWorkspaceReplay()
  // Optional manual scroll/disclosure/resize qualification of the actual view.
  // Intake has ended and the source bytes remain read-only.
  if CommandLine.arguments.contains("--inspect") {
    print("OFFLINE_INSPECTOR_READY — no deck access")
    try await Task.sleep(for: .seconds(60))
  }
  window.orderOut(nil)
 }
}
