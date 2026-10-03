// Host-only execution of the production ring, with DMA storage owned by this test.
#include "Isoch/Receive/IsochRxDmaRing.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>

class Memory final : public ASFW::Isoch::Memory::IIsochDMAMemory {
public:
    alignas(16) std::array<std::byte, 128> descriptors{};
    alignas(16) std::array<std::byte, 8 * 4096> payload{};
    mutable unsigned fetches{}, publishes{};
    std::optional<ASFW::Shared::DMARegion> AllocateDescriptor(size_t n) override {
        assert(n <= descriptors.size()); return ASFW::Shared::DMARegion{reinterpret_cast<uint8_t*>(descriptors.data()),0x10000,n};
    }
    std::optional<ASFW::Shared::DMARegion> AllocatePayloadBuffer(size_t n) override {
        assert(n <= payload.size()); return ASFW::Shared::DMARegion{reinterpret_cast<uint8_t*>(payload.data()),0x20000,n};
    }
    std::optional<ASFW::Shared::DMARegion> AllocateRegion(size_t, size_t) override { return {}; }
    uint64_t VirtToIOVA(const std::byte*) const noexcept override { return 0; }
    std::byte* IOVAToVirt(uint64_t) const noexcept override { return nullptr; }
    void PublishToDevice(const std::byte*, size_t) const noexcept override { ++publishes; }
    void FetchFromDevice(const std::byte*, size_t) const noexcept override { ++fetches; }
    size_t TotalSize() const noexcept override { return descriptors.size()+payload.size(); }
    size_t AvailableSize() const noexcept override { return 0; }
};

int main() {
    // Include actual capture shapes (16 empty CIP, 496 DV packet), zero/full
    // lengths, and active-only status without an event. None is completion.
    for (uint16_t length : {uint16_t(496),uint16_t(16),uint16_t(0),uint16_t(4096)}) {
        for (uint16_t pending : {uint16_t(0),uint16_t(0x400)}) {
            Memory memory; ASFW::Isoch::Rx::IsochRxDmaRing ring;
            assert(ring.SetupRings(memory,8,4096)==kIOReturnSuccess);
            auto* first=ring.DescriptorAt(0); auto* next=ring.DescriptorAt(1);
            const uint32_t waiting=(uint32_t(pending)<<16)|(4096-length);
            first->statusWord=waiting;
            next->statusWord=(0x11u<<16)|4080; // completed successor must wait
            unsigned calls=0; const auto published=memory.publishes;
            const auto deferred=ring.DrainCompleted(memory,[&](auto const&){++calls;});
            if(deferred!=0 || calls!=0 || first->statusWord!=waiting || memory.publishes!=published) {
                std::fprintf(stderr,"FAIL: pending descriptor consumed/rearmed: status=%x length=%u calls=%u\n",pending,length,calls);
                return 1;
            }
            first->statusWord=(0x11u<<16)|(4096-length);
            const auto completed=ring.DrainCompleted(memory,[&](auto const& packet){
                assert(packet.xferStatus==0x11);
                assert(packet.descriptorIndex==calls);
                assert(packet.actualLength==(calls==0?length:16));
                assert((ring.DescriptorAt(calls)->statusWord>>16)==0x11); // rearm AFTER consumer
                ++calls;
            });
            assert(completed==2 && calls==2 && first->statusWord==4096 && (next->statusWord>>16)==0x11);
            assert(ring.DrainCompleted(memory,[&](auto const&){assert(false);})==0);
        }
    }
    Memory memory; ASFW::Isoch::Rx::IsochRxDmaRing ring;
    assert(ring.SetupRings(memory,8,4096)==kIOReturnSuccess);
    unsigned calls=0;
    // Error completions stay visible; bounded wraparound never duplicates.
    for(unsigned round=0;round<3;++round) {
        for(unsigned i=0;i<8;++i) {
            // A later completion releases the previous descriptor; do not
            // overwrite every slot, including the hardware resume anchor.
            ring.DescriptorAt(i)->statusWord=((i==3?0x02u:0x11u)<<16)|3600;
            assert(ring.DrainCompleted(memory,[&](auto const& packet){
                assert(packet.descriptorIndex==calls%8);
                assert(packet.xferStatus==(calls%8==3?2:17));
                assert(packet.actualLength==496);++calls;
            })==1);
        }
    }
    assert(calls==24);
    std::puts("PASS: 8 deferred-completion shapes, ordered later completion, no early rearm, error preservation, 3 ring wraps");
}
