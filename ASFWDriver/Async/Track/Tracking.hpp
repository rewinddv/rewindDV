// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
#pragma once

#include <cstdint>
#include <cstddef>
#include <memory>
#include <span>
#include <cstring>
#include <optional>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <DriverKit/IOLib.h>

#include "../AsyncTypes.hpp"
#include "../../Shared/Memory/DMAMemoryManager.hpp"
#include "../../Common/FWCommon.hpp"  // For FW::Response, FW::RespName, FW::ResponseFromByte
#include "CompletionQueue.hpp"
#include "TxCompletion.hpp"
#include "LabelAllocator.hpp"
#include "PayloadRegistry.hpp"
#include "../Engine/ContextManager.hpp"
#include "../../Logging/Logging.hpp"
#include "../../Logging/LogConfig.hpp"

// Phase 2.0: Transaction infrastructure (sole source of truth)
#include "../Core/Transaction.hpp"
#include "../Core/TransactionManager.hpp"
#include "TransactionCompletionHandler.hpp"

namespace ASFW::Async {

// Forward declarations
class LabelAllocator;
namespace Engine { class ContextManager; }

// Metadata for registering a new outgoing transaction.
struct TxMetadata {
    uint16_t generation{0};
    uint16_t sourceNodeID{0};
    uint16_t destinationNodeID{0};
    uint8_t  tLabel{0};
    uint8_t  tCode{0};
    uint32_t expectedLength{0};
    uint64_t address{0};
    uint16_t extendedTCode{0};
    uint32_t lockOperand0{0};
    uint32_t lockOperand1{0};
    uint8_t lockOperandCount{0};
    CompletionCallback callback{nullptr};
    CompletionStrategy completionStrategy{CompletionStrategy::CompleteOnAT};  // Explicit two-path model
};

struct TimeoutTransactionSnapshot {
    uint16_t generation{0};
    uint16_t destinationNodeID{0};
    uint8_t tLabel{0};
    uint8_t tCode{0};
    TransactionState state{TransactionState::Created};
    uint8_t ackCode{0};
    uint8_t deadlineExtensionCount{0};
    uint64_t deadlineUsec{0};
    uint64_t address{0};
    uint16_t extendedTCode{0};
    uint32_t lockOperand0{0};
    uint32_t lockOperand1{0};
    uint8_t lockOperandCount{0};
};

// A parsed incoming response packet, ready for matching.
struct RxResponse {
    uint16_t generation{0};
    uint16_t sourceNodeID{0};
    uint16_t destinationNodeID{0};
    uint8_t  tLabel{0};
    uint8_t  tCode{0};
    uint8_t  rCode{0};                // Response code (for response tCodes 0x6, 0x7)
    std::span<const uint8_t> payload{};
    OHCIEventCode eventCode{static_cast<OHCIEventCode>(0)};
    uint16_t hardwareTimeStamp{0};
};

// Bounded diagnostic evidence for replies that cannot be attributed. Counts
// are cumulative; latest bytes are explicitly a prefix, never a claimed full
// history or a successful response to a replacement operation.
struct UnattributedResponseEvidence {
    uint64_t count{0};
    bool uncertainWire{false};
    uint16_t generation{0};
    uint16_t sourceNodeID{0};
    uint16_t destinationNodeID{0};
    uint8_t label{0};
    uint8_t tCode{0};
    uint8_t rCode{0};
    size_t wirePayloadLength{0};
    size_t preservedPrefixLength{0};
    std::array<uint8_t, 512> latestPrefix{};
};

// Tracking actor - templated on completion queue type
template <typename TCompletionQueue>
class Track_Tracking {
public:
    Track_Tracking(LabelAllocator* allocator,
                   TransactionManager* txnMgr,
                   TCompletionQueue& completionQueue,
                   Engine::ContextManager* contextManager = nullptr)
        : labelAllocator_(allocator),
          txnMgr_(txnMgr),
          completionQueue_(completionQueue),
          contextManager_(contextManager),
          lock_(nullptr),
          payloads_(std::make_unique<PayloadRegistry>()),
          // Phase 2.0: Transaction infrastructure (created below after validation)
          txnHandler_(nullptr)
    {
        lock_ = ::IOLockAlloc();
        if (lock_ == nullptr) {
            // Log error but don't crash - caller should check via RegisterTx return value
            ASFW_LOG(Async, "ERROR: Track_Tracking: IOLockAlloc failed!");
        }

        if (!txnMgr_) { // NOSONAR(cpp:S3923): branches log different diagnostic messages
            ASFW_LOG(Async, "ERROR: Track_Tracking: TransactionManager required!");
        } else {
            ASFW_LOG(Async, "✅ Track_Tracking: Transaction-only mode (Phase 2.0)");
        }

        // Create TransactionCompletionHandler with both txnMgr and labelAllocator
        txnHandler_ = std::make_unique<TransactionCompletionHandler>(txnMgr, allocator);
    }

