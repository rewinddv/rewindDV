// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
// Link-only host definitions for production ResponseSender.cpp. The tests use
// ResponseSender's ASFW_HOST_TEST capture seam, so these paths must not run.

#include "ASFWDriver/Async/Engine/ContextManager.hpp"
#include "ASFWDriver/Async/Tx/Submitter.hpp"

namespace ASFW::Async::Engine {

ASFW::Shared::DMAMemoryManager* ContextManager::DmaManager() noexcept {
    return nullptr;
}

ASFW::Async::ATResponseContext* ContextManager::GetAtResponseContext() noexcept {
    return nullptr;
}

} // namespace ASFW::Async::Engine

namespace ASFW::Async::Tx {

SubmitResult Submitter::submit_tx_chain(
    ATResponseContext*,
    DescriptorBuilder::DescriptorChain&&) noexcept {
    return SubmitResult{.kr = kIOReturnNotReady};
}

} // namespace ASFW::Async::Tx
