// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
#include "DriverKitSessionScheduler.hpp"

#include "../../../Common/TimingUtils.hpp"
#include "../../../Logging/Logging.hpp"
#include "../../../Shared/Completion/NativeSourceRetirement.hpp"

#ifndef ASFW_HOST_TEST
#include "ASFWDriver.h"
#endif

#include <algorithm>
#include <utility>

namespace ASFW::Protocols::SBP2 {

namespace {

class IOLockGuard {
public:
    explicit IOLockGuard(IOLock* lock) : lock_(lock) {
        if (lock_) {
            IOLockLock(lock_);
        }
    }

    ~IOLockGuard() {
        if (lock_) {
            IOLockUnlock(lock_);
        }
    }

    IOLockGuard(const IOLockGuard&) = delete;
    IOLockGuard& operator=(const IOLockGuard&) = delete;

private:
    IOLock* lock_{nullptr};
};

} // namespace

DriverKitSessionScheduler::DriverKitSessionScheduler() {
    lock_ = IOLockAlloc();
}

DriverKitSessionScheduler::~DriverKitSessionScheduler() {
    Reset();
    if (lock_) {
        IOLockFree(lock_);
        lock_ = nullptr;
    }
}

kern_return_t DriverKitSessionScheduler::Prepare(::ASFWDriver& service,
                                                 OSSharedPtr<IODispatchQueue> workQueue) {
    if (!workQueue) {
        return kIOReturnNotReady;
    }
    if (timer_) return kIOReturnBusy;
    Reset();
    if (!ASFW::Timing::initializeHostTimebase()) {
        return kIOReturnNotReady;
    }
    workQueue_ = std::move(workQueue);
    {
        IOLockGuard guard(lock_);
        retiring_ = false;
        nativeOperationEpoch_ = std::make_shared<ASFW::Shared::PostedWorkEpoch>();
    }

#ifdef ASFW_HOST_TEST
    (void)service;
    return kIOReturnSuccess;
#else
    IOTimerDispatchSource* rawTimer = nullptr;
    auto kr = IOTimerDispatchSource::Create(workQueue_.get(), &rawTimer);
    if (kr != kIOReturnSuccess || rawTimer == nullptr) {
        workQueue_.reset();
        return kr != kIOReturnSuccess ? kr : kIOReturnNoResources;
    }
    timer_ = OSSharedPtr(rawTimer, OSNoRetain);

    OSAction* rawAction = nullptr;
    kr = service.CreateActionSBP2SessionTimerFired(0, &rawAction);
    if (kr != kIOReturnSuccess || rawAction == nullptr) {
        timer_.reset();
        workQueue_.reset();
        return kr != kIOReturnSuccess ? kr : kIOReturnError;
    }
    action_ = OSSharedPtr(rawAction, OSNoRetain);

    kr = timer_->SetHandler(action_.get());
    if (kr != kIOReturnSuccess) {
        return kr;
    }

    kr = timer_->SetEnableWithCompletion(true, nullptr);
    if (kr != kIOReturnSuccess) {
        return kr;
    }

    return kIOReturnSuccess;
#endif
}

void DriverKitSessionScheduler::Reset() noexcept {
    {
        IOLockGuard guard(lock_);
        retiring_ = true;
        pending_.clear();
        nativeOperationEpoch_->Retire();
    }

    if (timer_) {
        ASFW_LOG_ERROR(Controller, "Control timer reset before native retirement; retaining timer/action");
        (void)timer_.detach();
        (void)action_.detach();
    }
    action_.reset();
    timer_.reset();
    workQueue_.reset();
}

void DriverKitSessionScheduler::BeginNativeRetirement(
    const std::shared_ptr<ASFW::Shared::NativeCallbackDrain>& drain) {
    OSSharedPtr<IOTimerDispatchSource> timer;
    OSSharedPtr<OSAction> action;
    {
        IOLockGuard guard(lock_);
        retiring_ = true;
        pending_.clear();
        nativeOperationEpoch_->Retire();
        if (!nativeOperationEpoch_->Quiesced()) {
            // A native arm RPC may be executing on another queue. Never issue
            // terminal Cancel while that call can still touch the source, and
            // never wait on Default for the RPC that needs Default to finish.
            drain->Quarantine();
            return;
        }
        timer = std::move(timer_);
        action = std::move(action_);
    }
#ifndef ASFW_HOST_TEST
    ASFW::Shared::RetireNativeSource(timer, action, drain);
    // An exhausted ledger quarantines without taking ownership. Keep those
    // references in the scheduler; never release on failed registration.
    if (timer || action) {
        IOLockGuard guard(lock_);
        timer_ = std::move(timer);
        action_ = std::move(action);
    }
#else
    (void)drain;
    Reset();
#endif
}

SchedulerToken DriverKitSessionScheduler::ScheduleAfter(uint64_t delayNs,
                                                        std::function<void()> fn) {
    if (!fn) {
        return kInvalidSchedulerToken;
    }

#ifdef ASFW_HOST_TEST
    if (!workQueue_) {
        fn();
        return kInvalidSchedulerToken;
    }
    const SchedulerToken token = nextToken_++;
    workQueue_->DispatchAsyncAfter(delayNs, std::move(fn));
    return token;
#else
    SchedulerToken token;
    uint64_t earliest;
    OSSharedPtr<IOTimerDispatchSource> timer;
    std::shared_ptr<ASFW::Shared::PostedWorkEpoch> nativeEpoch;
    {
        IOLockGuard guard(lock_);
        if (retiring_ || !timer_) return kInvalidSchedulerToken;
        token = nextToken_++;
        if (token == kInvalidSchedulerToken) {
            token = nextToken_++;
        }
        pending_.emplace(token, PendingCallback{
                                    .deadlineTicks = DeadlineTicksFromNow(delayNs),
                                    .fn = std::move(fn),
                                });
        earliest = EarliestDeadlineLocked();
        timer = timer_;
        nativeEpoch = nativeOperationEpoch_;
    }
    ArmTimerUnlocked(timer.get(), earliest, nativeEpoch);
    return token;
#endif
}

void DriverKitSessionScheduler::Cancel(SchedulerToken token) {
    if (token == kInvalidSchedulerToken) {
        return;
    }

    uint64_t earliest = 0;
    OSSharedPtr<IOTimerDispatchSource> timer;
    std::shared_ptr<ASFW::Shared::PostedWorkEpoch> nativeEpoch;
    bool changed = false;
    {
        IOLockGuard guard(lock_);
        if (pending_.erase(token) > 0) {
            changed = true;
            earliest = EarliestDeadlineLocked();
            timer = timer_;
            nativeEpoch = nativeOperationEpoch_;
        }
    }
    if (changed) {
        ArmTimerUnlocked(timer.get(), earliest, nativeEpoch);
    }
}

void DriverKitSessionScheduler::HandleTimerFired() noexcept {
    std::vector<std::function<void()>> due;
    uint64_t earliest = 0;
    OSSharedPtr<IOTimerDispatchSource> timer;
    std::shared_ptr<ASFW::Shared::PostedWorkEpoch> nativeEpoch;

    {
        IOLockGuard guard(lock_);
        if (retiring_) return;
        const uint64_t now = mach_absolute_time();
        for (auto it = pending_.begin(); it != pending_.end();) {
            if (it->second.deadlineTicks <= now) {
                due.push_back(std::move(it->second.fn));
                it = pending_.erase(it);
            } else {
                ++it;
            }
        }
        earliest = EarliestDeadlineLocked();
        timer = timer_;
        nativeEpoch = nativeOperationEpoch_;
    }
    ArmTimerUnlocked(timer.get(), earliest, nativeEpoch);

    for (auto& fn : due) {
        if (fn) {
            fn();
        }
    }
}

uint64_t DriverKitSessionScheduler::EarliestDeadlineLocked() const noexcept {
    if (pending_.empty()) {
        return 0;
    }
    const auto next = std::min_element(
        pending_.begin(), pending_.end(),
        [](const auto& a, const auto& b) {
            return a.second.deadlineTicks < b.second.deadlineTicks;
        });
    return next == pending_.end() ? 0 : next->second.deadlineTicks;
}

void DriverKitSessionScheduler::ArmTimerUnlocked(IOTimerDispatchSource* timer,
                                                 uint64_t deadlineTicks,
    const std::shared_ptr<ASFW::Shared::PostedWorkEpoch>& epoch) noexcept {
#ifdef ASFW_HOST_TEST
    (void)timer;
    (void)deadlineTicks;
    (void)epoch;
#else
    if (timer == nullptr || deadlineTicks == 0 || !epoch) {
        return;
    }
    ASFW::Shared::PostedWorkEpoch::Lease lease(*epoch);
    if (!lease) return;
    // lock_ MUST NOT be held here. WakeAtTime is RPC-dispatched to the timer's
    // queue (ASFWDriver-Default); that queue's completion handlers re-enter the
    // scheduler and take lock_. Holding lock_ across this call deadlocked the
    // user-client teardown queue against the driver queue and tripped the 60s
    // IOKit registry busy-timeout kernel panic (2026-06-22).
    (void)timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, deadlineTicks, 0);
#endif
}

uint64_t DriverKitSessionScheduler::DeadlineTicksFromNow(uint64_t delayNs) const noexcept {
    (void)ASFW::Timing::initializeHostTimebase();
    uint64_t deltaTicks = ASFW::Timing::nanosToHostTicks(delayNs);
    if (deltaTicks == 0) {
        deltaTicks = 1;
    }
    return mach_absolute_time() + deltaTicks;
}

} // namespace ASFW::Protocols::SBP2
