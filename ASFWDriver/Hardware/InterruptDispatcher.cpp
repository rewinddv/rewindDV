// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#include "InterruptDispatcher.hpp"

#include "../Async/Interfaces/IAsyncSubsystemPort.hpp"
#include "../Controller/ControllerCore.hpp"
#include "../Diagnostics/StatusPublisher.hpp"
#include "../Isoch/IsochService.hpp"
#include "../Logging/Logging.hpp"
#include "HardwareInterface.hpp"
#include "OHCIConstants.hpp"
#include "RegisterMap.hpp"
#include <array>

namespace ASFW::Driver {

void InterruptDispatcher::HandleSnapshot(const InterruptSnapshot& snap, ControllerCore& controller,
                                         HardwareInterface& hardware, IODispatchQueue& workQueue,
                                         IsochService& isoch, StatusPublisher& statusPublisher,
                                         ASFW::Async::IAsyncSubsystemPort* asyncSubsystem) {
    controller.HandleInterrupt(snap);
    const auto events = hardware.TakeIsochContextEvents(snap.intEvent);

    // ===== ISOCHRONOUS RECEIVE INTERRUPT =====
    // Per OHCI §9.1: kIsochRx (bit 7) indicates one or more IR contexts have completed descriptors.
    // We read isoRecvEvent to determine which contexts, clear it, then dispatch processing.
    if ((snap.intEvent & IntEventBits::kIsochRx) && events.receive != 0) {
        // Clear the per-context event bits to acknowledge
        // Already acknowledged by TakeIsochContextEvents.

        // One OHCI IR context backs each capture stream (contextIndex ==
        // streamIndex). A multi-stream DICE device (Venice F32 = 2×16) runs a
        // master (context 0) plus secondary contexts whose event bits are
        // (1 << contextIndex). Drain every signalled context, not just context 0;
        // the secondary's ring would otherwise fill without ever being polled and
        // its channel slice (e.g. 17–32) would never reach the input buffer.
        // Poll the master first so the producer timeline is published before the
        // secondary slices anchor to it.
        const uint32_t recvEvent = events.receive;
        std::array<std::shared_ptr<ASFW::Isoch::IsochReceiveContext>,
                   IsochService::kMaxStreamsPerDirection> receiveOwners{};
        for (uint32_t index = 0; index < receiveOwners.size(); ++index) {
            if ((recvEvent & (1u << index)) != 0) {
                receiveOwners[index] = isoch.CopyReceiveContext(index);
            }
        }
        // Capture the exact contexts, never a borrowed ServiceContext member.
        // A late queued poll sees the old stopped context after a rebuild.
        workQueue.DispatchAsync(^{
          for (const auto& rx : receiveOwners) {
              if (rx) rx->Poll();
          }
        });
    }

    // ===== ISOCHRONOUS TRANSMIT INTERRUPT =====
    // Per OHCI §9.2: kIsochTx (bit 6) indicates IT context completion.
    // Similar to IR, we read IsoXmitEvent, clear it, and process.
    if ((snap.intEvent & IntEventBits::kIsochTx) && events.transmit != 0) {
        // DEBUG: Sample interrupt rate
        static uint32_t txIrqCtr = 0;
        if ((++txIrqCtr % 100) == 0) {
            ASFW_LOG_V3(Controller, "[IRQ] IsoTx Fired! Count=%u IsoTxEvent=0x%08x", txIrqCtr,
                        events.transmit);
        }

        // Clear event bits to acknowledge
        // Already acknowledged by TakeIsochContextEvents.

        // One OHCI IT context backs each playback stream (contextIndex ==
        // streamIndex). A multi-stream DICE device (Venice F32 = 2×16) runs a
        // master (context 0) plus secondary contexts (event bit 1 << contextIndex).
        // Process every signalled context directly in ISR for lowest latency
        // (IT RefillRing is fast; DispatchAsync would add underrun-prone latency).
        for (uint32_t ctxIdx = 0; ctxIdx < IsochService::kMaxStreamsPerDirection; ++ctxIdx) {
            if ((events.transmit & (1u << ctxIdx)) == 0) {
                continue;
            }
            if (auto* tx = isoch.TransmitContext(ctxIdx)) {
                tx->HandleInterrupt();
            }
        }
    }

    if (snap.intEvent != 0) {
        const uint32_t asyncMask = IntEventBits::kReqTxComplete | IntEventBits::kRespTxComplete |
                                   IntEventBits::kARRQ | IntEventBits::kARRS |
                                   IntEventBits::kRQPkt | IntEventBits::kRSPkt;
        if (snap.intEvent & asyncMask) {
            statusPublisher.SetLastAsyncCompletion(mach_absolute_time());
        }

        SharedStatusReason reason = SharedStatusReason::Interrupt;
        if (snap.intEvent & IntEventBits::kBusReset) {
            reason = SharedStatusReason::BusReset;
        } else if (snap.intEvent & asyncMask) {
            reason = SharedStatusReason::AsyncActivity;
        } else if (snap.intEvent & IntEventBits::kUnrecoverableError) {
            reason = SharedStatusReason::Interrupt;
        }

        statusPublisher.Publish(&controller, asyncSubsystem, reason, snap.intEvent);
    }
}

} // namespace ASFW::Driver
