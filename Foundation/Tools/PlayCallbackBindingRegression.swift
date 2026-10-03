// Offline compiler regression. Extracts the production send signature and idle
// PLAY call site, so Swift-language callback binding is tested, not re-created.
import Foundation

@main struct PlayCallbackBindingRegression {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let model = try String(contentsOf: root.appendingPathComponent("Foundation/App/RewindDVApp.swift"), encoding: .utf8)
    let workspace = try String(contentsOf: root.appendingPathComponent("Foundation/App/UnifiedMonitorWorkspace.swift"), encoding: .utf8)
    let signatureStart = model.range(of: "  func send(_ command: DeckCommand,")!
    let signatureEnd = model.range(of: ") {", range: signatureStart.lowerBound..<model.endIndex)!
    let signature = String(model[signatureStart.lowerBound..<signatureEnd.upperBound])
    let callStart = workspace.range(of: #"model\.send\(\.play(?:\)|, onAccepted:)"#, options: .regularExpression)!
    let callEnd = workspace.range(of: "\n            }", range: callStart.lowerBound..<workspace.endIndex)!
    let call = String(workspace[callStart.lowerBound..<callEnd.lowerBound])
    let bridge = try String(contentsOf: root.appendingPathComponent("Foundation/App/DriverBridge.swift"), encoding: .utf8)
    let admissionStart = bridge.range(of: "      try Task.checkCancellation()", range: bridge.range(of: "  func beginLiveReceive")!.lowerBound..<bridge.endIndex)!.lowerBound
    let admissionEnd = bridge.range(of: "      finalLiveStatistics = nil", range: admissionStart..<bridge.endIndex)!.lowerBound
    let admission = String(bridge[admissionStart..<admissionEnd])
    let fixture = """
    import Foundation
    enum DeckCommand { case play }
    enum DriverBridgeError: Error { case permanentSessionLockout, commandAlreadyInFlight }
    func checkAdmission(_ mask: Int) throws {
      let permanentlyLockedOut = mask & 1 != 0
      let commandInFlight = mask & 2 != 0
      let inspectionInFlight = mask & 4 != 0
      let liveConnection: Int? = mask & 8 != 0 ? 1 : nil
      \(admission)
    }
    @MainActor final class Model {
      var phase = "idle"
      var accepted = true
      var pending: Task<Void, Never>?
      let bridge = 1
      \(signature)
        pending = Task {
          await beforeSubmission?()
          phase = "submitted"
          await Task.yield()
          phase = accepted ? "accepted" : "rejected"
          if accepted { onAccepted?() }
        }
      }
    }
    @MainActor final class Live {
      let model: Model
      var starts = 0
      var clocks = 0
      init(_ model: Model) { self.model = model }
      func start(bridge: Int, deck: Int, expectedRoute: Int? = nil) {
        guard model.phase == "accepted" else {
          print("FAIL: receive callback ran during \\(model.phase), before PLAY acceptance")
          exit(1)
        }
        starts += 1
      }
      func observeCaptureTransportPlaying(bridge: Int, deck: Int, route: Int) { clocks += 1 }
    }
    Task { @MainActor in
        for mask in 0..<16 {
          do {
            try checkAdmission(mask)
            guard mask == 0 else { exit(3) }
          } catch DriverBridgeError.permanentSessionLockout {
            guard mask & 1 != 0 else { exit(4) }
          } catch DriverBridgeError.commandAlreadyInFlight {
            guard mask & 1 == 0, mask != 0 else { exit(5) }
          } catch { exit(6) }
        }
        for accept in [false, true] {
          let model = Model(); model.accepted = accept
          let live = Live(model); let deck = 1; let route = 1
          \(call)
          await model.pending?.value
          guard live.starts == (accept ? 1 : 0), live.clocks == live.starts else { exit(2) }
        }
        print("PASS: production PLAY callback runs once after acceptance and never on rejection")
        print("PASS: 16 production receive-admission combinations distinguish busy from permanent lockout")
        exit(0)
    }
    dispatchMain()
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "-swift-version", "6", "-"]
    let input = Pipe(); process.standardInput = input
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(fixture.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
  }
}
