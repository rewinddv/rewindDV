// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Executes blocking durability operations in order without occupying a caller
/// actor. Ownership is explicit: every submitted operation is awaited, and the
/// serial queue provides the join boundary for callers.
final class DurableSerialExecutor: @unchecked Sendable {
  private let queue: DispatchQueue

  init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

  func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try operation()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
}
