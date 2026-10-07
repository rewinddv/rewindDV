// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

private struct Command: Codable {
  let name: String
  let arguments: [String: String]
}

private struct Tool {
  let name: String
  let summary: String
  let required: [String]
  let optional: [String]
  var mcpName: String { "rewinddv_" + name.replacingOccurrences(of: ".", with: "_") }
  var schema: [String: Any] {
    let fields = Dictionary(uniqueKeysWithValues: (required + optional).map { key in
      (key, ["type": "string", "description": key])
    })
    return ["type": "object", "properties": fields, "required": required,
            "additionalProperties": false]
  }
  var listing: [String: Any] {
    ["name": mcpName, "description": summary, "inputSchema": schema]
  }
}

private let tools: [Tool] = [
  .init(name: "status", summary: "Read app, driver, capture, playback and Surgery status.", required: [], optional: []),
  .init(name: "app.navigate", summary: "Show workspace, archives, device-inspector or diagnostics.", required: ["page"], optional: []),
  .init(name: "archive.verify", summary: "Verify a raw archive folder and report its acquisition state.", required: ["path"], optional: []),
  .init(name: "archive.metadata", summary: "Analyze capture metadata epochs from a native DV file.", required: ["path"], optional: []),
  .init(name: "archive.status", summary: "Read raw archive and native metadata analysis results.", required: [], optional: []),
  .init(name: "playback.open", summary: "Open a local DV file for playback in the app.", required: ["path"], optional: []),
  .init(name: "playback.status", summary: "Read playback state and timing.", required: [], optional: []),
  .init(name: "playback.play", summary: "Play the loaded file.", required: [], optional: []),
  .init(name: "playback.pause", summary: "Pause the loaded file.", required: [], optional: []),
  .init(name: "playback.stop", summary: "Return to the first frame of the loaded file.", required: [], optional: []),
  .init(name: "playback.close", summary: "Close the loaded file.", required: [], optional: []),
  .init(name: "playback.seek", summary: "Seek to nonnegative seconds.", required: ["seconds"], optional: []),
  .init(name: "playback.step", summary: "Step by signed frame count.", required: ["frames"], optional: []),
  .init(name: "playback.metadata", summary: "Read metadata for the selected playback frame.", required: [], optional: ["evidence"]),
  .init(name: "playback.view", summary: "Set or read presentation mode, aspect, zoom and zebras.", required: [], optional: ["mode", "aspect", "zoom", "zebras"]),
  .init(name: "playback.exact_timeline", summary: "Start explicit full-file timeline analysis.", required: [], optional: []),
  .init(name: "playback.assess", summary: "Start explicit whole-file source audit.", required: [], optional: []),
  .init(name: "surgery.open", summary: "Analyze a raw DV file for Surgery.", required: ["path"], optional: []),
  .init(name: "surgery.status", summary: "Read Surgery progress, segments and export result.", required: [], optional: []),
  .init(name: "surgery.range", summary: "Select an exact [first,end) source-frame range.", required: ["first", "end"], optional: ["splitScenes"]),
  .init(name: "surgery.select", summary: "Toggle a segment for lossless merge.", required: ["segment"], optional: []),
  .init(name: "surgery.select_all", summary: "Select or clear all Surgery segments.", required: [], optional: ["selected"]),
  .init(name: "surgery.export", summary: "Export a selected range or merge selected segments to a new folder.", required: ["destination"], optional: ["merged"]),
  .init(name: "surgery.cancel", summary: "Cancel current Surgery analysis or export.", required: [], optional: []),
  .init(name: "map.create", summary: "Create a verified tape evidence map from a DV source.", required: ["source", "destination"], optional: []),
  .init(name: "map.open", summary: "Open an existing tape evidence map directory.", required: ["path"], optional: []),
  .init(name: "map.status", summary: "Read map progress, source verification and scene review.", required: [], optional: []),
  .init(name: "map.connect_source", summary: "Verify a map against its original DV source.", required: ["path"], optional: []),
  .init(name: "map.jump", summary: "Select a frame in the open map.", required: ["frame"], optional: []),
  .init(name: "map.page", summary: "Load a bounded map page by number.", required: ["number"], optional: []),
  .init(name: "map.find_issue", summary: "Find the next or previous observed issue.", required: ["direction"], optional: ["code"]),
  .init(name: "map.export_reports", summary: "Export evidence map reports to a new folder.", required: ["destination"], optional: []),
  .init(name: "map.import_external_report", summary: "Preserve an external XML report separately from native evidence.", required: ["source", "destination"], optional: []),
  .init(name: "map.review_open", summary: "Create or open a source-bound review queue.", required: ["path"], optional: ["create", "access"]),
  .init(name: "map.review_add", summary: "Add the selected frame to the open review queue.", required: [], optional: ["note"]),
  .init(name: "map.review_update", summary: "Update a visible review item by ID and state.", required: ["id", "state"], optional: ["note"]),
  .init(name: "map.review_page", summary: "Load a review queue page by number.", required: ["number"], optional: []),
  .init(name: "map.scenes_analyze", summary: "Propose scene boundaries from a verified map.", required: [], optional: []),
  .init(name: "map.scenes_decide", summary: "Review a proposed scene boundary.", required: ["frame", "decision"], optional: ["note"]),
  .init(name: "map.scenes_publish", summary: "Publish scene reports and optionally scene DV clips.", required: ["destination"], optional: ["exportDV"]),
  .init(name: "map.cancel", summary: "Cancel current map processing.", required: [], optional: []),
  .init(name: "recovery.create", summary: "Create a source-bound supervised-recovery budget plan without moving tape.", required: ["destination", "tape", "first", "end"], optional: ["maximumAttempts", "attemptsPerTarget", "passSeconds", "totalSeconds", "cooldownSeconds"]),
  .init(name: "recovery.open", summary: "Open an existing recovery plan bound to the verified map.", required: ["path"], optional: []),
  .init(name: "recovery.refresh", summary: "Refresh recovery attempt state.", required: [], optional: []),
  .init(name: "recovery.status", summary: "Read recovery plan, targets, charge and attempts.", required: [], optional: []),
  .init(name: "forensic_prefix.recover", summary: "Recover a verified prefix from a partial DV source.", required: ["source", "destination"], optional: []),
  .init(name: "forensic_prefix.status", summary: "Read forensic prefix recovery state.", required: [], optional: []),
  .init(name: "forensic_prefix.cancel", summary: "Cancel forensic prefix recovery.", required: [], optional: []),
  .init(name: "multi_pass.base", summary: "Use the verified open map as the base pass.", required: [], optional: []),
  .init(name: "multi_pass.add", summary: "Verify and add a donor pass.", required: ["map", "source"], optional: []),
  .init(name: "multi_pass.compare", summary: "Compare verified passes for candidate frames.", required: [], optional: []),
  .init(name: "multi_pass.status", summary: "Read passes, candidate frames and review decisions.", required: [], optional: []),
  .init(name: "multi_pass.choose", summary: "Choose a donor candidate for one reviewed frame.", required: ["frame", "candidate"], optional: []),
  .init(name: "multi_pass.originals", summary: "Keep original frames for every pending review.", required: [], optional: []),
  .init(name: "multi_pass.note", summary: "Record a note for one reviewed frame.", required: ["frame", "text"], optional: []),
  .init(name: "multi_pass.publish", summary: "Publish the comparison plan and optionally derived DV.", required: ["destination"], optional: ["exportDV"]),
  .init(name: "multi_pass.cancel", summary: "Cancel current multi-pass processing.", required: [], optional: []),
  .init(name: "driver.refresh", summary: "Refresh attached driver and deck readiness.", required: [], optional: []),
  .init(name: "driver.activate", summary: "Present driver activation confirmation in the app.", required: [], optional: []),
  .init(name: "deck.inspect", summary: "Request the current deck inspection using the GUI model.", required: [], optional: []),
  .init(name: "deck.capabilities", summary: "Probe selected deck transport capabilities.", required: [], optional: []),
  .init(name: "deck.select", summary: "Select an operational deck by GUID.", required: ["guid"], optional: []),
  .init(name: "deck.command", summary: "Send one permitted play, stop, rewind, fast_forward or shuttle command.", required: ["action"], optional: []),
  .init(name: "capture.start", summary: "Start manual ingest at an existing writable destination.", required: ["destination"], optional: []),
  .init(name: "capture.whole_tape", summary: "Start the supervised whole-tape job at an existing writable destination.", required: ["destination"], optional: []),
  .init(name: "capture.stop", summary: "Request the active capture's normal stop procedure.", required: [], optional: []),
]

