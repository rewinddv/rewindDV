// SPDX-License-Identifier: Apache-2.0
// Modified by Rewind Digital, LLC, 2026: host-only regression support.
// Retained ASFireWire baseline attribution: see ASFireWire-NOTICE.txt.
#include "ASFWDriver/Async/AsyncSubsystem.hpp"

// Stub definitions for unique_ptr-owned forward-declared types so AsyncSubsystem's
// destructor can compile in this host-only test target.
namespace ASFW::Async {
class PacketBuilder {};
class ResponseSender {};
namespace Tx {
class Submitter {};
} // namespace Tx
} // namespace ASFW::Async

namespace ASFW::Async {

// This fixture represents an initialized subsystem, not a constructed-but-idle
// production object. Match Initialize's callback admission and Shutdown's fence.
AsyncSubsystem::AsyncSubsystem() : postedWorkEpoch_(std::make_shared<PostedWorkEpoch>()) {
#ifdef ASFW_QUEUE_CONTRACT_TEST
    // The queue regression links the real command queue with a controlled Read
    // boundary. No completion queue, DMA or controller is initialized.
    commandQueue_ = std::make_unique<std::deque<PendingCommandPtr>>();
    commandQueueLock_ = IOLockAlloc();
    HostTest_SetDeferPostedWork(true);
#endif
}
AsyncSubsystem::~AsyncSubsystem() {
    if (postedWorkEpoch_) postedWorkEpoch_->Retire();
#ifdef ASFW_QUEUE_CONTRACT_TEST
    IOLockFree(commandQueueLock_);
#endif
}

#ifndef ASFW_QUEUE_CONTRACT_TEST
AsyncHandle AsyncSubsystem::Read(const ReadParams&, CompletionCallback callback) {
    const AsyncHandle handle{1};
    if (callback) {
        callback(handle, AsyncStatus::kHardwareError, 0xFF, {});
    }
    return handle;
}

AsyncHandle AsyncSubsystem::ReadWithRetry(const ReadParams&, const RetryPolicy&,
                                          CompletionCallback callback) {
    const AsyncHandle handle{1};
    if (callback) {
        callback(handle, AsyncStatus::kHardwareError, 0xFF, {});
    }
    return handle;
}
#endif

AsyncHandle AsyncSubsystem::Write(const WriteParams&, CompletionCallback callback) {
    const AsyncHandle handle{1};
    if (callback) {
        callback(handle, AsyncStatus::kHardwareError, 0xFF, {});
    }
    return handle;
}

AsyncHandle AsyncSubsystem::Lock(const LockParams&, uint16_t, CompletionCallback callback) {
    const AsyncHandle handle{1};
    if (callback) {
        callback(handle, AsyncStatus::kHardwareError, 0xFF, {});
    }
    return handle;
}

AsyncHandle AsyncSubsystem::CompareSwap(const CompareSwapParams&, CompareSwapCallback callback) {
    if (callback) {
        callback(AsyncStatus::kHardwareError, 0u, false);
    }
    return AsyncHandle{1};
}

AsyncHandle AsyncSubsystem::PhyRequest(const PhyParams&, CompletionCallback callback) {
    const AsyncHandle handle{1};
    if (callback) {
        callback(handle, AsyncStatus::kHardwareError, 0xFF, {});
    }
    return handle;
}

#ifndef ASFW_QUEUE_CONTRACT_TEST
bool AsyncSubsystem::Cancel(AsyncHandle) { return false; }
#endif

void AsyncSubsystem::OnTxInterrupt() {}

void AsyncSubsystem::OnRxInterrupt(ARContextType) {}

kern_return_t AsyncSubsystem::ArmARContextsOnly() { return kIOReturnSuccess; }

void AsyncSubsystem::OnBusResetObserved() noexcept { GetGenerationTracker().OnBusResetObserved(); }

void AsyncSubsystem::OnBusResetBegin(uint8_t) {}

void AsyncSubsystem::OnBusResetComplete(uint8_t) {}

void AsyncSubsystem::ConfirmBusGeneration(uint8_t) {}

void AsyncSubsystem::StopATContextsOnly() {}

void AsyncSubsystem::FlushATContexts() {}

void AsyncSubsystem::RearmATContexts() {}

void AsyncSubsystem::OnTimeoutTick() {}

AsyncWatchdogStats AsyncSubsystem::GetWatchdogStats() const { return {}; }

DMAMemoryManager* AsyncSubsystem::GetDMAManager() { return nullptr; }

std::optional<AsyncStatusSnapshot> AsyncSubsystem::GetStatusSnapshot() const {
    return std::nullopt;
}

Debug::AsyncTraceCapture* AsyncSubsystem::GetAsyncTraceCapture() const {
    return nullptr;
}

ASFWDiagInboundCSRStats* AsyncSubsystem::GetInboundCSRStats() const {
    return nullptr;
}

} // namespace ASFW::Async

// Stub destructors for out-of-line definitions that this test target doesn't link.
namespace ASFW::Async::Engine {
struct ContextManager::State {};
ContextManager::~ContextManager() {}
} // namespace ASFW::Async::Engine

namespace ASFW::Debug {
BusResetPacketCapture::~BusResetPacketCapture() {}
} // namespace ASFW::Debug

namespace ASFW::Shared {
PayloadHandle::~PayloadHandle() noexcept {}
void PayloadHandle::Release() noexcept {}
} // namespace ASFW::Shared
