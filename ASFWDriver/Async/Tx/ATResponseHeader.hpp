// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
#pragma once

#include <cstdint>

namespace ASFW::Async::Tx::ATResponseHeader {

// OHCI 1.1 asynchronous receive xferStatus mirrors ContextControl[15:0].
// Bits [7:5] are the received packet speed for AR contexts. RewindDV's
// supported link-speed model is S100..S800 (codes 0..3); 4..7 are rejected
// instead of fabricating a response speed from malformed/out-of-model status.
constexpr uint8_t kReceiveSpeedShift = 5;
constexpr uint8_t kReceiveSpeedMask = 0x07;
constexpr uint8_t kMaxSupportedSpeedCode = 0x03;
constexpr uint8_t kEventMask = 0x1F;
constexpr uint8_t kAckPendingEvent = 0x12;

// IEEE 1394 response packets use RETRY_1 for their first transmission.
// Linux firewire-core fw_fill_response() uses the same value, while ordinary
// requests use RETRY_X.
constexpr uint8_t kRetry1 = 0x00;

struct Q0Result {
    uint32_t value{0};
    uint8_t speedCode{0};
    uint8_t eventCode{0};
    bool valid{false};
};

[[nodiscard]] constexpr uint8_t DecodeReceiveSpeed(uint16_t xferStatus) noexcept {
    return static_cast<uint8_t>((xferStatus >> kReceiveSpeedShift) & kReceiveSpeedMask);
}

[[nodiscard]] constexpr Q0Result Build(uint16_t requestXferStatus,
                                       uint8_t tLabel,
                                       uint8_t tCode) noexcept {
    constexpr uint8_t kSrcBusID = 0;
    constexpr uint8_t kPriority = 0;

    const uint8_t speedCode = DecodeReceiveSpeed(requestXferStatus);
    const uint8_t eventCode = static_cast<uint8_t>(requestXferStatus & kEventMask);
    if (eventCode != kAckPendingEvent) {
        return Q0Result{.speedCode = speedCode, .eventCode = eventCode};
    }
    if (speedCode > kMaxSupportedSpeedCode) {
        return Q0Result{.speedCode = speedCode, .eventCode = eventCode};
    }

    const uint32_t value =
        (static_cast<uint32_t>(kSrcBusID) << 23) |
        (static_cast<uint32_t>(speedCode) << 16) |
        (static_cast<uint32_t>(tLabel & 0x3Fu) << 10) |
        (static_cast<uint32_t>(kRetry1) << 8) |
        (static_cast<uint32_t>(tCode & 0x0Fu) << 4) |
        static_cast<uint32_t>(kPriority);
    return Q0Result{
        .value = value,
        .speedCode = speedCode,
        .eventCode = eventCode,
        .valid = true,
    };
}

} // namespace ASFW::Async::Tx::ATResponseHeader
