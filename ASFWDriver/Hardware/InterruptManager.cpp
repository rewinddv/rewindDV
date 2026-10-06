#include "InterruptManager.hpp"

#ifndef ASFW_HOST_TEST
#include <DriverKit/IOInterruptDispatchSource.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOService.h>
#include <DriverKit/OSAction.h>
#endif

#include <utility>
#include "../Logging/Logging.hpp"
#include "RegisterMap.hpp"
#include "HardwareInterface.hpp"
#include "../Shared/Completion/NativeSourceRetirement.hpp"

namespace ASFW::Driver {

InterruptManager::InterruptManager() = default;
InterruptManager::~InterruptManager() { Teardown(); }

kern_return_t InterruptManager::Initialise(IOService* owner,
                                           OSSharedPtr<IODispatchQueue> queue,
                                           OSSharedPtr<OSAction> handler) {
    queue_ = std::move(queue);
    handler_ = std::move(handler);

    if (source_) {
        ASFW_LOG(Controller, "InterruptManager: source already exists, updating handler");
        if (handler_ && source_) {
            return source_->SetHandler(handler_.get());
        }
        return kIOReturnSuccess;
    }

    IOInterruptDispatchSource* rawSource = nullptr;
    kern_return_t kr = IOInterruptDispatchSource::Create(owner, 0, queue_.get(), &rawSource);
    if (kr != kIOReturnSuccess) {
        return kr;
    }

    source_ = OSSharedPtr(rawSource, OSNoRetain);
    if (handler_) {
        kr = source_->SetHandler(handler_.get());
        if (kr != kIOReturnSuccess) {
            // Failed setup still belongs to the root's native drain.
            return kr;
        }
    }
    return kIOReturnSuccess;
}

void InterruptManager::Enable() {
    ASFW_LOG(Controller, "InterruptManager::Enable called: source=%p", source_.get());
    if (source_) {
        source_->SetEnableWithCompletion(true, nullptr);
    } else {
        ASFW_LOG(Controller, "⚠️  InterruptManager::Enable: NO SOURCE!");
    }
}

void InterruptManager::Disable() {
    if (source_) {
        source_->SetEnableWithCompletion(false, nullptr);
    }
    // The manager (and its shadow mask) now survives suspend, but the silicon's
    // IntMask does not — a stale shadow would make UnmaskInterrupts skip the
    // hardware write after the wake re-init's soft reset.
    shadowMask_.store(0, std::memory_order_release);
}

void InterruptManager::Teardown() {
#ifdef ASFW_HOST_TEST
    source_.reset();
    handler_.reset();
    queue_.reset();
#else
    if (!source_) {
        queue_.reset();
        handler_.reset();
        return;
    }

    // Destruction is not a cancellation barrier. Normal root teardown transfers
    // these references to its drain first. An unexpected destructor keeps the
    // action's service retention and source backing instead of guessing.
    ASFW_LOG_ERROR(Controller, "InterruptManager destroyed before native retirement; retaining source/action");
    (void)source_.detach();
    (void)handler_.detach();
    (void)queue_.detach();
#endif
}

void InterruptManager::BeginNativeRetirement(
    const std::shared_ptr<ASFW::Shared::NativeCallbackDrain>& drain, bool suspend) {
    shadowMask_.store(0, std::memory_order_release);
#ifndef ASFW_HOST_TEST
    if (suspend) ASFW::Shared::DisableNativeSource(source_.get(), drain);
    else ASFW::Shared::RetireNativeSource(source_, handler_, drain);
#else
    (void)drain;
    if (!suspend) Teardown();
#endif
}

void InterruptManager::EnableInterrupts(uint32_t bits) {
    shadowMask_.fetch_or(bits, std::memory_order_release);
}

void InterruptManager::DisableInterrupts(uint32_t bits) {
    shadowMask_.fetch_and(~bits, std::memory_order_release);
}

uint32_t InterruptManager::EnabledMask() const {
    return shadowMask_.load(std::memory_order_acquire);
}

void InterruptManager::MaskInterrupts(HardwareInterface* hw, uint32_t bits) {
    if (!hw) return;
    if (auto access = hw->TryBeginAccess()) {
        access.Write(Register32::kIntMaskClear, bits);
    }
    DisableInterrupts(bits);
}

void InterruptManager::UnmaskInterrupts(HardwareInterface* hw, uint32_t bits) {
    if (!hw) return;
    
    const uint32_t cur  = shadowMask_.load(std::memory_order_acquire);
    const uint32_t want = (cur | bits | IntMaskBits::kMasterIntEnable);
    const uint32_t add  = want & ~cur;
    
    if (add) {
        if (auto access = hw->TryBeginAccess()) {
            access.Write(Register32::kIntMaskSet, add);
        } else {
            return;
        }
        shadowMask_.fetch_or(add, std::memory_order_release);
        ASFW_LOG(Hardware, "IntMask updated: shadow=0x%08x add=0x%08x (masterEnable=%d busReset=%d)",
                 shadowMask_.load(), add,
                 (shadowMask_.load() >> 31) & 1,
                 (shadowMask_.load() >> 17) & 1);
    }
}

} // namespace ASFW::Driver
