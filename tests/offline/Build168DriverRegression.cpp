// SPDX-License-Identifier: Apache-2.0

#include "ASFWDriver/Async/Track/PreExpiryResponseService.hpp"
#include "ASFWDriver/Bus/IRM/IRMTypes.hpp"
#include "ASFWDriver/ConfigROM/Common/ConfigROMPolicies.hpp"
#include "ASFWDriver/Controller/InterruptEventSequencer.hpp"
#include "ASFWDriver/Hardware/RegisterMap.hpp"

#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

using ASFW::Driver::IntEventBits;

struct CheckRunner {
    int failures{0};

    void Check(bool condition, const char* name) {
        std::printf("%s %s\n", condition ? "PASS" : "FAIL", name);
        if (!condition) ++failures;
    }
};

constexpr uint32_t kPreserved = IntEventBits::kBusReset |
                                IntEventBits::kSelfIDComplete |
                                IntEventBits::kSelfIDComplete2;

struct ResponseFixture {
    uint32_t latched{IntEventBits::kARRS};
    uint32_t unread{16};
    uint32_t drains{0};
    bool injectFollowup{true};

    void Service(uint32_t snapshot) {
        ASFW::Driver::InterruptEventSequencer::DispatchAndAcknowledge(
            snapshot, 0, kPreserved,
            [this](uint32_t events) {
                if ((events & IntEventBits::kARRS) == 0 || unread == 0) return;
                unread = 0;
                ++drains;
                if (injectFollowup) {
                    injectFollowup = false;
                    unread = 32;
                    latched |= IntEventBits::kARRS;
                }
            },
            [] {},
            [this](uint32_t mask) { latched &= ~mask; });
    }
};

struct DrainStats {
    uint32_t buffersProcessed{0};
    uint32_t packetsFound{0};
};

} // namespace

