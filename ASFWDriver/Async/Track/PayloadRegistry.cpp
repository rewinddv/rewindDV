#include "PayloadRegistry.hpp"
#include "../Tx/PayloadContext.hpp"

#ifdef ASFW_HOST_TEST
    #include <thread>
    #include <chrono>
    static inline void sleep_ms(uint32_t ms) { if (ms) std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
#else
    static inline void sleep_ms(uint32_t ms) { if (ms) IOSleep(ms); }
#endif

namespace ASFW::Async {

PayloadRegistry::PayloadRegistry() {
    lock_ = ::IOLockAlloc();
}

PayloadRegistry::~PayloadRegistry() {
    CancelAll(CancelMode::Synchronous);
    if (lock_) { ::IOLockFree(lock_); lock_ = nullptr; }
}

bool PayloadRegistry::Attach(uint32_t handle, std::shared_ptr<PayloadContext> payload,
                             uint32_t epoch) {
    if (!lock_ || !handle) return false;
    ::IOLockLock(lock_);
    const bool attached = map_.size() < 64 &&
        map_.try_emplace(handle, Entry{ std::move(payload), epoch }).second;
    ::IOLockUnlock(lock_);
    return attached;
}

std::shared_ptr<PayloadContext> PayloadRegistry::Detach(uint32_t handle) {
    if (!lock_) return nullptr;
    ::IOLockLock(lock_);
    auto it = map_.find(handle);
    if (it == map_.end()) { ::IOLockUnlock(lock_); return nullptr; }
    auto p = it->second.payload;
    map_.erase(it);
    ::IOLockUnlock(lock_);
    return p;
}

void PayloadRegistry::CancelAll(CancelMode mode) {
    if (!lock_) return;
    ::IOLockLock(lock_);
    map_.clear();
    ::IOLockUnlock(lock_);
    (void)mode; // Ownership proof belongs to the caller, never a delay.
}

void PayloadRegistry::CancelByEpoch(uint32_t epoch, CancelMode mode) {
    if (!lock_) return;
    ::IOLockLock(lock_);
    for (auto it = map_.begin(); it != map_.end(); ) {
        if (it->second.epoch <= epoch) {
            it = map_.erase(it);
        } else {
            ++it;
        }
    }
    ::IOLockUnlock(lock_);
    (void)mode;
}

bool PayloadRegistry::Drain(uint32_t timeoutMs) {
    if (!lock_) return true;
    const uint32_t stepMs = 5;
    uint32_t waited = 0;
    while (true) {
        ::IOLockLock(lock_);
        bool empty = map_.empty();
        ::IOLockUnlock(lock_);
        if (empty) return true;
        if (waited >= timeoutMs) return false;
        sleep_ms(stepMs);
        waited += stepMs;
    }
}

void PayloadRegistry::SetEpoch(uint32_t epoch) {
    if (!lock_) return;
    ::IOLockLock(lock_);
    epoch_ = epoch;
    ::IOLockUnlock(lock_);
}

uint32_t PayloadRegistry::GetEpoch() const {
    if (!lock_) return epoch_;
    ::IOLockLock(lock_);
    uint32_t v = epoch_;
    ::IOLockUnlock(lock_);
    return v;
}

} // namespace ASFW::Async
