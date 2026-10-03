// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Mirrors FoundationReceiveWire.hpp. Actor-confined, read-only client mapping.
import Foundation
import IOKit

struct LiveReceiveStatus: Sendable {
  let raw: Data
  let epoch: UInt64
  let route: FoundationRoute
  let channel: UInt32
  let state: UInt32
  let lastStatus: Int32
  let writeSequence: UInt64
  let packetsSeen: UInt64
  let dropped: UInt64
  let oversized: UInt64
  let acknowledged: UInt64
  let capacity: UInt32

  init(_ data: Data) throws {
    let r = WireReader(data: data)
    guard data.count == 128, try r.integer(0, as: UInt32.self) == 0x58524452,
      try r.integer(4, as: UInt16.self) == 1, try r.integer(6, as: UInt16.self) == 256,
      try r.integer(8, as: UInt32.self) == 4160,
      [UInt32(8192), 65536].contains(try r.integer(12, as: UInt32.self))
    else { throw ControlWireError.invalid("Live receive ABI mismatch") }
    raw = data
    capacity = try r.integer(12)
    epoch = try r.integer(16)
    route = try FoundationRoute(data: data.subdata(in: 24..<72))
    channel = try r.integer(72)
    state = try r.integer(80)
    lastStatus = try r.integer(84)
    writeSequence = try r.integer(88)
    packetsSeen = try r.integer(96)
    dropped = try r.integer(104)
    oversized = try r.integer(112)
    acknowledged = try r.integer(120)
    guard epoch > 0, state <= 6, acknowledged <= writeSequence,
      state != 1 || channel < 64 else { throw ControlWireError.invalid("Invalid live receive state") }
  }
}

struct LiveReceiveRecord: Sendable {
  let header: Data
  let payload: Data
  let sequence: UInt64
  let transferStatus: UInt16
}

final class LiveReceiveRing {
  private let connection: io_connect_t
  private let address: mach_vm_address_t
  private let base: UnsafeRawPointer
  private let epoch: UInt64
  private let capacity: UInt64
  private let identity: Data
  private var copiedThrough: UInt64 = 0
  private var acknowledgedThrough: UInt64 = 0
  private var mapped = true
  private var ownsIOKitMapping = true

  #if REWINDDV_OFFLINE_REGRESSION
  // Host-only test seam: caller owns allocated memory. No IOKit calls.
  init(testingMapping base: UnsafeRawPointer, length: UInt64, status: LiveReceiveStatus) throws {
    guard length >= 256 + UInt64(status.capacity) * 4160,
      Data(bytes: base, count: 72) == status.raw.prefix(72), status.acknowledged == 0 else {
      throw ControlWireError.invalid("Invalid offline mapping")
    }
    connection = 0; address = 0; self.base = base; epoch = status.epoch
    capacity = UInt64(status.capacity); identity = status.raw.prefix(72); ownsIOKitMapping = false
  }
  #endif

  init(connection: io_connect_t, status: LiveReceiveStatus) throws {
    var address: mach_vm_address_t = 0
    var length: mach_vm_size_t = 0
    let kr = IOConnectMapMemory64(connection, 2, mach_task_self_, &address, &length,
      UInt32(kIOMapAnywhere | kIOMapReadOnly))
    guard kr == KERN_SUCCESS, address != 0 else {
      throw DriverBridgeError.callFailed(selector: 2, status: kr)
    }
    // Capacity is a strict ABI whitelist, not an untrusted allocation request.
    guard length >= 256 + UInt64(status.capacity) * 4160, address.isMultiple(of: 8),
      let base = UnsafeRawPointer(bitPattern: UInt(address)) else {
      IOConnectUnmapMemory64(connection, 2, mach_task_self_, address)
      throw ControlWireError.invalid("Truncated or unaligned live ring")
    }
    // Only immutable identity fields are read without an atomic operation.
    let header = Data(bytes: base, count: 72)
    guard header == status.raw.prefix(72), status.acknowledged == 0 else {
      IOConnectUnmapMemory64(connection, 2, mach_task_self_, address)
      throw ControlWireError.invalid("Live ring identity changed")
    }
    self.connection = connection
    self.address = address
    self.base = base
    epoch = status.epoch
    capacity = UInt64(status.capacity)
    identity = header
  }

  func copyAvailable(snapshot: LiveReceiveStatus, limit: Int = 2048) throws -> [LiveReceiveRecord] {
    guard mapped, snapshot.epoch == epoch, snapshot.raw.prefix(72) == identity,
      (1...2048).contains(limit) else {
      throw ControlWireError.invalid("Stale live receive mapping")
    }
    let published = RDLiveLoadAcquireU64(base.advanced(by: 88).assumingMemoryBound(to: UInt64.self))
    let through = min(published, snapshot.writeSequence)
    guard through >= copiedThrough, through - acknowledgedThrough <= capacity else {
      throw ControlWireError.invalid("Live receive sequence escaped ring bounds")
    }
    var records: [LiveReceiveRecord] = []
    records.reserveCapacity(Int(min(UInt64(limit), through - copiedThrough)))
    for sequence in (0..<min(UInt64(limit), through - copiedThrough)).map({ copiedThrough + 1 + $0 }) {
      let record = base.advanced(by: 256 + Int((sequence - 1) % capacity) * 4160)
      let header = Data(bytes: record, count: 64)
      let r = WireReader(data: header)
      let payloadBytes = try r.integer(36, as: UInt32.self)
      guard try r.integer(0, as: UInt64.self) == sequence,
        try r.integer(8, as: UInt64.self) == epoch, payloadBytes <= 4096,
        try r.integer(60, as: UInt32.self) == 0 else {
        throw ControlWireError.invalid("Malformed live receive record")
      }
      records.append(LiveReceiveRecord(header: header,
        payload: Data(bytes: record.advanced(by: 64), count: Int(payloadBytes)),
        sequence: sequence, transferStatus: try r.integer(32)))
    }
    return records
  }

  func copied(through sequence: UInt64) {
    precondition(sequence >= copiedThrough)
    copiedThrough = sequence
  }
  func acknowledged(through sequence: UInt64) {
    precondition(sequence >= acknowledgedThrough && sequence <= copiedThrough)
    acknowledgedThrough = sequence
  }
  func unmap() {
    guard mapped else { return }
    mapped = false
    if ownsIOKitMapping { IOConnectUnmapMemory64(connection, 2, mach_task_self_, address) }
  }
  deinit { unmap() }
}
