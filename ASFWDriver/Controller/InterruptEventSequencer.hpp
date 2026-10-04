// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <utility>

#include "../Hardware/RegisterMap.hpp"

namespace ASFW::Driver::InterruptEventSequencer {

// The reset FSM owns busReset W1C until positive AT quiescence. Self-ID has
// already been latched at IRQ ingress and belongs to the ordinary early ack.
inline constexpr uint32_t kDeferredHardwareAcks = IntEventBits::kBusReset;

// Keep the ControllerCore interrupt work and its W1C acknowledgement in one
// testable production seam. Linux acknowledges ordinary OHCI interrupt events
// before queueing their async work so an event arriving during the drain remains
// latched for a later pass (linux-firewire-22098763/ohci.c:2067-2088).
template <typename DispatchAsync, typename AfterAsyncDispatch, typename ClearEvents>
void DispatchAndAcknowledge(uint32_t events,
                            uint32_t faultAcks,
                            uint32_t preservedAcks,
                            DispatchAsync&& dispatchAsync,
                            AfterAsyncDispatch&& afterAsyncDispatch,
                            ClearEvents&& clearEvents) {
    const uint32_t earlyAcks = events & ~(preservedAcks | faultAcks);
    if (earlyAcks != 0U) {
        std::forward<ClearEvents>(clearEvents)(earlyAcks);
    }

    std::forward<DispatchAsync>(dispatchAsync)(events);
    std::forward<AfterAsyncDispatch>(afterAsyncDispatch)();

    if (faultAcks != 0U) {
        std::forward<ClearEvents>(clearEvents)(faultAcks);
    }

}

} // namespace ASFW::Driver::InterruptEventSequencer
