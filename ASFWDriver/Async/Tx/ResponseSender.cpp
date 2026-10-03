// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#include <DriverKit/IOLib.h>
#include "ResponseSender.hpp"

#include <DriverKit/IOLib.h>
#include "../Engine/ContextManager.hpp"
#include <DriverKit/IOLib.h>
#include "../Contexts/ATResponseContext.hpp"
#include <DriverKit/IOLib.h>
#include "../PacketHelpers.hpp"
#include <DriverKit/IOLib.h>
#include "DescriptorBuilder.hpp"
#include "ATResponseHeader.hpp"
#include <DriverKit/IOLib.h>
#include "Submitter.hpp"
#include <DriverKit/IOLib.h>
#include "../../Bus/GenerationTracker.hpp"
#include <DriverKit/IOLib.h>
#include "../../Logging/Logging.hpp"

#include <DriverKit/IOLib.h>
#include <DriverKit/IOReturn.h>

#include <DriverKit/IOLib.h>
#include <bit>
#include <DriverKit/IOLib.h>
#include <cstring>
#include <DriverKit/IOLib.h>
#include <utility>

namespace ASFW::Async {

namespace {

constexpr std::size_t kLockResponseScratchSlots = 64;
constexpr std::size_t kLockResponseScratchStride = 16;

uint32_t BuildQ1(uint16_t destID, ResponseCode rcode) {
    return (static_cast<uint32_t>(destID) << 16) |
           (static_cast<uint32_t>(static_cast<uint8_t>(rcode) & 0x0F) << 12);
}

// Split-timeout deadline for the response: request arrival timestamp
// (3-bit seconds, 13-bit cycle) plus the split timeout. The AT response
// context drops packets whose deadline has passed (evt_timeout) without
// transmitting them, so this MUST be a real future time — a zero timeStamp
// is "expired" for most of the 8-second wrap window. Mirrors Linux
// compute_split_timeout_timestamp (core-transaction.c) with the same
// 2-second default (core-card.c DEFAULT_SPLIT_TIMEOUT).
constexpr uint32_t kSplitTimeoutCycles = 2 * 8000;

uint16_t ComputeResponseDeadline(uint16_t requestTimeStamp) {
    const uint32_t cycles = kSplitTimeoutCycles + (requestTimeStamp & 0x1FFFu);
    uint32_t deadline = requestTimeStamp & ~0x1FFFu;
    deadline += (cycles / 8000u) << 13;
    deadline |= cycles % 8000u;
    return static_cast<uint16_t>(deadline);
}

} // namespace

ResponseSender::ResponseSender(DescriptorBuilder& builder,
                               Tx::Submitter& submitter,
                               Engine::ContextManager& ctxMgr,
                               Bus::GenerationTracker& generationTracker) noexcept
    : builder_(builder)
    , submitter_(&submitter)
    , ctxMgr_(&ctxMgr)
    , generationTracker_(&generationTracker) {
    if (auto* dma = ctxMgr_->DmaManager()) {
        const auto region =
            dma->AllocateRegion(kLockResponseScratchSlots * kLockResponseScratchStride,
                                kLockResponseScratchStride);
        if (region.has_value()) {
            lockResponseScratch_.base = reinterpret_cast<std::byte*>(region->virtualBase);
            lockResponseScratch_.deviceBase = region->deviceBase;
            lockResponseScratch_.slotCount =
                static_cast<uint32_t>(region->size / kLockResponseScratchStride);
        }
    }
}

#if defined(ASFW_HOST_TEST)
ResponseSender::ResponseSender(DescriptorBuilder& builder,
                               HostSubmitCapture capture,
                               void* captureContext) noexcept
    : builder_(builder)
    , hostSubmitCapture_(capture)
    , hostSubmitCaptureContext_(captureContext) {}
#endif

void ResponseSender::SendResponse(const ARPacketView& request,
                                  ResponseCode rcode,
                                  uint8_t responseTCode,
                                  uint32_t* header,
                                  std::size_t headerBytes,
                                  uint64_t payloadDeviceAddress,
                                  std::size_t payloadLength) noexcept {
    // Per IEEE 1394, broadcast requests (destID=0xFFFF) do not get responses.
    if (request.destID == 0xFFFF) {
        ASFW_LOG_V3(Async, "ResponseSender: skip response for broadcast destID=0xFFFF");
        return;
    }

    const auto q0 = Tx::ATResponseHeader::Build(
        request.xferStatus,
        static_cast<uint8_t>(request.tLabel & 0x3F),
        responseTCode);
    if (!q0.valid) {
        if (q0.eventCode != Tx::ATResponseHeader::kAckPendingEvent) {
            ASFW_LOG_V2(Async,
                        "ResponseSender: no response required for receive event=0x%02x "
                        "(xferStatus=0x%04x tCode=0x%x tLabel=%u)",
                        q0.eventCode,
                        request.xferStatus,
                        responseTCode,
                        static_cast<unsigned>(request.tLabel & 0x3F));
        } else {
            ASFW_LOG_ERROR(Async,
                           "ResponseSender: reject response for unsupported receive speed=%u "
                           "(xferStatus=0x%04x tCode=0x%x tLabel=%u)",
                           q0.speedCode,
                           request.xferStatus,
                           responseTCode,
                           static_cast<unsigned>(request.tLabel & 0x3F));
        }
        return;
    }

    // Callers own fixed-size local header arrays. Patch Q0 only after the AR
    // receive metadata has been validated so no descriptor can be built or
    // submitted with a fabricated speed.
    header[0] = q0.value;

    ATResponseContext* atRspCtx = nullptr;
#if defined(ASFW_HOST_TEST)
    if (!hostSubmitCapture_) {
#endif
        atRspCtx = ctxMgr_ ? ctxMgr_->GetAtResponseContext() : nullptr;
        if (!atRspCtx || !submitter_) {
            ASFW_LOG_ERROR(Async,
                           "ResponseSender: ATResponseContext unavailable, cannot send response");
            return;
        }
#if defined(ASFW_HOST_TEST)
    }
#endif

    // BuildTransactionChain takes the header as a byte span; reinterpret the
    // host-order quadlet buffer the same way AsyncCommandImpl/SendWriteResponse do.
    auto chain = builder_.BuildTransactionChain(
        reinterpret_cast<const uint8_t*>(header),
        headerBytes,
        payloadDeviceAddress,
        payloadLength,
        /*needsFlush*/ false,
        ComputeResponseDeadline(static_cast<uint16_t>(request.timeStamp)));
    if (chain.Empty()) {
        ASFW_LOG_ERROR(
            Async,
            "ResponseSender: failed to build response chain (tCode=0x%x payload=%zu)",
            responseTCode,
            payloadLength);
        return;
    }

#if defined(ASFW_HOST_TEST)
    if (hostSubmitCapture_) {
        hostSubmitCapture_(chain.first, chain.TotalBlocks(), hostSubmitCaptureContext_);
        return;
    }
#endif

    const auto submitRes = submitter_->submit_tx_chain(atRspCtx, std::move(chain));
    if (submitRes.kr != kIOReturnSuccess) {
        ASFW_LOG_ERROR(
            Async,
            "ResponseSender: submit_tx_chain failed (tCode=0x%x kr=0x%x)",
            responseTCode,
            submitRes.kr);
        return;
    }

    const uint8_t proofBit = static_cast<uint8_t>(1u << q0.speedCode);
    const uint8_t priorProofMask =
        responseHeaderProofSpeedMask_.fetch_or(proofBit, std::memory_order_relaxed);
    if ((priorProofMask & proofBit) == 0) {
        ASFW_LOG(
            Async,
            "AT_RESPONSE_HEADER_QUEUED_PROOF src=0x%04x dst=0x%04x tLabel=%u tCode=0x%x "
            "inXferStatus=0x%04x inEvent=0x%02x inSpeed=%u "
            "outQ0=0x%08x outSpeed=%u outRetry=%u",
            request.sourceID,
            request.destID,
            static_cast<unsigned>(request.tLabel & 0x3F),
            responseTCode,
            request.xferStatus,
            q0.eventCode,
            q0.speedCode,
            q0.value,
            static_cast<unsigned>((q0.value >> 16) & 0x07),
            static_cast<unsigned>((q0.value >> 8) & 0x03));
    }

    ASFW_LOG_V2(
        Async,
        "ResponseSender: response queued (tCode=0x%x tLabel=%u dst=0x%04x rcode=0x%x payload=%zu)",
        responseTCode,
        static_cast<unsigned>(request.tLabel & 0x3F),
        request.sourceID,
        static_cast<unsigned>(rcode),
        payloadLength);
}

void ResponseSender::SendWriteResponse(const ARPacketView& request, ResponseCode rcode) noexcept {
    // Only write requests (quadlet/block) receive a WrResp.
    if (request.tCode != 0x0 && request.tCode != 0x1) {
        ASFW_LOG_V3(Async, "ResponseSender: skip WrResp for non-write tCode=0x%x", request.tCode);
        return;
    }

    uint32_t header[3]{};
    header[1] = BuildQ1(request.sourceID, rcode);
    header[2] = 0;

    SendResponse(request,
                 rcode,
                 /*responseTCode*/ 0x2,
                 header,
                 sizeof(header),
                 /*payloadDeviceAddress*/ 0,
                 /*payloadLength*/ 0);
}

void ResponseSender::SendReadQuadletResponse(const ARPacketView& request,
                                             ResponseCode rcode,
                                             uint32_t quadletData) noexcept {
    if (request.tCode != 0x4) {
        ASFW_LOG_V3(Async,
                    "ResponseSender: skip RdQuadResp for non-read-quadlet tCode=0x%x",
                    request.tCode);
        return;
    }

    uint32_t header[4]{};
    header[1] = BuildQ1(request.sourceID, rcode);
    header[2] = 0;
    header[3] = (rcode == ResponseCode::Complete) ? quadletData : 0;

    SendResponse(request,
                 rcode,
                 /*responseTCode*/ 0x6,
                 header,
                 sizeof(header),
                 /*payloadDeviceAddress*/ 0,
                 /*payloadLength*/ 0);
}

void ResponseSender::SendReadBlockResponse(const ARPacketView& request,
                                           ResponseCode rcode,
                                           uint64_t payloadDeviceAddress,
                                           uint32_t payloadLength) noexcept {
    if (request.tCode != 0x5) {
        ASFW_LOG_V3(Async,
                    "ResponseSender: skip RdBlockResp for non-read-block tCode=0x%x",
                    request.tCode);
        return;
    }

    uint32_t header[4]{};
    header[1] = BuildQ1(request.sourceID, rcode);
    header[2] = 0;

    std::size_t responsePayloadLen = 0;
    uint64_t responsePayloadAddress = 0;

    if (rcode == ResponseCode::Complete && payloadLength > 0) {
        header[3] = static_cast<uint32_t>(payloadLength) << 16;
        responsePayloadLen = payloadLength;
        responsePayloadAddress = payloadDeviceAddress;
    } else {
        header[3] = 0;
    }

    SendResponse(request,
                 rcode,
                 /*responseTCode*/ 0x7,
                 header,
                 sizeof(header),
                 responsePayloadAddress,
                 responsePayloadLen);
}

void ResponseSender::SendLockResponse(const ARPacketView& request,
                                      ResponseCode rcode,
                                      uint32_t oldValue) noexcept {
    if (request.tCode != 0x9) {
        ASFW_LOG_V3(Async,
                    "ResponseSender: skip LockResp for non-lock tCode=0x%x",
                    request.tCode);
        return;
    }

    const uint16_t extTCode = ExtractExtendedTCode(request.header);
    uint32_t header[4]{};
    header[1] = BuildQ1(request.sourceID, rcode);
    header[2] = 0;

    uint64_t payloadAddress = 0;
    std::size_t payloadLength = 0;
    ResponseCode responseCode = rcode;

    if (rcode == ResponseCode::Complete) {
        if (lockResponseScratch_.base == nullptr || lockResponseScratch_.slotCount == 0) {
            ASFW_LOG_ERROR(Async, "ResponseSender: no DMA scratch for lock response payload");
            responseCode = ResponseCode::Busy;
            header[1] = BuildQ1(request.sourceID, responseCode);
        } else if (auto* dma = ctxMgr_ ? ctxMgr_->DmaManager() : nullptr) {
            const uint32_t slot =
                lockResponseScratch_.nextSlot.fetch_add(1u, std::memory_order_relaxed) %
                lockResponseScratch_.slotCount;
            auto* slotBase = lockResponseScratch_.base +
                             static_cast<std::size_t>(slot) * kLockResponseScratchStride;
            const uint32_t oldValueBE = OSSwapHostToBigInt32(oldValue);
            std::memcpy(slotBase, &oldValueBE, sizeof(oldValueBE));
            dma->PublishRange(slotBase, sizeof(oldValueBE));

            payloadAddress = lockResponseScratch_.deviceBase +
                             static_cast<uint64_t>(slot) * kLockResponseScratchStride;
            payloadLength = sizeof(oldValueBE);
            header[3] = (static_cast<uint32_t>(payloadLength) << 16) |
                        static_cast<uint32_t>(extTCode);
        } else {
            responseCode = ResponseCode::Busy;
            header[1] = BuildQ1(request.sourceID, responseCode);
        }
    }

    SendResponse(request,
                 responseCode,
                 /*responseTCode*/ 0xB,
                 header,
                 sizeof(header),
                 payloadAddress,
                 payloadLength);
}

} // namespace ASFW::Async
