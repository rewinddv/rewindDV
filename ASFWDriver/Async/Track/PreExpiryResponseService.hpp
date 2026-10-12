// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstddef>
#include "../../Hardware/RegisterMap.hpp"
#include <utility>

namespace ASFW::Async {

[[nodiscard]] constexpr bool CanServiceResponsesBeforeTimeout(
    bool isRunning, bool busResetInProgress) noexcept {
    return isRunning && !busResetInProgress;
}

// An unprocessed reset/fault event is not a validated generation boundary.
// Raw hardware evidence is required even if software has not received its IRQ.
[[nodiscard]] constexpr bool CanServiceReceiveBeforeTimeout(
    bool isRunning, bool busResetInProgress, bool eventsAvailable, uint32_t events) noexcept {
    using Driver::IntEventBits;
    constexpr uint32_t unsafe = IntEventBits::kBusReset | IntEventBits::kSelfIDComplete |
        IntEventBits::kSelfIDComplete2 | IntEventBits::kUnrecoverableError |
        IntEventBits::kRegAccessFail | IntEventBits::kPostedWriteErr;
    return CanServiceResponsesBeforeTimeout(isRunning, busResetInProgress) &&
        eventsAvailable && events != UINT32_MAX && (events & unsafe) == 0;
}

// The watchdog and IRQ callbacks share the driver's serialized workloop. When
// a transaction reaches its deadline, service response bytes already in ARRsp
// before allowing timeout policy to extend or finalize it. This performs no
// remote access and never resubmits the transaction.
template <typename ExpiredRange, typename DrainResponses, typename ApplyTimeouts>
auto ServiceResponsesBeforeTimeout(const ExpiredRange& expired,
                                   DrainResponses&& drainResponses,
                                   ApplyTimeouts&& applyTimeouts) {
    using DrainResult = decltype(std::forward<DrainResponses>(drainResponses)());
    DrainResult result{};
    if (!expired.empty()) {
        result = std::forward<DrainResponses>(drainResponses)();
    }
    std::forward<ApplyTimeouts>(applyTimeouts)(result);
    return result;
}

} // namespace ASFW::Async
