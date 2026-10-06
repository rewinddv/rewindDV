// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
// ATContextBase.hpp

#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <type_traits>
#include <DriverKit/IOLib.h>

#include "ContextBase.hpp"
#include "../Tx/DescriptorBuilder.hpp"
#include "../../Hardware/OHCIEventCodes.hpp"
#include "../../Hardware/OHCIDescriptors.hpp"
#include "../../Shared/Rings/DescriptorRing.hpp"
#include "../../Shared/Memory/DMAMemoryManager.hpp"
#include "../Track/TxCompletion.hpp"
#include "../../Hardware/OHCIConstants.hpp"
#include "../../Logging/Logging.hpp"
#include "../../Logging/LogConfig.hpp"

namespace ASFW::Async {

// Use global OHCI bit constants as single source of truth
using ASFW::Driver::kContextControlRunBit;
using ASFW::Driver::kContextControlWakeBit;
using ASFW::Driver::kContextControlActiveBit;
using ASFW::Driver::kContextControlDeadBit;
using ASFW::Driver::kContextControlEventMask;

/**
 * \brief CRTP base class for AT (Asynchronous Transmit) contexts.
 *
 * Implements common transmit operations for AT Request and AT Response contexts:
 * - Initialization: Allocate lock, setup sentinel descriptors
 * - Arming: Write CommandPtr, set ContextControl.run
 * - Stopping: Clear run, poll active bit with timeout
 * - Submission: Link descriptor chains via branchWord, wake context
 * - Completion: Scan for completed descriptors, extract status/timestamp
 *
 * \tparam Derived Concrete context class (ATRequestContext or ATResponseContext)
 * \tparam Tag Context role tag (ATRequestTag or ATResponseTag)
 *
 * **OHCI Specification References**
 * - §7.2.3: ContextControl register (run/wake/active/dead bits)
 * - §7.2.4: CommandPtr register and arming sequence
 * - §7.1.5.1: branchWord field for descriptor linking
 * - §7.1.5.2: xferStatus field written by hardware on completion
 *
 * **Apple Pattern**
 * Similar to AppleFWOHCI ChannelBundle methods:
 * - SubmitTransmitRequest(): Links descriptors and wakes context
 * - ScanNextATReqCompletion(): Scans for completed descriptors
 * - StopTransmitContext(): Stops context with timeout polling
 *
 * **Linux Pattern**
 * See drivers/firewire/ohci.c:
 * - context_append(): Appends descriptors by linking branchWord
 * - handle_at_packet(): Processes completed AT descriptors
 * - context_stop(): Clears run bit and polls active bit
 *
 * **Design Rationale**
 * - **CRTP**: Zero-overhead polymorphism for context-specific behavior
 * - **RAII Lock**: std::unique_ptr<IOLock> ensures cleanup on destruction
 * - **Move Semantics**: SubmitChain takes DescriptorChain&& to prevent copies
 * - **Memory Barriers**: Release fence before wake ensures descriptor visibility
 */
template<typename Derived, ContextRole Tag>
class ATContextBase : public ContextBase<Derived, Tag> {
public:
    ATContextBase() = default;
    ~ATContextBase() {
        if (submitLock_) {
            IOLockFree(submitLock_);
            submitLock_ = nullptr;
        }
    }

    /**
     * \brief Initialize AT context with hardware interface and descriptor ring.
     *
     * Allocates IOLock for submission serialization and initializes the
     * descriptor ring for storing in-flight chains.
     *
     * \param hw Hardware register interface
     * \param ring Pre-allocated descriptor ring (must be initialized)
     * \param dmaManager Shared DMA allocator providing phys/virt mapping
     * \return kIOReturnSuccess or error code
     *
     * **Implementation**
     * - Calls ContextBase::Initialize() for register setup
     * - Allocates IOLock for SubmitChain() serialization
     * - Validates ring is initialized and not empty
     *
     * **Thread Safety**
     * Must be called before any SubmitChain() or ScanCompletion() calls.
     * Not thread-safe; caller must ensure exclusive access during init.
     */
    [[nodiscard]] kern_return_t Initialize(Driver::HardwareInterface& hw,
                                           DescriptorRing& ring,
                                           DMAMemoryManager& dmaManager) noexcept;

    /**
     * \brief Arm AT context with initial descriptor chain.
     *
     * Writes CommandPtr register and sets ContextControl.run bit to start
     * hardware DMA. Follows OHCI-mandated arming sequence.
     *
     * \param commandPtr Physical address of first descriptor with Z field
     *                    (use MakeBranchWordAT for encoding)
     * \return kIOReturnSuccess or error code
     *
     * **OHCI Arming Sequence (§7.2.4)**
     * 1. If context is running, call Stop() first
     * 2. Write CommandPtr register with descriptor physical address + Z
     * 3. Memory barrier (OSSynchronizeIO) to ensure write completes
     * 4. Write ContextControl.run=1 to start DMA
     *
     * **Sequence Rationale**
     * OHCI hardware fetches from CommandPtr immediately upon run=1, so
     * CommandPtr MUST be written first. Barrier ensures ordering.
     *
     * \warning commandPtr must be 16-byte aligned with valid Z field.
     *          No validation is performed (caller's responsibility).
     */
    [[nodiscard]] kern_return_t Arm(uint32_t commandPtr) noexcept;

