#pragma once

#include "NativeCallbackDrain.hpp"
#include <memory>

#if !defined(ASFW_HOST_TEST) || defined(ASFW_NATIVE_RETIREMENT_TEST)
#ifdef ASFW_HOST_TEST
#include "../../Testing/HostDriverKitStubs.hpp"
#else
#include <DriverKit/OSAction.h>
#include <DriverKit/OSSharedPtr.h>
#endif

namespace ASFW::Shared {

// Transfer the owner's final source/action references into the drain ledger.
// DriverKit 27 IOTimer/IOInterrupt/IOServiceNotification/IODataQueue dispatch
// source Cancel documentation makes the completion the terminal barrier.
// A Cancel error provides no release authority. The root keeps the failed
// ledger, runtime and service alive, and permanently refuses another start.
template <typename Source>
void RetireNativeSource(OSSharedPtr<Source>& sourceOwner,
                        OSSharedPtr<OSAction>& actionOwner,
                        const std::shared_ptr<NativeCallbackDrain>& drain) {
    if (!sourceOwner) { actionOwner.reset(); return; }
    auto* source = sourceOwner.get();
    auto* action = actionOwner.get();
    const auto ticket = drain->BeginSource([source, action] {
        if (action) action->release();
        source->release();
    }, action ? 2 : 1);
    if (!ticket) return; // Original owner references remain intact on overflow.
    (void)sourceOwner.detach();
    (void)actionOwner.detach();
    // Also cover a platform implementation that completes inline from Cancel.
    OSSharedPtr<Source> callingSource(source, OSRetain);
    // C++ Blocks preserve reference captures. Copy the ledger into a value
    // variable so delayed completion cannot borrow the caller's shared_ptr.
    const auto completionDrain = drain;
    const auto completionTicket = *ticket;
    const auto kr = source->Cancel(^{ completionDrain->CompletionObserved(completionTicket); });
    drain->RequestReturned(*ticket, kr == kIOReturnSuccess);
}

template <typename Source>
void RetireNativeSource(OSSharedPtr<Source>& sourceOwner,
                        const std::shared_ptr<NativeCallbackDrain>& drain) {
    OSSharedPtr<OSAction> noAction;
    RetireNativeSource(sourceOwner, noAction, drain);
}

// Suspend preserves interrupt registration. The documented disable completion
// drains the old handler before the root discards any old runtime borrowers.
template <typename Source>
void DisableNativeSource(Source* source,
                         const std::shared_ptr<NativeCallbackDrain>& drain) {
    if (!source) return;
    const auto ticket = drain->BeginSource([] {});
    if (!ticket) return;
    const auto completionDrain = drain;
    const auto completionTicket = *ticket;
    const auto kr = source->SetEnableWithCompletion(false, ^{
        completionDrain->CompletionObserved(completionTicket);
    });
    drain->RequestReturned(*ticket, kr == kIOReturnSuccess);
}

} // namespace ASFW::Shared
#endif
