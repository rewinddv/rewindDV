// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "../FoundationDriverPolicy.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <iostream>
#include <utility>
namespace P = RewindDV::Foundation::DriverPolicy;
int main() {
    const auto medium = P::InspectorCommandFrame(P::InspectorQuery::kTapeMediumInfo, 0);
    const auto state = P::InspectorCommandFrame(P::InspectorQuery::kTapeTransportState, 0);
    assert((medium == std::array<uint8_t,8>{1,0x20,0xDA,0x7F,0x7F,0,0,0}));
    assert((state == std::array<uint8_t,8>{1,0x20,0xD0,0x7F,0,0,0,0}));
    assert(P::InspectorCommandLength(P::InspectorQuery::kTapeMediumInfo) == 5);
    assert(P::InspectorCommandLength(P::InspectorQuery::kTapeTransportState) == 4);
    assert(!P::IsExactPermittedFrame(std::span(medium).first(5)));
    assert(!P::IsExactPermittedFrame(std::span(state).first(4)));
    P::InspectorRequestWire r{};
    r.operationID=1; r.attemptID=2; r.guid=3; r.driverInstanceID=4;
    r.deviceIncarnation=5; r.routeEpoch=6; r.nodeID=1;
    for (uint8_t q = 4; q <= 7; ++q) {
        r.query=q; assert(P::IsValidInspectorRequest(r));
        r.subunitPage=1; assert(!P::IsValidInspectorRequest(r)); r.subunitPage=0;
        r.reserved[0]=1; assert(!P::IsValidInspectorRequest(r)); r.reserved[0]=0;
    }
    for (unsigned q=8; q<=255; ++q) { r.query=q; assert(!P::IsValidInspectorRequest(r)); }
    using C = P::InspectorResponseClassification;
    const auto atnQuery = P::InspectorQuery::kTapeAbsoluteTrackNumber;
    const auto atn = P::InspectorCommandFrame(atnQuery, 0);
    assert((atn == std::array<uint8_t,8>{1,0x20,0x52,0x71,255,255,255,255}));
    assert(P::InspectorCommandLength(atnQuery) == 8);
    assert(!P::IsExactPermittedFrame(atn));
    std::array<uint8_t,8> atnReply{12,0x20,0x52,0x71,3,0,0,255};
    assert(P::ClassifyInspectorResponse(atnQuery,0,atnReply) == C::kImplementedStable);
    assert(P::DecodeInspectorResponse(atnQuery,0,atnReply).validFields == 0);
    for (size_t n=0; n<8; ++n)
        assert(P::ClassifyInspectorResponse(atnQuery,0,std::span(atnReply).first(n)) == C::kMismatch);
    for (size_t i : {1,2,3}) {
        auto bad=atnReply; bad[i]^=1;
        assert(P::ClassifyInspectorResponse(atnQuery,0,bad) == C::kMismatch);
    }
    std::array<uint8_t,9> oversized{};
    std::copy(atnReply.begin(), atnReply.end(), oversized.begin());
    assert(P::ClassifyInspectorResponse(atnQuery,0,oversized) == C::kMismatch);
    for (const auto [code, expected] : std::array<std::pair<uint8_t,C>,4>{{
        {8,C::kNotImplemented}, {10,C::kRejected},
        {11,C::kInTransitionInvalidForQuery}, {9,C::kAcceptedInvalidForStatus}}}) {
        auto other=atnReply; other[0]=code;
        assert(P::ClassifyInspectorResponse(atnQuery,0,other) == expected);
        assert(P::DecodeInspectorResponse(atnQuery,0,other).validFields == 0);
    }
    for (uint8_t opcode : {0xC1,0xC2,0xC3,0xC4}) {
        std::array<uint8_t,4> response{0x0C,0x20,opcode,0x60};
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response) == C::kImplementedStable);
        assert(P::DecodeInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response).validFields == 0);
        response[0]=0x0B;
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response) == C::kInTransitionInvalidForQuery);
        response[0]=0x09;
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response) == C::kMismatch);
        response[2]=0xD0;
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response) == C::kAcceptedInvalidForStatus);
        response[1]=0x21;
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,response) == C::kMismatch);
    }
    for (uint8_t code : {0x0C,0x0B}) {
        const std::array<uint8_t,4> echoed{code,0x20,0xD0,0x60};
        assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeTransportState,0,echoed) == C::kMismatch);
    }
    std::array<uint8_t,5> response{0x0C,0x20,0xDA,0x7F,0x7F};
    assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeMediumInfo,0,response) == C::kImplementedStable);
    assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeMediumInfo,0,std::span(response).first(4)) == C::kMismatch);
    response[0]=0x08;
    assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeMediumInfo,0,response) == C::kNotImplemented);
    response[2]=0xD0;
    assert(P::ClassifyInspectorResponse(P::InspectorQuery::kTapeMediumInfo,0,response) == C::kMismatch);
    const auto timeCodeQuery = P::InspectorQuery::kTapeTimeCode;
    const auto timeCode = P::InspectorCommandFrame(timeCodeQuery, 0);
    assert((timeCode == std::array<uint8_t,8>{1,0x20,0x51,0x71,255,255,255,255}));
    assert(P::InspectorCommandLength(timeCodeQuery) == 8);
    assert(P::kTapeTimeCodeResponseDeadlineMs == 250);
    assert(!P::IsExactPermittedFrame(timeCode));
    std::array<uint8_t,8> timeCodeReply{0x0C,0x20,0x51,0x71,0x12,0x34,0x56,0x07};
    assert(P::ClassifyInspectorResponse(timeCodeQuery,0,timeCodeReply) == C::kImplementedStable);
    assert(P::DecodeInspectorResponse(timeCodeQuery,0,timeCodeReply).validFields == 0);
    timeCodeReply[4]=0x7F;
    timeCodeReply[5]=timeCodeReply[6]=timeCodeReply[7]=0xFF;
    assert(P::ClassifyInspectorResponse(timeCodeQuery,0,timeCodeReply) == C::kImplementedStable);
    timeCodeReply={0x0C,0x20,0x51,0x71,0x1A,0x34,0x56,0x07};
    assert(P::ClassifyInspectorResponse(timeCodeQuery,0,timeCodeReply) == C::kOtherTerminal);
    timeCodeReply={0x08,0x20,0x51,0x71,255,255,255,255};
    assert(P::ClassifyInspectorResponse(timeCodeQuery,0,timeCodeReply) == C::kNotImplemented);
    timeCodeReply[2]=0x52;
    assert(P::ClassifyInspectorResponse(timeCodeQuery,0,timeCodeReply) == C::kMismatch);
    // The outbound motion/control catalog is unchanged; RECORD remains absent.
    for (uint32_t cmd=7; cmd<256; ++cmd) assert(!P::IsPermittedDeckCommand(static_cast<P::DeckCommand>(cmd)));
    std::cout << "TAPE_STATE_EXACT_STATUS_LENGTH_CORRELATION_AND_NO_WRITING_PASS\n";
}