    /**
     * \brief Stop AT context and wait for hardware to quiesce.
     *
     * Clears ContextControl.run bit and polls ContextControl.active until
     * hardware finishes current descriptor or timeout expires.
     *
     * \return kIOReturnSuccess if stopped, kIOReturnTimeout if timed out
     *
     * **OHCI Stop Sequence (§7.2.3)**
     * 1. Write ContextControl.run=0 to prevent new descriptor fetches
     * 2. Poll ContextControl.active with 100µs delay between reads
     * 3. If active=0, context has stopped gracefully
     * 4. If timeout expires, return kIOReturnTimeout (hardware may be stuck)
     *
     * **Timeout Behavior**
     * - Default timeout: 100ms (1000 iterations × 100µs)
     * - If timeout occurs, hardware may be in dead state (check dead bit)
     * - Caller should inspect ContextControl.dead and consider bus reset
     *
     * **Linux Pattern**
     * drivers/firewire/ohci.c:context_stop() uses similar polling with
     * 10ms timeout (CONTEXT_STOP_TIMEOUT).
     */
    [[nodiscard]] kern_return_t Stop() noexcept;

    /**
     * \brief Wait for context to quiesce (active bit to clear).
     *
     * Implements Apple's escalating delay pattern from stopDMAAfterTransmit/waitForDMA.
     * Uses progressively longer delays to optimize for quick quiesce while handling
     * slow hardware gracefully.
     *
     * \return kIOReturnSuccess if quiesced, kIOReturnTimeout if still active
     *
     * **Apple's Pattern (AppleFWOHCI_AsyncTransmit::waitForDMA)**
     * - Initial check: Return immediately if already inactive
     * - Initial delay: 5µs
     * - Escalating poll: 250 iterations with delays 6→255µs
     * - Total timeout: ~32ms (5µs + Σ(6..255µs))
     *
     * **Rationale**
     * Hardware typically quiesces in <100µs. Escalating delays optimize for:
     * - Fast path: Minimal latency when hardware responds quickly
     * - Slow path: Adequate timeout for busy hardware
     * - Power efficiency: Longer delays reduce bus traffic
     *
     * **Modern C++23 Implementation**
     * - constexpr for compile-time constants
     * - [[nodiscard]] to prevent ignoring timeout errors
     * - noexcept for hard real-time guarantee
     */
    [[nodiscard]] kern_return_t WaitForQuiesce() noexcept;

    /**
     * \brief Submit descriptor chain to AT context.
     *
     * Links the chain into the descriptor ring via branchWord, updates tail
     * pointer, and wakes the context if it's running. Uses move semantics to
     * transfer chain ownership.
     *
     * \param chain Descriptor chain to submit (moved, will be empty on return)
     * \return kIOReturnSuccess or error code
     *
     * **OHCI Submission Sequence (§7.1.5.1)**
     * 1. Lock context (serialize with concurrent SubmitChain)
     * 2. Check ring capacity (fail if full)
     * 3. Write tail descriptor's branchWord to link new chain
     * 4. Update tail index in ring
     * 5. Release fence: __atomic_thread_fence(__ATOMIC_RELEASE)
     * 6. If context is running, write ContextControl.wake=1
     * 7. Unlock context
     *
     * **Memory Barrier Rationale**
     * Release fence ensures descriptor writes (step 3) are visible to hardware
     * before wake bit (step 6) signals new descriptors available. Without this,
     * hardware might read stale branchWord values.
     *
     * **Apple Pattern**
     * Similar to ChannelBundle::SubmitTransmitRequest():
     * - Locks transmit queue
     * - Updates tail descriptor branchWord
     * - Issues OSSynchronizeIO() barrier
     * - Writes wake bit if context active
     *
     * **Thread Safety**
     * Serialized via IOLock. Safe to call concurrently from multiple threads.
     *
     * \warning After return, chain.first/last are invalidated (moved).
     *          Caller must not access chain members.
     */
    [[nodiscard]] kern_return_t SubmitChain(DescriptorBuilder::DescriptorChain&& chain) noexcept;

    /**
     * \brief Push descriptor block count into FIFO for head advancement tracking.
     *
     * Called by Submitter after successful descriptor submission.
     * Used to track how many blocks to advance head when consuming completions.
     *
     * \param blocks Total block count of the submitted chain
     */

    /**
     * \brief Scan for completed descriptors and extract completion status.
     *
     * Walks the descriptor ring by complete AT programs. For a block-write
     * program, hardware reports completion on the terminal OUTPUT_LAST, not
     * on the leading OUTPUT_MORE_Immediate descriptor.
     *
     * \return TxCompletion if descriptor completed, std::nullopt if none ready
     *
     * **OHCI Completion Detection (§7.1.5.2)**
     * Hardware writes xferStatus field when descriptor completes. A non-zero
     * xferStatus[15:0] indicates completion (contains event code and ack code).
     *
     * **Scan Algorithm**
     * 1. Lock context (serialize with SubmitChain)
     * 2. Load head index (atomic acquire)
     * 3. If head == tail, ring is empty → return nullopt
     * 4. Validate one canonical program shape at head: two-block
     *    OUTPUT_LAST_Immediate, or three-block
     *    OUTPUT_MORE_Immediate + OUTPUT_LAST
     * 5. Read xferStatus from that program's terminal OUTPUT_LAST
     * 6. If terminal xferStatus == 0, program is pending → return nullopt
     * 7. Extract event code/timestamp from the terminal descriptor and tLabel
     *    from the program-start immediate header
     * 8. Advance head by the complete program size (two or three blocks)
     * 9. Unlock context, return TxCompletion
     *
     * **Apple Pattern**
     * ChannelBundle::ScanNextATReqCompletion():
     * - Checks xferStatus != 0 for completion
     * - Extracts ack code and event code from status word
     * - Extracts tLabel from packet header for response matching
     * - Advances completion cursor
     *
     * **Thread Safety**
     * Serialized via IOLock. Safe to call concurrently with SubmitChain().
     *
     * \note Caller must repeatedly call ScanCompletion() until it returns
     *       nullopt to drain all completed descriptors. Typically called
     *       from interrupt handler or timer callback.
     */
    [[nodiscard]] std::optional<TxCompletion> ScanCompletion() noexcept;

