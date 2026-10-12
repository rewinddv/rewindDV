// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Production CSR/meter readers with a bounded, callback-free refusal boundary.
#include <gtest/gtest.h>
#include "ASFWDriver/Audio/Protocols/Oxford/OxfordCsr.hpp"
#include "ASFWDriver/Audio/Protocols/Oxford/Apogee/ApogeeTransport.hpp"
#include <array>

namespace {
using namespace ASFW;
namespace Oxford = Audio::Oxford;
namespace Meters = Oxford::Apogee::MeterRegisters;

struct RegisterBus final : Async::IFireWireBusOps {
    bool reject{true};
    unsigned reads{0};
    uint32_t length{0};
    Async::InterfaceCompletionCallback pending;
    Async::AsyncHandle ReadBlock(FW::Generation, FW::NodeId, Async::FWAddress,
        uint32_t size, FW::FwSpeed, Async::InterfaceCompletionCallback callback) override {
        ++reads; length = size;
        if (reject) return {};
        pending = std::move(callback);
        return Async::AsyncHandle{reads};
    }
    Async::AsyncHandle WriteBlock(FW::Generation, FW::NodeId, Async::FWAddress,
        std::span<const uint8_t>, FW::FwSpeed, Async::InterfaceCompletionCallback) override {
        ADD_FAILURE() << "register reads must not write"; return {};
    }
    Async::AsyncHandle Lock(FW::Generation, FW::NodeId, Async::FWAddress, FW::LockOp,
        std::span<const uint8_t>, uint32_t, FW::FwSpeed,
        Async::InterfaceCompletionCallback) override {
        ADD_FAILURE() << "register reads must not lock"; return {};
    }
    bool Cancel(Async::AsyncHandle) override { return false; }
    void Complete() {
        ASSERT_TRUE(pending);
        std::array<uint8_t, 16> payload{};
        auto callback = std::move(pending);
        callback(Async::AsyncStatus::kSuccess, std::span(payload).first(length));
    }
};

class RegisterSubmission : public testing::TestWithParam<int> {};

TEST_P(RegisterSubmission, RefusalCompletesOnceAndAdmittedReadWaitsForResponse) {
    RegisterBus bus;
    auto route = [] { return std::optional{Discovery::DeviceRouteToken{
        .guid = 1, .deviceIncarnation = 1, .routeEpoch = 1,
        .generation = FW::Generation{1}, .nodeId = 2}}; };
    unsigned completions = 0;
    IOReturn result = kIOReturnSuccess;
    auto callback = [&](IOReturn status, auto) { ++completions; result = status; };
    auto issue = [&] {
        switch (GetParam()) {
        case 0: Oxford::ReadFirmwareId(bus, route, callback); break;
        case 1: Oxford::ReadHardwareId(bus, route, callback); break;
        case 2: Meters::ReadInput(bus, route, callback); break;
        case 3: Meters::ReadMixer(bus, route, callback); break;
        }
    };
    issue();
    EXPECT_EQ(completions, 1u);
    EXPECT_EQ(result, kIOReturnNotReady);
    EXPECT_FALSE(bus.pending);
    bus.reject = false;
    issue();
    EXPECT_EQ(completions, 1u) << "admission is not completion";
    bus.Complete();
    EXPECT_EQ(completions, 2u);
    EXPECT_EQ(result, kIOReturnSuccess);
    EXPECT_EQ(bus.reads, 2u);
}

INSTANTIATE_TEST_SUITE_P(FirmwareHardwareInputMixer, RegisterSubmission,
                         testing::Values(0, 1, 2, 3));
} // namespace
