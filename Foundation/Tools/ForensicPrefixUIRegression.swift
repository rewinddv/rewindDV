// Native UI/model only. No driver, capture, transport or IOKit implementation.
import AppKit
import SwiftUI
@main struct ForensicPrefixUIRegression {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 3 else { fatalError("Provide ended flight and existing qualification folder") }
    _ = NSApplication.shared
    let source = URL(fileURLWithPath: CommandLine.arguments[1]), parent = URL(fileURLWithPath: CommandLine.arguments[2])
    let model = ForensicPrefixModel()
    model.recover(source: source, parent: parent)
    precondition(model.busy)
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while model.busy { precondition(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(20)) }
    precondition(model.receipt?.state == "INCOMPLETE_ACQUISITION_VERIFIED_PREFIX", model.message)
    precondition(model.message.contains("INCOMPLETE ACQUISITION") && model.output != nil)
    let host = NSHostingView(rootView: ForensicPrefixView(model: model, available: true)
      .frame(width: 1050).padding(20).environment(\.colorScheme, .dark).background(Color.black))
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1090,height:450),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no render") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using:.png, properties:[:]) else { fatalError("no PNG") }
    try png.write(to: parent.appendingPathComponent("forensic-recovery-ui.png"), options:.withoutOverwriting)
    window.close()
    model.recover(source: source, parent: parent); model.cancel()
    while model.busy { precondition(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(20)) }
    precondition(model.receipt == nil && model.message.contains("incomplete"))
    print("FORENSIC_NATIVE_MODEL_EXPORT_CANCEL_AND_VIEW_PASS")
  }
}