    /**
     * Discard complete, structurally valid AT programs after the context has
     * been positively stopped. This is bus-reset cleanup only: it emits no
     * TxCompletion and is never used by the IRQ/watchdog completion path.
     * Unknown program shapes or a running/active/unavailable context fail
     * closed without moving the ring head.
     */
    [[nodiscard]] size_t DiscardStoppedPrograms() noexcept;

    /**
     * \brief Get descriptor ring for diagnostics.
     *
     * \return Reference to descriptor ring (const access)
     */
    [[nodiscard]] const DescriptorRing& Ring() const noexcept {
        return *ring_;
    }

    /**
     * Serialize AT queue mutation with completion retirement.
     *
     * ATManager owns the production submission path, while ScanCompletion()
     * lives on the context. Both must use this same lock so a completion cannot
     * retire the previous branch anchor between append publication and WAKE.
     */
    // Called with the shared submission/scan lock. At most one identity per
    // configured ring block, allocated only during context initialization.
    bool BindProgramIdentity(size_t index, uint32_t operation) noexcept {
        if (!ring_ || index >= ring_->Capacity() || !programIdentity_ || programIdentity_[index]) return false;
        programIdentity_[index] = operation;
        return true;
    }
    void ForgetUnpostedIdentity(size_t index) noexcept {
        if (ring_ && index < ring_->Capacity() && programIdentity_) programIdentity_[index] = 0;
    }
    void LockSubmissionQueue() noexcept { LockSubmit(); }
    void UnlockSubmissionQueue() noexcept { UnlockSubmit(); }

    ATContextBase(const ATContextBase&) = delete;
    ATContextBase& operator=(const ATContextBase&) = delete;

protected:
    using ContextBase<Derived, Tag>::hw_;

    // Simple lock-free FIFO for tracking descriptor block counts
    // Used to know how many blocks to advance head when consuming completions

private:
    struct SubmitState {
        size_t headIndex{0};
        size_t tailIndex{0};
        size_t capacity{0};
        size_t freeBlocks{0};
        size_t neededBlocks{0};
        uint32_t commandPtr{0};
        bool ringEmpty{false};
        bool needsReArm{false};
    };

    struct ScanState {
        size_t capacity{0};
        size_t headIndex{0};
        size_t tailIndex{0};
        size_t terminalIndex{0};
        HW::OHCIDescriptor* programStart{nullptr};
        HW::OHCIDescriptor* terminal{nullptr};
        uint8_t blocksConsumed{0};
        uint16_t xferStatus{0};
        uint8_t eventCodeRaw{0};
        uint8_t ackCode{0};
        OHCIEventCode eventCode{OHCIEventCode::kEvtNoStatus};
        uint8_t command{0};
        uint8_t key{0};
        uint16_t timeStamp{0};
    };

    /// Descriptor ring for tracking in-flight chains
    DescriptorRing* ring_{nullptr};
    std::unique_ptr<uint32_t[]> programIdentity_;

    /// DMA memory manager for virtual↔physical translation
    DMAMemoryManager* dmaManager_{nullptr};

    /// Tracks whether context has been armed with CommandPtr + run bit
    /// Per Apple's implementation: AT contexts remain idle until first SubmitChain() call
    bool contextRunning_{false};

    /// One bounded proof that a three-block program was retired from terminal status.
    bool terminalCompletionProofEmitted_{false};

    /// FIFO for tracking descriptor block counts (for head advancement)

    /// Lock shared by manager submission and completion retirement.
    IOLock* submitLock_{nullptr};

    void LockSubmit() noexcept;
    void UnlockSubmit() noexcept;
    [[nodiscard]] kern_return_t PrepareSubmitState(const DescriptorBuilder::DescriptorChain& chain,
                                                   SubmitState& state) const noexcept;
    [[nodiscard]] kern_return_t SubmitViaRearm(const DescriptorBuilder::DescriptorChain& chain,
                                               const SubmitState& state) noexcept;
    [[nodiscard]] kern_return_t SubmitViaAppend(const DescriptorBuilder::DescriptorChain& chain,
                                                const SubmitState& state) noexcept;
    [[nodiscard]] size_t CommitSubmittedChain(const DescriptorBuilder::DescriptorChain& chain,
                                              size_t capacity) noexcept;
    [[nodiscard]] bool LoadScanState(ScanState& state) noexcept;
    void FetchScanDescriptor(HW::OHCIDescriptor* descriptor, bool isImmediate) noexcept;
    [[nodiscard]] bool DecodeCompletionState(ScanState& state) const noexcept;
    void ClearTerminalStatus(const ScanState& state) noexcept;
    void StopIfRingDrained(const char* scopeTag, size_t newHead, bool logWhenNotEmpty) noexcept;
    [[nodiscard]] uint8_t ExtractCompletionTLabel(const ScanState& state) const noexcept;
    void LogCompletionTelemetry(const ScanState& state) const noexcept;
    [[nodiscard]] TxCompletion MakeCompletion(const ScanState& state, uint8_t tLabel) const noexcept;

    /// Utility to rewrite descriptor branch control field
    static void ClearDescriptorStatus(HW::OHCIDescriptor& desc) noexcept;

