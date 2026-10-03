// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
#pragma once

#include <atomic>
#include <cstdint>

#include "../Async/Track/LabelAllocator.hpp"

namespace ASFW::Async::Bus {

class GenerationTracker {
public:
    struct BusState {
        uint16_t generation16{0};
        uint8_t generation8{0};
        uint16_t localNodeID{0};
        uint32_t requestGeneration{UINT32_MAX};
        bool requestGenerationValid{false};
    };

    explicit GenerationTracker(ASFW::Async::LabelAllocator& allocator) noexcept;

    [[nodiscard]] BusState GetCurrentState() const noexcept;

    /// Apply the generation confirmed from the OHCI SelfIDCount register.
    /// This is NOT the AR bus-reset marker generation — that value is informational
    /// only and is never fed into the tracker.
    void OnConfirmedBusGeneration(uint8_t confirmedGeneration) noexcept;
    // Identity-only notification at the observed reset edge, before Self-ID
    // confirmation. AT cancellation ordering remains owned by the reset FSM.
    void OnBusResetObserved() noexcept;

    void OnSelfIDComplete(uint16_t newNodeID) noexcept;

    void Reset() noexcept;

private:
    void ApplyBusGeneration(uint8_t generation8bit, const char* source) noexcept;

    ASFW::Async::LabelAllocator& labelAllocator_;

    std::atomic<uint8_t> busGeneration8bit_{0};
    std::atomic<uint16_t> localNodeID_{0};
    std::atomic<uint32_t> requestGeneration_{UINT32_MAX};
    // Writers are confined to the controller queue; readers use the atomic
    // published identity. These retain history while admission is invalid.
    uint32_t lastConfirmedRequest_{0};
    bool hasConfirmedRequest_{false};
    bool resetPending_{false};
    bool requestIdentityExhausted_{false};

#ifdef ASFW_HOST_TEST
    friend class GenerationTrackerTestPeer;
#endif
};

} // namespace ASFW::Async::Bus