private enum CommandError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { text } else { nil }
  }
}

private func socketPath() -> String {
  // The sandbox rewrites the app's user temporary directory into its container.
  return FileManager.default.homeDirectoryForCurrentUser.path
    + "/Library/Containers/net.rewinddigital.RewindDV/Data/tmp/rewinddv-\(getuid()).sock"
}

private func call(_ command: Command) throws -> [String: Any] {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CommandError.message("Cannot create local socket") }
  defer { Darwin.close(fd) }
  var address = sockaddr_un()
  let location = socketPath()
  guard location.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw CommandError.message("Command socket path is too long")
  }
  let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
  _ = location.withCString { pointer in
    withUnsafeMutablePointer(to: &address.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
        strcpy($0, pointer)
      }
    }
  }
  address.sun_family = sa_family_t(AF_UNIX)
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else {
    throw CommandError.message("RewindDV is not accepting commands. Open the app and accept its alpha notice.")
  }
  var timeout = timeval(tv_sec: 30, tv_usec: 0)
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var noSignal: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  let request = try JSONEncoder().encode(command) + Data([10])
  guard request.count <= 65_536 else { throw CommandError.message("Command request is too large") }
  let sent = request.withUnsafeBytes { raw -> Bool in
    guard let base = raw.baseAddress else { return false }
    var offset = 0
    while offset < raw.count {
      let count = send(fd, base.advanced(by: offset), raw.count - offset, 0)
      if count <= 0 { return false }
      offset += count
    }
    return true
  }
  guard sent else { throw CommandError.message("Command request was not sent") }
  shutdown(fd, SHUT_WR)
  var response = Data()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while response.count < 4_194_304 {
    let count = recv(fd, &chunk, chunk.count, 0)
    if count <= 0 { break }
    response.append(contentsOf: chunk.prefix(count))
    if response.last == 10 { break }
  }
  guard response.last == 10,
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
        let ok = object["ok"] as? Bool else {
    throw CommandError.message("No valid response from RewindDV")
  }
  guard ok else { throw CommandError.message(object["error"] as? String ?? "Command rejected") }
  return object["result"] as? [String: Any] ?? [:]
}

