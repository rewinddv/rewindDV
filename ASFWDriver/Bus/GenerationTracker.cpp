// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
#include "GenerationTracker.hpp"
#include "../Logging/Logging.hpp"

namespace ASFW::Async::Bus {

using namespace ASFW::Async;

GenerationTracker::GenerationTracker(LabelAllocator& allocator) noexcept
    : labelAllocator_(allocator)
{}

void GenerationTracker::Reset() noexcept {
    requestGeneration_.store(UINT32_MAX, std::memory_order_release);
    lastConfirmedRequest_ = 0;
    hasConfirmedRequest_ = false;
    resetPending_ = false;
    requestIdentityExhausted_ = false;
    localNodeID_.store(0, std::memory_order_release);
    busGeneration8bit_.store(0, std::memory_order_release);
    labelAllocator_.Reset();
}

GenerationTracker::BusState GenerationTracker::GetCurrentState() const noexcept {
    const uint32_t request = requestGeneration_.load(std::memory_order_acquire);
    const uint16_t gen16 = labelAllocator_.CurrentGeneration();
    const uint16_t node = localNodeID_.load(std::memory_order_acquire);
    const uint8_t gen8 = static_cast<uint8_t>(gen16 & 0x00FF);
    const bool valid = request != UINT32_MAX &&
        request == requestGeneration_.load(std::memory_order_acquire);
    return BusState{ .generation16 = gen16, .generation8 = gen8, .localNodeID = node,
        .requestGeneration = valid ? request : UINT32_MAX, .requestGenerationValid = valid };
}

void GenerationTracker::OnBusResetObserved() noexcept {
    requestGeneration_.store(UINT32_MAX, std::memory_order_release);
    resetPending_ = true;
}

void GenerationTracker::OnConfirmedBusGeneration(uint8_t confirmedGeneration) noexcept {
    if (hasConfirmedRequest_ && !resetPending_ && !requestIdentityExhausted_ &&
        static_cast<uint8_t>(lastConfirmedRequest_) == confirmedGeneration) return;
    // Confirmations may reveal a reset whose edge was not observed. Revoke the
    // old identity before changing any fields which readers associate with it.
    requestGeneration_.store(UINT32_MAX, std::memory_order_release);
    // Named for its actual source: the caller passes the generation read from the OHCI
    // SelfIDCount register (see AsyncSubsystem::ConfirmBusGeneration), NOT the value in
    // the controller-synthesized AR bus-reset marker. RxPath deliberately does not feed
    // the marker generation here at all. The old "synthetic" naming made traces read as
    // though the marker had supplied the generation, which is precisely the confusion
    // that made the wrong-quadlet marker bug hard to see.
    ASFW_LOG(Async, "GenerationTracker: Bus generation confirmed from SelfIDCount: %u",
             confirmedGeneration);
    localNodeID_.store(0, std::memory_order_release);
    ApplyBusGeneration(confirmedGeneration, "selfid-count");
    if (requestIdentityExhausted_) return;
    uint32_t next = confirmedGeneration;
    if (hasConfirmedRequest_) {
        uint32_t delta = static_cast<uint8_t>(confirmedGeneration -
                                             static_cast<uint8_t>(lastConfirmedRequest_));
        if (delta == 0 && resetPending_) delta = 256;
        if (delta >= UINT32_MAX - lastConfirmedRequest_) {
            requestIdentityExhausted_ = true;
            requestGeneration_.store(UINT32_MAX, std::memory_order_release);
            ASFW_LOG_ERROR(Async, "Request generation exhausted; runtime rebuild required");
            return;
        }
        next = lastConfirmedRequest_ + delta;
    }
    lastConfirmedRequest_ = next;
    hasConfirmedRequest_ = true;
    resetPending_ = false;
    requestGeneration_.store(next, std::memory_order_release);
}

void GenerationTracker::OnSelfIDComplete(uint16_t newNodeID) noexcept {
    ASFW_LOG(Async, "GenerationTracker: Self-ID complete. New NodeID: 0x%04x", newNodeID);
    localNodeID_.store(newNodeID, std::memory_order_release);
}

void GenerationTracker::ApplyBusGeneration(uint8_t generation8bit, const char* source) noexcept {
    const uint8_t previous8bit = busGeneration8bit_.exchange(generation8bit, std::memory_order_acq_rel);
    const uint16_t current16bit = labelAllocator_.CurrentGeneration();
    const uint8_t currentLow8bit = static_cast<uint8_t>(current16bit & 0x00FF);
    uint16_t newHigh = static_cast<uint16_t>(current16bit & 0xFF00);

    if (generation8bit < currentLow8bit) {
        newHigh = static_cast<uint16_t>(newHigh + 0x0100);
    }

    const uint16_t newGen16 = static_cast<uint16_t>(newHigh | generation8bit);
    labelAllocator_.SetGeneration(newGen16);

    ASFW_LOG(Async,
             "Bus generation update (%{public}s): prev8=%u, new8=%u -> prev16=0x%04x, new16=0x%04x",
             source,
             previous8bit,
             generation8bit,
             current16bit,
             newGen16);
}

} // namespace ASFW::Async::Bus
