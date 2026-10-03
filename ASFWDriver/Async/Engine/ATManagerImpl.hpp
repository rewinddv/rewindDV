// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#pragma once

#include "ATManager.hpp"
#include "ATTrace.hpp"
#include "../Contexts/ContextBase.hpp"  // For ATRequestTag, ATResponseTag full definitions
#include "../../Hardware/OHCIDescriptors.hpp"
#include "../../Hardware/HardwareInterface.hpp"
#include "../../Hardware/OHCIConstants.hpp"
#include "../Core/LockPolicy.hpp"  // Phase 1.2: Fine-grained locking
#include "../../Logging/LogConfig.hpp"  // For ASFW_LOG_V1 macro

using ASFW::Driver::kContextControlRunBit;
using ASFW::Driver::kContextControlWakeBit;
using ASFW::Driver::kContextControlDeadBit;
using ASFW::Driver::kContextControlActiveBit;

namespace ASFW::Async::Engine {

namespace {
inline const char* ToStringImpl(ATState s) noexcept {
    switch (s) {
        case ATState::IDLE: return "IDLE";
        case ATState::ARMING: return "ARMING";
        case ATState::RUNNING: return "RUNNING";
        case ATState::STOPPING: return "STOPPING";
        case ATState::ERROR: return "ERROR";
        default: return "UNKNOWN";
    }
}
} // anonymous namespace

inline const char* ToString(ATState s) noexcept {
    return ToStringImpl(s);
}

template<typename ContextT, typename RingT, typename RoleTag>
kern_return_t ATManager<ContextT, RingT, RoleTag>::Submit(DescriptorChain&& chain, const AsyncCmdOptions& opts) {
    if (!this->HasStateLock()) return kIOReturnNoMemory;
    if (chain.Empty()) {
        ASFW_LOG_ERROR(Async, "[%{public}s] Submit: Empty chain", RoleTag::kContextName);
        return kIOReturnBadArgument;
    }

    const uint32_t txid = chain.txid;

    // Completion retirement is implemented by ContextT::ScanCompletion(), so
    // submission must use the context's queue lock as its outer ownership
    // boundary. This keeps branch publication, WAKE, and tail commit atomic
    // with respect to retirement. It also serializes manager submissions after
    // each caller has finished constructing its descriptor chain.
    struct SubmissionQueueGuard {
        explicit SubmissionQueueGuard(ContextT& context) noexcept : context_(context) {
            context_.LockSubmissionQueue();
        }
        ~SubmissionQueueGuard() { context_.UnlockSubmissionQueue(); }
        ContextT& context_;
    } submissionQueueGuard(ctx());

    // PATH decision using software state only (Apple's pattern)
    // From decompilation @ 0xDBBE line 109: if (*((_BYTE *)this + 28))
    // Apple checks ONLY software flag, never reads hardware registers
    bool canP2;
    {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);

        // Simple check: Is context marked as running in software?
        // Additional safety: Ring must still have descriptors we can link to
        const bool hasPrevLast = ring().PrevLastBlocks() > 0;
        const bool ringHasData = !ring().IsEmpty();
        canP2 = (this->state_ == State::RUNNING) && hasPrevLast && ringHasData;
    }  // Lock automatically released here (RAII)

    if (canP2) {
        // PATH 2: Hot-append to running context (fire-and-forget)
        kern_return_t kr = SubmitPath2_(chain, txid, opts);
        if (kr == kIOReturnSuccess) {
            // FIX: Removed duplicate requestStop_ call - was being called twice!
            // Also removed to prevent deadlock (same reason as PATH 1/2 inline fixes)
            // if (opts.needsFlush) {
            //     // Re-acquire lock only for requestStop_
            //     IOLockWrapper lockWrapper(lock());
            //     ScopedLock guard(lockWrapper);
            //     requestStop_(txid, "needsFlush");
            // }
            return kIOReturnSuccess;
        }
        // Fall through to PATH 1 fallback on failure
        ASFW_LOG_V2(Async, "[%{public}s] PATH 2 failed, falling back to PATH 1", RoleTag::kContextName);
    }

