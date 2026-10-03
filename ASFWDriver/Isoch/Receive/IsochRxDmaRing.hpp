// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
// IsochRxDmaRing.hpp
// ASFW - Low-level OHCI IR DMA ring engine (generic, no audio semantics).

#pragma once

#include "../Memory/IIsochDMAMemory.hpp"
#include "../../Shared/Rings/BufferRing.hpp"
#include "../../Hardware/OHCIDescriptors.hpp"
#include "../../Common/BarrierUtils.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>

namespace ASFW::Isoch::Rx {

class IsochRxDmaRing final {
public:
    using OHCIDescriptor = Async::HW::OHCIDescriptor;

    struct CompletedPacket final {
        uint32_t descriptorIndex{0};
        uint16_t xferStatus{0};
        uint16_t resCount{0};
        uint16_t actualLength{0};
        const uint8_t* payload{nullptr};
    };

    [[nodiscard]] kern_return_t SetupRings(Memory::IIsochDMAMemory& dma,
                                          size_t numDescriptors,
                                          size_t maxPacketSizeBytes) noexcept;

    // Quiesced context only: reinitialize the complete descriptor program.
    [[nodiscard]] kern_return_t ResetForStart() noexcept;
    [[nodiscard]] bool TakeWakeRequired() noexcept {
        const bool required = wakeRequired_;
        wakeRequired_ = false;
        return required;
    }

    [[nodiscard]] uint32_t InitialCommandPtrWord() const noexcept;

    template <typename Handler>
    [[nodiscard]] uint32_t DrainCompleted(Memory::IIsochDMAMemory& dma,
                                          Handler&& onPacket,
                                          bool recycle = true) noexcept {
        const uint32_t capacity = static_cast<uint32_t>(bufferRing_.Capacity());
        if (capacity == 0 || maxPacketSizeBytes_ == 0) {
            return 0;
        }

        const uint16_t reqCount = static_cast<uint16_t>(maxPacketSizeBytes_);

        uint32_t processed = 0;
        uint32_t idx = lastProcessedIndex_;

        for (uint32_t scanned = 0; scanned < capacity; ++scanned) {
            // A quiesced final drain does not rearm descriptors. Do not deliver
            // the retained completion from the previous traversal twice.
            if (consumedAnchor_ && idx == *consumedAnchor_) break;
            auto* desc = bufferRing_.GetDescriptor(idx);
            if (!desc) {
                break;
            }

            dma.FetchFromDevice(desc, sizeof(*desc));

            // Packet-per-buffer INPUT_LAST: evt_no_status means hardware still
            // owns this descriptor. A changed residual alone is not completion.
            // Take one aligned snapshot so status and residual cannot come from
            // different DMA writebacks. FetchFromDevice supplies DMA coherency;
            // the acquire load keeps subsequent payload reads after this check.
            static_assert(__atomic_always_lock_free(sizeof(uint32_t), nullptr));
            const uint32_t statusWord = __atomic_load_n(&desc->statusWord, __ATOMIC_ACQUIRE);
            const uint16_t xferStatus = static_cast<uint16_t>(statusWord >> 16);
            if ((xferStatus & 0x1Fu) == 0) {
                break;
            }
            // Preserve error completions as well as evt_ack_complete. The raw
            // consumer, not the ring, owns evidence classification.
            const uint16_t resCount = static_cast<uint16_t>(statusWord);

            const uint16_t actualLength = (resCount <= reqCount) ? static_cast<uint16_t>(reqCount - resCount) : 0;
            auto* payloadVA = bufferRing_.GetElementVA(idx);
            if (payloadVA && actualLength > 0) {
                dma.FetchFromDevice(payloadVA, actualLength);
            }

            CompletedPacket packet{
                .descriptorIndex = idx,
                .xferStatus = xferStatus,
                .resCount = resCount,
                .actualLength = actualLength,
                .payload = payloadVA,
            };
            onPacket(packet);

            if (recycle) {
                // OHCI may reread the just-completed descriptor's branch on
                // WAKE (1.1 sections 3.1.1.2 and 3.2.1.2). Retain it until a
                // successor completion proves hardware has advanced.
                if (consumedAnchor_) RecycleConsumed(dma, *consumedAnchor_);
                consumedAnchor_ = idx;
            }

            idx = (idx + 1) % capacity;
            lastProcessedIndex_ = idx;
            ++processed;
        }

        if (processed > 0) {
            ::ASFW::Driver::WriteBarrier();
        }

        return processed;
    }

    // Debug/test helpers.
    [[nodiscard]] size_t Capacity() const noexcept { return bufferRing_.Capacity(); }

    [[nodiscard]] OHCIDescriptor* DescriptorAt(size_t index) noexcept { return bufferRing_.GetDescriptor(index); }

    [[nodiscard]] uint8_t* PayloadVA(size_t index) const noexcept {
        return bufferRing_.GetElementVA(index);
    }

    [[nodiscard]] uint32_t Descriptor0IOVA() const noexcept;

private:
    Shared::BufferRing bufferRing_{};
    size_t maxPacketSizeBytes_{0};
    uint32_t lastProcessedIndex_{0};
    uint32_t terminalIndex_{0};
    std::optional<uint32_t> consumedAnchor_;
    bool wakeRequired_{false};
    void RecycleConsumed(Memory::IIsochDMAMemory& dma, uint32_t index) noexcept;
};

} // namespace ASFW::Isoch::Rx
