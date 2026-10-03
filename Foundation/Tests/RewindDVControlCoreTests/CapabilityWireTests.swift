import Foundation
import Testing
@testable import RewindDVControlCore

private func put<T: FixedWidthInteger>(_ v: T, _ o: Int, _ data: inout Data) {
  var le = v.littleEndian
  withUnsafeBytes(of: &le) { data.replaceSubrange(o..<(o+$0.count), with: $0) }
}
private func route(_ epoch: UInt64 = 12) throws -> FoundationRoute {
  var d = Data(count: 48)
  put(UInt32(1),0,&d); put(UInt32(48),4,&d)
  for (o,v) in [(8,UInt64(0xa1b2c3d4e5f60718)),(16,10),(24,11),(32,epoch)] { put(v,o,&d) }
  put(UInt32(4),40,&d); put(UInt16(1),44,&d)
  return try FoundationRoute(data:d)
}
private func fixture(_ command: DeckCommand = .fastForward, supported: Bool = true) throws -> Data {
  let r = try route(); var d = Data(count:1264)
  for (o,v) in [(0,UInt32(1)),(4,1264),(112,4),(116,command.rawValue),
    (120,supported ? (command.rawValue >= DeckCommand.fastForward.rawValue ? 0x17f : 0x7f) : 0xbf),
    (124,supported ? 2 : 3),(136,4),(140,1),(152,1),(156,supported ? 1 : 2),
    (160,supported ? (command.rawValue >= DeckCommand.fastForward.rawValue ? 2 : 1) : 0),(192,4),(200,supported ? 2 : 3),(204,4)] { put(v,o,&d) }
  for (o,v) in [(8,UInt64(1)),(16,2),(24,3),(32,r.guid),(40,10),(48,11),(56,12),
    (64,13),(72,14),(80,100),(88,101),(96,102),(104,104),(176,103),(184,13)] { put(v,o,&d) }
  put(UInt16(1),148,&d); put(UInt16(1),196,&d)
  d.replaceSubrange(168..<172,with:TransportCapabilityCatalog.inquiry(command))
  d.replaceSubrange(208..<212,with:[supported ? 0x0c : 0x08] + command.frame.dropFirst())
  return d
}

@Test func exactCapabilityCatalogAndRequests() throws {
  var d = Data(count:176)
  for (i,v) in [UInt32(1),176,6,0x3f,1,128,512,2].enumerated() { put(v,i*4,&d) }
  for (i,c) in TransportCapabilityCatalog.commands.enumerated() {
    let o = 32+i*24
    put(c.rawValue,o,&d); put(UInt32(c.rawValue >= DeckCommand.fastForward.rawValue ? 13 : 11),o+4,&d)
    put(UInt32(4),o+8,&d); put(UInt32(4),o+12,&d)
    d.replaceSubrange((o+16)..<(o+20),with:TransportCapabilityCatalog.inquiry(c))
    d.replaceSubrange((o+20)..<(o+24),with:c.frame)
    let request = try TransportCapabilityCatalog.request(c,operationID:2,attemptID:3,route:route())
    #expect(request.count == 72 && request[64] == UInt8(c.rawValue))
    #expect(request[62..<64].allSatisfy { $0 == 0 } && request[68..<72].allSatisfy { $0 == 0 })
  }
  try TransportCapabilityCatalog.validate(d)
  for i in 0..<d.count {
    var bad = d; bad[i] ^= 1
    #expect(throws:ControlWireError.self) { try TransportCapabilityCatalog.validate(bad) }
  }
  #expect(TransportCapabilityCatalog.inquiry(.fastForward) == [2,32,196,117])
  #expect(DeckCommand.fastForward.frame == [0,32,196,117])
  #expect(TransportCapabilityCatalog.inquiry(.shuttleForward) == [2,32,195,63])
  #expect(TransportCapabilityCatalog.inquiry(.shuttleReverse) == [2,32,195,79])
  #expect(DeckCommand.shuttleForward.frame == [0,32,195,63])
  #expect(DeckCommand.shuttleReverse.frame == [0,32,195,79])
  #expect(DeckCommand(rawValue:7) == nil)
}