private func writeJSON(_ object: Any) {
  guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return }
  try? FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
}

private func mcpLoop() {
  while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    guard let id = message["id"] else { continue } // notifications have no response
    let params = message["params"] as? [String: Any] ?? [:]
    var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
    switch method {
    case "initialize":
      reply["result"] = ["protocolVersion": "2025-06-18",
                         "capabilities": ["tools": ["listChanged": false]],
                         "serverInfo": ["name": "rewinddv", "version": "0.1.0"]]
    case "ping": reply["result"] = [:]
    case "tools/list": reply["result"] = ["tools": tools.map(\.listing)]
    case "tools/call":
      guard let name = params["name"] as? String,
            let tool = tools.first(where: { $0.mcpName == name }),
            params["arguments"] == nil || params["arguments"] is [String: Any] else {
        reply["error"] = ["code": -32602, "message": "Unknown tool or invalid arguments"]
        writeJSON(reply); continue
      }
      let values = params["arguments"] as? [String: Any] ?? [:]
      let argumentKeys = Set(tool.required + tool.optional)
      guard tool.required.allSatisfy({ values[$0] is String }),
            values.keys.allSatisfy({ argumentKeys.contains($0) && values[$0] is String }) else {
        reply["result"] = ["content": [["type": "text", "text": "Invalid tool arguments"]], "isError": true]
        writeJSON(reply); continue
      }
      do {
        let arguments = values.mapValues { $0 as! String }
        let result = try call(Command(name: tool.name, arguments: arguments))
        let text = String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        reply["result"] = ["content": [["type": "text", "text": text]], "structuredContent": result, "isError": false]
      } catch {
        reply["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
      }
    default: reply["error"] = ["code": -32601, "message": "Method not found"]
    }
    writeJSON(reply)
  }
}

@main struct RewindDVCommandCLI {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["mcp"] { mcpLoop(); return }
    guard let name = args.first, let tool = tools.first(where: { $0.name == name }) else {
      let usage = "Usage: rewinddv COMMAND [key=value ...] | rewinddv mcp\nCommands: \(tools.map(\.name).joined(separator: ", "))\n"
      try? FileHandle.standardError.write(contentsOf: Data(usage.utf8)); exit(2)
    }
    var values: [String: String] = [:]
    for argument in args.dropFirst() {
      guard let separator = argument.firstIndex(of: "=") else {
        try? FileHandle.standardError.write(contentsOf: Data("Expected key=value: \(argument)\n".utf8)); exit(2)
      }
      let key = String(argument[..<separator]); let value = String(argument[argument.index(after: separator)...])
      guard (tool.required + tool.optional).contains(key), values[key] == nil else {
        try? FileHandle.standardError.write(contentsOf: Data("Unknown or repeated argument: \(key)\n".utf8)); exit(2)
      }
      values[key] = value
    }
    guard tool.required.allSatisfy({ values[$0] != nil }) else {
      try? FileHandle.standardError.write(contentsOf: Data("Required: \(tool.required.joined(separator: ", "))\n".utf8)); exit(2)
    }
    do { writeJSON(try call(Command(name: name, arguments: values))) }
    catch { try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8)); exit(1) }
  }
}
