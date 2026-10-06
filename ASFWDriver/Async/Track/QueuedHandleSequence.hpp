// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once
#include "../AsyncTypes.hpp"
#include <atomic>

namespace ASFW::Async {
// Queued public handles occupy only the high-bit namespace. Zero is a terminal
// exhausted state, never a value to advance back into transaction identities.
inline AsyncHandle ReserveQueuedHandle(std::atomic<uint32_t>& next) noexcept {
    auto value = next.load(std::memory_order_relaxed);
    while (value >= 0x80000000u) {
        const uint32_t following = value == UINT32_MAX ? 0u : value + 1u;
        if (next.compare_exchange_weak(value, following, std::memory_order_relaxed))
            return AsyncHandle{value};
    }
    return {};
}
} // namespace ASFW::Async
