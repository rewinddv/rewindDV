// OFFLINE ONLY: allocated host memory; no driver connection or tape access.
import Foundation
enum DriverBridgeError: Error { case callFailed(selector: Int, status: Int32) }
@main struct LiveReceiveRingRegression {
  static func put<T: FixedWidthInteger>(_ x: T, _ data: inout Data, _ at: Int) {
    var x = x.littleEndian; withUnsafeBytes(of: &x) { data.replaceSubrange(at..<at + $0.count, with: $0) }
  }
  static func status(_ capacity: UInt32) -> Data {
    var d = Data(repeating: 0, count: 128)
    put(UInt32(0x58524452), &d, 0); put(UInt16(1), &d, 4); put(UInt16(256), &d, 6)
    put(UInt32(4160), &d, 8); put(capacity, &d, 12); put(UInt64(1), &d, 16)
    put(UInt32(1), &d, 24); put(UInt32(48), &d, 28)
    for at in [32,40,48,56] { put(UInt64(at), &d, at) }
    put(UInt32(1), &d, 64); put(UInt16(7), &d, 68); put(UInt32(1), &d, 80)
    return d
  }
  static func refuses(_ body: () throws -> Void) { do { try body(); preconditionFailure("accepted invalid input") } catch {} }
  static func main() throws {
    for capacity: UInt32 in [0,1,8191,8193,65535,65537,UInt32.max] {
      refuses { _ = try LiveReceiveStatus(status(capacity)) }
    }
    for capacity: UInt32 in [8192,65536] {
      var wire = status(capacity)
      let initial = try LiveReceiveStatus(wire), size = 256 + Int(capacity) * 4160
      let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
      defer { pointer.deallocate() }
      pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
      wire.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: 128) }
      refuses { _ = try LiveReceiveRing(testingMapping: pointer, length: UInt64(size - 1), status: initial) }
      let ring = try LiveReceiveRing(testingMapping: pointer, length: UInt64(size), status: initial)
      for sequence in 1...(UInt64(capacity) + 2048) {
        var h = Data(repeating: 0, count: 64)
        put(sequence, &h, 0); put(UInt64(1), &h, 8); put(UInt16(0x11), &h, 32)
        put(UInt32(1), &h, 36); put(sequence, &h, 40); put(UInt32(1), &h, 56)
        let slot = pointer.advanced(by: 256 + Int((sequence - 1) % UInt64(capacity)) * 4160)
        h.withUnsafeBytes { slot.copyMemory(from: $0.baseAddress!, byteCount: 64) }
        slot.advanced(by: 64).storeBytes(of: UInt8(truncatingIfNeeded: sequence), as: UInt8.self)
        if sequence % 2048 == 0 {
          put(sequence, &wire, 88); put(sequence, &wire, 96)
          pointer.advanced(by: 88).storeBytes(of: sequence.littleEndian, as: UInt64.self)
          let rows = try ring.copyAvailable(snapshot: LiveReceiveStatus(wire))
          precondition(rows.count == 2048 && rows.last?.sequence == sequence)
          precondition(rows.allSatisfy { $0.payload == Data([UInt8(truncatingIfNeeded: $0.sequence)]) })
          ring.copied(through: sequence); ring.acknowledged(through: sequence)
        }
      }
      var changed = wire; put(UInt32(capacity == 8192 ? 65536 : 8192), &changed, 12)
      refuses { _ = try ring.copyAvailable(snapshot: LiveReceiveStatus(changed)) }
      changed = wire; put(UInt64(2), &changed, 16)
      refuses { _ = try ring.copyAvailable(snapshot: LiveReceiveStatus(changed)) }
      changed = wire; put(UInt64(99), &changed, 32)
      refuses { _ = try ring.copyAvailable(snapshot: LiveReceiveStatus(changed)) }
      ring.unmap()
      refuses { _ = try ring.copyAvailable(snapshot: LiveReceiveStatus(wire)) }
      print("RING_READER_WRAP_IDENTITY_LENGTH_PASS capacity=\(capacity)")
    }
  }
}
