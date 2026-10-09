// Test-only state adapter. Compiled in the same file as the production model. No bridge call.

extension LiveMonitorModel {
  func beginOfflineWorkspaceReplay() async {
    active = true; hasCurrentPreview = true; ingestRequested = true; receiverReady = true
    await preview.begin();markCaptureTransportPlaying()
  }
  func observeOfflineWorkspaceFrame(_ frame: Data, ordinal: UInt64, publish: Bool) {
    var next = captureElapsed;next.observeCompleteDVFrame(byteCount: frame.count)
    if next != captureElapsed { captureElapsed = next }
    preview.offerPreservedFrame(frame, ordinal: ordinal, sourceTimecode: LiveDVMedia(frame: frame)?.timecode)
    if publish {
      detail = "OFFLINE REPLAY — saved DV, no hardware access"
      packetsSeen = (ordinal+1)*300;knownDroppedPackets = 0;oversizedPackets = 0
      completeFrames = ordinal+1;incompleteFrames = 0;continuityBreaks = 0;rejectedPackets = 0
      deliverySkips = 0;pendingDurabilityRecords = 0;durableRecords = (ordinal+1)*300;writerUnderPressure = false
    }
  }
  func endOfflineWorkspaceReplay() async { markCaptureTransportStopped();await preview.end();active = false }
}
