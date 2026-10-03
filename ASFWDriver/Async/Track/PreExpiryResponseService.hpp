// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstddef>
#include <utility>

namespace ASFW::Async {

[[nodiscard]] constexpr bool CanServiceResponsesBeforeTimeout(
    bool isRunning, bool busResetInProgress) noexcept {
    return isRunning && !busResetInProgress;
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
