// Copyright 2026 Rewind Digital, LLC
// Copyright (c) 2024 ASFireWire Project
// SPDX-License-Identifier: Apache-2.0
// Extracted and modified from ASFireWire Service/LocalRequestWiring.cpp.
//
// FCPInboundLocalHandler.hpp — byte-preserving local FCP command/response writes.

#pragma once

#include "../Async/Rx/LocalRequestDispatch.hpp"
#include "../Hardware/IEEE1394.hpp"
#include "../Protocols/AVC/FCPResponseRouter.hpp"

#include <span>

namespace ASFW::Service::Detail {

// Both block writes and quadlet writes must be handled: short AV/C responses
// arrive as quadlet writes (tCode 0x0) to the FCP response register. This class
// is separate from the service assembly so the production byte path can be
// exercised by a standalone native regression.
class FCPInboundLocalHandler final : public Async::ILocalAddressHandler {
public:
    explicit FCPInboundLocalHandler(Protocols::AVC::FCPResponseRouter* fcp) noexcept
        : fcp_(fcp) {}

    [[nodiscard]] const char* Name() const noexcept override { return "FCP"; }

    [[nodiscard]] Async::LocalRequestResult
    HandleLocalRequest(const Async::LocalRequestContext& ctx) override {
        using AReq = Async::HW::AsyncRequestHeader;
        if (fcp_ == nullptr) {
            return Async::LocalRequestResult::NotMine();
        }

        if (ctx.tCode == AReq::kTcodeWriteBlock) {
            if (ctx.writePayload.empty()) {
                return Async::LocalRequestResult::NotMine();
            }
            return Route(ctx, ctx.writePayload);
        }

        if (ctx.tCode == AReq::kTcodeWriteQuad) {
            // The fourth AR-request quadlet is the byte-exact FCP data field.
            // Rebuilding it from the numeric scalar reverses the physical Sony
            // response 09 20 C3 75 into 75 C3 20 09.
            if (ctx.writePayload.size() != 4) {
                return Async::LocalRequestResult::Write(Async::ResponseCode::TypeError);
            }
            return Route(ctx, ctx.writePayload);
        }

        return Async::LocalRequestResult::NotMine();
    }

private:
    [[nodiscard]] Async::LocalRequestResult
    Route(const Async::LocalRequestContext& ctx, std::span<const uint8_t> payload) {
        const Protocols::Ports::BlockWriteRequestView request{
            .sourceID = ctx.sourceID,
            .destOffset = ctx.destOffset,
            .generation = ctx.generation,
            .payload = payload,
        };
        const auto disposition = fcp_->RouteBlockWrite(request);
        if (disposition == Protocols::Ports::BlockWriteDisposition::kAddressError) {
            return Async::LocalRequestResult::NotMine();
        }
        return Async::LocalRequestResult::Write(Async::ResponseCode::Complete);
    }

    Protocols::AVC::FCPResponseRouter* fcp_;
};

} // namespace ASFW::Service::Detail
