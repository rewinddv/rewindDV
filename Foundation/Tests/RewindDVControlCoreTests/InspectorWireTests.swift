import Foundation
import Testing
@testable import RewindDVControlCore

@Test func explicitReceiptsKeepTheirOriginalFieldSet() throws {
  for mode in 0..<3 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let flight = try InspectorFlight(parentDirectory: root, capabilityProbe: mode == 1, tapeStateProbe: mode == 2)
    try flight.append(event: "schema_regression", query: nil, route: nil)
    try flight.finish()
    let bytes = try Data(contentsOf: flight.directoryURL.appendingPathComponent("flight.ndjson"))
    let record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(Set(record.keys) == Set(["schema", "parser", "protocolReference", "utc", "event"]))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("observationID"))
  }
}

@Test func passiveSegmentDirectoryFailureIsStickyAtCreationAndRotation() throws {
  for failAt in [1, 2] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var limits = PassiveInspectorStore.Limits(); limits.segmentBytes = 1
    var calls = 0
    let store = try PassiveInspectorStore(root: root, limits: limits, segmentDirectoryBarrier: { _ in
      calls += 1
      if calls == failAt { throw CocoaError(.fileWriteUnknown) }
    })
    if failAt == 2 {
      let flight = try InspectorFlight(compact: store)
      try flight.append(event: "prior_durable_observation", query: .tapeTransportState, route: nil)
      try flight.finish()
    }
    #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
    let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
    let before = try files.map { try Data(contentsOf: $0) }
    #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
    #expect(calls == failAt, "A failed directory barrier must never be bypassed or automatically retried")
    #expect(try files.map { try Data(contentsOf: $0) } == before)
    #expect(files.count == failAt)
  }
}

@Test func passiveInspectorRotatesBetweenObservationsAndRetainsRawReceipts() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var limits = PassiveInspectorStore.Limits(); limits.segmentBytes = 1
  let store = try PassiveInspectorStore(root: root, limits: limits)
  var ids: [String] = []
  for _ in 0..<12 {
    let flight = try InspectorFlight(compact: store)
    ids.append(flight.observationID.uuidString)
    try flight.append(event: "query_intent_durable", query: .tapeTransportState, route: Data([1]), request: Data([2]))
    try flight.append(event: "query_result_returned", query: .tapeTransportState, route: Data([1]), result: Data([3]))
    try flight.finish()
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
  let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
  #expect(files.count == 12)
  for (index, file) in files.enumerated() {
    let lines = try Data(contentsOf: file).split(separator: 10)
    #expect(lines.count == 2)
    for line in lines {
      let event = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      #expect(event["observationID"] as? String == ids[index])
      #expect(event["route"] as? String == Data([1]).base64EncodedString())
      #expect((event["hostUptimeNanoseconds"] as? NSNumber)?.uint64Value ?? 0 > 0)
    }
  }
}

@Test func passiveInspectorBudgetStopsBeforeNextIntentAndNeverDeletesEvidence() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var limits = PassiveInspectorStore.Limits(); limits.sessionBytes = 64 * 1024
  let store = try PassiveInspectorStore(root: root, limits: limits)
  let flight = try InspectorFlight(compact: store)
  #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
  try flight.append(event: "read_only", query: .tapeTransportState, route: nil)
  try flight.finish()
  let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
  let before = try Data(contentsOf: #require(files.first))
  #expect(throws: (any Error).self) { try InspectorFlight(compact: store) }
  #expect(try Data(contentsOf: #require(files.first)) == before)
}

private func write<T: FixedWidthInteger>(_ value: T, _ offset: Int, _ data: inout Data) {
  var le = value.littleEndian
  withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
}

private func inspectorRoute() throws -> FoundationRoute {
  var data = Data(count: 48)
  write(UInt32(1), 0, &data); write(UInt32(48), 4, &data)
  for (offset,value) in [(8,UInt64(0xa1b2c3d4e5f60718)),(16,10),(24,11),(32,12)] { write(value,offset,&data) }
  write(UInt32(4),40,&data); write(UInt16(1),44,&data)
  return try FoundationRoute(data: data)
}

private func inspectorResultFixture() throws -> Data {
  let route = try inspectorRoute()
  var data = Data(count: InspectorResult.wireBytes)
  for (offset,value) in [(0,UInt32(1)),(4,1284),(112,4),(116,1),(120,0x7f),(124,3),
    (136,8),(140,1),(152,1),(156,1),(212,4),(220,3),(224,8)] { write(value,offset,&data) }
  for (offset,value) in [(8,UInt64(1)),(16,2),(24,3),(32,route.guid),(40,10),(48,11),(56,12),
    (64,13),(72,14),(80,100),(88,101),(96,102),(104,104),(196,103),(204,13)] { write(value,offset,&data) }
  write(UInt16(1),148,&data); write(UInt16(1),216,&data)
  data.replaceSubrange(188..<196, with: InspectorQuery.unitInfo.frame)
  data.replaceSubrange(228..<236, with: [12,255,48,7,32,8,0,70])
  return data
}

