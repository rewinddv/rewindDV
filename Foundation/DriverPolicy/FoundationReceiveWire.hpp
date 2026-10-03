// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "FoundationDriverPolicy.hpp"
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace RewindDV::Foundation::Receive {
inline constexpr uint32_t kMagic = 0x58524452; // memory bytes: R D R X
inline constexpr uint16_t kVersion = 1;
inline constexpr uint32_t kCapacity = 65536;
inline constexpr uint32_t kPayloadBytes = 4096;
inline constexpr uint64_t kMemoryType = 2;
inline constexpr uint64_t kStart = 68, kStop = 69, kStatus = 70, kAcknowledge = 71;
enum class State : uint32_t {
    Preparing = 0, Active = 1, Stopped = 2, BusReset = 3, Failed = 4,
    Quarantined = 5, CleanupPending = 6,
};
enum class ChannelEvidence : uint32_t {
    Unknown = 0,
    BroadcastOPCR = 1,
    ExistingP2POPCR = 2,
    OwnedManagedP2P = 3,
};
// Driver-owned read-only mapping. The client acknowledges through selector 71;
// no mapped value is ever trusted as a consumer cursor or allocation bound.
struct alignas(8) RingHeader {
    uint32_t magic;
    uint16_t version;
    uint16_t headerBytes;
    uint32_t recordBytes;
    uint32_t capacity;
    uint64_t epoch;
    DriverPolicy::FoundationRouteWire route;
    uint32_t channel;
    uint32_t channelEvidence;
    std::atomic<uint32_t> state;
    std::atomic<int32_t> lastStatus;
    std::atomic<uint64_t> writeSequence;
    std::atomic<uint64_t> packetsSeen;
    std::atomic<uint64_t> dropped;
    std::atomic<uint64_t> oversized;
    std::atomic<uint64_t> acknowledgedSequence;
    std::array<uint8_t, 128> reserved;
};
struct alignas(8) Record {
    uint64_t writeSequence;
    uint64_t epoch;
    uint64_t hostTicks;
    uint32_t cycleTimer;
    uint32_t descriptorIndex;
    uint16_t transferStatus;
    uint16_t residualCount;
    uint32_t payloadBytes;
    uint64_t observedSequence;
    uint64_t lossBefore;
    uint32_t flags; // bit 0: transport continuity unknown; not archival durability
    uint32_t reserved;
    std::array<uint8_t, kPayloadBytes> payload;
};
struct SessionWire {
    uint32_t version{kVersion};
    uint32_t size{sizeof(SessionWire)};
    uint64_t epoch{};
    uint32_t state{static_cast<uint32_t>(State::Preparing)};
    uint32_t reserved{};
};
// Snapshot uses the first 128 bytes of the header layout, but contains ordinary
// values copied with atomic loads. The record interval through writeSequence is
// stable until this owner's acknowledgement. HW packet loss remains unknown.
struct StatusWire {
    uint32_t magic{};
    uint16_t version{};
    uint16_t headerBytes{};
    uint32_t recordBytes{};
    uint32_t capacity{};
    uint64_t epoch{};
    DriverPolicy::FoundationRouteWire route{};
    uint32_t channel{};
    uint32_t channelEvidence{};
    uint32_t state{};
    int32_t lastStatus{};
    uint64_t writeSequence{};
    uint64_t packetsSeen{};
    uint64_t dropped{};
    uint64_t oversized{};
    uint64_t acknowledgedSequence{};
};
static_assert(sizeof(RingHeader) == 256 && sizeof(Record) == 4160);
static_assert(sizeof(SessionWire) == 24 && sizeof(StatusWire) == 128);
static_assert(offsetof(RingHeader, writeSequence) == 88);
static_assert(offsetof(RingHeader, acknowledgedSequence) == 120);
static_assert(offsetof(Record, payload) == 64);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
} // namespace RewindDV::Foundation::Receive