    ~Track_Tracking() {
        if (lock_) {
            ::IOLockFree(lock_);
        }
    }

    [[nodiscard]] AsyncHandle RegisterTx(const TxMetadata& meta) {
        if (!labelAllocator_ || !txnMgr_ || !lock_) {
            return AsyncHandle{0};
        }

        ::IOLockLock(lock_);

        // A completed client may still own an AT program or uncertain wire
        // response. Never infer a stale allocation bitmap from Count()==0.
        if (labelAllocator_->HasUncertainWire()) {
            ::IOLockUnlock(lock_);
            return AsyncHandle{0}; // No proved wire-fence reopening; no automatic reconstruction or replay.
        }

        // Allocate a free label from the bitmap allocator to avoid collisions
        uint8_t label = labelAllocator_->Allocate();
        if (label == LabelAllocator::kInvalidLabel) {
            ::IOLockUnlock(lock_);
            ASFW_LOG(Async, "ERROR: RegisterTx failed - no available tLabels");
            return AsyncHandle{0};
        }

        // Initialize privately, then publish under the manager lock. Readers
        // can never observe a partially initialized transaction or callback.
        auto owned = std::make_unique<Transaction>(TLabel{label},
            BusGeneration{meta.generation}, NodeID{meta.destinationNodeID});
        auto* txn = owned.get();
        // Process-wide serial is not reset by bus reset or runtime reconstruction.
        // Six low bits select the bounded label record; exhaustion fails closed.
        static std::atomic<uint32_t> nextOperation{0};
        uint32_t serial = nextOperation.load(std::memory_order_relaxed);
        while (serial < 0x01ffffffu && !nextOperation.compare_exchange_weak(
                   serial, serial + 1, std::memory_order_relaxed)) {}
        if (serial >= 0x01ffffffu) {
            labelAllocator_->Free(label);
            ::IOLockUnlock(lock_);
            return AsyncHandle{0};
        }
        const uint32_t operation = (serial << 6) + label + 1;
        txn->SetOperationIdentity(operation);
        labelAllocator_->BindOperation(label, operation);

        ASFW_LOG_V3(Async, "🔍 [RegisterTx] Allocated Transaction: txn=%p tLabel=%u",
                    txn, label);

        // Set transaction parameters
        txn->SetTimeout(200);  // TODO: Get from config or meta
        txn->SetTCode(meta.tCode);  // Store tCode for IsReadOperation() check
        txn->SetRequestDiagnostics(meta.address, meta.extendedTCode,
                                   meta.lockOperand0, meta.lockOperand1,
                                   meta.lockOperandCount);
        txn->SetCompletionStrategy(meta.completionStrategy);

        // EXPLICIT: Mark read operations to skip AT completion
        if (meta.completionStrategy == CompletionStrategy::CompleteOnAR) {
            txn->SetSkipATCompletion(true);
            ASFW_LOG_V3(Async, "🔍 [RegisterTx] Read operation: will skip AT completion, strategy=%{public}s",
                        ToString(meta.completionStrategy));
        }

        ASFW_LOG_V3(Async, "🔍 [RegisterTx] meta.callback valid=%d for tLabel=%u",
                    meta.callback ? 1 : 0, label);

        // Set response handler (wraps meta.callback)
        txn->SetResponseHandler([callback = meta.callback, label, operation]
                                (kern_return_t kr, uint8_t responseCode, std::span<const uint8_t> data) // NOLINT(bugprone-easily-swappable-parameters)
                                {
            ASFW_LOG_V3(Async, "🔍 [Wrapper Lambda] ENTRY: tLabel=%u callback=%p valid=%d kr=0x%x",
                        label, &callback, callback ? 1 : 0, kr);
            if (callback) {
                // Convert kern_return_t to AsyncStatus for Phase 2.3 callback
                AsyncStatus status = AsyncStatus::kHardwareError;
                if (kr == kIOReturnSuccess) {
                    status = AsyncStatus::kSuccess;
                } else if (kr == kIOReturnTimeout) {
                    status = AsyncStatus::kTimeout;
                } else if (kr == kIOReturnAborted) {
                    status = AsyncStatus::kAborted;
                }
                // Phase 2.3: CompletionCallback now takes (handle, status, span)
                // The full host operation token is opaque to callers.
                ASFW_LOG_V3(Async, "🔍 [Wrapper Lambda] About to invoke callback: handle=%u status=%{public}s rCode=0x%02X",
                            operation, ASFW::Async::ToString(status), responseCode);
                callback(AsyncHandle{operation}, status, responseCode, data);
                ASFW_LOG_V3(Async, "🔍 [Wrapper Lambda] Callback returned");
            } else {
                ASFW_LOG(Async, "⚠️ [Wrapper Lambda] callback is NULL!");
            }
        });

        // Transition to Submitted state (Created → Submitted)
        txn->TransitionTo(TransactionState::Submitted, "RegisterTx");
        if (!txnMgr_->Adopt(std::move(owned))) {
            labelAllocator_->AbandonUnposted(operation);
            ::IOLockUnlock(lock_);
            return AsyncHandle{0};
        }

        ASFW_LOG_V2(Async,
                    "✅ RegisterTx: Created txn (tLabel=%u gen=%u nodeID=0x%04X tCode=0x%02X)",
                    label, meta.generation, meta.destinationNodeID, meta.tCode);

        ::IOLockUnlock(lock_);

        // Return the nonrecycled host operation identity.
        return AsyncHandle{operation};
    }

