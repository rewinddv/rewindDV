// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import SwiftUI
#if canImport(RewindDVMonitorCore)
import RewindDVMonitorCore
#endif

/// Owned by the workspace, above the responsive layout and tab branches.
struct DVInspectorPresentationState {
  var tab = 0
  var query = ""
  var category = DVInspectorBrowser.Category.all
  var showFormatChecks = false
  var page = 0
}

struct DVInspectorBrowserView: View {
  let report:DVPackSemanticReport
  @Binding var query:String
  @Binding var category: DVInspectorBrowser.Category
  @Binding var showFormatChecks: Bool
  @Binding var page: Int
  private let pageSize=32
  var body:some View {
    let all=DVInspectorBrowser.entries(report)
    let filtered=DVInspectorBrowser.filter(all,query:query,category:category).filter {
      showFormatChecks || !query.isEmpty || ($0.field.map { !DVMetadataPresentation.isFormatDetail($0) } ?? true)
    }
    let pages=max(1,(filtered.count+pageSize-1)/pageSize),selected=min(page,pages-1)
    VStack(alignment:.leading,spacing:12) {
      HStack {
        Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
        TextField("Find a setting, value or pack ID",text:$query)
          .textFieldStyle(.plain).accessibilityIdentifier("inspector-field-search")
        if !query.isEmpty { Button { query="" } label:{ Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear metadata search") }
      }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
      HStack {
        Picker("Metadata category",selection:$category) {
          ForEach(DVInspectorBrowser.Category.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().accessibilityIdentifier("inspector-category")
        Spacer(minLength:4)
        Text("\(filtered.count) \(filtered.count == 1 ? "field":"fields")").font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Include format checks",isOn:$showFormatChecks).font(.caption)
        .accessibilityIdentifier("inspector-format-checks")
      if filtered.isEmpty {
        Text("No matching recorded fields in this frame.").foregroundStyle(.secondary).padding(.vertical,12)
      }
      ForEach(Array(filtered.dropFirst(selected*pageSize).prefix(pageSize))) { entry in
        DVInspectorFieldRow(entry:entry)
        Divider()
      }
      if pages>1 {
        HStack {
          Button("Previous") { page=max(0,selected-1) }.disabled(selected==0)
          Spacer()
          Text("\(selected+1) of \(pages)").font(.caption).monospacedDigit()
          Spacer()
          Button("Next") { page=min(pages-1,selected+1) }.disabled(selected==pages-1)
        }.controlSize(.small).accessibilityIdentifier("inspector-field-pages")
      }
      Text("Current frame only. Exact repetitions share a row; distinct values remain separate. Details retain original codes, references and every observation.")
        .font(.caption2).foregroundStyle(.secondary)
    }.onChange(of:query) { _,_ in page=0 }.onChange(of:category) { _,_ in page=0 }
      .onChange(of:showFormatChecks) { _,_ in page=0 }
  }
}

private struct DVInspectorFieldRow:View {
  let entry:DVInspectorBrowser.Entry
  @State private var details=false
  var body:some View {
    HStack(alignment:.top,spacing:8) {
      VStack(alignment:.leading,spacing:4) {
        Text(entry.name).font(.callout.weight(.medium))
        Text(entry.value).font(.callout).foregroundStyle(valueColor).textSelection(.enabled)
          .fixedSize(horizontal:false,vertical:true)
        HStack(spacing:6) {
          Text(entry.source).font(.caption2.monospaced()).foregroundStyle(.secondary)
          if let badge=entry.badge {
            Text(badge).font(.caption2).foregroundStyle(valueColor)
              .padding(.horizontal,5).padding(.vertical,2).background(valueColor.opacity(0.09),in:Capsule())
          }
          if entry.count>1 { Text("\(entry.count) observations").font(.caption2).foregroundStyle(.secondary) }
        }
      }.frame(maxWidth:.infinity,alignment:.leading)
      Button { details.toggle() } label:{ Image(systemName:"info.circle") }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Details for \(entry.name)")
        .popover(isPresented:$details,arrowEdge:.trailing) { DVInspectorFieldDetails(entry:entry) }
    }.accessibilityElement(children:.contain)
      .accessibilityIdentifier("inspector-field-"+entry.source+"-"+(entry.field?.id ?? entry.name))
  }
  private var valueColor:Color {
    if ["Invalid","Conflicting"].contains(entry.badge ?? "") { return .red }
    if ["Unresolved","Provisional"].contains(entry.badge ?? "") { return .orange }
    if entry.badge != nil { return .secondary }
    return .primary
  }
}

private struct DVInspectorFieldDetails:View {
  let entry:DVInspectorBrowser.Entry
  @State private var page=0
  var body:some View {
    let pages=max(1,(entry.observations.count+7)/8),selected=min(page,pages-1)
    ScrollView {
      VStack(alignment:.leading,spacing:10) {
        Text(entry.name).font(.headline)
        if let field=entry.field {
          LabeledContent("Original meaning",value:field.meaning)
          LabeledContent("Recorded code",value:String(format:"%u · 0x%X",field.rawValue,field.rawValue))
          LabeledContent("Interpretation",value:field.confidence.label+" · "+field.status)
          Text(field.reference).font(.caption)
          if let qualifier=field.qualifier { Text(qualifier).font(.caption).foregroundStyle(.secondary) }
          if field.numeric != nil { Text(DVMetadataPresentation.fieldCaption(field)).font(.caption.monospaced()) }
        }
        Divider()
        Text("Source observations").font(.subheadline.weight(.semibold))
        ForEach(Array(entry.observations.dropFirst(selected*8).prefix(8).enumerated()),id:\.offset) { _,text in
          Text(text).font(.caption.monospaced()).textSelection(.enabled)
        }
        if pages>1 {
          HStack {
            Button("Previous observations") { page=max(0,selected-1) }.disabled(selected==0)
            Text("\(selected+1) / \(pages)").font(.caption)
            Button("Next observations") { page=min(pages-1,selected+1) }.disabled(selected==pages-1)
          }.controlSize(.small)
        }
      }.padding(16).textSelection(.enabled)
    }.frame(width:380,height:400)
  }
}