@Test func atnInspectorReportsOnlyStableDVAndKeepsUnknownFormatsUnknown() throws {
  let query = InspectorQuery.tapeAbsoluteTrackNumber
  let reply: [UInt8] = [12,32,82,113,3,0,0,255]
  let value = try InspectorInterpretation.decode(reply, query: query)
  #expect(value.facts[0].value == "1")
  #expect(value.facts[2].value.contains("not yet qualified"))
  for unknown: [UInt8] in [[12,32,82,113,3,0,0,0], [12,32,82,113,255,255,255,255]] {
    #expect(try InspectorInterpretation.decode(unknown, query: query).facts[0].value.contains("Unavailable or unsupported"))
  }
  for code: UInt8 in [8,10] {
    var other = reply; other[0] = code
    #expect(try InspectorInterpretation.decode(other, query: query).facts.isEmpty)
  }
  for code: UInt8 in [9,11,13,15] {
    var other = reply; other[0] = code
    #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode(other, query: query) }
  }
}

@Test func tapeStateUsesExactStatusFramesAndDoesNotInferBOTOrEOT() throws {
  #expect(InspectorQuery.tapeMediumInfo.frame == [1,0x20,0xda,0x7f,0x7f])
  #expect(InspectorQuery.tapeTransportState.frame == [1,0x20,0xd0,0x7f])
  for opcode: UInt8 in [0xc1,0xc2,0xc3,0xc4] {
    let stable = try InspectorInterpretation.decode([0x0c,0x20,opcode,0x60], query: .tapeTransportState)
    #expect(stable.disposition.contains("Stable device-reported"))
    #expect(stable.facts.last?.value == "Not established by this observation")
    let transition = try InspectorInterpretation.decode([0x0b,0x20,opcode,0x60], query: .tapeTransportState)
    #expect(transition.disposition.contains("not stable state proof"))
  }
  let medium = try InspectorInterpretation.decode([0x0c,0x20,0xda,0x7f,0x7f], query: .tapeMediumInfo)
  #expect(medium.facts[0].value == "0x7F")
  #expect(medium.facts[2].value.contains("Unknown"))
  #expect(medium.facts[3].value.contains("BOT/EOT not established"))
  #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode([0x0b,0x20,0xda,0x7f,0x7f], query: .tapeMediumInfo) }
  for code: UInt8 in [0x0c,0x0b] {
    #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode([code,0x20,0xd0,0x60], query: .tapeTransportState) }
  }
  for code: UInt8 in [0x08,0x0a] {
    #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode([code,0x20,0xc4,0x60], query: .tapeTransportState) }
    #expect(try InspectorInterpretation.decode([code,0x20,0xd0,0x7f], query: .tapeTransportState).facts.isEmpty)
  }
  for bad: [UInt8] in [[],[0x0c,0x20,0xd0],[0x09,0x20,0xc4,0x60],[0x0c,0x21,0xc4,0x60],[0x0c,0x20,0x40,0x60],[0x0c,0x20,0xc4,0x60,0]] {
    #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode(bad, query: .tapeTransportState) }
  }
}

@Test func tapeStatusWireLengthsPaddingAndRouteAreBound() throws {
  let route = try inspectorRoute()
  for query in [InspectorQuery.tapeMediumInfo,.tapeTransportState,.tapeAbsoluteTrackNumber,.tapeTimecode] {
    var fixture = try inspectorResultFixture()
    write(UInt32(query.kind),116,&fixture)
    write(UInt32(query.frame.count),136,&fixture)
    write(UInt32(0),156,&fixture)
    fixture.replaceSubrange(188..<196, with: query.frame + Array(repeating:0,count:8-query.frame.count))
    fixture.replaceSubrange(228..<236, with: Array(repeating:0,count:8))
    let reply: [UInt8] = query == .tapeMediumInfo ? [0x0c,0x20,0xda,0x7f,0x7f] : query == .tapeAbsoluteTrackNumber ? [12,32,0x52,0x71,3,0,0,255] : query == .tapeTimecode ? [12,32,0x51,0x71,0x23,0x59,0x58,0x12] : [0x0c,0x20,0xc4,0x60]
    fixture.replaceSubrange(228..<(228+reply.count),with:reply)
    write(UInt32(reply.count),224,&fixture)
    func parse(_ data: Data) throws -> InspectorResult {
      try InspectorResult(data:data,requestID:1,operationID:2,attemptID:3,route:route,query:query)
    }
    #expect(try parse(fixture).interpretation(for:query) != nil)
    for offset in [32,56,112,136,148,195,204,212,739] {
      var bad = fixture; bad[offset] ^= 0x80
      #expect(throws: ControlWireError.self) { try parse(bad) }
    }
    var wrongNode = fixture; write(UInt16(2),216,&wrongNode)
    #expect(throws: ControlWireError.self) { try parse(wrongNode) }
    var stale = fixture; write(UInt32(2),152,&stale)
    #expect(try parse(stale).interpretation(for:query) == nil)
  }
}

