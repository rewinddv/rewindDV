// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "Debug/BusResetPacketCapture.hpp"
#include <libkern/OSByteOrder.h>
#include <gtest/gtest.h>
#include <array>

TEST(BusResetPacketCaptureTests, RetainsPhyMarkerTypeAndUnchangedAcquisitionWords) {
    ASFW::Debug::BusResetPacketCapture capture;
    const std::array<uint32_t, 4> words{
        OSSwapHostToLittleInt32(0x000000E0),
        OSSwapHostToLittleInt32(0x07000000),
        OSSwapHostToLittleInt32(0x12345678),
        OSSwapHostToLittleInt32(0x00091234)};
    capture.CapturePacket(words.data(), 7, "offline PHY marker");
    ASSERT_EQ(capture.GetCount(), 1u);
    const auto* snapshot = capture.GetLatest();
    ASSERT_NE(snapshot, nullptr);
    EXPECT_EQ(snapshot->tCode, 0xEu);
    EXPECT_EQ(snapshot->generation, 7u);
    EXPECT_EQ(snapshot->eventCode, 9u);
    EXPECT_EQ(snapshot->cycleTime, 0x1234u);
    for (size_t i = 0; i < words.size(); ++i) {
        EXPECT_EQ(snapshot->rawQuadlets[i], words[i]);
        EXPECT_EQ(snapshot->wireQuadlets[i], OSSwapLittleToHostInt32(words[i]));
    }
    EXPECT_STREQ(snapshot->contextInfo, "offline PHY marker");
}
