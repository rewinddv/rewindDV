// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "ASFWDriver/Async/AsyncTypes.hpp"
#include "ASFWDriver/Async/Tx/PacketBuilder.hpp"
#include <array>
#include <cassert>
#include <cstddef>
#include <cstring>
#include <cstdio>
#include <type_traits>

using ASFW::Async::FWAddress;
static_assert(sizeof(FWAddress) == 8 && alignof(FWAddress) == 4);
static_assert(offsetof(FWAddress, nodeID) == 0 && offsetof(FWAddress, addressHi) == 2);
static_assert(offsetof(FWAddress, addressLo) == 4);
static_assert(std::is_aggregate_v<FWAddress> && std::is_standard_layout_v<FWAddress>);
static_assert(std::is_trivially_copyable_v<FWAddress>);
static_assert(ASFW::FW::Pack(FWAddress{}) == 0x0000deadcafebabeull);
static_assert(ASFW::FW::Pack(FWAddress{0, 0, 0}) == 0);

int main() {
    for (unsigned bit = 0; bit < 64; ++bit) {
        const auto n = uint64_t{1} << bit;
        const auto a = ASFW::FW::Unpack(n);
        assert(a.nodeID == (bit >= 48 ? uint16_t{1} << (bit - 48) : 0));
        assert(a.addressHi == (bit >= 32 && bit < 48 ? uint16_t{1} << (bit - 32) : 0));
        assert(a.addressLo == (bit < 32 ? uint32_t{1} << bit : 0));
        assert(ASFW::FW::Pack(a) == n);
        const auto copy = a;
        assert(copy.nodeID == a.nodeID && copy.addressHi == a.addressHi && copy.addressLo == a.addressLo);
    }
    for (uint64_t n : {0ull, 0xffffffffffffffffull, 0x0123456789abcdefull, 0xffc1fffff0000400ull}) {
        assert(ASFW::FW::ToU64(ASFW::FW::Unpack(n)) == n);
    }
    const FWAddress target{.nodeID = 0xffc9, .addressHi = 0xa135, .addressLo = 0x72b4c6d8};
    ASFW::Async::ReadParams request{};
    request.destinationID = target.nodeID;
    request.addressHigh = target.addressHi;
    request.addressLow = target.addressLo;
    ASFW::Async::PacketContext context{};
    context.sourceNodeID = 0xffc2;
    std::array<uint8_t, 16> bytes{};
    ASFW::Async::PacketBuilder builder;
    assert(builder.BuildReadQuadlet(request, 3, context, bytes.data(), bytes.size()) == 12);
    // OHCI transmit headers use native-order quadlets, NOT native FWAddress bytes.
    std::array<uint32_t, 4> words{};
    std::memcpy(words.data(), bytes.data(), bytes.size());
    assert((words[0] >> 10 & 63) == 3);
    assert(words[1] == 0xffc9a135);
    assert(words[2] == 0x72b4c6d8);
    std::puts("Address native layout, defaults, bitwise packing and request serialization PASS");
}