    // Roll back a registration that never reached DMA. The Submit caller sees
    // an invalid handle; do not also deliver an asynchronous completion.
    void AbandonUnposted(AsyncHandle handle) {
        if (!txnMgr_ || !labelAllocator_ || !lock_ || !labelAllocator_->Matches(handle.value)) return;
        const TLabel label{static_cast<uint8_t>((handle.value - 1) & 63)};
        ::IOLockLock(lock_);
        bool unposted = false;
        txnMgr_->WithTransaction(label, [&](Transaction* txn) {
            unposted = txn->OperationIdentity() == handle.value && txn->state() == TransactionState::Submitted;
        });
        if (unposted) {
            auto discarded = txnMgr_->Extract(label, handle.value);
            if (discarded) {
                labelAllocator_->AbandonUnposted(handle.value);
                (void)payloads_->Detach(handle.value);
            }
        }
        ::IOLockUnlock(lock_);
    }

    [[nodiscard]] std::optional<uint8_t> GetLabelFromHandle(AsyncHandle handle) const {
        if (!txnMgr_ || !lock_) {
            return std::nullopt;
        }

        // The low six bits select the label; the full token proves this assignment.
        if (!labelAllocator_->Matches(handle.value)) {
            return std::nullopt;  // Invalid handle
        }
        uint8_t label = static_cast<uint8_t>((handle.value - 1) & 63);
        if (label >= 64) {
            return std::nullopt;
        }
        
        bool current = false;
        txnMgr_->WithTransaction(TLabel{label}, [&](Transaction* txn) {
            current = txn->OperationIdentity() == handle.value;
        });
        return current ? std::optional<uint8_t>{label} : std::nullopt;
    }

    [[nodiscard]] bool PreparePosted(AsyncHandle handle) { return labelAllocator_->MarkPosted(handle.value); }

    // Only the submit guard, which has not transferred its chain to hardware,
    // may use this proof. Cancellation can already have removed the client.
    void RollbackUnpublished(AsyncHandle handle) {
        auto discarded = txnMgr_->Extract(TLabel{static_cast<uint8_t>((handle.value - 1) & 63)}, handle.value);
        labelAllocator_->AbandonUnposted(handle.value);
        (void)payloads_->Detach(handle.value);
    }

