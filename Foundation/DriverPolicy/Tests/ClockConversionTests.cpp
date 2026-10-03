// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "ASFWDriver/Common/TimingUtils.hpp"
#include <cassert>
#include <cstdio>
#include <limits>
using namespace ASFW::Timing;

int main() {
    assert(encodedFWTimeToNanos(0) == 0);
    assert(nanosToEncodedFWTime(128'000'000'000) == 0);
    assert(nanosToEncodedFWTime(128'000'125'000) == 0x1000);
    const auto maximum = decodeCycleTimer(0xffffffff);
    assert(maximum.seconds == 127 && maximum.cycle == 8191 && maximum.offset == 4095);
    assert(encodeCycleTimer(255, 16383, 8191) == 0xffffffff);
    // Independently calculated rational result for the full raw register, not
    // a normalized/valid timer value. Preserve malformed input visibility.
    assert(encodedFWTimeToNanos(0xffffffff) == 128'024'041'625ull);
    for (uint32_t offset = 0; offset < 3072; ++offset) {
        const auto ns = encodedFWTimeToNanos(encodeCycleTimer(127, 7999, offset));
        const uint64_t expected = 127'999'875'000ull + (uint64_t{offset} * 15625) / 384;
        assert(ns == expected);
        const auto back = decodeCycleTimer(nanosToEncodedFWTime(ns));
        const int64_t error = tstampToOffsets(127, 7999, offset) - tstampToOffsets(back);
        assert(error >= 0 && error <= 1);
    }
    for (uint64_t ns : {0ull, 1ull, 40ull, 41ull, 42ull, 124999ull, 125000ull,
                       127999999999ull, 128000000000ull, 0xffffffffffffffffull}) {
        const auto actual = encodedFWTimeToNanos(nanosToEncodedFWTime(ns));
        const auto wrapped = ns % 128'000'000'000ull;
        assert(actual <= wrapped && wrapped - actual <= 41);
    }
    assert(deltaFWTimeNanos(encodeCycleTimer(64,0,0),0) == 64'000'000'000);
    assert(deltaFWTimeNanos(0,encodeCycleTimer(64,0,0)) == -64'000'000'000);
    assert(deltaFWTimeNanos(0,encodeCycleTimer(127,7999,0)) == 125000);
    for (int64_t value : {std::numeric_limits<int64_t>::min(), int64_t{-1}, int64_t{0},
                          std::numeric_limits<int64_t>::max()}) {
        const auto normalized = normalizeToFWTimeRange(value);
        assert(normalized < 128'000'000'000ull);
        assert((__int128_t{value} - normalized) % 128'000'000'000 == 0);
    }
    assert(tstampToOffsets(0xffffffff,0xffffffff,0xffffffff) == 105566314676417535ll);
    const auto halfPlus = encodeCycleTimer(64,0,1);
    assert(deltaFWTimeNanos(halfPlus,0) == -63'999'999'960ll);
    assert(deltaFWTimeNanos(0,halfPlus) == 63'999'999'960ll);
    gHostTimebaseInfo = {0,3};
    assert(hostTicksToNanos(99) == 0 && nanosToHostTicks(99) == 0);
    gHostTimebaseInfo = {125,0};
    assert(hostTicksToNanos(99) == 0 && nanosToHostTicks(99) == 0);
    gHostTimebaseInfo = {0xffffffff,1};
    assert(hostTicksToNanos(0xffffffffffffffffull) == 0xffffffff00000001ull);
    gHostTimebaseInfo = {1,0xffffffff};
    assert(nanosToHostTicks(0xffffffffffffffffull) == 0xffffffff00000001ull);
    gHostTimebaseInfo = {125,3};
    assert(hostTicksToNanos(3) == 125 && hostTicksToNanos(1) == 41);
    assert(nanosToHostTicks(125) == 3 && nanosToHostTicks(41) == 0);
    assert(hostTicksToNanos(0xffffffffffffffffull) == uint64_t{0xaaaaaaaaaaaaaa81ull});
    gHostTimebaseInfo = {0,0};
    assert(hostTicksToNanos(999) == 0 && nanosToHostTicks(999) == 0);
    // Deterministic failure injection at the actual initialization helper.
    mach_timebase_info_data_t cached{};
    int queries = 0;
    auto partialFailure = [&](auto* result) { ++queries; *result = {125,3}; return -1; };
    assert(!detail::EnsureHostTimebase(cached, partialFailure));
    assert(cached.numer == 0 && cached.denom == 0 && queries == 1);
    auto zeroNumerator = [](auto* result) { *result = {0,3}; return KERN_SUCCESS; };
    auto zeroDenominator = [](auto* result) { *result = {125,0}; return KERN_SUCCESS; };
    assert(!detail::EnsureHostTimebase(cached, zeroNumerator));
    assert(!detail::EnsureHostTimebase(cached, zeroDenominator));
    auto success = [&](auto* result) { ++queries; *result = {125,3}; return KERN_SUCCESS; };
    assert(detail::EnsureHostTimebase(cached, success));
    assert(cached.numer == 125 && cached.denom == 3 && queries == 2);
    assert(detail::EnsureHostTimebase(cached, partialFailure) && queries == 2);
    gHostTimebaseInfo = cached;
    assert(hostTicksToNanos(0) == 0 && nanosToHostTicks(0) == 0);
    assert(initializeHostTimebase());
    std::puts("Rational clock, overflow, raw field, rounding and wrap boundaries PASS");
}
