// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstdint>
#include <limits>

namespace ASFW::UserClient {
// Process-lifetime identities: object addresses may be reused after a failed
// owner close, but a retained receive session must never be inherited by one.
class ReceiveOwnerTokenAllocator {
public:
    explicit ReceiveOwnerTokenAllocator(uint64_t first = 1) noexcept : next_(first) {}
    uint64_t Allocate() noexcept {
        auto current = next_.load(std::memory_order_relaxed);
        while (current && current != std::numeric_limits<uint64_t>::max()) {
            if (next_.compare_exchange_weak(current, current + 1,
                                           std::memory_order_relaxed)) return current;
        }
        return 0; // permanent exhaustion, never wrap or recycle
    }
private:
    std::atomic<uint64_t> next_;
};
inline uint64_t AllocateReceiveOwnerToken() noexcept {
    static ReceiveOwnerTokenAllocator allocator;
    return allocator.Allocate();
}
} // namespace ASFW::UserClient
