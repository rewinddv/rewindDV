// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#pragma once

#include <cstddef>
#include <cstdint>
#include <atomic>

#include "../ResponseCode.hpp"
#include "../Rx/PacketRouter.hpp"

namespace ASFW::Async {

class DescriptorBuilder;
class ATResponseContext;
class IFireWireBusInfo;
namespace Bus { class GenerationTracker; }
namespace Engine { class ContextManager; }
namespace Tx { class Submitter; }

/// Utility to build and send Write Response (WrResp) packets for incoming AR requests.
class ResponseSender {
public:
    ResponseSender(DescriptorBuilder& builder,
                   Tx::Submitter& submitter,
                   Engine::ContextManager& ctxMgr,
                   Bus::GenerationTracker& generationTracker) noexcept;

#if defined(ASFW_HOST_TEST)
    // Host-only seam: exercise the real public response methods and
    // SendResponse header/descriptor construction without an AT controller.
    using HostSubmitCapture = void (*)(const void* firstDescriptor,
                                       uint8_t descriptorBlocks,
                                       void* context) noexcept;
    ResponseSender(DescriptorBuilder& builder,
                   HostSubmitCapture capture,
                   void* captureContext) noexcept;
#endif

    /// Build and transmit a WrResp for the given request packet.
    /// Skips transmission for broadcast requests (destID=0xFFFF).
    void SendWriteResponse(const ARPacketView& request, ResponseCode rcode) noexcept;

    /// Build and transmit a Read Quadlet Response (tCode 0x6).
    void SendReadQuadletResponse(const ARPacketView& request,
                                 ResponseCode rcode,
                                 uint32_t quadletData) noexcept;

    /// Build and transmit a Read Block Response (tCode 0x7).
    void SendReadBlockResponse(const ARPacketView& request,
                               ResponseCode rcode,
                               uint64_t payloadDeviceAddress,
                               uint32_t payloadLength) noexcept;

    /// Build and transmit a Lock Response (tCode 0xB) for compare-swap requests.
    void SendLockResponse(const ARPacketView& request,
                          ResponseCode rcode,
                          uint32_t oldValue) noexcept;

private:
    struct ScratchRegion {
        std::byte* base{nullptr};
        uint64_t deviceBase{0};
        uint32_t slotCount{0};
        std::atomic<uint32_t> nextSlot{0};
    };

    void SendResponse(const ARPacketView& request,
                      ResponseCode rcode,
                      uint8_t responseTCode,
                      uint32_t* header,
                      std::size_t headerBytes,
                      uint64_t payloadDeviceAddress,
                      std::size_t payloadLength) noexcept;

    DescriptorBuilder& builder_;
    Tx::Submitter* submitter_{nullptr};
    Engine::ContextManager* ctxMgr_{nullptr};
    Bus::GenerationTracker* generationTracker_{nullptr};
    ScratchRegion lockResponseScratch_;
    // One queued proof per supported speed (maximum four records per driver
    // lifetime), so mixed-speed decks remain observable without hot-path spam.
    std::atomic<uint8_t> responseHeaderProofSpeedMask_{0};
#if defined(ASFW_HOST_TEST)
    HostSubmitCapture hostSubmitCapture_{nullptr};
    void* hostSubmitCaptureContext_{nullptr};
#endif
};

} // namespace ASFW::Async
