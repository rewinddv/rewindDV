// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>

namespace ASFW::Isoch::Detail {

// Control-path slow acquisition only. The caller has already failed its fast
// attempt. Never clear a gate owned by the callback, including on expiry.
// An elapsed policy budget bounds retries; scheduling can delay actual return.
template <typename Expired, typename Yield>
[[nodiscard]] bool AcquireReceiveStopGate(std::atomic_flag& gate,
                                          Expired expired, Yield yield) noexcept {
    while (!expired()) {
        if (!gate.test_and_set(std::memory_order_acquire)) return true;
        yield();
    }
    return false;
}

} // namespace ASFW::Isoch::Detail