    /// Sentinel loop consumes two 16-byte blocks (OUTPUT_LAST_Immediate per OHCI §7.1.4)
    ///
    /// CRITICAL CONSTRAINT: DescriptorRing MUST reserve TWO contiguous slots (32 bytes)
    /// for the sentinel at storage_[0..1]. When Z=2, hardware fetches 32 bytes starting
    /// from CommandPtr. If only 16 bytes are allocated, hardware reads garbage from the
    /// next ring slot, resulting in evt_unknown (0x0e) and UnrecoverableError.
    ///
    /// This value MUST match DescriptorRing::Initialize()'s capacity calculation:
    ///   capacity = descriptors.size() - 2  (reserve 2 slots for sentinel)
    static constexpr uint8_t kSentinelLoopBlocks = 2;
};

// =============================================================================
// Template Implementation
// =============================================================================

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::Initialize(Driver::HardwareInterface& hw,
                                                      DescriptorRing& ring,
                                                      DMAMemoryManager& dmaManager) noexcept {
    // Initialize base class (register interface)
    kern_return_t result = ContextBase<Derived, Tag>::Initialize(hw);
    if (result != kIOReturnSuccess) {
        return result;
    }

    // Validate ring is initialized
    if (ring.Capacity() == 0) {
        return kIOReturnBadArgument;
    }

    programIdentity_.reset(new (std::nothrow) uint32_t[ring.Capacity()]{});
    if (!programIdentity_) return kIOReturnNoMemory;
    ring_ = &ring;
    dmaManager_ = &dmaManager;

    // Allocate lock for SubmitChain() serialization
    submitLock_ = IOLockAlloc();
    if (!submitLock_) {
        return kIOReturnNoMemory;
    }

    // Per Apple's implementation: AT contexts do NOT arm during initialization.
    // Context will arm during first SubmitChain() call (Path 1: CommandPtr + run bit).
    contextRunning_ = false;
    terminalCompletionProofEmitted_ = false;

    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::Arm(uint32_t commandPtr) noexcept {
    if (!hw_) {
        ASFW_LOG_ERROR(Async, "Arm: Hardware not ready");
        return kIOReturnNotReady;
    }

    // IDA ANALYSIS: Apple NEVER clears RUN bit when context is idle!
    // Apple's executeCommandElement() shows context runs continuously until
    // explicit stopDMA() call. When ring drains (active=0 but run=1), Apple
    // simply programs new CommandPtr and sets RUN (which is already set, no-op).
    //
    // Linux does use ControlClear(~0), but ONLY in context_run() which is called
    // after context_stop(). For successive transactions without stop(), Linux uses
    // context_append() which just updates branch address and sets WAKE.
    //
    // Our implementation: Always check if context is ACTIVE (processing descriptors).
    // If active, we must stop and poll for quiescence before reprogramming CommandPtr.
    // If inactive (idle), just program CommandPtr directly - hardware will fetch
    // when we set RUN bit (even if RUN was already set from previous transaction).
    const uint32_t before = this->ReadControl();
    if (before == 0xFFFFFFFFu) return kIOReturnNotReady;
    const bool wasActive = (before & (kContextControlRunBit | kContextControlActiveBit)) != 0;

    if (wasActive) {
        // Context is actively processing - must stop and wait for quiescence
        // OHCI §7.2.4: Cannot reprogram CommandPtr while active=1
        ASFW_LOG(Async, "Arm: Context active, stopping first (active=%d)", wasActive);
        kern_return_t stopResult = Stop();
        if (stopResult != kIOReturnSuccess) {
            ASFW_LOG_ERROR(Async, "Arm: Stop() failed: 0x%x", stopResult);
            return stopResult;
        }
    }
    // If context is idle (active=0), proceed directly to programming CommandPtr
    // The RUN bit state doesn't matter - we'll set it again below anyway

    // Step 1: Write CommandPtr BEFORE setting run bit
    // OHCI §7.2.4: Hardware fetches from CommandPtr immediately on run=1,
    // so CommandPtr MUST be visible before RUN bit is set.
    this->WriteCommandPtr(commandPtr);
    ASFW_LOG(Async, "Arm: Wrote CommandPtr=0x%08x", commandPtr);

    // Step 2: Memory barrier to ensure CommandPtr write completes
    // This ensures PCIe posted write reaches hardware before we set RUN.
    OSSynchronizeIO();

    // Step 3: Set RUN bit ONLY (Apple pattern from IDA decompilation)
    // Apple executeCommandElement() at 0xdbbe, lines 116-120:
    //   WriteCommandPtr(elementPhysAddr | elementZ);
    //   WriteControlSet(0x8000);  // RUN ONLY, NO WAKE
    //   contextRunning_ = 1;
    //
    // CRITICAL: Do NOT set WAKE bit during initial CommandPtr programming!
    // WAKE is edge-triggered and should only be used for branch chaining (PATH 2).
    // Setting RUN causes hardware to fetch from CommandPtr immediately (OHCI §7.2.4).
    this->WriteControlSet(kContextControlRunBit);
    ASFW_LOG(Async,
             "Arm: ControlSet applied (run=1 wakePulse=0)");

    // Step 4: Read-back verification (Linux pattern + diagnostic requirement)
    // This serves two purposes:
    // 1. Forces PCIe read-back barrier (ensures writes have completed)
    // 2. Verifies hardware accepted our writes (detects PCIe failures)
    const uint32_t ctrlAfter = this->ReadControl();
    const bool runVerified = (ctrlAfter & kContextControlRunBit) != 0;
    const bool activeAfter = (ctrlAfter & kContextControlActiveBit) != 0;
    const bool wakeAfter = (ctrlAfter & kContextControlWakeBit) != 0;

    ASFW_LOG(Async, "Arm: Read-back ControlReg=0x%08x (run=%d active=%d wake=%d)",
             ctrlAfter, runVerified, activeAfter, wakeAfter);
    
    if (!runVerified) {
        // CRITICAL: RUN bit not set after write - hardware may have rejected our write
        // This could indicate PCIe bus error, OHCI in dead state, or power management issue
        ASFW_LOG_ERROR(Async, "Arm: RUN bit not set after write! ControlReg=0x%08x", ctrlAfter);
        return kIOReturnIOError;
    }

    contextRunning_ = true;
    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::WaitForQuiesce() noexcept {
    // Fast path: Already inactive (common case for idle hardware)
    const uint32_t initial = this->ReadControl();
    if (initial == 0xFFFFFFFFu) return kIOReturnNotReady;
    if ((initial & kContextControlActiveBit) == 0) {
        return kIOReturnSuccess;
    }

    // Apple's pattern: Initial 5µs delay before polling
    IODelay(5);

    // Escalating delay pattern from Apple's waitForDMA
    constexpr uint32_t kMaxIterations = 250;
    constexpr uint32_t kBaseDelayMicros = 6;

    for (uint32_t iteration = 0; iteration < kMaxIterations; ++iteration) {
        const uint32_t control = this->ReadControl();
        if (control == 0xFFFFFFFFu) return kIOReturnNotReady;
        if ((control & kContextControlActiveBit) == 0) {
            return kIOReturnSuccess;
        }

        // Escalating delay: 6, 7, 8, ..., 255 µs
        // Optimizes for quick quiesce while handling slow hardware
        IODelay(kBaseDelayMicros + iteration);
    }

    // Still active after ~32ms - hardware stuck or dead
    return kIOReturnTimeout;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::Stop() noexcept {
    if (!hw_) {
        return kIOReturnNotReady;
    }

    if (hw_->HardwareGone()) {
        // Software access revocation is not proof that DMA has retired.
        return kIOReturnNotReady;
    }

    // Step 1: Clear ContextControl.run bit (bit 15 = 0x8000)
    // This tells hardware to stop fetching new descriptors
    this->WriteControlClear(kContextControlRunBit);

    // Step 2: Wait for hardware to quiesce (Apple's escalating delay pattern)
    const kern_return_t result = WaitForQuiesce();

    if (result == kIOReturnSuccess) {
        // Hardware quiesced cleanly - mark context as stopped
        contextRunning_ = false;
        return kIOReturnSuccess;
    }

    if (result == kIOReturnNotReady) return result;

    // Hardware didn't quiesce - check if it's in dead state
    const uint32_t control = this->ReadControl();
    if (control & kContextControlDeadBit) {
        ASFW_LOG_ERROR(Async, "Stop: Context in DEAD state (control=0x%08x)", control);
        return kIOReturnDMAError;
    }

    // Still active but not dead - likely hardware issue
    ASFW_LOG_ERROR(Async, "Stop: Timeout waiting for quiesce (control=0x%08x)", control);
    return kIOReturnTimeout;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::SubmitChain(
    DescriptorBuilder::DescriptorChain&& chain) noexcept {
    SubmitState state;
    const kern_return_t prepareResult = PrepareSubmitState(chain, state);
    if (prepareResult != kIOReturnSuccess) {
        return prepareResult;
    }

    if (!BindProgramIdentity(chain.firstRingIndex, chain.operationIdentity)) return kIOReturnBusy;
    const kern_return_t submitResult = state.needsReArm
        ? SubmitViaRearm(chain, state)
        : SubmitViaAppend(chain, state);
    if (submitResult != kIOReturnSuccess) {
        ForgetUnpostedIdentity(chain.firstRingIndex);
        return submitResult;
    }

    ASFW_LOG(Async, "  ✅ SubmitChain complete: chain submitted successfully");
    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
std::optional<TxCompletion> ATContextBase<Derived, Tag>::ScanCompletion() noexcept {
    if (!ring_) {
        return std::nullopt;
    }

    const size_t capacity = ring_->Capacity();
    if (capacity == 0) {
        return std::nullopt;
    }

    bool lockHeld = false;
    if (submitLock_) {
        IOLockLock(submitLock_);
        lockHeld = true;
    }
    auto unlock = [&]() {
        if (lockHeld) {
            IOLockUnlock(submitLock_);
            lockHeld = false;
        }
    };

    ScanState state;
    state.capacity = capacity;
    if (!LoadScanState(state)) {
        unlock();
        return std::nullopt;
    }

    // Completion belongs to the terminal OUTPUT_LAST for the complete AT
    // program. A zero terminal status is pending regardless of CommandPtr or
    // run/active state; those registers are not transaction completion proof.
    if (state.xferStatus == 0 || !DecodeCompletionState(state)) {
        unlock();
        return std::nullopt;
    }

    LogCompletionTelemetry(state);
    const uint8_t tLabel = ExtractCompletionTLabel(state);
    if (!terminalCompletionProofEmitted_ && state.blocksConsumed == 3 &&
        HW::AT_xferStatus(*state.programStart) == 0) {
        terminalCompletionProofEmitted_ = true;
        ASFW_LOG(Async,
                 "ctx=%{public}s AT_PROGRAM_TERMINAL_PROOF head=%zu terminal=%zu blocks=3 tLabel=%u xferStatus=0x%04x",
                 Tag::kContextName,
                 state.headIndex,
                 state.terminalIndex,
                 tLabel,
                 state.xferStatus);
    }

    ClearTerminalStatus(state);
    const size_t newHead = (state.headIndex + state.blocksConsumed) % state.capacity;
    ring_->SetHead(newHead);
    ASFW_LOG_V2(Async,
                "ScanCompletion: head %zu→%zu (program terminal=%zu, %u blocks)",
                state.headIndex,
                newHead,
                state.terminalIndex,
                state.blocksConsumed);
    StopIfRingDrained("ScanCompletion", newHead, true);

    TxCompletion completion = MakeCompletion(state, tLabel);
    completion.operationIdentity = programIdentity_[state.headIndex];
    programIdentity_[state.headIndex] = 0;
    unlock();
    return completion;
}

template<typename Derived, ContextRole Tag>
size_t ATContextBase<Derived, Tag>::DiscardStoppedPrograms() noexcept {
    if (!ring_ || !hw_) {
        return 0;
    }

    bool lockHeld = false;
    if (submitLock_) {
        IOLockLock(submitLock_);
        lockHeld = true;
    }
    auto unlock = [&]() {
        if (lockHeld) {
            IOLockUnlock(submitLock_);
            lockHeld = false;
        }
    };

    const uint32_t control = this->ReadControl();
    if (control == 0xFFFFFFFFu ||
        (control & (kContextControlRunBit | kContextControlActiveBit)) != 0) {
        unlock();
        return 0;
    }

    size_t discarded = 0;
    const size_t capacity = ring_->Capacity();
    while (capacity != 0 && !ring_->IsEmpty()) {
        ScanState state;
        state.capacity = capacity;
        if (!LoadScanState(state)) {
            break;
        }

        // The transaction manager has already cancelled reset-invalidated
        // operations. Clear only the terminal device-written status; retain
        // branch words and payload bytes until DescriptorBuilder reuses them.
        ClearTerminalStatus(state);
        programIdentity_[state.headIndex] = 0;
        ring_->SetHead((state.headIndex + state.blocksConsumed) % capacity);
        ++discarded;
    }

    if (ring_->IsEmpty()) {
        ring_->SetPrevLastBlocks(0);
        contextRunning_ = false;
    }
    unlock();
    return discarded;
}



template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::LockSubmit() noexcept {
    if (submitLock_) {
        IOLockLock(submitLock_);
    }
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::UnlockSubmit() noexcept {
    if (submitLock_) {
        IOLockUnlock(submitLock_);
    }
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::PrepareSubmitState(
    const DescriptorBuilder::DescriptorChain& chain,
    SubmitState& state) const noexcept {
    if (!ring_ || !hw_ || !dmaManager_) {
        ASFW_LOG_ERROR(Async, "SubmitChain FAILED: not ready (ring=%p hw=%p dma=%p)",
                       ring_, hw_, dmaManager_);
        return kIOReturnNotReady;
    }
    if (chain.Empty()) {
        ASFW_LOG(Async, "  ❌ SubmitChain FAILED: empty chain");
        return kIOReturnBadArgument;
    }
    if (!chain.last) {
        ASFW_LOG(Async, "  ❌ SubmitChain FAILED: chain tail descriptor missing");
        return kIOReturnInternalError;
    }

    ASFW_LOG(Async, "  🔧 SubmitChain: Entering (chain: first=%p last=%p firstIOVA=0x%08x firstBlocks=%u)",
             chain.first, chain.last, chain.firstIOVA32, static_cast<unsigned>(chain.firstBlocks));

    state.headIndex = ring_->Head();
    state.tailIndex = ring_->Tail();
    state.capacity = ring_->Capacity();
    if (state.capacity <= 1) {
        ASFW_LOG(Async, "  ❌ SubmitChain FAILED: ring capacity insufficient (capacity=%zu)", state.capacity);
        return kIOReturnInternalError;
    }

    ASFW_LOG(Async, "  🔧 Ring state: head=%zu tail=%zu capacity=%zu",
             state.headIndex, state.tailIndex, state.capacity);

    const size_t usedBlocks = (state.tailIndex >= state.headIndex)
        ? (state.tailIndex - state.headIndex)
        : (state.capacity - state.headIndex + state.tailIndex);
    state.freeBlocks = state.capacity - usedBlocks - 1;
    state.neededBlocks = static_cast<size_t>(chain.TotalBlocks());
    ASFW_LOG(Async, "  🔧 Space check: freeBlocks=%zu needed=%zu", state.freeBlocks, state.neededBlocks);

    if (state.neededBlocks == 0 || state.neededBlocks > state.freeBlocks) {
        ASFW_LOG(Async, "  ❌ SubmitChain FAILED: insufficient space (freeBlocks=%zu needed=%zu)",
                 state.freeBlocks, state.neededBlocks);
        return kIOReturnNoSpace;
    }

    state.ringEmpty = (state.headIndex == state.tailIndex);
    state.commandPtr = HW::MakeBranchWordAT(chain.firstIOVA32, chain.TotalBlocks());
    if (state.commandPtr == 0) {
        ASFW_LOG(Async, "  ❌ SubmitChain FAILED: invalid CommandPtr encoding (iova=0x%08x blocks=%u)",
                 chain.firstIOVA32, static_cast<unsigned>(chain.firstBlocks));
        return kIOReturnInternalError;
    }

    const bool hwIsRunning = this->IsRunning();
    const bool hwIsActive = this->IsActive();
    ASFW_LOG(Async, "  🔧 Ring state: %{public}s, contextRunning=%d, hw.run=%d, hw.active=%d",
             state.ringEmpty ? "EMPTY" : "HAS DATA", contextRunning_, hwIsRunning, hwIsActive);
    state.needsReArm = !contextRunning_ || !hwIsRunning || state.ringEmpty;
    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::SubmitViaRearm(
    const DescriptorBuilder::DescriptorChain& chain,
    const SubmitState& state) noexcept {
    ASFW_LOG(Async,
             "  🔧 PATH 1: %{public}s - programming CommandPtr via Arm() (cmdPtr=0x%08x)",
             !contextRunning_ ? "First command" : "Re-arming after drain",
             state.commandPtr);

    const kern_return_t armResult = this->Arm(state.commandPtr);
    if (armResult != kIOReturnSuccess) {
        ASFW_LOG(Async, "  ❌ PATH 1 Arm() failed: 0x%x", armResult);
        return armResult;
    }

    LockSubmit();
    const size_t newTail = CommitSubmittedChain(chain, state.capacity);
    UnlockSubmit();
    ASFW_LOG(Async, "  ✅ PATH 1 complete: command pointer armed, tail=%zu", newTail);
    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
kern_return_t ATContextBase<Derived, Tag>::SubmitViaAppend(
    const DescriptorBuilder::DescriptorChain& chain,
    const SubmitState& state) noexcept {
    HW::OHCIDescriptor* prevLast = nullptr;
    size_t prevLastIndex = 0;
    uint8_t prevBlocks = 0;
    if (!ring_->LocatePreviousLast(state.tailIndex, prevLast, prevLastIndex, prevBlocks)) {
        ASFW_LOG(Async,
                 "  ❌ SubmitChain FAILED: unable to locate previous LAST descriptor (tail=%zu)",
                 state.tailIndex);
        return kIOReturnInternalError;
    }

    const uint32_t prevControlBefore = prevLast->control;
    const uint32_t prevBranchWordBefore = prevLast->branchWord;
    const bool prevImmediate = HW::IsImmediate(*prevLast);
    const size_t flushLength = prevImmediate ? sizeof(HW::OHCIDescriptorImmediate)
                                             : sizeof(HW::OHCIDescriptor);
    ASFW_LOG(Async,
             "  🔧 PATH 2: Linking prevLast[%zu] blocks=%u imm=%u ctrl=0x%08x branch=0x%08x -> newCmdPtr=0x%08x",
             prevLastIndex,
             prevBlocks,
             prevImmediate ? 1u : 0u,
             prevControlBefore,
             prevBranchWordBefore,
             state.commandPtr);

    LockSubmit();
    prevLast->branchWord = state.commandPtr;
    if (dmaManager_) {
        dmaManager_->PublishRange(prevLast, flushLength);
    }
    ::ASFW::Driver::IoBarrier();
    this->WriteControlSet(kContextControlWakeBit);
    const size_t newTail = CommitSubmittedChain(chain, state.capacity);
    UnlockSubmit();

    ASFW_LOG(Async, "  ✅ PATH 2 complete: branchWord linked, control updated, wake bit set, tail=%zu", newTail);
    return kIOReturnSuccess;
}

template<typename Derived, ContextRole Tag>
size_t ATContextBase<Derived, Tag>::CommitSubmittedChain(
    const DescriptorBuilder::DescriptorChain& chain,
    size_t capacity) noexcept {
    const size_t newTail = (chain.lastRingIndex + 1) % capacity;
    ring_->SetTail(newTail);
    // LocatePreviousLast() needs the complete preceding program span (2 blocks
    // for immediate-only requests, 3 for header + payload), not merely the size
    // of its final descriptor.
    ring_->SetPrevLastBlocks(chain.TotalBlocks());
    return newTail;
}

template<typename Derived, ContextRole Tag>
bool ATContextBase<Derived, Tag>::LoadScanState(ScanState& state) noexcept {
    state.headIndex = ring_->Head();
    state.tailIndex = ring_->Tail();
    if (state.headIndex == state.tailIndex) {
        return false;
    }

    state.programStart = ring_->At(state.headIndex);
    if (!state.programStart) {
        return false;
    }

    // DescriptorBuilder emits exactly two AT program shapes:
    //   2 blocks: OUTPUT_LAST_Immediate
    //   3 blocks: OUTPUT_MORE_Immediate + OUTPUT_LAST_Standard
    // It deliberately reserves each shape contiguously, so an apparent shape
    // that crosses the allocation boundary is malformed and must not retire.
    FetchScanDescriptor(state.programStart, false);
    const uint32_t startControlHi =
        state.programStart->control >> HW::OHCIDescriptor::kControlHighShift;
    const uint8_t startCommand = static_cast<uint8_t>(
        (startControlHi >> HW::OHCIDescriptor::kCmdShift) & 0xFu);
    const uint8_t startKey = static_cast<uint8_t>(
        (startControlHi >> HW::OHCIDescriptor::kKeyShift) & 0x7u);

    if (startCommand == HW::OHCIDescriptor::kCmdOutputLast &&
        startKey == HW::OHCIDescriptor::kKeyImmediate) {
        if (ring_->Size() < 2 || state.headIndex + 2 > state.capacity) {
            return false;
        }
        FetchScanDescriptor(state.programStart, true);
        state.terminalIndex = state.headIndex;
        state.terminal = state.programStart;
        state.blocksConsumed = 2;
    } else if (startCommand == HW::OHCIDescriptor::kCmdOutputMore &&
               startKey == HW::OHCIDescriptor::kKeyImmediate) {
        if (ring_->Size() < 3 || state.headIndex + 3 > state.capacity) {
            return false;
        }
        FetchScanDescriptor(state.programStart, true);
        state.terminalIndex = state.headIndex + 2;
        state.terminal = ring_->At(state.terminalIndex);
        if (!state.terminal) {
            return false;
        }
        FetchScanDescriptor(state.terminal, false);

        const uint32_t terminalControlHi =
            state.terminal->control >> HW::OHCIDescriptor::kControlHighShift;
        const uint8_t terminalCommand = static_cast<uint8_t>(
            (terminalControlHi >> HW::OHCIDescriptor::kCmdShift) & 0xFu);
        const uint8_t terminalKey = static_cast<uint8_t>(
            (terminalControlHi >> HW::OHCIDescriptor::kKeyShift) & 0x7u);
        if (terminalCommand != HW::OHCIDescriptor::kCmdOutputLast ||
            terminalKey != HW::OHCIDescriptor::kKeyStandard) {
            return false;
        }
        state.blocksConsumed = 3;
    } else {
        return false;
    }

    state.xferStatus = HW::AT_xferStatus(*state.terminal);
    return true;
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::FetchScanDescriptor(HW::OHCIDescriptor* descriptor,
                                                      bool isImmediate) noexcept {
    if (dmaManager_) {
        dmaManager_->FetchRange(descriptor,
                                isImmediate ? sizeof(HW::OHCIDescriptorImmediate)
                                            : sizeof(HW::OHCIDescriptor));
    }

    if (DMAMemoryManager::IsTracingEnabled()) {
        ASFW_LOG(Async,
                 "  🔍 ScanCompletion: ReadBarrier DISABLED (uncached device memory, DSB sufficient)");
    }
}

template<typename Derived, ContextRole Tag>
bool ATContextBase<Derived, Tag>::DecodeCompletionState(ScanState& state) const noexcept {
    state.eventCodeRaw = static_cast<uint8_t>(state.xferStatus & 0x1F);
    state.eventCode = static_cast<OHCIEventCode>(state.eventCodeRaw);

    if (state.eventCodeRaw == 0x10 && hw_->HasAgereQuirk()) {
        ASFW_LOG(Async,
                 "  ⚠️  Agere/LSI quirk: eventCode 0x10→kAckComplete");
        state.eventCode = OHCIEventCode::kAckComplete;
        state.eventCodeRaw = static_cast<uint8_t>(OHCIEventCode::kAckComplete);
    }

    // Raw ack nibble from xferStatus[15:12]. NOTE: the authoritative acknowledge for
    // AT completions is the event-code field [4:0] (Validated with Linux — refs:
    // ohci.c handle_at_packet). xferStatus[15:12] are the RUN(15)/WAKE(12) control
    // bits and read as 0x8 on a running context, so this value is normalized from
    // eventCode at the point of consumption (TransactionCompletionHandler::NormalizeAckFromEvent).
    state.ackCode = static_cast<uint8_t>((state.xferStatus >> 12) & 0x0F);

    if (state.eventCode == OHCIEventCode::kEvtNoStatus ||
        state.eventCode == OHCIEventCode::kEvtDescriptorRead) {
        return false;
    }

    const uint16_t controlHi = static_cast<uint16_t>(
        state.terminal->control >> HW::OHCIDescriptor::kControlHighShift);
    state.command = static_cast<uint8_t>((controlHi >> HW::OHCIDescriptor::kCmdShift) & 0xF);
    state.key = static_cast<uint8_t>((controlHi >> HW::OHCIDescriptor::kKeyShift) & 0x7);
    state.timeStamp = HW::AT_timeStamp(*state.terminal);
    return true;
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::ClearTerminalStatus(const ScanState& state) noexcept {
    ClearDescriptorStatus(*state.terminal);
    if (dmaManager_) {
        // xferStatus/timeStamp live in the terminal descriptor's first 16-byte
        // block for both immediate and standard forms. Do not include the
        // immediate-data block in retirement publication.
        dmaManager_->PublishRange(state.terminal, sizeof(HW::OHCIDescriptor));
    }
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::StopIfRingDrained(const char* scopeTag,
                                                    size_t newHead,
                                                    bool logWhenNotEmpty) noexcept {
    if (!ring_->IsEmpty()) {
        if (logWhenNotEmpty) {
            ASFW_LOG_V3(Async,
                        "  🔧 %{public}s: Ring has data (head=%zu tail=%zu), context continues",
                        scopeTag, newHead, ring_->Tail());
        }
        return;
    }

    ring_->SetPrevLastBlocks(0);
    this->WriteControlClear(kContextControlRunBit);
    const kern_return_t quiesceResult = WaitForQuiesce();
    if (quiesceResult == kIOReturnSuccess) {
        contextRunning_ = false;
        ASFW_LOG_V3(Async,
                    "  ✅ %{public}s: Ring empty (head=%zu tail=%zu), context quiesced",
                    scopeTag, newHead, ring_->Tail());
        return;
    }

    ASFW_LOG_ERROR(Async,
                   "  ⚠️ %{public}s: Ring empty (head=%zu tail=%zu), but quiesce failed (0x%x)",
                   scopeTag, newHead, ring_->Tail(), quiesceResult);
}

template<typename Derived, ContextRole Tag>
uint8_t ATContextBase<Derived, Tag>::ExtractCompletionTLabel(const ScanState& state) const noexcept {
    auto* immediateHeader =
        reinterpret_cast<HW::OHCIDescriptorImmediate*>(state.programStart);
    return HW::ExtractTLabel(immediateHeader);
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::LogCompletionTelemetry(const ScanState& state) const noexcept {
    ASFW_LOG_V3(Async,
                "🔍 ScanCompletion: head=%zu tail=%zu terminal=%zu desc=%p",
                state.headIndex, state.tailIndex, state.terminalIndex, state.terminal);
    // OHCI ContextControl/xferStatus bits [7:5] are `spd`, and the OHCI
    // specification defines them only for receive contexts. AT completions do
    // not expose an attempt count. ACK_BUSY_* is the terminal event reported
    // after any controller-managed retry behavior; it cannot reveal the exact
    // number of attempts.
    ASFW_LOG_V3(Async,
                "  xferStatus=0x%04x → eventCode=0x%02x (%{public}s); AT attempts unavailable",
                state.xferStatus, state.eventCodeRaw, ToString(state.eventCode));
}

template<typename Derived, ContextRole Tag>
TxCompletion ATContextBase<Derived, Tag>::MakeCompletion(const ScanState& state,
                                                         uint8_t tLabel) const noexcept {
    TxCompletion completion;
    completion.eventCode = state.eventCode;
    completion.timeStamp = state.timeStamp;
    completion.ackCode = state.ackCode;
    completion.tLabel = tLabel;
    completion.descriptor = state.terminal;
    completion.isResponseContext = std::is_same_v<Tag, ATResponseTag>;
    return completion;
}

template<typename Derived, ContextRole Tag>
void ATContextBase<Derived, Tag>::ClearDescriptorStatus(HW::OHCIDescriptor& desc) noexcept {
    // Retirement owns only the device-written completion status. Preserve the
    // branch: a preceding hot append may just have published it and pulsed
    // WAKE, without proof that OHCI has consumed the branch yet. Descriptor
    // construction zero-initializes the complete slot before it is reused.
    desc.statusWord = 0;
}

} // namespace ASFW::Async
