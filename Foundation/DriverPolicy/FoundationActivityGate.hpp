// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <atomic>
#include <cstdint>

namespace RewindDV::Foundation::DriverPolicy {

// One process-wide, non-queuing admission point keeps generic inspection
// exclusive while preserving receive + deck control (especially STOP). The
// typed tape-transport-state exception below may overlap receive only.
enum class ActivityKind : uint8_t {
    kReceive = 1,
    kDeckControl = 2,
    kInspector = 3,
    // The only inspector class permitted alongside receive. It remains
    // exclusive with deck control, generic inspectors, and itself.
    kLiveTapeTransportStateInspector = 4,
};

inline constexpr uint64_t kActivitySequenceMask = (uint64_t{1} << 56u) - 1u;
inline constexpr uint32_t kReceiveActivityBit = 1u << 0;
inline constexpr uint32_t kDeckControlActivityBit = 1u << 1;
inline constexpr uint32_t kInspectorActivityBit = 1u << 2;
inline constexpr uint32_t kLiveTapeTransportStateInspectorActivityBit = 1u << 3;
inline std::atomic<uint32_t> gFoundationActivities{0};
inline std::atomic<uint64_t> gFoundationActivitySequence{1};
inline std::atomic<uint64_t> gFoundationReceiveOwner{0};
inline std::atomic<uint64_t> gFoundationDeckControlOwner{0};
inline std::atomic<uint64_t> gFoundationInspectorOwner{0};
inline std::atomic<uint64_t> gFoundationLiveTapeTransportStateInspectorOwner{0};

[[nodiscard]] inline uint32_t ActivityBit(ActivityKind kind) noexcept {
    switch (kind) {
    case ActivityKind::kReceive: return kReceiveActivityBit;
    case ActivityKind::kDeckControl: return kDeckControlActivityBit;
    case ActivityKind::kInspector: return kInspectorActivityBit;
    case ActivityKind::kLiveTapeTransportStateInspector:
        return kLiveTapeTransportStateInspectorActivityBit;
    }
    return 0;
}

[[nodiscard]] inline std::atomic<uint64_t>& ActivityOwner(ActivityKind kind) noexcept {
    switch (kind) {
    case ActivityKind::kReceive: return gFoundationReceiveOwner;
    case ActivityKind::kDeckControl: return gFoundationDeckControlOwner;
    case ActivityKind::kInspector: return gFoundationInspectorOwner;
    case ActivityKind::kLiveTapeTransportStateInspector:
        return gFoundationLiveTapeTransportStateInspectorOwner;
    }
    return gFoundationInspectorOwner;
}

[[nodiscard]] inline uint64_t TryAcquireActivity(ActivityKind kind) noexcept {
    const uint32_t bit = ActivityBit(kind);
    if (bit == 0) {
        return 0;
    }
    const uint64_t sequence = gFoundationActivitySequence.fetch_add(1, std::memory_order_relaxed);
    if (sequence == 0 || sequence > kActivitySequenceMask) {
        return 0;
    }
    const uint64_t token = (static_cast<uint64_t>(kind) << 56u) | sequence;
    auto& owner = ActivityOwner(kind);
    uint64_t emptyOwner = 0;
    if (!owner.compare_exchange_strong(
            emptyOwner, token, std::memory_order_acq_rel, std::memory_order_acquire)) {
        return 0;
    }
    uint32_t current = gFoundationActivities.load(std::memory_order_acquire);
    for (;;) {
        const bool conflict = [&] {
            switch (kind) {
            case ActivityKind::kInspector:
                return current != 0;
            case ActivityKind::kLiveTapeTransportStateInspector:
                return (current & (kDeckControlActivityBit | kInspectorActivityBit |
                                   kLiveTapeTransportStateInspectorActivityBit)) != 0;
            case ActivityKind::kDeckControl:
                return (current & (kInspectorActivityBit |
                                   kLiveTapeTransportStateInspectorActivityBit | bit)) != 0;
            case ActivityKind::kReceive:
                return (current & (kInspectorActivityBit | bit)) != 0;
            }
            return true;
        }();
        if (conflict) {
            uint64_t owned = token;
            (void)owner.compare_exchange_strong(
                owned, 0, std::memory_order_acq_rel, std::memory_order_acquire);
            return 0;
        }
        if (gFoundationActivities.compare_exchange_weak(
                current, current | bit, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            return token;
        }
    }
}

inline void ReleaseActivity(uint64_t token) noexcept {
    if (token == 0) {
        return;
    }
    const auto kind = static_cast<ActivityKind>(token >> 56u);
    auto& owner = ActivityOwner(kind);
    uint64_t owned = token;
    if (owner.compare_exchange_strong(
            owned, 0, std::memory_order_acq_rel, std::memory_order_acquire)) {
        (void)gFoundationActivities.fetch_and(
            ~ActivityBit(kind), std::memory_order_acq_rel);
    }
}

[[nodiscard]] inline bool IsActivityActive(ActivityKind kind) noexcept {
    return (gFoundationActivities.load(std::memory_order_acquire) & ActivityBit(kind)) != 0;
}

} // namespace RewindDV::Foundation::DriverPolicy
