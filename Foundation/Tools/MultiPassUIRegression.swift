// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Actual native model/view regression with synthetic source bytes. No driver,
// IOKit user client, tape transport or capture implementation is linked.
import AppKit
import SwiftUI

enum MultiPassUIRegression {
  // Original structurally valid synthetic IEC DV fixtures, not camera footage.
  static func fixture(_ id: Int, damaged: Bool) -> Data {
    var result = Data()
    for sequence in 0..<10 {
      func append(_ section: Int, _ number: Int) {
        var block = Data(repeating: 0xff, count: 80)
        block[0] = UInt8(section << 5); block[1] = UInt8(sequence << 4) | 4; block[2] = UInt8(number)
        if section == 0 { for i in 3...7 { block[i] = 0 }; block[9] = UInt8(id) }
        if section == 2 && number == 0 {
          block.replaceSubrange(3..<8, with: [0x60,0xff,0xff,0xc0,0xff])
          block.replaceSubrange(8..<13, with: [0x61,0,0xc8,0xf0,0xff])
        }
        if section == 3 && number < 2 {
          block.replaceSubrange(3..<8, with: number == 0 ? [0x50,20,0,0x80,0xc0] : [0x51,0,7,0x80,0xff])
        }
        if section == 4 {
          block[3] = damaged && sequence == 0 && number == 0 ? 0x10 : 0
          if number == 0 { block[12] = UInt8(id) }
        }
        result.append(block)
      }
      append(0,0); for n in 0..<2 { append(1,n) }; for n in 0..<3 { append(2,n) }
      for group in 0..<9 { append(3,group); for n in group * 15..<(group + 1) * 15 { append(4,n) } }
    }
    return result
  }
  @MainActor static func run(parent: URL) async throws {
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
      guard value() else { throw NSError(domain: "MultiPassUIRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
      print("PASS: \(message)")
    }
    let root = parent.appendingPathComponent("synthetic-multipass-ui")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var files: [URL] = [], maps: [URL] = []
    for pass in 0..<2 {
      let file = root.appendingPathComponent("synthetic-pass-\(pass).dv"), map = root.appendingPathComponent("map-\(pass)")
      var bytes = Data()
      for i in 0..<9 { bytes.append(fixture(i, damaged: pass == 0 && i == 4)) }
      try bytes.write(to: file, options: .withoutOverwriting)
      _ = try DVTapeEvidenceMapExporter.create(source: file, destination: map)
      files.append(file); maps.append(map)
    }
    let map = TapeEvidenceMapModel(), model = MultiPassModel()
    func settled() async throws {
      let limit = Date().addingTimeInterval(120)
      while map.busy || map.detailBusy || model.busy {
        guard Date() < limit else { throw NSError(domain: "MultiPassUIRegression", code: 2) }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    map.open(maps[0]); try await settled(); map.connectSource(files[0]); try await settled()
    model.reset(base: map.multiPassInput)
    model.add(mapURL: maps[1], sourceURL: files[1]); try await settled()
    try require(model.bindings.count == 2, "actual multi-pass UI loads whole-file-verified base and donor")
    model.compare(); try await settled()
    try require(model.plan?.pending == 1 && model.plan?.candidates.first?.eligible == true, "actual comparison model exposes one pending eligible replacement")
    guard let candidate = model.plan?.candidates.first else { fatalError(model.message) }
    model.choose(frame: 4, candidate: candidate.id); model.note(frame: 4, text: "Synthetic offline UI test; not recovered camera footage")
    try require(model.plan?.pending == 0 && model.plan?.replacements == 1, "explicit donor selection resolves UI review")
    model.publish(parent: root, exportDV: false); try await settled()
    guard let review = model.output else { fatalError(model.message) }
    model.compare(restoring: review.appendingPathComponent("review.json")); try await settled()
    try require(model.plan?.replacements == 1, "actual UI restores reviewed choices after fresh byte comparison")
    model.inspect(candidate)
    let inspectionLimit = Date().addingTimeInterval(30)
    while model.inspectionMessage.hasPrefix("Verifying") {
      guard Date() < inspectionLimit else { fatalError("Inspection did not finish") }
      try await Task.sleep(for: .milliseconds(20))
    }
    try require(model.inspectionMessage.hasPrefix("Both frame hashes match"), "native inspection verifies both original frame hashes independently of decoder success")
    let host = NSHostingView(rootView: MultiPassView(model: model, map: map)
      .frame(width: 1320).environment(\.colorScheme, .dark).padding(16).background(Color.black))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1352, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host; window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Multi-pass view unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Multi-pass PNG unavailable") }
    let image = parent.appendingPathComponent("multipass-ui.png")
    try png.write(to: image, options: .withoutOverwriting); window.close()
    print("MULTIPASS_UI_RENDERED: \(image.path)")
    model.publish(parent: root, exportDV: true); try await settled()
    guard let output = model.output else { fatalError(model.message) }
    let merged = try Data(contentsOf: output.appendingPathComponent("merged.dv")), donor = try Data(contentsOf: files[1])
    let receipt = try JSONDecoder().decode(DVMultiPass.Receipt.self, from: Data(contentsOf: output.appendingPathComponent("merge.json")))
    try require(merged == donor && receipt.replacements == 1 && receipt.state == "verified_reviewed_derivative", "actual UI publishes an independently reread whole-frame derivative")
    let provenance = try Data(contentsOf: output.appendingPathComponent("provenance.ndjson")).split(separator: 10)
    try require(provenance.count == 9, "actual UI output has provenance for all nine output frames")
    let baseBytes = try Data(contentsOf: files[0])
    try require(baseBytes != merged, "original damaged synthetic capture remains unchanged")
    model.compare(); model.reset() // Context changed while a worker was active.
    try await settled()
    try require(model.bindings.isEmpty && model.plan == nil && model.output == nil, "clearing input context revokes merge choices and prior output status")
    print("MULTIPASS_DIRECTORY: \(output.path)")
    print("OFFLINE_MULTIPASS_UI_PASS")
  }
}