    // V1: Compact AT transmit one-liner for packet flow visibility
    const uint8_t totalBlocks = chain.TotalBlocks();
    ASFW_LOG_V2(Async, "📤 AT/TX: txid=%u blocks=%u (%{public}s)",
               txid, totalBlocks, canP2 ? "PATH2" : "PATH1");

    // PATH 1: First submission or re-arm. Hardware operations do not hold the
    // FSM lock, but remain inside the outer context queue lock.
    return SubmitPath1_(chain, txid, opts);
}

template<typename ContextT, typename RingT, typename RoleTag>
kern_return_t ATManager<ContextT, RingT, RoleTag>::SubmitPath1_(const DescriptorChain& chain, uint32_t txid, const AsyncCmdOptions& opts) {
    // Phase 1.2: Fine-grained locking for PATH 1
    // The FSM lock is held only for FSM transitions and ring updates.

    // FSM transition under lock
    {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        Base::Transition(State::ARMING, txid, "path1_start");
    }

    // Hardware operations without the FSM lock; the context queue lock is held.
    // Z nibble must be total blocks per OHCI; use TotalBlocks() not firstBlocks
    const uint8_t z = ATSubmitPolicy::ComputeZ(chain.TotalBlocks());
    PublishChain_(chain);
    this->IoWriteFence();

    // Keep the existing short poll budget: a refused submit is safer than
    // reprogramming live DMA or blocking the shared queue for tens of ms.
    uint32_t control = ctx().ReadControl();
    if (control != 0xFFFFFFFFu &&
        (control & (kContextControlRunBit | kContextControlActiveBit)) != 0) {
        clearRunAndPoll_();
        control = ctx().ReadControl();
    }
    if (control == 0xFFFFFFFFu ||
        (control & (kContextControlRunBit | kContextControlActiveBit)) != 0) {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        Base::Transition(State::ERROR, txid, "path1_not_quiescent");
        return control == 0xFFFFFFFFu ? kIOReturnNotReady : kIOReturnBusy;
    }

    const uint32_t cmdPtr = ring().CommandPtrWordFromIOVA(chain.firstIOVA32, z);
    if (cmdPtr == 0) {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        Base::Transition(State::ERROR, txid, "invalid_cmdptr");
        return kIOReturnBadArgument;
    }

    // Program hardware without the FSM lock; the context queue lock is held.
    ctx().WriteCommandPtr(cmdPtr);
    ctx().WriteControlSet(kContextControlRunBit);

    ASFW_LOG_V3(Async, "ctx=%{public}s txid=%u gen=%u P1_ARM head=%lu tail=%lu z=%u cmdPtr=0x%08x", RoleTag::kContextName, txid, generation_, (unsigned long)ring().Head(), (unsigned long)ring().Tail(), z, cmdPtr);

    trace_.push({NowNs(), txid, generation_, ATEvent::P1_ARM, cmdPtr, z});

    // FSM transition and ring update under lock
    {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        Base::Transition(State::RUNNING, txid, "path1_armed");
        UpdateRingTail_(chain);

        // FIX: Don't call requestStop_ with lock held - causes deadlock!
        // Same fix as PATH 2 - let interrupt handler stop context when appropriate
        // if (opts.needsFlush) {
        //     requestStop_(txid, "needsFlush");
        // }
    }

    return kIOReturnSuccess;
}

