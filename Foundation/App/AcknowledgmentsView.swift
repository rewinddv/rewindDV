// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct AcknowledgmentsView: View {
  private let documents = [
    ("ASFireWire, MediaInfoLib, DVRescue and downstream changes", "ThirdPartyNotices"),
    ("Upstream attribution notices", "ASFireWire-NOTICE"),
    ("Apache License 2.0", "ASFireWire-LICENSE")
  ]
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Acknowledgments").font(.largeTitle.bold())
        Text("rewindDV includes modified ASFireWire software, selected metadata mappings adapted from MediaInfoLib, and DV25 block geometry adapted from DVRescue. We gratefully acknowledge their contributors.")
        ForEach(documents, id: \.1) { title, resource in
          RewindDVSection(title) {
            Text(text(resource)).font(.callout).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
        }
      }.padding(24)
    }.frame(minWidth: 620, minHeight: 500)
  }
  private func text(_ name: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
      let value = try? String(contentsOf: url, encoding: .utf8) else {
      return "Required notice is missing from this package. This candidate must not be distributed."
    }
    return value
  }
}
