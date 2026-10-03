// Modified for RewindDV; see Foundation/NOTICE.md.
#include "SpeedPolicy.hpp"
#include "DiscoveryValues.hpp"  // For MaxPayload constants
#include "../Logging/Logging.hpp"

#include <limits>

namespace ASFW::Discovery {

namespace {
class LockGuard final {
  public:
    explicit LockGuard(IOLock* lock) noexcept : lock_(lock) {
        if (lock_ != nullptr) {
            IOLockLock(lock_);
        }
    }

    ~LockGuard() {
        if (lock_ != nullptr) {
            IOLockUnlock(lock_);
        }
    }

    LockGuard(const LockGuard&) = delete;
    LockGuard& operator=(const LockGuard&) = delete;

  private:
    IOLock* lock_{nullptr};
};

uint32_t SpeedMbps(FwSpeed speed) {
    return 100u << static_cast<uint8_t>(speed);
}
} // namespace

SpeedPolicy::SpeedPolicy() : lock_(IOLockAlloc()) {}

SpeedPolicy::~SpeedPolicy() {
    if (lock_ != nullptr) {
        IOLockFree(lock_);
        lock_ = nullptr;
    }
}

uint64_t SpeedPolicy::BeginGeneration(Generation generation) noexcept {
    if (lock_ == nullptr) {
        return 0;
    }
    LockGuard guard(lock_);
    // Every scan admission gets a distinct software epoch, even if the finite
    // wire generation repeats. This quarantines callbacks from an aborted
    // same-generation scan. A targeted rescan in the same still-live generation
    // preserves successful evidence for other nodes; a reset first calls
    // InvalidateForBusReset(), so a repeated/wrapped generation cannot retain it.
    if (!activeGeneration_.has_value() || *activeGeneration_ != generation) {
        nodeStates_.clear();
    }
    if (AdvanceEpochLocked() == 0) {
        activeGeneration_.reset();
        return 0;
    }
    activeGeneration_ = generation;
    return admissionEpoch_;
}

LinkPolicy SpeedPolicy::ForNode(Generation generation, uint8_t nodeId) const {
    if (lock_ == nullptr) {
        // Lock allocation failure disables learning rather than exposing the
        // unordered_map unsynchronized. No mutation method writes in this state.
        LinkPolicy policy{};
        policy.localToNode = FwSpeed::S400;
        policy.maxPayloadBytes = ComputeMaxPayload(policy.localToNode);
        return policy;
    }
    LockGuard guard(lock_);
    const uint64_t currentEpoch = admissionEpochExhausted_ ? 0 : admissionEpoch_;
    if (currentEpoch == 0 || !activeGeneration_.has_value() ||
        *activeGeneration_ != generation) {
        LinkPolicy policy{};
        policy.localToNode = FwSpeed::S400;
        policy.maxPayloadBytes = ComputeMaxPayload(policy.localToNode);
        policy.halvePackets = halfSizePackets_;
        return policy;
    }

    LinkPolicy policy{};
    const auto it = nodeStates_.find(nodeId);
    policy.localToNode = it != nodeStates_.end() ? it->second.currentSpeed : FwSpeed::S400;
    policy.maxPayloadBytes = ComputeMaxPayload(policy.localToNode);
    policy.halvePackets = halfSizePackets_;
    return policy;
}

LinkPolicy SpeedPolicy::ForNode(Generation generation, uint64_t admissionEpoch,
                                uint8_t nodeId) const {
    LinkPolicy policy{};

    if (lock_ == nullptr) {
        policy.localToNode = FwSpeed::S400;
        policy.maxPayloadBytes = ComputeMaxPayload(policy.localToNode);
        return policy;
    }

    LockGuard guard(lock_);
    if (IsActiveLocked(generation, admissionEpoch)) {
        const auto it = nodeStates_.find(nodeId);
        if (it != nodeStates_.end()) {
            policy.localToNode = it->second.currentSpeed;
        } else {
            policy.localToNode = FwSpeed::S400;
        }
    } else {
        policy.localToNode = FwSpeed::S400;
    }

    policy.maxPayloadBytes = ComputeMaxPayload(policy.localToNode);
    policy.halvePackets = halfSizePackets_;

    return policy;
}

std::optional<FW::FwSpeed>
SpeedPolicy::SuccessfulSpeed(FW::Generation generation, FW::NodeId nodeId) const noexcept {
    if (lock_ == nullptr) {
        return std::nullopt;
    }
    LockGuard guard(lock_);
    if (!activeGeneration_.has_value() || *activeGeneration_ != generation) {
        return std::nullopt;
    }
    const auto it = nodeStates_.find(nodeId.value);
    return it == nodeStates_.end() ? std::nullopt : it->second.successfulSpeed;
}

bool SpeedPolicy::RecordSuccess(Generation generation, uint64_t admissionEpoch,
                                uint8_t nodeId,
                                FwSpeed speed) noexcept {
    if (lock_ == nullptr) {
        return false;
    }
    uint8_t successCount = 0;
    {
        LockGuard guard(lock_);
        if (!IsActiveLocked(generation, admissionEpoch)) {
            return false;
        }
        auto& state = nodeStates_[nodeId];
        state.currentSpeed = speed;
        state.successfulSpeed = speed;
        if (state.successCount != UINT8_MAX) {
            ++state.successCount;
        }
        state.timeoutCount = 0;
        successCount = state.successCount;
    }

    // Rate-limited success logging
    ASFW_LOG_RL(Discovery, "speed_success", 5000, OS_LOG_TYPE_DEBUG,
                "Node %u: Success at S%u (total=%u)",
                nodeId, SpeedMbps(speed), successCount);
    return true;
}

bool SpeedPolicy::RecordTimeout(Generation generation, uint64_t admissionEpoch,
                                uint8_t nodeId,
                                FwSpeed speed) noexcept {
    if (lock_ == nullptr) {
        return false;
    }

    const FwSpeed downgraded = DowngradeSpeed(speed);
    uint8_t timeoutCount = 0;
    {
        LockGuard guard(lock_);
        if (!IsActiveLocked(generation, admissionEpoch)) {
            return false;
        }
        auto& state = nodeStates_[nodeId];
        state.currentSpeed = speed;
        if (state.timeoutCount != UINT8_MAX) {
            ++state.timeoutCount;
        }
        timeoutCount = state.timeoutCount;
        if (downgraded != speed) {
            state.currentSpeed = downgraded;
            state.timeoutCount = 0;
        }
    }

    ASFW_LOG(Discovery, "Node %u: Timeout at S%u (count=%u)",
             nodeId, SpeedMbps(speed), timeoutCount);

    // ROMScanSession calls this only after the per-step retry budget is exhausted.
    // Downgrade one tier immediately so discovery really follows S400→S200→S100.
    if (downgraded != speed) {
        ASFW_LOG(Discovery, "Node %u: Downgraded S%u → S%u",
                 nodeId, SpeedMbps(speed), SpeedMbps(downgraded));
    }
    return true;
}

void SpeedPolicy::SetHalfSizePackets(bool enabled) {
    if (lock_ == nullptr) {
        return;
    }
    LockGuard guard(lock_);
    halfSizePackets_ = enabled;
}

void SpeedPolicy::InvalidateForBusReset() noexcept {
    if (lock_ == nullptr) {
        return;
    }
    LockGuard guard(lock_);
    nodeStates_.clear();
    activeGeneration_.reset();
    (void)AdvanceEpochLocked();
}

bool SpeedPolicy::IsActiveLocked(Generation generation,
                                 uint64_t admissionEpoch) const noexcept {
    return !admissionEpochExhausted_ && admissionEpoch != 0 &&
           admissionEpoch == admissionEpoch_ && activeGeneration_.has_value() &&
           *activeGeneration_ == generation;
}

uint64_t SpeedPolicy::AdvanceEpochLocked() noexcept {
    if (admissionEpochExhausted_ ||
        admissionEpoch_ == std::numeric_limits<uint64_t>::max()) {
        admissionEpochExhausted_ = true;
        admissionEpoch_ = 0;
        return 0;
    }
    ++admissionEpoch_;
    return admissionEpoch_;
}

uint16_t SpeedPolicy::ComputeMaxPayload(FwSpeed speed) const {
    uint16_t basePayload = 0;
    
    switch (speed) {
        case FwSpeed::S100: basePayload = MaxPayload::kS100; break;
        case FwSpeed::S200: basePayload = MaxPayload::kS200; break;
        case FwSpeed::S400: basePayload = MaxPayload::kS400; break;
        case FwSpeed::S800: basePayload = MaxPayload::kS800; break;
    }
    
    if (halfSizePackets_) {
        basePayload /= 2;
    }
    
    return basePayload;
}

FwSpeed SpeedPolicy::DowngradeSpeed(FwSpeed current) const {
    switch (current) {
        case FwSpeed::S800: return FwSpeed::S400;
        case FwSpeed::S400: return FwSpeed::S200;
        case FwSpeed::S200: return FwSpeed::S100;
        case FwSpeed::S100: return FwSpeed::S100;  // Can't go lower
    }
    return FwSpeed::S100;
}

} // namespace ASFW::Discovery