@Test func supportRequiresExactBoundTerminalEvidence() throws {
  let r = try route()
  func decode(_ d:Data) throws -> TransportCapabilityResult {
    try .init(data:d,requestID:1,operationID:2,attemptID:3,route:r,command:.fastForward)
  }
  let f = try fixture()
  #expect(try decode(f).conditionalAuthorization)
  #expect(try decode(fixture(supported:false)).support == .notImplemented)
  for n in [0,72,176,720,1263] {
    #expect(throws:ControlWireError.self) { try decode(Data(f.prefix(n))) }
  }
  for o in [8,16,24,32,40,48,56,112,116,132,136,148,150,164,168,172,184,192,198,200,208,211,719,720] {
    var bad = f; bad[o] ^= 0x80
    #expect(throws:ControlWireError.self) { try decode(bad) }
  }
  var wrongNode = f; put(UInt16(2),196,&wrongNode)
  #expect(throws:ControlWireError.self) { try decode(wrongNode) }
  var busQualifiedNode = f; put(UInt16(0xffc1),196,&busQualifiedNode)
  #expect(try decode(busQualifiedNode).conditionalAuthorization)
  // Synchronous completion may precede WriteBlock returning its accepted handle.
  var immediate = f; put(UInt64(105),96,&immediate)
  #expect(try decode(immediate).conditionalAuthorization)
  for (o,v) in [(120,UInt32(0x17b)),(72,0),(88,0),(96,0),(176,0)] {
    var bad=f; put(v,o,&bad)
    #expect(throws:ControlWireError.self) { try decode(bad) }
  }
  for (o,v) in [(128,UInt32(1)),(140,0),(144,1),(152,2),(156,0),(160,1)] {
    var bad=f; put(v,o,&bad)
    #expect(throws:ControlWireError.self) { try decode(bad) }
  }
  for response in [UInt8(0x09),0x0a,0x0b,0x0f] {
    var bad=f; bad[208]=response
    #expect(throws:ControlWireError.self) { try decode(bad) }
  }
  let report = TransportCapabilityReport(route:r, observedAt:Date(), receiptURL:URL(fileURLWithPath:"/offline-fixture"),
    entries:[.init(command:.fastForward,support:.implemented,detail:"fixture",responses:[],conditionalAuthorization:true)],
    completion:"synthetic",lockedOut:false)
  #expect(report.permitsFastForward(on:r))
  #expect(!report.permitsFastForward(on:nil))
  #expect(!report.permitsFastForward(on:try route(13)))
  let shuttleReport = TransportCapabilityReport(route:r, observedAt:Date(), receiptURL:URL(fileURLWithPath:"/offline-fixture"),
    entries:[.init(command:.shuttleForward,support:.implemented,detail:"fixture",responses:[],conditionalAuthorization:true),
      .init(command:.shuttleReverse,support:.implemented,detail:"fixture",responses:[],conditionalAuthorization:true)],
    completion:"synthetic",lockedOut:false)
  #expect(shuttleReport.permits(.shuttleForward,on:r))
  #expect(shuttleReport.permits(.shuttleReverse,on:r))
  #expect(!shuttleReport.permits(.play,on:r))
}

@Test func capabilityJournalNamesTheCorrectProtocol() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let flight=try InspectorFlight(parentDirectory:root,capabilityProbe:true)
  try flight.append(event:"offline_test",query:nil,route:nil,command:.fastForward)
  try flight.finish()
  let d=try Data(contentsOf:flight.directoryURL.appendingPathComponent("flight.ndjson"))
  let json=try #require(JSONSerialization.jsonObject(with:d) as? [String:Any])
  #expect(json["schema"] as? String == "rewinddv.transport-capabilities.v1")
  #expect(json["query"] as? String == "Fast-forward tape")
}