    void OnTxPosted(AsyncHandle handle, uint64_t nowUsec, uint64_t timeoutUsec) {
        if (!txnMgr_ || !lock_) {
            return;
        }

        // Validate full operation identity before touching the selected label.
        if (!labelAllocator_->Matches(handle.value)) {
            return;  // Invalid handle
        }
        uint8_t label = static_cast<uint8_t>((handle.value - 1) & 63);

        if (!labelAllocator_->MarkPosted(handle.value)) return;
        bool found = txnMgr_->WithTransaction(TLabel{label}, [&](Transaction* txn) {
            if (txn->OperationIdentity() != handle.value) return;
            // Transition to ATPosted state
            txn->TransitionTo(TransactionState::ATPosted, "OnTxPosted");

            // EXPLICIT: Read operations bypass AT completion (go straight to AwaitingAR)
            // This matches Apple's IOFWReadQuadCommand gotAck() pattern:
            // - gotAck() stores ackCode but doesn't complete
            // - gotPacket() completes the command with response data
            if (txn->GetCompletionStrategy() == CompletionStrategy::CompleteOnAR) {
                txn->TransitionTo(TransactionState::ATCompleted, "OnTxPosted: CompleteOnAR bypass");
                txn->TransitionTo(TransactionState::AwaitingAR, "OnTxPosted: CompleteOnAR bypass");
                ASFW_LOG_V3(Async, "  📤 Read operation: bypassing AT completion, going to AwaitingAR");
            }

            // Set deadline for timeout
            txn->SetDeadline(nowUsec + timeoutUsec);

            ASFW_LOG_V3(Async,
                        "📤 OnTxPosted: tLabel=%u deadline=%llu state=%{public}s strategy=%{public}s",
                        txn->label().value,
                        static_cast<unsigned long long>(nowUsec + timeoutUsec),
                        ToString(txn->state()),
                        ToString(txn->GetCompletionStrategy()));
        });

        if (!found) {
            ASFW_LOG(Async, "⚠️  OnTxPosted: Transaction tLabel=%u not found", label);
        }
    }

    // AR Response Reception - FINAL TRANSACTION STATE
    // Per Apple IOFWAsyncCommand::gotPacket() and Linux close_transaction() (core-transaction.c:60-70):
    // Response packet arrival is the definitive completion event that overrides AT completion status.
    // Even if AT reported eventCode 0x10 or other errors, successful AR response means transaction succeeded.
    // This matches FireWire spec: split transactions complete on response, not on request ack.
    void OnRxResponse(const RxResponse& response) {
        ASFW_LOG_V2(Async, "📥 OnRxResponse: tLabel=%u gen=%u tCode=0x%X rCode=0x%X event=0x%02X len=%zu ts=0x%04X",
                 response.tLabel, response.generation, response.tCode, response.rCode,
                 static_cast<uint8_t>(response.eventCode), response.payload.size(), response.hardwareTimeStamp);

        if (!txnHandler_ || !txnMgr_ || !lock_) {
            return;
        }

        // Phase 2.0: Transaction-only path
        MatchKey key{
            .node = NodeID{response.sourceNodeID},
            .generation = BusGeneration{response.generation},
            .label = TLabel{response.tLabel}
        };

        if (!txnHandler_->OnARResponse(key, response.rCode, response.payload)) {
            ::IOLockLock(lock_);
            if (unattributed_.count != UINT64_MAX) ++unattributed_.count;
            unattributed_.uncertainWire = labelAllocator_->HasUncertainWire();
            unattributed_.generation = response.generation;
            unattributed_.sourceNodeID = response.sourceNodeID;
            unattributed_.destinationNodeID = response.destinationNodeID;
            unattributed_.label = response.tLabel;
            unattributed_.tCode = response.tCode;
            unattributed_.rCode = response.rCode;
            unattributed_.wirePayloadLength = response.payload.size();
            unattributed_.preservedPrefixLength = std::min(response.payload.size(), unattributed_.latestPrefix.size());
            unattributed_.latestPrefix.fill(0);
            std::copy_n(response.payload.begin(), unattributed_.preservedPrefixLength, unattributed_.latestPrefix.begin());
            ::IOLockUnlock(lock_);
        }
    }


