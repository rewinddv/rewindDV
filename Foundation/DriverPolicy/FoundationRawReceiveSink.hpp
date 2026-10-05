// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "FoundationReceiveWire.hpp"
#include "../../ASFWDriver/Isoch/Core/IsochTypes.hpp"
#include "../../ASFWDriver/Common/DMASafeCopy.hpp"
#include <cstring>
#include <new>

namespace RewindDV::Foundation::Receive {
class RawSink final : public ASFW::Isoch::IIsochReceiveConsumer {
public:
    static constexpr uint64_t RequiredBytes(uint32_t capacity = kCapacity) {
        return sizeof(RingHeader) + uint64_t(capacity) * sizeof(Record);
    }
    bool Initialize(void* base, uint64_t bytes, uint64_t epoch,
                    const DriverPolicy::FoundationRouteWire& route,
                    uint32_t capacity = kCapacity) noexcept {
        if (!base || reinterpret_cast<uintptr_t>(base) % alignof(RingHeader) ||
            !capacity || !epoch || bytes < RequiredBytes(capacity)) return false;
        std::memset(base, 0, static_cast<size_t>(RequiredBytes(capacity)));
        header_ = ::new(base) RingHeader{};
        records_ = reinterpret_cast<Record*>(static_cast<uint8_t*>(base) + sizeof(RingHeader));
        capacity_ = capacity;
        header_->magic = kMagic;
        header_->version = kVersion;
        header_->headerBytes = sizeof(RingHeader);
        header_->recordBytes = sizeof(Record);
        header_->capacity = capacity;
        header_->epoch = epoch;
        header_->route = route;
        header_->channel = 0xffffffffu;
        written_ = seen_ = dropped_ = 0;
        acknowledged_.store(0, std::memory_order_relaxed);
        return true;
    }
    void SetChannel(uint32_t channel, ChannelEvidence evidence) noexcept {
        header_->channel = channel;
        header_->channelEvidence = static_cast<uint32_t>(evidence);
    }
    void SetState(State state, int32_t status = 0) noexcept {
        header_->lastStatus.store(status, std::memory_order_relaxed);
        header_->state.store(static_cast<uint32_t>(state), std::memory_order_release);
    }
    State GetState() const noexcept {
        return static_cast<State>(header_->state.load(std::memory_order_acquire));
    }
    // The service publishes Active only after the final route revalidation.
    void OnReceiveActivated() noexcept override {}
    void BeginReceiveBatch(const ASFW::Isoch::IsochReceiveBatch&) noexcept override {}
    void ConsumePacket(const ASFW::Isoch::IsochReceiveBatch& batch,
                       const ASFW::Isoch::IsochReceivePacket& packet) noexcept override {
        // Every callback is recorded before any CIP/DIF interpretation, including
        // empty packets, malformed data and non-success descriptor statuses.
        const uint64_t observed = ++seen_;
        header_->packetsSeen.store(observed, std::memory_order_relaxed);
        const bool oversized = packet.payload.size() > kPayloadBytes;
        if (oversized || written_ - acknowledged_.load(std::memory_order_acquire) >= capacity_) {
            header_->dropped.store(++dropped_, std::memory_order_release);
            if (oversized) header_->oversized.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        auto& record = records_[written_ % capacity_];
        record.writeSequence = written_ + 1;
        record.epoch = header_->epoch;
        record.hostTicks = batch.drainHostTicks;
        record.cycleTimer = batch.drainCycleTimer;
        record.descriptorIndex = packet.descriptorIndex;
        record.transferStatus = packet.transferStatus;
        record.residualCount = packet.residualCount;
        record.payloadBytes = static_cast<uint32_t>(packet.payload.size());
        record.observedSequence = observed;
        record.lossBefore = dropped_;
        record.flags = 1; // transport continuity unknown
        record.reserved = 0;
        ASFW::Common::CopyFromQuadletAlignedDeviceMemory(
            std::span<uint8_t>(record.payload.data(), packet.payload.size()),
            packet.payload.data());
        // Do not publish stale bytes beyond this packet's actual payload length.
        std::memset(record.payload.data() + packet.payload.size(), 0,
                    kPayloadBytes - packet.payload.size());
        header_->writeSequence.store(++written_, std::memory_order_release);
    }
    bool Acknowledge(uint64_t sequence) noexcept {
        const uint64_t prior = acknowledged_.load(std::memory_order_relaxed);
        if (sequence < prior || sequence > header_->writeSequence.load(std::memory_order_acquire))
            return false;
        header_->acknowledgedSequence.store(sequence, std::memory_order_release);
        acknowledged_.store(sequence, std::memory_order_release);
        return true;
    }
    StatusWire Snapshot() const noexcept {
        StatusWire result{};
        result.magic = header_->magic;
        result.version = header_->version;
        result.headerBytes = header_->headerBytes;
        result.recordBytes = header_->recordBytes;
        result.capacity = header_->capacity;
        result.epoch = header_->epoch;
        result.route = header_->route;
        result.channel = header_->channel;
        result.channelEvidence = header_->channelEvidence;
        result.state = header_->state.load(std::memory_order_acquire);
        result.lastStatus = header_->lastStatus.load(std::memory_order_acquire);
        result.writeSequence = header_->writeSequence.load(std::memory_order_acquire);
        result.packetsSeen = header_->packetsSeen.load(std::memory_order_acquire);
        result.dropped = header_->dropped.load(std::memory_order_acquire);
        result.oversized = header_->oversized.load(std::memory_order_acquire);
        result.acknowledgedSequence = header_->acknowledgedSequence.load(std::memory_order_acquire);
        return result;
    }
private:
    RingHeader* header_{};
    Record* records_{};
    uint32_t capacity_{};
    uint64_t written_{}, seen_{}, dropped_{}; // single receive poll writer
    std::atomic<uint64_t> acknowledged_{}; // server-owned cursor
};
} // namespace RewindDV::Foundation::Receive
