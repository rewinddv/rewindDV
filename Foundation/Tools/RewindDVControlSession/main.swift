// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Supervised bench adapter. Compiles the exact reviewed App control implementation.
import Darwin
import Foundation
import IOKit

@main
struct RewindDVControlSession {
  static func hex(_ value: UInt64) -> String { String(format: "%016llX", value) }

  static func verifyInstalledIdentity() throws {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceNameMatching("ASFWDriver"), &iterator) == KERN_SUCCESS
    else {
      throw ControlWireError.invalid("Cannot enumerate the installed driver")
    }
    defer { IOObjectRelease(iterator) }
    var exact = 0
    var total = 0
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      total += 1
      defer { IOObjectRelease(service) }
      let value =
        IORegistryEntryCreateCFProperty(
          service, "IOUserServerCDHash" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        as? String
      if value?.lowercased() == "69f528d16e1470fad91b3197f98327891057c9b7" { exact += 1 }
    }
    guard total == 1, exact == 1 else {
      throw ControlWireError.invalid("Exact reviewed driver CDHash is not uniquely attached")
    }
  }

  static func main() async {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
      print("Usage: RewindDVControlSession /absolute/approved/run/root")
      exit(2)
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let identityURL = root.appendingPathComponent("RUN.json")
    guard let identity = try? Data(contentsOf: identityURL),
      let dictionary = try? JSONSerialization.jsonObject(with: identity) as? [String: Any],
      dictionary["driver_cdhash"] as? String == "69f528d16e1470fad91b3197f98327891057c9b7",
      dictionary["expected_deck_guid"] as? String == "0800460104F1311B"
    else {
      print("Run identity does not match this reviewed Sony candidate")
      exit(2)
    }
    // Never reopen a consumed session, including after process death or uncertainty.
    let path = root.appendingPathComponent("native-session-events.ndjson")
    let descriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      print("Session already exists or destination is unavailable; no replay")
      exit(2)
    }
    let journal = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? journal.close() }
    let directoryDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
      print("Cannot durably consume session directory; no control")
      exit(2)
    }
    let directorySync = Darwin.fsync(directoryDescriptor)
    Darwin.close(directoryDescriptor)
    guard directorySync == 0 else {
      print("Cannot durably consume session directory; no control")
      exit(2)
    }
    func emit(_ fields: [String: Any]) throws {
      var record = fields
      record["utc"] = ISO8601DateFormatter().string(from: Date())
      let data =
        try JSONSerialization.data(
          withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
      try journal.write(contentsOf: data)
      try journal.synchronize()
      try FileHandle.standardOutput.write(contentsOf: data)
    }
    let bridge = DriverBridge()
    var selected: DiscoveredDeck?
    var lockedOut = false
    var physicalStopUnverified = false
    var awaitingStopObservation = false
    var freshStopAllowed = false
    do {
      try emit([
        "event": "session_ready",
        "commands": [
          "probe", "play", "stop", "rewind", "observed-stopped", "observed-playing", "quit",
        ], "hardware_motion": "unknown",
      ])
      while let line = readLine() {
        let instruction = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction == "quit" {
          if physicalStopUnverified {
            try emit([
              "event": "quit_refused", "reason": "Physical stop observation is still required",
            ])
            continue
          }
          try emit(["event": "session_closed", "hardware_motion": "unknown_verify_stopped"])
          if lockedOut { exit(1) }
          return
        }
        var commandMayHaveBeenSubmitted = false
        do {
          if instruction == "observed-stopped" || instruction == "observed-playing" {
            physicalStopUnverified = instruction != "observed-stopped"
            if instruction == "observed-stopped" {
              awaitingStopObservation = false
              freshStopAllowed = false
            }
            try emit([
              "event": "operator_physical_observation", "observation": instruction,
              "authority": "operator report, not inferred from protocol response",
            ])
            continue
          }
          if instruction == "probe" {
            selected = nil
            try verifyInstalledIdentity()
            let snapshot = try await bridge.refresh()
            selected = snapshot.decks.first { $0.guid == 0x0800_4601_04f1_311b && $0.isOperational }
            let decks: [[String: Any]] = snapshot.decks.map { deck in
              [
                "guid": hex(deck.guid), "generation": deck.generation, "node": deck.node,
                "state": deck.state, "operational": deck.isOperational, "vendor": deck.vendor,
                "model": deck.model,
              ]
            }
            try emit([
              "event": "read_only_probe", "decks": decks,
              "capabilities": snapshot.capabilities.flags,
              "raw_status_base64": snapshot.rawStatus.base64EncodedString(),
              "controller_health": "unverified_raw_status_retained",
              "control_locked_out": lockedOut,
            ])
            continue
          }
          let command: DeckCommand
          switch instruction {
          case "play": command = .play
          case "stop": command = .stop
          case "rewind": command = .rewind
          default: throw ControlWireError.invalid("Unknown command; no raw selector interface")
          }
          guard !lockedOut else {
            throw ControlWireError.invalid(
              "Terminal uncertainty: physical STOP if needed; no further control")
          }
          guard !awaitingStopObservation else {
            throw ControlWireError.invalid("Physical STOP observation is required before further control")
          }
          if physicalStopUnverified {
            guard command == .stop, freshStopAllowed else {
              throw ControlWireError.invalid("Only one fresh-route STOP is permitted while motion is unverified")
            }
          }
          guard let deck = selected else {
            throw ControlWireError.invalid("A fresh exact Sony probe is required")
          }
          try verifyInstalledIdentity()
          try emit(["event": "operator_command", "command": instruction, "guid": hex(deck.guid)])
          commandMayHaveBeenSubmitted = true
          physicalStopUnverified = true
          freshStopAllowed = false
          awaitingStopObservation = command == .stop
          selected = nil
          let report = try await bridge.perform(command, selectedDeck: deck, explicitlyArmed: true)
          lockedOut = report.disposition == .uncertainLockedOut
          freshStopAllowed = !lockedOut && command != .stop
          do {
            var fields: [String: Any] = [
              "event": "control_result", "command": instruction,
              "protocol_accepted": report.disposition == .protocolAcceptedMotionUnverified,
              "physical_motion": "unknown",
              "requires_supervised_stop": report.requiresSupervisedStop,
              "locked_out": lockedOut, "receipt_path": report.receiptURL.path,
              "message": report.message, "first_error": report.firstError as Any? ?? NSNull(),
              "cleanup_errors": report.cleanupErrors,
            ]
            if let result = report.result {
              fields["request_id"] = hex(result.requestID)
              fields["operation_id"] = hex(result.operationID)
              fields["attempt_id"] = hex(result.attemptID)
              fields["driver_instance_id"] = hex(result.driverInstanceID)
              fields["device_incarnation"] = hex(result.deviceIncarnation)
              fields["route_epoch"] = hex(result.routeEpoch)
              fields["generation"] = result.generation
              fields["node_id"] = result.nodeID
              fields["terminal_status"] = result.status
              fields["stages"] = result.stages
              fields["response_hex"] = result.response.map { String(format: "%02X", $0) }.joined(
                separator: " ")
            }
            try emit(fields)
          }
        } catch {
          if commandMayHaveBeenSubmitted {
            lockedOut = true
            selected = nil
          }
          try emit([
            "event": "error", "message": error.localizedDescription,
            "control_locked_out": lockedOut,
          ])
        }
      }
      if physicalStopUnverified {
        try emit([
          "event": "input_closed_with_unverified_stop",
          "action": "PHYSICAL STOP if motion may persist; no replay",
        ])
        exit(1)
      }
      if lockedOut { exit(1) }
    } catch {
      // A failed supervising journal ends the process; the consumed session file
      // prevents restart/replay. The operator must physically verify STOP.
      try? FileHandle.standardError.write(
        contentsOf: Data(
          "Evidence output failed: \(error). PHYSICAL STOP if motion may persist. No replay.\n".utf8
        ))
      exit(1)
    }
  }
}