    [[nodiscard]] UnattributedResponseEvidence CopyUnattributedResponseEvidence() const {
        if (!lock_) return {};
        ::IOLockLock(lock_);
        const auto result = unattributed_;
        ::IOLockUnlock(lock_);
        return result;
    }

    void OnTimeoutTick(uint64_t nowUsec) {
        if (!txnMgr_ || !txnHandler_) {
            return;
        }

        // Phase 2.0: Check all transactions for timeout
        // TODO: Optimize with priority queue/timer wheel if performance becomes issue
        std::vector<std::pair<TLabel,uint32_t>> timedOutLabels;

        // Collect timed-out transactions
        txnMgr_->ForEachTransaction([&](Transaction* txn) {
            if (!txn) return;

            // Skip transactions in terminal states (already completed/failed/cancelled/timed out)
            TransactionState state = txn->state();
            if (state == TransactionState::Completed ||
                state == TransactionState::Failed ||
                state == TransactionState::Cancelled ||
                state == TransactionState::TimedOut) {
                return;  // Don't check deadline for terminal states
            }

            uint64_t deadline = txn->deadlineUs();
            if (deadline > 0 && nowUsec >= deadline) {
                // Transaction has timed out
                timedOutLabels.emplace_back(txn->label(), txn->OperationIdentity());

                ASFW_LOG_V2(Async,
                            "⏱️ Timeout: tLabel=%u state=%{public}s deadline=%llu now=%llu",
                            txn->label().value, ToString(txn->state()),
                            static_cast<unsigned long long>(deadline),
                            static_cast<unsigned long long>(nowUsec));
            }
        });

        // Handle timeouts outside iteration (avoid modifying during iteration)
        for (const auto& [label, operation] : timedOutLabels) {
            txnHandler_->OnTimeout(label, operation);
        }
    }

    [[nodiscard]] std::vector<TimeoutTransactionSnapshot>
    CopyExpiredSnapshots(uint64_t nowUsec) const {
        std::vector<TimeoutTransactionSnapshot> snapshots;
        if (!txnMgr_) {
            return snapshots;
        }

        txnMgr_->ForEachTransaction([&](Transaction* txn) {
            if (!txn || IsTerminalState(txn->state()) || txn->deadlineUs() == 0 ||
                nowUsec < txn->deadlineUs()) {
                return;
            }
            snapshots.push_back(TimeoutTransactionSnapshot{
                .generation = static_cast<uint16_t>(txn->generation().value),
                .destinationNodeID = txn->nodeID().value,
                .tLabel = txn->label().value,
                .tCode = txn->tCode(),
                .state = txn->state(),
                .ackCode = txn->ackCode(),
                .deadlineExtensionCount = txn->retryCount(),
                .deadlineUsec = txn->deadlineUs(),
                .address = txn->requestAddress(),
                .extendedTCode = txn->extendedTCode(),
                .lockOperand0 = txn->lockOperand0(),
                .lockOperand1 = txn->lockOperand1(),
                .lockOperandCount = txn->lockOperandCount(),
            });
        });
        return snapshots;
    }

    void CancelByGeneration(uint16_t oldGeneration) {
        if (!txnMgr_) {
            return;
        }

        // Phase 2.0: Cancel all transactions with old generation and FREE their labels.
        // Previously we transitioned transactions to Cancelled but left them in the manager,
        // which leaked label allocations across bus resets. That forced subsequent requests
        // to reuse a single label (e.g. tLabel=3 forever). Extract and free here to release
        // the bitmap slots.
        ASFW_LOG(Async, "🔄 CancelByGeneration: gen=%u (will extract and free labels)", oldGeneration);

        // Collect labels to cancel (avoid modifying during iteration)
        std::vector<std::pair<TLabel,uint32_t>> victims;
        txnMgr_->ForEachTransaction([&](Transaction* txn) {
            if (!txn) return;
            if (txn->generation().value == oldGeneration) {
                victims.emplace_back(txn->label(), txn->OperationIdentity());
            }
        });

        // Cancel collected transactions
        for (const auto& [label, operation] : victims) {
            auto txnPtr = txnMgr_->Extract(label, operation);
            if (!txnPtr) {
                continue;
            }

            if (labelAllocator_) labelAllocator_->CompleteLogical(label.value, true);
            if (!IsTerminalState(txnPtr->state())) {
                txnPtr->TransitionTo(TransactionState::Cancelled, "CancelByGeneration");
                txnPtr->InvokeResponseHandler(kIOReturnAborted, 0xFF, {});
            }

        }

        ASFW_LOG(Async, "✅ CancelByGeneration: Cancelled %zu transactions", victims.size());
    }