int main() {
    CheckRunner runner;

    ResponseFixture responses;
    responses.Service(responses.latched);
    const bool followupVisible = (responses.latched & IntEventBits::kARRS) != 0;
    if (followupVisible) responses.Service(responses.latched);
    runner.Check(followupVisible && responses.drains == 2 && responses.unread == 0,
                 "ordinary ARRsp event arriving during dispatch retains a wake");

    const uint32_t faultAcks = IntEventBits::kPostedWriteErr |
                               IntEventBits::kRegAccessFail |
                               IntEventBits::kUnrecoverableError;
    const uint32_t allEvents = IntEventBits::kARRS | kPreserved | faultAcks;
    std::vector<uint32_t> clearMasks;
    bool dispatchSawEarlyAck = false;
    bool afterDispatchRan = false;
    ASFW::Driver::InterruptEventSequencer::DispatchAndAcknowledge(
        allEvents, faultAcks, kPreserved,
        [&](uint32_t) {
            dispatchSawEarlyAck = clearMasks.size() == 1 &&
                                  clearMasks.front() == IntEventBits::kARRS;
        },
        [&] { afterDispatchRan = true; },
        [&](uint32_t mask) { clearMasks.push_back(mask); });
    runner.Check(dispatchSawEarlyAck && afterDispatchRan && clearMasks.size() == 2 &&
                     clearMasks[1] == faultAcks,
                 "reset and sticky events stay preserved while fault acks remain deferred");

    clearMasks.clear();
    bool emptyDispatched = false;
    bool emptyAfterRan = false;
    ASFW::Driver::InterruptEventSequencer::DispatchAndAcknowledge(
        0, 0, kPreserved, [&](uint32_t) { emptyDispatched = true; },
        [&] { emptyAfterRan = true; },
        [&](uint32_t mask) { clearMasks.push_back(mask); });
    runner.Check(emptyDispatched && emptyAfterRan && clearMasks.empty(),
                 "empty interrupt snapshot performs no W1C");

    std::vector<uint8_t> expired{7};
    bool pending = true;
    bool timedOut = false;
    uint32_t remoteSubmissions = 0;
    const auto lateStats = ASFW::Async::ServiceResponsesBeforeTimeout(
        expired,
        [&] {
            pending = false; // matching response completed from existing ARRsp bytes
            return DrainStats{1, 1};
        },
        [&](const DrainStats&) { timedOut = pending; });
    runner.Check(lateStats.packetsFound == 1 && !pending && !timedOut &&
                     remoteSubmissions == 0,
                 "late ARRsp completion wins before timeout without remote replay");

    pending = true;
    timedOut = false;
    ASFW::IRM::ResourceOwnership ownership = ASFW::IRM::ResourceOwnership::None;
    const auto emptyStats = ASFW::Async::ServiceResponsesBeforeTimeout(
        expired,
        [] { return DrainStats{}; },
        [&](const DrainStats&) {
            timedOut = pending;
            if (timedOut) {
                ownership = ASFW::IRM::ReleaseOwnershipAfter(
                    ASFW::IRM::AllocationStatus::Timeout);
            }
        });
    const bool quarantined = timedOut && ownership == ASFW::IRM::ResourceOwnership::Uncertain;
    runner.Check(emptyStats.packetsFound == 0 && quarantined && remoteSubmissions == 0,
                 "empty ARRsp drain preserves uncertain ownership and quarantine");

    runner.Check(!ASFW::Async::CanServiceResponsesBeforeTimeout(false, false) &&
                     !ASFW::Async::CanServiceResponsesBeforeTimeout(true, true) &&
                     ASFW::Async::CanServiceResponsesBeforeTimeout(true, false) &&
                     ASFW::IRM::ReleaseOwnershipAfter(
                         ASFW::IRM::AllocationStatus::GenerationMismatch) ==
                         ASFW::IRM::ResourceOwnership::None,
                 "quiesce and bus-reset generation gates suppress recovery service");

    using ASFW::Async::CanServiceReceiveBeforeTimeout;
    runner.Check(CanServiceReceiveBeforeTimeout(true, false, true, 0x00300031u) &&
                     CanServiceReceiveBeforeTimeout(true, false, true, 0),
                 "frozen observed IRQ event word and quiet DMA both permit receive fallback");
    runner.Check(!CanServiceReceiveBeforeTimeout(false, false, true, 0) &&
                     !CanServiceReceiveBeforeTimeout(true, true, true, 0) &&
                     !CanServiceReceiveBeforeTimeout(true, false, false, 0) &&
                     !CanServiceReceiveBeforeTimeout(true, false, true, UINT32_MAX),
                 "stopped reset unavailable and all-ones hardware never permit fallback");
    for (auto fault : {IntEventBits::kBusReset, IntEventBits::kSelfIDComplete,
            IntEventBits::kSelfIDComplete2, IntEventBits::kUnrecoverableError,
            IntEventBits::kRegAccessFail, IntEventBits::kPostedWriteErr}) {
        runner.Check(!CanServiceReceiveBeforeTimeout(true, false, true, fault | 0x30u),
                     "pending reset or fault is preserved for its normal owner");
    }

    using ASFW::Discovery::FwSpeed;
    using ASFW::Discovery::InitialROMSpeedPolicy;
    runner.Check(InitialROMSpeedPolicy::Select(FwSpeed::S400, FwSpeed::S100) ==
                     FwSpeed::S100,
                 "reported S100 node maximum caps configured S400 initial ROM speed");
    runner.Check(InitialROMSpeedPolicy::Select(FwSpeed::S200, FwSpeed::S400) ==
                     FwSpeed::S200,
                 "configured S200 cap is never raised by a reported S400 node maximum");
    runner.Check(InitialROMSpeedPolicy::Select(FwSpeed::S400, FwSpeed::S400) ==
                     FwSpeed::S400,
                 "matching configured and topology speeds remain unchanged");

    std::printf("SUMMARY failures=%d\n", runner.failures);
    return runner.failures == 0 ? 0 : 1;
}
