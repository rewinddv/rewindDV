// Host-only byte/bounds checks. Ordinary host RAM does not reproduce the ARM
// device-memory alignment trap; the runner also checks optimized ARM64 loads.
#include "../../../ASFWDriver/Common/DMASafeCopy.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <sys/mman.h>
#include <unistd.h>

extern "C" __attribute__((noinline))
void rewindDVCopyFromDMA(uint8_t* destination, const uint8_t* source, size_t size) {
    ASFW::Common::CopyFromQuadletAlignedDeviceMemory({destination, size}, source);
}

int main() {
    constexpr size_t maxPayload = 4096;
    alignas(16) std::array<uint8_t, maxPayload + 16> source{};
    for (size_t i = 0; i < source.size(); ++i) source[i] = uint8_t(i * 37 + i / 256);
    std::array<uint8_t, maxPayload + 2> destination;
    for (size_t alignment = 0; alignment < 16; ++alignment) {
        for (size_t length = 0; length <= maxPayload; ++length) {
            destination.fill(0xa5);
            rewindDVCopyFromDMA(destination.data() + 1, source.data() + alignment, length);
            assert(std::equal(source.begin() + alignment, source.begin() + alignment + length,
                              destination.begin() + 1));
            assert(destination.front() == 0xa5 && destination[length + 1] == 0xa5);
        }
    }
    // Place each possible packet tail immediately before an inaccessible page.
    // This catches rounded-up reads, including 1/2/3-byte and non-vector tails.
    const size_t page = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    assert(page >= maxPayload);
    auto* mapping = static_cast<uint8_t*>(mmap(nullptr, 2 * page,
        PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    assert(mapping != MAP_FAILED);
    assert(mprotect(mapping + page, page, PROT_NONE) == 0);
    for (size_t i = 0; i < page; ++i) mapping[i] = uint8_t(i * 19);
    for (size_t length = 0; length <= maxPayload; ++length) {
        const auto* tail = mapping + page - length;
        rewindDVCopyFromDMA(destination.data(), tail, length);
        assert(std::equal(tail, tail + length, destination.data()));
    }
    assert(munmap(mapping, 2 * page) == 0);
    std::puts("PASS: DMA copy lengths 0..4096, all 16 source alignments, unaligned destination and guarded packet tails (host RAM)");
}