    // Cancel ALL transactions regardless of generation and free labels.
    void CancelAllAndFreeLabels() {
        if (!txnMgr_) {
            return;
        }

        std::vector<std::pair<TLabel,uint32_t>> victims;
        txnMgr_->ForEachTransaction([&](Transaction* txn) {
            if (!txn) return;
            victims.emplace_back(txn->label(), txn->OperationIdentity());
        });

        for (const auto& [label, operation] : victims) {
            auto txnPtr = txnMgr_->Extract(label, operation);
            if (!txnPtr) {
                continue;
            }

            if (labelAllocator_) labelAllocator_->CompleteLogical(label.value, true);
            if (!IsTerminalState(txnPtr->state())) {
                txnPtr->TransitionTo(TransactionState::Cancelled, "CancelAll");
                txnPtr->InvokeResponseHandler(kIOReturnAborted, 0xFF, {});
            }

        }

        ASFW_LOG(Async, "✅ CancelAllAndFreeLabels: cancelled %zu transactions", victims.size());
    }

    void RetireStoppedAT() {
        // Caller proves both contexts idle AND all queued programs discarded.
        labelAllocator_->RetireStoppedAT();
        payloads_->CancelAll(PayloadRegistry::CancelMode::Deferred);
    }

    LabelAllocator* GetLabelAllocator() const { return labelAllocator_; }

    void OnTxCompletion(const TxCompletion& completion) {
        if (!txnHandler_) {
            return;
        }

        // Only the copied host identity may retire ownership. A descriptor
        // address or wire label can already belong to a later program.
        if (completion.isResponseContext) { txnHandler_->OnATCompletion(completion); return; }
        if (!labelAllocator_ || completion.tLabel >= 64 ||
            ((completion.operationIdentity - 1) & 63) != completion.tLabel ||
            !labelAllocator_->RetireAT(completion.operationIdentity)) return;
        (void)payloads_->Detach(completion.operationIdentity);
        txnHandler_->OnATCompletion(completion);
    }

    // Accessors
    TransactionManager* GetTransactionManager() const { return txnMgr_; }  // Phase 2.0
    // Payload registry access (owned by tracking actor)
    PayloadRegistry* Payloads() const { return payloads_.get(); }

    // Only after posted work is retired: uncertain DMA may still reference
    // these mappings. Retain the registry until process exit, without retaining
    // Tracking's borrowed transaction/completion pointers.
    void QuarantinePayloads() noexcept { (void)payloads_.release(); }
    
    // Context manager access (for AR-side stop behavior)
    void SetContextManager(Engine::ContextManager* ctxMgr) { contextManager_ = ctxMgr; }

private:
    // Phase 2.0: All legacy Phase 1.2 helper functions removed
    // (TracePayload, TCodeExpectsResponse, CompletionDispatch, DetachAndBuildDispatch_, DispatchCompletion_)
    // Transaction-only architecture uses TransactionCompletionHandler instead

    // Components
    UnattributedResponseEvidence unattributed_{};
    LabelAllocator* labelAllocator_;
    TransactionManager* txnMgr_;  // Phase 2.0: Required (sole source of truth)
    TCompletionQueue& completionQueue_;
    Engine::ContextManager* contextManager_;  // For AR-side stop on empty (wired in Start)
    IOLock* lock_;
    std::unique_ptr<PayloadRegistry> payloads_;

    // Phase 2.0: Transaction infrastructure (required)
    std::unique_ptr<TransactionCompletionHandler> txnHandler_;
};

} // namespace ASFW::Async
