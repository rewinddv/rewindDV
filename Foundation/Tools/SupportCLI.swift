// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Darwin

/// Shipped standalone: Foundation + system tools only, no Xcode/Codex needed.
@main struct SupportCLI {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
      print("Usage: rewindDV-support --collect new-output-folder [capture-folder] OR --record-system-log new-folder")
      exit(2)
    }
    let destination = URL(fileURLWithPath: args[2]).standardizedFileURL
    if args[1] == "--record-system-log" {
      guard mkdir(destination.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
      try JSONEncoder().encode(["schema": "rewinddv.system-log.v1", "startedUTC": Date().ISO8601Format(),
        "limits": "256 MiB per run; 4 MiB segments; concatenate in filename order; OS may redact or omit events"])
        .write(to: destination.appendingPathComponent("recorder.json"))
      var file: FileHandle?
      var segment = 0, segmentBytes = 0, total = 0
      defer { try? file?.synchronize(); try? file?.close() }
      while let data = try FileHandle.standardInput.read(upToCount: 65536), !data.isEmpty {
        if total >= 256 * 1024 * 1024 {
          try Data("{\"status\":\"system log recording reached 256 MiB limit; later logs not retained\"}".utf8)
            .write(to: destination.appendingPathComponent("limit.json"))
          print("System-log storage limit reached. App capture is unaffected; restart logging after exporting.")
          break
        }
        if file == nil || segmentBytes >= 4 * 1024 * 1024 {
          try file?.synchronize(); try file?.close()
          let url = destination.appendingPathComponent(String(format: "system-%04d.ndjson", segment))
          FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
          file = try FileHandle(forWritingTo: url); segment += 1; segmentBytes = 0
        }
        try file?.write(contentsOf: data)
        try file?.synchronize()
        segmentBytes += data.count; total += data.count
      }
      return
    }
    guard args[1] == "--collect" else { exit(2) }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let support = home.appendingPathComponent("Library/Containers/net.rewinddigital.RewindDV/Data/Library/Application Support/RewindDV")
    var roots = SupportBundleCollector.applicationRoots(in: support)
    roots.insert(home.appendingPathComponent("Library/Application Support/rewindDV Alpha/SystemLogs"), at: 0)
    if args.count > 3 { roots.insert(URL(fileURLWithPath: args[3]), at: 0) }
    let manifest = try SupportBundleCollector.collect(roots: roots, into: destination)
    let system = destination.appendingPathComponent("system")
    try fm.createDirectory(at: system, withIntermediateDirectories: false)
    var commands: [[String: String]] = []
    func run(_ name: String, _ executable: String, _ arguments: [String]) throws {
      let url = system.appendingPathComponent(name + ".txt")
      fm.createFile(atPath: url.path, contents: nil)
      let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
      let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments; process.standardOutput = handle; process.standardError = handle
      do {
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        var sizeLimited = false
        while process.isRunning && Date() < deadline {
          if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 16 * 1024 * 1024 { sizeLimited = true; break }
          Thread.sleep(forTimeInterval: 0.1)
        }
        let timedOut = process.isRunning && !sizeLimited
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.2); if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        commands.append(["file": "system/" + name + ".txt", "status": String(process.terminationStatus), "timedOut": String(timedOut), "sizeLimited": String(sizeLimited)])
      } catch { commands.append(["file": name, "error": error.localizedDescription]) }
    }
    try run("macOS", "/usr/bin/sw_vers", [])
    try run("architecture", "/usr/bin/uname", ["-m"])
    try run("hardware-model", "/usr/sbin/sysctl", ["hw.model", "hw.memsize", "hw.ncpu"])
    try run("SIP", "/usr/bin/csrutil", ["status"])
    try run("extensions", "/usr/bin/systemextensionsctl", ["list"])
    try run("driver-registry", "/usr/sbin/ioreg", ["-r", "-c", "ASFWDriver", "-l"])
    try run("recent-system-log", "/usr/bin/log", ["show", "--last", "20m", "--style", "compact", "--info", "--debug", "--predicate",
      "process CONTAINS[c] 'RewindDV' OR senderImagePath CONTAINS[c] 'net.rewinddigital.RewindDV' OR subsystem BEGINSWITH 'net.rewinddigital' OR eventMessage CONTAINS 'net.rewinddigital.RewindDV' OR eventMessage BEGINSWITH '[ASFW' OR eventMessage BEGINSWITH '[FCP'"])
    // Crash evidence is opt-in through running this collector. Narrow names,
    // regular files only, bounded; never scan all personal diagnostic reports.
    for crashRoot in [home.appendingPathComponent("Library/Logs/DiagnosticReports"), URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")] {
      let files = (try? fm.contentsOfDirectory(at: crashRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])) ?? []
      for url in files.filter({ $0.lastPathComponent.lowercased().contains("rewinddv") && $0.pathExtension == "ips" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(10) {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? Int.max) < 8 * 1024 * 1024 else { continue }
        do { try fm.copyItem(at: url, to: system.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)) }
        catch { commands.append(["crashReport": url.lastPathComponent, "error": error.localizedDescription]) }
      }
    }
    try JSONEncoder().encode(commands).write(to: destination.appendingPathComponent("system-command-results.json"))
    // Every exported file, including OS reports, has a transport checksum.
    var hashes: [String: String] = [:]
    if let walker = fm.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey]) {
      for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        hashes[try SupportBundleCollector.relativePath(of: url, within: destination)] = hash.finalize().map { String(format: "%02x", $0) }.joined()
      }
    }
    try JSONEncoder().encode(hashes).write(to: destination.appendingPathComponent("checksums.json"))
    print("Reports saved: \(destination.path). Manifest notices: \(manifest.entries.filter { $0.outcome != "copied snapshot" }.count). Review before sharing. No video was collected.")
  }
}
