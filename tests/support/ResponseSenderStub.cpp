#include "ASFWDriver/Async/Tx/ResponseSender.hpp"

namespace ASFW::Async {

ResponseSender::ResponseSender(DescriptorBuilder& builder,
                               Tx::Submitter& submitter,
                               Engine::ContextManager& ctxMgr,
                               Bus::GenerationTracker& generationTracker) noexcept
    : builder_(builder)
    , submitter_(&submitter)
    , ctxMgr_(&ctxMgr)
    , generationTracker_(&generationTracker) {}

ResponseSender::WriteDisposition ResponseSender::SendWriteResponse(const ARPacketView& request, ResponseCode rcode) noexcept {
    // No response was submitted by this unrelated routing-test stub.
    (void)request;
    (void)rcode;
    return WriteDisposition::Failed;
}

void ResponseSender::SendReadQuadletResponse(const ARPacketView& request,
                                             ResponseCode rcode,
                                             uint32_t quadletData) noexcept {
    (void)request;
    (void)rcode;
    (void)quadletData;
}

void ResponseSender::SendReadBlockResponse(const ARPacketView& request,
                                           ResponseCode rcode,
                                           uint64_t payloadDeviceAddress,
                                           uint32_t payloadLength) noexcept {
    (void)request;
    (void)rcode;
    (void)payloadDeviceAddress;
    (void)payloadLength;
}

void ResponseSender::SendLockResponse(const ARPacketView& request,
                                      ResponseCode rcode,
                                      uint32_t oldValue) noexcept {
    (void)request;
    (void)rcode;
    (void)oldValue;
}

ResponseSender::WriteDisposition ResponseSender::SendResponse(const ARPacketView& request,
                                  ResponseCode rcode,
                                  uint8_t responseTCode,
                                  uint32_t* header,
                                  std::size_t headerBytes,
                                  uint64_t payloadDeviceAddress,
                                  std::size_t payloadLength) noexcept {
    (void)request;
    (void)rcode;
    (void)responseTCode;
    (void)header;
    (void)headerBytes;
    (void)payloadDeviceAddress;
    (void)payloadLength;
    return WriteDisposition::Failed;
}

} // namespace ASFW::Async