template<typename ContextT, typename RingT, typename RoleTag>
kern_return_t ATManager<ContextT, RingT, RoleTag>::SubmitPath2_(const DescriptorChain& chain, uint32_t txid, const AsyncCmdOptions& opts) {
    // PATH 2: Hot-append to running context (Apple's fire-and-forget pattern)
    // The FSM lock is held only for ring updates, not hardware operations. The
    // outer context queue lock remains held across this entire method so a
    // completion cannot retire the branch anchor before WAKE + tail commit.
    // WAKE is pulsed without polling, allowing immediate return.

    // Reject only while the new chain is still unreachable by DMA. Once the
    // branch is published, ownership must remain with completion/reset handling
    // even if RUN drops before the WAKE check.
    const uint32_t beforeLink = ctx().ReadControl();
    if (beforeLink == 0xFFFFFFFFu ||
        (beforeLink & kContextControlRunBit) == 0 ||
        (beforeLink & kContextControlDeadBit) != 0) {
        return kIOReturnNotReady;
    }

    // Ring updates under lock
    kern_return_t linkResult = kIOReturnSuccess;
    uint8_t previousChainBlocks = 0;
    size_t appendHead = 0;
    size_t appendTail = 0;
    {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        previousChainBlocks = ring().PrevLastBlocks();
        appendHead = ring().Head();
        appendTail = ring().Tail();
        linkResult = LinkTailTo_(chain);
    }  // Lock released before hardware operations

    if (linkResult != kIOReturnSuccess) {
        ASFW_LOG(Async,
                 "ctx=%{public}s txid=%u gen=%u P2_FALLBACK cause=LinkTailTo prevChainBlocks=%u head=%zu tail=%zu nextBlocks=%u",
                 RoleTag::kContextName,
                 txid,
                 generation_,
                 previousChainBlocks,
                 appendHead,
                 appendTail,
                 chain.TotalBlocks());
        trace_.push({NowNs(), txid, generation_, ATEvent::P2_FALLBACK, 0, 0});
        return linkResult;
    }

    // Hardware operations without the FSM lock; the context queue lock is held.
    this->IoWriteFence();

    // WAKE guard: Check RUN==1 && DEAD==0 before pulsing WAKE
    const uint32_t ctrl = ctx().ReadControl();
    const bool run = (ctrl & kContextControlRunBit) != 0;
    const bool dead = (ctrl & kContextControlDeadBit) != 0;

    ASFW_LOG_V3(Async, "ctx=%{public}s txid=%u gen=%u WAKE_GUARD ctrl=0x%08x run=%d dead=%d", RoleTag::kContextName, txid, generation_, ctrl, run ? 1 : 0, dead ? 1 : 0);

    if (ctrl != 0xFFFFFFFFu && run && !dead) {
        // WAKE is only a hint; never poll ACTIVE here.
        ctx().WriteControlSet(kContextControlWakeBit);
        trace_.push({NowNs(), txid, generation_, ATEvent::P2_WAKE, 0, 0});
    } else {
        // The branch may already have been fetched. Do not unlink, replay or
        // report this as an unposted failure (which releases its payload).
        // Success here means admitted, not completed; normal completion/reset
        // handling still determines the transaction's actual result.
        ASFW_LOG(Async, "ctx=%{public}s txid=%u gen=%u P2_PUBLISHED_NO_WAKE ctrl=0x%08x",
                 RoleTag::kContextName, txid, generation_, ctrl);
    }

    // Ring update under lock. The outer context queue lock remains held, so
    // ScanCompletion() cannot retire the previous branch anchor before this
    // new tail becomes visible.
    bool emitHotAppendProof = false;
    {
        IOLockWrapper lockWrapper(lock());
        ScopedLock guard(lockWrapper);
        UpdateRingTail_(chain);
        if (!hotAppendProofEmitted_ &&
            previousChainBlocks == 3 && chain.TotalBlocks() == 3) {
            hotAppendProofEmitted_ = true;
            emitHotAppendProof = true;
        }

        // FIX: Don't call requestStop_ with lock held - causes deadlock!
        // Apple's pattern: Let interrupt handler (ScanCompletion) stop context when ring drains
        // The interrupt handler already has correct stop logic at ATContextBase.hpp:886-903
        // if (opts.needsFlush) {
        //     requestStop_(txid, "needsFlush");
        // }
    }

    if (emitHotAppendProof) {
        ASFW_LOG_V1(Async,
                    "ctx=%{public}s txid=%u gen=%u P2_APPEND_PROOF prevChainBlocks=%u head=%zu tail=%zu nextBlocks=%u",
                    RoleTag::kContextName,
                    txid,
                    generation_,
                    previousChainBlocks,
                    appendHead,
                    appendTail,
                    chain.TotalBlocks());
    }

    return kIOReturnSuccess;
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::RequestStop(uint32_t txid, const char* why) noexcept {
    if (!this->HasStateLock()) return;
    struct SubmissionQueueGuard {
        explicit SubmissionQueueGuard(ContextT& context) noexcept : context_(context) {
            context_.LockSubmissionQueue();
        }
        ~SubmissionQueueGuard() { context_.UnlockSubmissionQueue(); }
        ContextT& context_;
    } submissionQueueGuard(ctx());
    // Phase 1.2: Use ScopedLock for automatic RAII
    IOLockWrapper lockWrapper(lock());
    ScopedLock guard(lockWrapper);
    requestStop_(txid, why);
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::requestStop_(uint32_t txid, const char* why) noexcept {
    if (this->state_ != State::RUNNING) {
        ASFW_LOG_V2(Async, "ctx=%{public}s txid=%u gen=%u STOP_SKIP state=%{public}s", RoleTag::kContextName, txid, generation_, ToString(this->state_));
        return;
    }

    Base::Transition(State::STOPPING, txid, why);
    const auto t0 = NowUs();

    ctx().WriteControlClear(kContextControlRunBit);
    IODelay(1);
    this->IoReadFence();

    // FIX: Don't poll for ACTIVE=0 with lock held - causes deadlock!
    // Apple's pattern: Fire-and-forget, interrupt handler detects quiescence
    // Polling here blocks interrupt handler from acquiring lock to drain completions
    // Result: Hardware ACTIVE never clears because completion isn't drained → deadlock
    // for (uint32_t i = 0; i < 250; ++i) {
    //     if (!ctx().IsActive()) break;
    //     IODelay(1);
    // }

    const auto elapsed = NowUs() - t0;
    
    // Verify ring is empty before rotation
    if (ring().Head() != ring().Tail()) {
        ASFW_LOG_ERROR(Async, "[%{public}s] STOP: Ring not empty (head=%zu tail=%zu)",
                       RoleTag::kContextName, ring().Head(), ring().Tail());
    }

    rotateRingBy2_();
    ring().SetPrevLastBlocks(0);
    ++generation_;

    ASFW_LOG_V2(Async, "ctx=%{public}s txid=%u gen=%u STOP_IMM why=%{public}s elapsed_us=%lu gen=%u", RoleTag::kContextName, txid, generation_, why, (unsigned long)elapsed, generation_);
    trace_.push({NowNs(), txid, generation_, ATEvent::STOP_IMM, static_cast<uint32_t>(elapsed), generation_});

    Base::Transition(State::IDLE, txid, "stopped");
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::clearRunAndPoll_() noexcept {
    ctx().WriteControlClear(kContextControlRunBit);
    IODelay(1);
    this->IoReadFence();
    
    for (uint32_t i = 0; i < 250; ++i) {
        if (!ctx().IsActive()) break;
        IODelay(1);
    }
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::rotateRingBy2_() noexcept {
    const size_t capacity = ring().Capacity();
    if (capacity == 0) return;
    
    const size_t currentHead = ring().Head();
    const size_t newHead = (currentHead + 2) % capacity;
    ring().SetHead(newHead);
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::PublishChain_(const DescriptorChain& chain) {
    builder_.FlushChain(chain);
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::UpdateRingTail_(const DescriptorChain& chain) {
    const size_t newTail = (chain.lastRingIndex + 1) % ring().Capacity();
    ring().SetTail(newTail);
    // LocatePreviousLast() walks backward from tail across the whole previous
    // descriptor program to find its branch-bearing OUTPUT_LAST descriptor.
    // A block write is 2 immediate-header blocks + 1 payload block, so caching
    // only lastBlocks (=1) makes the hot-append path unlocatable and forces an
    // unsafe CommandPtr re-arm while the prior completion is still pending.
    ring().SetPrevLastBlocks(chain.TotalBlocks());
}

template<typename ContextT, typename RingT, typename RoleTag>
kern_return_t ATManager<ContextT, RingT, RoleTag>::LinkTailTo_(const DescriptorChain& chain) {
    return builder_.LinkTailTo(ring().Tail(), chain) ? kIOReturnSuccess : kIOReturnNotReady;
}

template<typename ContextT, typename RingT, typename RoleTag>
void ATManager<ContextT, RingT, RoleTag>::UnlinkTail_() noexcept {
    builder_.UnlinkTail(ring().Tail());
}

} // namespace ASFW::Async::Engine
