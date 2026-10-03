// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
#pragma once

#include "../ForwardDecls.hpp"
#include "../Track/Tracking.hpp"
#include "../Track/CompletionQueue.hpp"
#include "../../Debug/BusResetPacketCapture.hpp"
#include "../Contexts/ARRequestContext.hpp"
#include "../Contexts/ARResponseContext.hpp"
#include "PacketRouter.hpp"
#include "ARPacketParser.hpp"
#include "ARStreamProcessor.hpp"
#include "../../Hardware/OHCIEventCodes.hpp"
#include "../../Bus/GenerationTracker.hpp"

#include <optional>

namespace ASFW::Async::Rx {

// Define the concrete Tracking type alias for clarity
using TrackingActor = Track_Tracking<CompletionQueue>;

class RxPath {
public:
    // Constructor takes references to all the actors it collaborates with.
    RxPath(ARRequestContext& arReqContext,
           ARResponseContext& arRespContext,
           TrackingActor& tracking,
           ASFW::Async::Bus::GenerationTracker& generationTracker,
           PacketRouter& packetRouter);

    // This single method will be called by the engine on an RX interrupt.
    void ProcessARInterrupts(bool isRunning,
                             Debug::BusResetPacketCapture* busResetCapture);

    // Same-workloop response-only service used immediately before timeout
    // finalization. It processes only bytes already present in ARRsp DMA.
    [[nodiscard]] ARStreamStats
    ProcessResponseInterrupts(bool isRunning,
                              Debug::BusResetPacketCapture* busResetCapture,
                              std::optional<uint32_t> maxBuffers = std::nullopt);

    [[nodiscard]] uint32_t ResponseBufferCount() const noexcept {
        return static_cast<uint32_t>(arResponseContext_.GetBufferRing().BufferCount());
    }

private:
    void ProcessRequestInterrupts();
    void DumpRequestBuffer(uint32_t buffersProcessed,
                           const uint8_t* bufferStart,
                           size_t bufferSize) const;
    void DumpResponseInterruptState(ARResponseContext& ctx) const;
    void LogResponseNewData(const uint8_t* newDataStart,
                            size_t startOffset,
                            size_t bufferSize) const;
    void DumpEmptyResponseBuffer(ARResponseContext& ctx) const;

    // Private helper to process a single parsed packet.
    void ProcessReceivedPacket(ARContextType contextType,
                               const ARPacketParser::PacketInfo& info,
                               Debug::BusResetPacketCapture* busResetCapture);

    // Handle synthetic bus reset packet
    void HandleSyntheticBusResetPacket(const ARPacketView& view,
                                       uint8_t newGeneration,
                                       Debug::BusResetPacketCapture* busResetCapture);

    // References to collaborators (owned by the engine).
    ARRequestContext& arRequestContext_;
    ARResponseContext& arResponseContext_;
    TrackingActor& tracking_;
    ASFW::Async::Bus::GenerationTracker& generationTracker_;
    PacketRouter& packetRouter_;

    // Lifetime count of dequeued AR request buffers, drives the [ARReq] heartbeat.
    uint64_t requestBuffersSeen_ = 0;

    // Handle synthetic / general PHY packets coming via PacketRouter
    void HandlePhyRequestPacket(const ARPacketView& view);

    // Current bus-reset capture target for this interrupt pass
    Debug::BusResetPacketCapture* currentBusResetCapture_ = nullptr;
};

} // namespace ASFW::Async::Rx
