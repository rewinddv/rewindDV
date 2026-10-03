// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>

namespace ASFW::Driver {
// Watchdog-queue owned. A missing notification is not permission to replay a
// transaction or poll DMA concurrently with the interrupt owner.
class InterruptStallPolicy {
public:
    static constexpr uint64_t kStallNanoseconds = 100'000'000;
    bool Observe(uint64_t now, uint64_t completed, bool handlerActive, bool pending) {
        if (handlerActive || !pending || completed != completed_) {
            completed_ = completed;
            since_ = now;
            tracking_ = pending && !handlerActive;
            attempted_ = false;
            return false;
        }
        if (!tracking_) {
            tracking_ = true;
            since_ = now;
            return false;
        }
        if (attempted_ || now < since_ || now - since_ < kStallNanoseconds) return false;
        attempted_ = true; // One attempt per stalled epoch, even if hardware refuses it.
        return true;
    }
private:
    uint64_t completed_{0};
    uint64_t since_{0};
    bool tracking_{false};
    bool attempted_{false};
};
} // namespace ASFW::Driver
