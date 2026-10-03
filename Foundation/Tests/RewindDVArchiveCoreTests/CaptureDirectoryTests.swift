import Foundation
import Testing
@testable import RewindDVArchiveCore

@Test func captureNamesUseLocalGregorianTimeAndPortableCharacters() {
  let date = Date(timeIntervalSince1970: 1_600_000_000)
  #expect(CaptureDirectory.name(kind: .manual, date: date, timeZone: TimeZone(secondsFromGMT: 0)!)
    == "Manual Capture — 2020-09-13 at 12-26-40")
  #expect(CaptureDirectory.name(kind: .wholeTape, date: date, timeZone: TimeZone(secondsFromGMT: -21600)!)
    == "WholeTape Capture — 2020-09-13 at 06-26-40")
  #expect(CaptureDirectory.name(kind: .wholeTapePayload, date: date) == "Capture")
}

@Test func captureDirectoryCollisionsNeverReuseFilesDirectoriesOrSymlinks() throws {
  let parent = FileManager.default.temporaryDirectory.appendingPathComponent("capture-names-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: parent) }
  let date = Date(timeIntervalSince1970: 1_600_000_000), zone = TimeZone(secondsFromGMT: 0)!
  let name = CaptureDirectory.name(kind: .manual, date: date, timeZone: zone)
  let occupied = parent.appendingPathComponent(name)
  try Data("untouched".utf8).write(to: occupied)
  try FileManager.default.createSymbolicLink(atPath: parent.appendingPathComponent(name + "-002").path,
    withDestinationPath: occupied.path)
  let third = try CaptureDirectory.create(parent: parent, kind: .manual, date: date, timeZone: zone)
  let fourth = try CaptureDirectory.create(parent: parent, kind: .manual, date: date, timeZone: zone)
  #expect(third.lastPathComponent == name + "-003")
  #expect(fourth.lastPathComponent == name + "-004")
  #expect(try Data(contentsOf: occupied) == Data("untouched".utf8))
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: parent.appendingPathComponent(name + "-002").path) == occupied.path)
  #expect(throws: (any Error).self) {
    try CaptureDirectory.create(parent: occupied, kind: .manual, date: date, timeZone: zone)
  }
}
