#pragma once

#include <cstddef>
#include <cstdint>
#include <span>

namespace ASFW::Common {

// Cache-inhibited DMA memory requires naturally aligned reads. Even an aligned
// source can fault in memcpy when its partial-packet tail uses an unaligned wide
// load. Volatile reads prevent the optimizer from widening/coalescing these
// device accesses or replacing the loop with memcpy. Destination is normal RAM.
inline void CopyFromQuadletAlignedDeviceMemory(std::span<uint8_t> destination,
                                               const uint8_t* source) noexcept {
    if (destination.empty() || source == nullptr) {
        return;
    }

    size_t offset = 0;
    // Receive-ring slices can start within a quadlet. Copy their prefix bytewise
    // before using aligned 32-bit reads; never read outside the supplied extent.
    const auto* bytes = reinterpret_cast<const volatile uint8_t*>(source);
    for (; offset < destination.size() &&
           (reinterpret_cast<uintptr_t>(source + offset) % alignof(uint32_t)) != 0; ++offset) {
        destination[offset] = bytes[offset];
    }
    for (; offset + sizeof(uint32_t) <= destination.size(); offset += sizeof(uint32_t)) {
        const uint32_t quadlet =
            *reinterpret_cast<const volatile uint32_t*>(source + offset);
        __builtin_memcpy(destination.data() + offset, &quadlet, sizeof(quadlet));
    }

    for (; offset < destination.size(); ++offset) {
        destination[offset] = bytes[offset];
    }
}

} // namespace ASFW::Common
