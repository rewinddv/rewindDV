#pragma once

#include <atomic>
#include <cstdint>

namespace ASFW::Shared {

// A queued callback owns this token independently of its borrowed target.
// Retirement rejects work that has not entered. The teardown owner must retain
// the target and its dependencies until Quiesced() confirms all leases left.
// This is a lifetime fence, not a runtime-state or hardware-admission authority.
class PostedWorkEpoch final {
public:
    [[nodiscard]] bool TryEnter() noexcept {
        auto state = state_.load(std::memory_order_acquire);
        while ((state & kRetired) == 0 && (state & kCountMask) != kCountMask) {
            if (state_.compare_exchange_weak(state, state + 1,
                                            std::memory_order_acq_rel,
                                            std::memory_order_acquire)) return true;
        }
        return false;
    }
    void Leave() noexcept { state_.fetch_sub(1, std::memory_order_acq_rel); }
    void Retire() noexcept { state_.fetch_or(kRetired, std::memory_order_acq_rel); }
    [[nodiscard]] bool Quiesced() const noexcept {
        return (state_.load(std::memory_order_acquire) & kCountMask) == 0;
    }

    class Lease final {
    public:
        explicit Lease(PostedWorkEpoch& epoch) noexcept
            : epoch_(epoch.TryEnter() ? &epoch : nullptr) {}
        ~Lease() { if (epoch_) epoch_->Leave(); }
        explicit operator bool() const noexcept { return epoch_ != nullptr; }
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
    private:
        PostedWorkEpoch* epoch_;
    };

private:
    // Admission and retirement have one modification order. Independent
    // accepting/count atomics could both miss the other's concurrent update.
    static constexpr uint32_t kRetired = uint32_t{1} << 31;
    static constexpr uint32_t kCountMask = kRetired - 1;
    std::atomic<uint32_t> state_{0};
};
} // namespace ASFW::Shared
