// Modified by Rewind Digital for rewindDV, 2026-09-30: replace timing helpers
// with first-party rational-clock arithmetic; omit unused transfer-delay constants.
// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>
#include <DriverKit/IOLib.h>

namespace ASFW::Timing {

// Numeric register facts: TI TSB82AA2-EP SCPS167A (September 2006), section 4.34,
// Table 4-27. https://www.ti.com/lit/ds/symlink/tsb82aa2-ep.pdf
inline constexpr uint32_t kCyclesPerSecond = 8000;
inline constexpr uint32_t kTicksPerCycle = 3072;
inline constexpr uint64_t kTicksPerSecond = uint64_t{kCyclesPerSecond} * kTicksPerCycle;
inline constexpr uint64_t kNanosPerSecond = 1'000'000'000;
inline constexpr uint64_t kNanosPerCycle = kNanosPerSecond / kCyclesPerSecond;
inline constexpr uint32_t kFWTimeWrapSeconds = 128;
inline constexpr int64_t kFWTimeWrapNanos = kFWTimeWrapSeconds * kNanosPerSecond;
inline constexpr uint32_t kCycleTimerSecondsShift = 25;
inline constexpr uint32_t kCycleTimerCyclesShift = 12;
inline constexpr uint32_t kCycleTimerSecondsMask = 0xfe000000;
inline constexpr uint32_t kCycleTimerCyclesMask = 0x01fff000;
inline constexpr uint32_t kCycleTimerOffsetMask = 0x00000fff;

struct CycleTimerFields {
    uint32_t seconds = 0;
    uint32_t cycle = 0;
    uint32_t offset = 0;
};

namespace detail {
// Floor the rational conversion without overflowing the product. Narrowing the
// quotient is deliberately modulo 2^64, matching existing callers' value domain.
[[nodiscard]] constexpr uint64_t ScaleFloor(uint64_t value, uint32_t multiply,
                                           uint32_t divide) noexcept {
    return divide == 0 ? 0 : uint64_t((__uint128_t{value} * multiply) / divide);
}
} // namespace detail

[[nodiscard]] constexpr CycleTimerFields decodeCycleTimer(uint32_t value) noexcept {
    return {value >> kCycleTimerSecondsShift,
            (value & kCycleTimerCyclesMask) >> kCycleTimerCyclesShift,
            value & kCycleTimerOffsetMask};
}

[[nodiscard]] constexpr uint32_t encodeCycleTimer(uint32_t seconds, uint32_t cycle,
                                                  uint32_t offset) noexcept {
    return ((seconds & 0x7fu) << kCycleTimerSecondsShift) |
           ((cycle & 0x1fffu) << kCycleTimerCyclesShift) |
           (offset & kCycleTimerOffsetMask);
}

[[nodiscard]] constexpr int64_t tstampToOffsets(uint32_t seconds, uint32_t cycle,
                                               uint32_t offset) noexcept {
    return int64_t(uint64_t{seconds} * kTicksPerSecond +
                   uint64_t{cycle} * kTicksPerCycle + offset);
}

[[nodiscard]] constexpr int64_t tstampToOffsets(CycleTimerFields value) noexcept {
    return tstampToOffsets(value.seconds, value.cycle, value.offset);
}

[[nodiscard]] constexpr int64_t encodedTstampToOffsets(uint32_t value) noexcept {
    return tstampToOffsets(decodeCycleTimer(value));
}

[[nodiscard]] constexpr uint64_t encodedFWTimeToNanos(uint32_t value) noexcept {
    return detail::ScaleFloor(uint64_t(encodedTstampToOffsets(value)),
                              uint32_t(kNanosPerSecond), uint32_t(kTicksPerSecond));
}

[[nodiscard]] constexpr uint32_t nanosToEncodedFWTime(uint64_t value) noexcept {
    const uint64_t ticks = detail::ScaleFloor(value % uint64_t(kFWTimeWrapNanos),
                                              uint32_t(kTicksPerSecond), uint32_t(kNanosPerSecond));
    const uint64_t cycles = ticks / kTicksPerCycle;
    return encodeCycleTimer(uint32_t(cycles / kCyclesPerSecond),
                            uint32_t(cycles % kCyclesPerSecond),
                            uint32_t(ticks % kTicksPerCycle));
}

[[nodiscard]] constexpr uint64_t normalizeToFWTimeRange(int64_t value) noexcept {
    const int64_t remainder = value % kFWTimeWrapNanos;
    return uint64_t(remainder < 0 ? remainder + kFWTimeWrapNanos : remainder);
}

// Chronology requires valid fields and an independently known interval <64 s.
// At exactly half a wrap the sign is only a deterministic tie rule, not evidence
// of direction. Readings alone cannot count elapsed wraps.
[[nodiscard]] constexpr int64_t deltaFWTimeNanos(uint32_t a, uint32_t b) noexcept {
    const int64_t difference = int64_t(encodedFWTimeToNanos(a)) - int64_t(encodedFWTimeToNanos(b));
    const int64_t direction = (difference > kFWTimeWrapNanos / 2) -
                              (difference < -kFWTimeWrapNanos / 2);
    return difference - direction * kFWTimeWrapNanos;
}

// Startup owns initialization. Publish a ratio only after a successful query;
// availability is separate from the valid conversion result zero.
namespace detail {
template <typename Query>
[[nodiscard]] inline bool EnsureHostTimebase(mach_timebase_info_data_t& cached,
                                             Query query) noexcept {
    if (cached.numer != 0 && cached.denom != 0) return true;
    mach_timebase_info_data_t candidate{};
    if (query(&candidate) != KERN_SUCCESS || candidate.numer == 0 || candidate.denom == 0)
        return false;
    cached = candidate;
    return true;
}
} // namespace detail
inline mach_timebase_info_data_t gHostTimebaseInfo{};
[[nodiscard]] inline bool initializeHostTimebase() noexcept {
    return detail::EnsureHostTimebase(gHostTimebaseInfo, mach_timebase_info);
}

// Preconditions: startup established a valid timebase before enabling consumers.
// Legacy numeric wrappers retain zero for an unavailable divisor; zero alone is
// never an availability test. They do not query, allocate, block or synchronize.
[[nodiscard]] inline uint64_t hostTicksToNanos(uint64_t value) noexcept {
    return detail::ScaleFloor(value, gHostTimebaseInfo.numer, gHostTimebaseInfo.denom);
}
[[nodiscard]] inline uint64_t nanosToHostTicks(uint64_t value) noexcept {
    return detail::ScaleFloor(value, gHostTimebaseInfo.denom, gHostTimebaseInfo.numer);
}

} // namespace ASFW::Timing