@Test func inspectorWireBindsFullIdentityAndNeverAllowsRawCommands() throws {
  let route = try inspectorRoute()
  let data = try InspectorQuery.subunitInfo(page: 7).encode(operationID: 2, attemptID: 3, route: route)
  #expect(data.count == 72 && data[62] == 2 && data[63] == 7)
  #expect(try WireReader(data: data).integer(24, as: UInt64.self) == route.guid)
  #expect(data[64..<72].allSatisfy { $0 == 0 })
  #expect(throws: ControlWireError.self) { try InspectorQuery.subunitInfo(page: 8).encode(operationID: 2, attemptID: 3, route: route) }
  #expect(throws: ControlWireError.self) { try InspectorQuery.unitInfo.encode(operationID: 0, attemptID: 3, route: route) }
}

@Test func inspectorTerminalRequiresExactRouteAndCompleteEvidence() throws {
  let route = try inspectorRoute()
  func decode(_ data: Data) throws -> InspectorResult {
    try InspectorResult(data: data, requestID: 1, operationID: 2, attemptID: 3, route: route, query: .unitInfo)
  }
  let fixture = try inspectorResultFixture()
  #expect(try decode(fixture).interpretation(for: .unitInfo)?.facts[2].value == "0x080046")
  for count in [0,40,72,196,740,1283] {
    #expect(throws: ControlWireError.self) { try decode(Data(fixture.prefix(count))) }
  }
  for offset in [8,16,24,32,40,48,56,112,116,132,136,148,150,151,178,188,204,212,218,739,740] {
    var bad = fixture; bad[offset] ^= 0x80
    #expect(throws: ControlWireError.self) { try decode(bad) }
  }
  var wrongNode = fixture; write(UInt16(2),216,&wrongNode)
  #expect(throws: ControlWireError.self) { try decode(wrongNode) }
  var fullBusNode = fixture; write(UInt16(0xffc1),216,&fullBusNode)
  #expect(try decode(fullBusNode).interpretation(for: .unitInfo) != nil)
  var noDecode = fixture; write(UInt32(0),156,&noDecode)
  #expect(throws: ControlWireError.self) { try decode(noDecode).interpretation(for: .unitInfo) }
  var invalidated = fixture; write(UInt32(2),152,&invalidated)
  #expect(try decode(invalidated).interpretation(for: .unitInfo) == nil)
  var overflow = fixture; write(UInt32(1),144,&overflow)
  #expect(try decode(overflow).interpretation(for: .unitInfo) == nil)
  var timeout = fixture; write(Int32(-1),128,&timeout)
  #expect(try decode(timeout).interpretation(for: .unitInfo) == nil)
}

@Test func inspectorCapabilitiesCannotSilentlyLoosenSafety() throws {
  var data = Data(count: 40)
  for (index,value) in [UInt32(1),40,127,127,7,1,128,512,2,0].enumerated() { write(value,index*4,&data) }
  _ = try InspectorCapabilities(data: data)
  for offset in stride(from: 0, to: 40, by: 4) {
    var bad = data; bad[offset] ^= 1
    #expect(throws: ControlWireError.self) { try InspectorCapabilities(data: bad) }
  }
}

@Test func inventoryIsStatusOnlyAndExactlyBounded() {
  let queries: [InspectorQuery] = [.unitInfo, .unitPlugInfo] + (0...7).map { .subunitInfo(page: $0) }
  #expect(queries.allSatisfy { $0.frame.count == 8 && $0.frame[0] == 1 && $0.frame[1] == 0xff })
  #expect(InspectorQuery.unitInfo.frame == [1,255,48,255,255,255,255,255])
  #expect(InspectorQuery.unitPlugInfo.frame == [1,255,2,0,255,255,255,255])
}

