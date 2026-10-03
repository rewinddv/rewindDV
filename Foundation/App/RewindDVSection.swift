// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// A native semantic section card used in scrollable workspaces.
///
/// SwiftUI's `GroupBox` nested in `ScrollView` currently exposes an unstable
/// transformed accessibility subtree on macOS 26. RewindDV keeps the same
/// visual hierarchy without that framework combination, and gives assistive
/// clients one stable section heading followed by the section's controls.
struct RewindDVSection<LabelContent: View, SectionContent: View>: View {
  private let label: LabelContent
  private let content: SectionContent

  init(
    @ViewBuilder content: () -> SectionContent,
    @ViewBuilder label: () -> LabelContent
  ) {
    self.label = label()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      label.font(.headline).accessibilityAddTraits(.isHeader)
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
  }
}

extension RewindDVSection where LabelContent == Text {
  init(_ title: String, @ViewBuilder content: () -> SectionContent) {
    self.init(content: content) { Text(title) }
  }
}

/// Analysis, Device Inspector and Diagnostics heading grammar. Metadata field names retain their separate
/// yellow-label/white-value treatment; this style is for navigation headings.
struct ArchiveHeading: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title.uppercased()).font(.headline.bold()).foregroundStyle(.blue)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Independent disclosure state, with contents kept mounted. Collapsing must
/// not cancel analysis via onDisappear, discard an edited review, or reset a
/// nested disclosure. Hidden controls are excluded from hit testing and AX.
struct ArchiveDisclosure<Content: View>: View {
  let title: String
  let content: Content
  @State private var expanded = false
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title; self.content = content()
  }
  var body: some View {
    VStack(alignment: .leading, spacing: expanded ? 10 : 0) {
      Button {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { expanded.toggle() }
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right").accessibilityHidden(true)
          ArchiveHeading(title)
          Spacer(minLength: 0)
        }.foregroundStyle(.blue).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(title.uppercased())
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Expand or collapse this section independently")
        .accessibilityIdentifier("archive-section-" + title)
      VStack(alignment: .leading, spacing: 10) { content }
        .accessibilityElement(children: .contain)
        .frame(height: expanded ? nil : 0, alignment: .top)
        .clipped().opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded).disabled(!expanded).accessibilityHidden(!expanded)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ArchiveSection<Content: View>: View {
  let title: String
  let content: Content
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title; self.content = content()
  }
  var body: some View {
    ArchiveDisclosure(title) { content }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1)
          .accessibilityHidden(true)
      }.accessibilityElement(children: .contain)
  }
}
