// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(RewindDVArchiveCore)
import RewindDVArchiveCore
#endif

/// A view model over immutable evidence. Only exact repeated interpretations
/// coalesce; distinct codes, context qualifications and conflicts stay separate.
public enum DVInspectorBrowser {
  public enum Category: String, CaseIterable, Identifiable, Sendable {
    case all="All metadata", camera="Camera", recording="Recording", video="Video", audio="Audio", text="Text & captions", structure="Tape structure", other="Other"
    public var id:String { rawValue }
  }
  public struct Entry: Identifiable, Sendable {
    public let id:String
    public let name:String
    public let value:String
    public let category:Category
    public let source:String
    public let field:DVPackSemanticReport.Field?
    public var observations:[String]
    public var count:Int
    public var badge:String? {
      guard let field else { return nil }
      if field.status == "invalid" { return "Invalid" }
      if field.status == "conflicting" { return "Conflicting" }
      if field.confidence == .conflictingEvidence { return "Unresolved" }
      if field.status == "unavailable" { return field.meaning == "No information" ? "Not recorded" : field.meaning == "Not used" || field.meaning.lowercased().contains("not applicable") ? "Not applicable":"Unavailable" }
      if field.status == "reserved" { return "Reserved" }
      if field.status == "uninterpreted" { return "Undecoded" }
      if field.confidence == .provisional || field.confidence == .mostLikely { return "Provisional" }
      return nil
    }
  }
  public static func entries(_ report:DVPackSemanticReport) -> [Entry] {
    var result:[Entry]=[],indices:[String:Int]=[:]
    func add(_ field:DVPackSemanticReport.Field,source:String,category:Category,observation:String,count:Int) {
      let numeric=field.numeric.map { "\($0.bitWidth)|\($0.unit)|\($0.relation)|\($0.rule)" } ?? ""
      let key=[source,field.id,String(field.rawValue),field.meaning,field.status,field.confidence.rawValue,field.qualifier ?? "",field.reference,numeric].joined(separator:"\u{1f}")
      if let index=indices[key] { result[index].observations.append(observation);result[index].count += count }
      else {
        indices[key]=result.count
        let value=friendlyValue(field)+(source == "DIF structure" ? " · code \(field.rawValue)":"")
        result.append(.init(id:key,name:displayName(field),value:value,category:category,source:source,field:field,observations:[observation],count:count))
      }
    }
    for pack in report.packs {
      let h=UInt8(pack.typeHex.dropFirst(2),radix:16) ?? 255
      let category:Category=(0x70...0x7f).contains(h) ? .camera : h&15 == 8 || h&15 == 9 || h == 0x65 || h == 0x67 ? .text : (0x50...0x5f).contains(h) ? .audio : (0x60...0x6f).contains(h) ? .video : h<0x50 ? .recording:.other
      let observation=pack.name+"\n"+pack.rawHex+"\n"+pack.status+"\n"+(pack.locations?.map(DVMetadataPresentation.location).joined(separator:"\n") ?? pack.sourceByteOffsets.map { "Source byte \($0)" }.joined(separator:"\n"))
      let fields=pack.fields.isEmpty ? DVMetadataPresentation.rawPayloadFields(pack):pack.fields
      let selectors:[String]=["0x16":["CATALOGUE_FORM"],"0x17":["ISRC_FORM"],"0x6D":["COORDINATE_FORM"],"0x7D":["CHANNEL","WB","SHADING_FORM"]][pack.typeHex] ?? []
      let names=selectors.compactMap { id in pack.fields.first{$0.id == id && $0.status == "interpreted"}?.meaning }
      let source=([pack.typeHex]+names).joined(separator:" · ")
      for field in fields { add(field,source:source,category:category,observation:observation,count:pack.observationCount) }
    }
    for item in report.structuralMetadata ?? [] {
      for field in item.fields {
        add(field,source:"DIF structure",category:.structure,observation:item.name+"\n"+item.rawHex+"\n"+item.locations.map(DVMetadataPresentation.location).joined(separator:"\n"),count:item.locations.count)
      }
    }
    for (index,sequence) in (report.sequences ?? []).enumerated() {
      let source="Sequence \(index+1)",observation=sequence.reference+"\n"+(sequence.textInterpretation ?? "")
      func sequenceEntry(_ id:String,_ name:String,_ value:String) {
        result.append(.init(id:source+id,name:name,value:value,category:sequence.kind == "line" ? .video:sequence.kind == "catalogue number" ? .recording:.text,source:source,field:nil,observations:[observation],count:sequence.observations.count))
      }
      sequenceEntry("status","Recorded \(sequence.kind) sequence",sequence.status)
      sequenceEntry("length","Expected sequence length","\(sequence.expectedCount) \(sequence.countUnit)")
      sequenceEntry("payload","Observed sequence payload","\(sequence.payload.count) bytes")
      if let text=sequence.decodedText { sequenceEntry("text",sequence.kind == "catalogue number" ? "Recorded catalogue number":"Recorded text",text) }
      else if let status=sequence.textInterpretation { sequenceEntry("text-status","Text interpretation",status) }
      for (set,code) in (sequence.characterSets ?? [:]).sorted(by:{$0.key<$1.key}) {
        sequenceEntry(set,"Character designation \(set)",DVIEC61834.characterSetName(code))
      }
      if let id=sequence.firstTeletextID {
        sequenceEntry("teletext-id","First teletext identifier",([0:"Japanese teletext",1:"North American teletext",3:"UK teletext"][Int(id.system)] ?? "Reserved system")+" · "+id.status)
        sequenceEntry("teletext-line","First teletext field and line",(id.secondField ? "Second field":"First field")+" · "+(id.lineNumber.map { "line \($0)" } ?? id.status))
      }
      for field in sequence.teletextInformation ?? [] { add(field,source:source+" · teletext information",category:.text,observation:observation,count:1) }
      for (i,component) in (sequence.components ?? []).enumerated() {
        sequenceEntry("component\(i)","Line component \(i+1)",String(format:"0x%02X",component.header)+" · \(component.status) · \(component.samples.count) observed samples · \(component.expectedSamples.map(String.init) ?? "unknown") expected samples · \(component.padding.count) padding samples")
      }
    }
    return result.sorted { ($0.category.rawValue,$0.source,$0.name,$0.id)<($1.category.rawValue,$1.source,$1.name,$1.id) }
  }
  public static func filter(_ entries:[Entry],query:String,category:Category) -> [Entry] {
    let term=query.trimmingCharacters(in:.whitespacesAndNewlines)
    return entries.filter { entry in
      (category == .all || entry.category == category) && (term.isEmpty || [entry.name,entry.value,entry.source,entry.field?.id ?? "",entry.field?.reference ?? ""].contains(where:{$0.localizedCaseInsensitiveContains(term)}))
    }
  }
  public static func friendlyValue(_ field:DVPackSemanticReport.Field) -> String {
    if field.status == "unavailable" && field.meaning == "No information" { return "Not recorded" }
    if field.id == "IRIS",field.meaning.hasSuffix(" f-number") { return "f/"+field.meaning.replacingOccurrences(of:" f-number",with:"") }
    if field.numeric?.unit == "s",field.status == "interpreted",let n=Double(field.meaning.replacingOccurrences(of:" s",with:"")),n>0,n<0.1 { return String(format:"%.5g ms",n*1000) }
    return field.meaning
  }
  public static func displayName(_ field:DVPackSemanticReport.Field) -> String {
    let names=["DSF":"DV system flag","DFTIA":"Track and pilot application code","APT":"Track application identifier","FR":"DIF sequence half","SYNC":"Sync block number","ID_PARITY":"Sync identifier filler byte", "ID_LOW4":"Recorded identifier low bits", "ID1_HIGH4":"Recorded identifier high bits", "ID_RESERVED":"Sync identifier format bits","ATN_HIGH_NIBBLE":"Absolute track number high fragment","ATN_LOW3":"Absolute track number low three bits","ATN_LOW4":"Absolute track number low four bits","ATN_FRAGMENT":"Absolute track number fragment","ATN":"Absolute track number","BF":"Blank flag","TRACK_PITCH":"Track pitch code","PILOT":"Pilot frame indication","INDEX":"Index identifier","SKIP":"Skip identifier","PP":"Picture identifier"]
    if let name=names[field.id],field.name == field.id { return name }
    if field.name == field.id && field.id.hasPrefix("TF") { return "Section \(field.id.dropFirst(2)) transmission flag" }
    if field.name == field.id && field.id.hasPrefix("AP") { return "Section \(field.id.dropFirst(2)) application identifier" }
    return field.name
  }
}
