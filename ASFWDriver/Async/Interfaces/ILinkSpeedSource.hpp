// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Rewind Digital, LLC

#pragma once

#include <optional>

#include "../../Common/FWTypes.hpp"

namespace ASFW::Async {

/**
 * Supplies link-speed evidence proven by a successful transaction in one bus
 * generation.
 *
 * Self-ID speed is an advertised ceiling. Discovery may probe below that
 * ceiling, but a timeout-selected fallback is not success evidence. Consumers
 * therefore receive only a speed at which the generation-pinned Config-ROM
 * scan actually completed. The generation parameter prevents a late callback
 * from an earlier topology from constraining a node ID that has been reused.
 */
class ILinkSpeedSource {
  public:
    virtual ~ILinkSpeedSource() = default;

    [[nodiscard]] virtual std::optional<FW::FwSpeed>
    SuccessfulSpeed(FW::Generation generation, FW::NodeId nodeId) const noexcept = 0;
};

} // namespace ASFW::Async
