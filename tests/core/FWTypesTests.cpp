// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "Common/FWTypes.hpp"
#include <gtest/gtest.h>
#include <array>

TEST(FWTypesTests, MaxRecDescribesBytesRatherThanQuadlets) {
    // OHCI 1.1 section 8.4.2: encoded payload is 2^(max_rec + 1) bytes.
    constexpr std::array<uint32_t, 16> expected{
        2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536};
    for (uint8_t field = 0; field < expected.size(); ++field) {
        EXPECT_EQ(ASFW::FW::MaxAsyncPayloadBytesFromMaxRec(field), expected[field])
            << "max_rec=" << unsigned(field);
    }
}

TEST(FWTypesTests, OutOfFieldMaxRecDoesNotAdvertiseACapability) {
    for (unsigned value = 16; value <= 255; ++value) {
        EXPECT_EQ(ASFW::FW::MaxAsyncPayloadBytesFromMaxRec(uint8_t(value)), 0u);
    }
}
