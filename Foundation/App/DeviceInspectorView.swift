// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI
import AppKit

struct DeviceInspectorView: View {
  @ObservedObject var model: RewindDVModel
  @ObservedObject var live: LiveMonitorModel
  let activationInFlight: Bool
  @State private var stoppedConfirmed = false
  private var blocked: Bool {
    model.navigationLocked || activationInFlight || live.active || live.busy
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("DEVICE INSPECTOR").font(.largeTitle.bold()).foregroundStyle(.white)
        Text("Device information and transport capabilities are read automatically on connection. Original responses and optional diagnostic refreshes are available here.").foregroundStyle(.secondary)
        Text(model.handshakeFeedback).foregroundStyle(.secondary)
        ArchiveSection("Connected device") {
          VStack(alignment: .leading, spacing: 12) {
            if let deck = model.selectedDeck {
              Text(deck.name.isEmpty ? "Discovered device" : deck.name).font(.headline)
              Text("\(deck.guidText) · node \(deck.node) · generation \(deck.generation)")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            } else {
              Text("Waiting for automatic driver discovery. Select a device in Workspace when available.")
            }
            Toggle("I have confirmed the tape is stopped", isOn: $stoppedConfirmed).disabled(blocked)
            Button(model.isBusy ? "Reading device…" : "Read device information", systemImage: "info.circle") {
              stoppedConfirmed = false
              model.inspectDevice()
            }.disabled(blocked || !stoppedConfirmed || model.selectedDeck == nil)
            Text("Unit information, bounded subunit pages, and unit plug counts only. No tape-motion, power, record, or erase commands. Capture must be idle.")
              .font(.callout).foregroundStyle(.secondary)
            Button("Read tape status (read-only)", systemImage: "list.clipboard") {
              stoppedConfirmed = false
              model.inspectDevice(tapeStateOnly: true)
            }.disabled(blocked || !stoppedConfirmed || model.selectedDeck == nil)
            Text("Whole-tape qualification: three exact STATUS requests for medium, transport and DV absolute track number. No tape motion or automatic capture. BOT/EOT and unattended completion remain unqualified.")
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        if let error = model.inspectionError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        ArchiveSection("Safe transport capability catalog") {
          VStack(alignment: .leading, spacing: 12) {
            Text("Six exact SPECIFIC INQUIRY commands: Play, Stop, Rewind, Fast-forward and forward/reverse picture search. No tape motion, power changes or opcode scanning.")
            Button(model.isBusy ? "Working…" : "Probe transport capabilities", systemImage: "list.bullet.rectangle") {
              stoppedConfirmed = false
              model.probeCapabilities()
            }.disabled(blocked || !stoppedConfirmed || model.selectedDeck == nil)
            Text("Manual diagnostic refresh requires the stopped confirmation above. Transport buttons stay visible; Fast-forward and picture search require a positive current-connection inquiry, checked again by the driver.")
              .font(.caption).foregroundStyle(.secondary)
            if let error = model.capabilityError { Text(error).foregroundStyle(.orange) }
            if let report = model.capabilityReport {
              Text(report.completion)
              Text("Observed \(report.observedAt.formatted()) · \(String(format: "0x%016llX", report.route.guid)) · generation \(report.route.generation)")
                .font(.caption.monospacedDigit())
              if model.selectedRoute != report.route {
                Text("Historical observation: the current connection no longer matches. Probe again while stopped.")
                  .foregroundStyle(.orange)
              }
              ForEach(report.entries) { entry in
                ArchiveDisclosure("\(entry.command.title): \(entry.support.title)") {
                  Text(entry.detail).frame(maxWidth: .infinity, alignment: .leading)
                  ForEach(Array(entry.responses.enumerated()), id: \.offset) { _, bytes in
                    Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                      .font(.caption.monospaced()).textSelection(.enabled)
                  }
                }
              }
              Button("Show capability evidence", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([report.receiptURL])
              }
            } else {
              ForEach(TransportCapabilityCatalog.commands) { command in
                LabeledContent(command.title, value: "Not queried")
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        if let report = model.inspectionReport {
          ArchiveSection("Recorded observation — not a live capability guarantee") {
            VStack(alignment: .leading, spacing: 8) {
              Text("\(report.deck.guidText) · \(report.observedAt.formatted())")
              Text(report.completion)
              Text("Full route identity is retained in the evidence. Reconnection or reset invalidates any authority to reuse this observation.")
                .font(.caption).foregroundStyle(.secondary)
              Button("Show inspection evidence", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([report.receiptURL])
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
          ForEach(report.entries) { entry in
            ArchiveSection(entry.query.title) {
              VStack(alignment: .leading, spacing: 8) {
                Text(entry.disposition).font(.headline)
                ForEach(entry.facts) { fact in LabeledContent(fact.label, value: fact.value) }
                ArchiveDisclosure("Original AV/C response") {
                  Text(entry.response.isEmpty ? "No response bytes available" : entry.response.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
          }
        }
        Text("Plug counts do not establish connections, formats, or supported transport commands. Unknown and failed observations are never presented as zero or unsupported.")
          .font(.callout).foregroundStyle(.secondary)
      }.padding(28)
    }
    .accessibilityIdentifier("device-inspector-page")
  }
}
