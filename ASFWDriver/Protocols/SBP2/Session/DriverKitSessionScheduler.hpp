#pragma once

#include "ISessionScheduler.hpp"

#ifdef ASFW_HOST_TEST
#include "../../../Testing/HostDriverKitStubs.hpp"
#else
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSSharedPtr.h>
#endif

#include <functional>
#include <map>
#include <vector>
#include "../../../Shared/Completion/NativeCallbackDrain.hpp"
#include "../../../Shared/Completion/PostedWorkEpoch.hpp"
#include <memory>

class ASFWDriver;

namespace ASFW::Protocols::SBP2 {

// Production implementation of ISessionScheduler. A single DriverKit timer
// source wakes the next due SBP-2 session callback; callbacks then run on the
// driver's Default queue.
class DriverKitSessionScheduler final : public ISessionScheduler {
public:
    DriverKitSessionScheduler();
    ~DriverKitSessionScheduler() override;

    DriverKitSessionScheduler(const DriverKitSessionScheduler&) = delete;
    DriverKitSessionScheduler& operator=(const DriverKitSessionScheduler&) = delete;

    [[nodiscard]] kern_return_t Prepare(::ASFWDriver& service,
                                        OSSharedPtr<IODispatchQueue> workQueue);
    void Reset() noexcept;
    void BeginNativeRetirement(const std::shared_ptr<ASFW::Shared::NativeCallbackDrain>& drain);
    [[nodiscard]] bool OwnsAction(const OSAction* action) const noexcept {
        return action != nullptr && action == action_.get();
    }

    [[nodiscard]] SchedulerToken ScheduleAfter(uint64_t delayNs,
                                               std::function<void()> fn) override;
    void Cancel(SchedulerToken token) override;

    void HandleTimerFired() noexcept;

private:
    struct PendingCallback {
        uint64_t deadlineTicks{0};
        std::function<void()> fn;
    };

    // Earliest pending deadline in mach-absolute ticks (0 = none). Caller holds lock_.
    [[nodiscard]] uint64_t EarliestDeadlineLocked() const noexcept;
    // Arms the hardware timer. MUST be called WITHOUT lock_ held: WakeAtTime is
    // RPC-dispatched to the timer's queue (ASFWDriver-Default), whose handlers
    // re-enter the scheduler and take lock_. Holding lock_ across it is an AB-BA
    // deadlock (kernel registry busy-timeout panic, 2026-06-22).
    static void ArmTimerUnlocked(IOTimerDispatchSource* timer, uint64_t deadlineTicks,
                                 const std::shared_ptr<ASFW::Shared::PostedWorkEpoch>& epoch) noexcept;
    [[nodiscard]] uint64_t DeadlineTicksFromNow(uint64_t delayNs) const noexcept;

    IOLock* lock_{nullptr};
    OSSharedPtr<IODispatchQueue> workQueue_{};
    OSSharedPtr<IOTimerDispatchSource> timer_{};
    OSSharedPtr<OSAction> action_{};
    std::map<SchedulerToken, PendingCallback> pending_;
    SchedulerToken nextToken_{1};
    bool retiring_{false}; // protected by lock_; never hold lock across native RPC
    std::shared_ptr<ASFW::Shared::PostedWorkEpoch> nativeOperationEpoch_{
        std::make_shared<ASFW::Shared::PostedWorkEpoch>()};
};

} // namespace ASFW::Protocols::SBP2