@Test func inspectorJournalClosesAndVerifiesExactBytes() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewinddv-inspector-test-\(UUID().uuidString)")
  let journal = try InspectorFlight(parentDirectory: root)
  try journal.append(event: "offline_test", query: .unitInfo, route: Data([1,2,3]),
    hostDeadlineUptimeNanoseconds: 123)
  try journal.finish()
  let bytes = try Data(contentsOf: journal.directoryURL.appendingPathComponent("flight.ndjson"))
  let value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  #expect(value["protocolReference"] as? String != nil)
  #expect(value["hostDeadlineUptimeNanoseconds"] as? UInt64 == 123)
  #expect(throws: (any Error).self) { try journal.append(event: "after_close", query: nil, route: nil) }
}

@Test func tapeStateJournalNamesItsOwnParserAndPinnedReference() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewinddv-state-test-\(UUID().uuidString)")
  let journal = try InspectorFlight(parentDirectory: root, tapeStateProbe: true)
  try journal.append(event: "offline_test", query: .tapeMediumInfo, route: nil)
  try journal.finish()
  let bytes = try Data(contentsOf: journal.directoryURL.appendingPathComponent("flight.ndjson"))
  let record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
  #expect(record["schema"] as? String == "rewinddv.tape-state.v1")
  #expect(record["parser"] as? String == "typed-tape-status.v3")
  #expect((record["protocolReference"] as? String)?.contains("4.28") == true)
  #expect((record["protocolReference"] as? String)?.contains("1feebabb10c03772124e88b375c47a12a6ef3a1d9ca3d25c5c07473077b048a1") == true)
  #expect(throws: (any Error).self) { try InspectorFlight(parentDirectory: root, capabilityProbe: true, tapeStateProbe: true) }
}

@Test func inspectorJournalDoesNotAcceptSyntacticallyValidTampering() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("rewinddv-inspector-test-\(UUID().uuidString)")
  let journal = try InspectorFlight(parentDirectory: root)
  try journal.append(event: "offline_test", query: .unitInfo, route: nil)
  let handle = try FileHandle(forWritingTo: journal.directoryURL.appendingPathComponent("flight.ndjson"))
  try handle.truncate(atOffset: 0)
  try handle.write(contentsOf: Data("{\"other\":true}\n".utf8))
  try handle.close()
  #expect(throws: (any Error).self) { try journal.finish() }
}

@Test func inventoryDoesNotInventMissingPlugs() throws {
  let result = try InspectorInterpretation.decode([12,255,2,0,0,1,2,31], query: .unitPlugInfo)
  #expect(result.facts.map(\.value) == ["0", "1", "2", "31"])
  #expect(throws: ControlWireError.self) {
    try InspectorInterpretation.decode([12,255,2,0,0,1,255,255], query: .unitPlugInfo)
  }
  #expect(!result.lastSubunitPage)
}

@Test func tapeTypeAndSubunitPaginationAreNotAddresses() throws {
  let result = try InspectorInterpretation.decode([12,255,49,7,32,255,255,255], query: .subunitInfo(page: 0))
  #expect(result.facts[0].value == "Tape recorder/player (0x04) · IDs 0–0")
  #expect(result.lastSubunitPage)
  #expect(throws: ControlWireError.self) {
    try InspectorInterpretation.decode([12,255,49,23,32,255,255,255], query: .subunitInfo(page: 0))
  }
  #expect(throws: ControlWireError.self) {
    try InspectorInterpretation.decode([12,255,49,7,255,32,255,255], query: .subunitInfo(page: 0))
  }
}

@Test func inspectorRejectsMalformedStatusWithoutInventingSupport() throws {
  let response: [UInt8] = [12,255,48,7,32,8,0,70]
  for count in 0..<8 {
    #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode(Array(response.prefix(count)), query: .unitInfo) }
  }
  #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode(response + [0], query: .unitInfo) }
  #expect(throws: ControlWireError.self) { try InspectorInterpretation.decode([9,255,48], query: .unitInfo) }
  #expect(try InspectorInterpretation.decode([8,255,48], query: .unitInfo).disposition == "Not implemented")
  #expect(try InspectorInterpretation.decode([10,255,48], query: .unitInfo).disposition == "Rejected in current state")
  #expect(try InspectorInterpretation.decode(response, query: .unitInfo).facts[2].value == "0x080046")
  #expect(try InspectorInterpretation.decode([12,255,48,7,39,8,0,70], query: .unitInfo).facts[1].value == "7")
  #expect(throws: ControlWireError.self) {
    try InspectorInterpretation.decode([12,255,48,7,240,8,0,70], query: .unitInfo)
  }
  #expect(try InspectorInterpretation.decode([11,255,2], query: .unitPlugInfo).disposition.contains("invalid"))
}
