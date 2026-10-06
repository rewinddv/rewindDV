// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Darwin
import Testing
@testable import RewindDVArchiveCore

@Test func cancelledDVIngestNeverBeginsPublication() async throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
  defer { try? FileManager.default.removeItem(at: fixture.url) }
  let cancelled = await Task.detached {
    withUnsafeCurrentTask { $0?.cancel() }
    do { _ = try DVIngestExporter.exportClosedFlight(at: fixture.url); return false }
    catch is CancellationError { return true }
    catch { return false }
  }.value
  #expect(cancelled)
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("frames.ndjson.partial").path))
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
}

@Test func cancelledDVPayloadPublicationCanResumeWithFreshTask() async throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
  defer { fixture.cleanup() }
  // Produce verified partials without crossing the publication boundary.
  await Task.detached {
    do {
      _ = try DVIngestExporter.exportClosedFlight(at: fixture.url) { progress in
        if progress.phase == .publishingVerifiedFiles { withUnsafeCurrentTask { $0?.cancel() } }
      }
      Issue.record("Expected cancellation")
    } catch is CancellationError {} catch { Issue.record(error) }
  }.value
  let cancelled = await Task.detached {
    do {
      try DVIngestExporter.publishVerifiedOutputs(hasNativeDV: true, promote: { name in
        let bytes = try Data(contentsOf: fixture.url.appendingPathComponent(name + ".partial"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try DVIngestExporter.promote(name, in: fixture.url, expectedBytes: UInt64(bytes.count), expectedSHA256: sha)
        if name == "capture.dv" { withUnsafeCurrentTask { $0?.cancel() } }
      }, syncDirectory: {}, withdrawMarker: { Issue.record("No marker should exist") })
      return false
    } catch is CancellationError { return true } catch { Issue.record(error); return false }
  }.value
  #expect(cancelled)
  #expect(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("capture.dv").path))
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  let resumed = try await Task.detached { try DVIngestExporter.resumeVerifiedPublication(at: fixture.url) }.value
  #expect(resumed.integritySHA256Verified)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
}

@Test func cancellationAfterMarkerCommitStillCompletesDurabilityBarrier() async throws {
  let calls = try await Task.detached {
    var calls: [String] = []
    try DVIngestExporter.publishVerifiedOutputs(hasNativeDV: true, promote: { name in
      calls.append(name)
      if name == "verification.json" { withUnsafeCurrentTask { $0?.cancel() } }
    }, syncDirectory: { calls.append("barrier") }, withdrawMarker: { calls.append("withdraw") })
    return calls
  }.value
  #expect(calls == ["capture.dv", "frames.ndjson", "barrier", "verification.json", "barrier"])
}

@Test(arguments: [DVIngestProgressPhase.reconstructingNativeDV, .rereadingNativeDV,
                  .rereadingRawEvidence, .rereadingFrameManifest, .publishingVerifiedFiles])
func dvIngestCancellationRetainsEvidenceWithoutSuccess(phase: DVIngestProgressPhase) async throws {
  let fixture = try IngestFixture(packets: ingestPackets(ingestFrame(pal: false)))
  defer { try? FileManager.default.removeItem(at: fixture.url) }
  let journal = try Data(contentsOf: fixture.url.appendingPathComponent("flight.ndjson"))
  let cancelled = await Task.detached {
    do {
      _ = try DVIngestExporter.exportClosedFlight(at: fixture.url) { progress in
        if progress.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
      }
      return false
    } catch is CancellationError { return true }
    catch { return false }
  }.value
  #expect(cancelled)
  #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("verification.json").path))
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("receive.records.raw")) == fixture.raw)
  #expect(try Data(contentsOf: fixture.url.appendingPathComponent("flight.ndjson")) == journal)
}
