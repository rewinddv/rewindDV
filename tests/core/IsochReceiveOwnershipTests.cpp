#include <gtest/gtest.h>
#include "ASFWDriver/Isoch/Receive/IsochRxDmaRing.hpp"
#include <array>
#include <cstring>

namespace {
using Ring = ASFW::Isoch::Rx::IsochRxDmaRing;
class Memory final : public ASFW::Isoch::Memory::IIsochDMAMemory {
public:
    alignas(16) std::array<std::byte, 8 * 16> descriptors{};
    alignas(16) std::array<std::byte, 8 * 4096> payload{};
    std::optional<ASFW::Shared::DMARegion> AllocateDescriptor(size_t n) override {
        if (n > descriptors.size()) return {};
        return ASFW::Shared::DMARegion{reinterpret_cast<uint8_t*>(descriptors.data()), 0x10000, n};
    }
    std::optional<ASFW::Shared::DMARegion> AllocatePayloadBuffer(size_t n) override {
        if (n > payload.size()) return {};
        return ASFW::Shared::DMARegion{reinterpret_cast<uint8_t*>(payload.data()), 0x20000, n};
    }
    std::optional<ASFW::Shared::DMARegion> AllocateRegion(size_t, size_t) override { return {}; }
    uint64_t VirtToIOVA(const std::byte*) const noexcept override { return 0; }
    std::byte* IOVAToVirt(uint64_t) const noexcept override { return nullptr; }
    void PublishToDevice(const std::byte*, size_t) const noexcept override {}
    void FetchFromDevice(const std::byte*, size_t) const noexcept override {}
    size_t TotalSize() const noexcept override { return descriptors.size() + payload.size(); }
    size_t AvailableSize() const noexcept override { return 0; }
};

// A bounded OHCI packet-per-buffer model using the production branch words.
// Cache the branch at completion. A zero-Z program stays asleep until Wake
// rereads the completed descriptor's branch (OHCI 1.1 sections 3.1.1.2/3.2.1.2).
// This checks descriptor protocol, not physical prefetch/cache coherency.
class Device {
public:
    explicit Device(Ring& ring) : ring_(ring), command_(ring.InitialCommandPtrWord()) {}
    bool Receive(uint32_t value) {
        if ((command_ & 0xf) == 0) return false;
        const uint32_t address = command_ & ~0xfU;
        EXPECT_GE(address, 0x10000U);
        const uint32_t index = (address - 0x10000) / 16;
        EXPECT_LT(index, ring_.Capacity());
        if (index >= ring_.Capacity()) return false;
        auto* descriptor = ring_.DescriptorAt(index);
        if ((descriptor->statusWord >> 16) != 0) overwritten = true;
        std::memcpy(ring_.PayloadVA(index), &value, sizeof(value));
        descriptor->statusWord = (0x11U << 16) | (4096 - sizeof(value));
        command_ = descriptor->branchWord;
        previous_ = index;
        return true;
    }
    void Wake() {
        if ((command_ & 0xf) == 0 && previous_)
            command_ = ring_.DescriptorAt(*previous_)->branchWord;
    }
    bool overwritten{false};
private:
    Ring& ring_;
    uint32_t command_;
    std::optional<uint32_t> previous_;
};

TEST(IsochReceiveOwnershipTests, FullProgramStopsBeforeOverwritingUnreadPayload) {
    Memory memory; Ring ring;
    ASSERT_EQ(ring.SetupRings(memory, 8, 4096), kIOReturnSuccess);
    Device device(ring);
    for (uint32_t i = 0; i < 8; ++i) ASSERT_TRUE(device.Receive(i));
    EXPECT_FALSE(device.Receive(99));
    EXPECT_FALSE(device.overwritten);
    uint32_t expected = 0;
    EXPECT_EQ(ring.DrainCompleted(memory, [&](const auto& packet) {
        uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
        EXPECT_EQ(value, expected++);
    }), 8U);
}

TEST(IsochReceiveOwnershipTests, ExhaustionResumesFromHardwareAnchorAcrossWraps) {
    for (const unsigned capacity : {2U, 8U}) {
        Memory memory; Ring ring;
        ASSERT_EQ(ring.SetupRings(memory, capacity, 4096), kIOReturnSuccess);
        Device device(ring);
        uint32_t emitted = 0, received = 0;
        for (unsigned round = 0; round < 100; ++round) {
            unsigned added = 0;
            while (added <= capacity && device.Receive(emitted)) { ++emitted; ++added; }
            ASSERT_GT(added, 0U) << "Recycling lost hardware's terminal continuation";
            ASSERT_LE(added, capacity) << "Program has no ownership boundary";
            const auto drained = ring.DrainCompleted(memory, [&](const auto& packet) {
                uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
                EXPECT_EQ(value, received++);
                // No wake yet: a cached zero-Z terminal cannot advance just
                // because software has changed a branch in memory.
                EXPECT_FALSE(device.Receive(emitted));
                uint32_t after{}; std::memcpy(&after, packet.payload, sizeof(after));
                EXPECT_EQ(after, value);
            });
            ASSERT_EQ(drained, added);
            ASSERT_FALSE(device.overwritten);
            EXPECT_FALSE(device.Receive(emitted));
            device.Wake();
        }
        EXPECT_EQ(emitted, received);
        // Reconfigure the existing allocation after a partial traversal.
        ASSERT_TRUE(device.Receive(emitted));
        ASSERT_EQ(ring.DrainCompleted(memory, [&](const auto&) {}), 1U);
        ASSERT_EQ(ring.SetupRings(memory, capacity, 4096), kIOReturnSuccess);
        Device restarted(ring);
        ASSERT_TRUE(restarted.Receive(123));
        EXPECT_EQ(ring.DrainCompleted(memory, [&](const auto& packet) {
            EXPECT_EQ(packet.descriptorIndex, 0U);
            uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
            EXPECT_EQ(value, 123U);
        }), 1U);
    }
}

TEST(IsochReceiveOwnershipTests, ActiveProducerCannotOverwritePacketDuringConsumerCopy) {
    Memory memory; Ring ring;
    ASSERT_EQ(ring.SetupRings(memory, 8, 4096), kIOReturnSuccess);
    Device device(ring);
    uint32_t emitted = 0, received = 0;
    ASSERT_TRUE(device.Receive(emitted++));
    for (unsigned round = 0; round < 100; ++round) {
        const auto drained = ring.DrainCompleted(memory, [&](const auto& packet) {
            uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
            EXPECT_EQ(value, received++);
            unsigned added = 0;
            while (added++ < 9 && device.Receive(emitted)) ++emitted;
            uint32_t after{}; std::memcpy(&after, packet.payload, sizeof(after));
            EXPECT_EQ(after, value);
        });
        ASSERT_GT(drained, 0U);
        ASSERT_FALSE(device.overwritten);
        device.Wake();
        if (device.Receive(emitted)) ++emitted;
    }
    const auto remaining = emitted - received;
    EXPECT_EQ(ring.DrainCompleted(memory, [&](const auto& packet) {
        uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
        EXPECT_EQ(value, received++);
    }), remaining);
    EXPECT_EQ(emitted, received);
}
TEST(IsochReceiveOwnershipTests, FinalDrainDoesNotRearmOrRedeliverRetainedAnchor) {
    Memory memory; Ring ring;
    ASSERT_EQ(ring.SetupRings(memory, 8, 4096), kIOReturnSuccess);
    Device device(ring);
    uint32_t received = 0;
    auto consume = [&](const auto& packet) {
        uint32_t value{}; std::memcpy(&value, packet.payload, sizeof(value));
        EXPECT_EQ(value, received++);
    };
    for (unsigned index = 0; index < 8; ++index) ASSERT_TRUE(device.Receive(index));
    ASSERT_EQ(ring.DrainCompleted(memory, consume), 8U);
    EXPECT_TRUE(ring.TakeWakeRequired());
    EXPECT_FALSE(ring.TakeWakeRequired());
    device.Wake();
    for (unsigned index = 8; index < 15; ++index) ASSERT_TRUE(device.Receive(index));
    EXPECT_FALSE(device.Receive(15));
    const auto descriptorsBefore = memory.descriptors;
    EXPECT_EQ(ring.DrainCompleted(memory, consume, false), 7U);
    EXPECT_EQ(received, 15U);
    EXPECT_EQ(memory.descriptors, descriptorsBefore);
    EXPECT_FALSE(ring.TakeWakeRequired());
    EXPECT_EQ(ring.DrainCompleted(memory, consume, false), 0U);
}

}
