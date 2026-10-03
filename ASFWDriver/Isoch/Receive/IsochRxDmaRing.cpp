// Modified by Rewind Digital for rewindDV; changes relative to the retained ASFireWire baseline.
// IsochRxDmaRing.cpp

#include "IsochRxDmaRing.hpp"

#include "../../Hardware/OHCIConstants.hpp"
#include "../../Hardware/OHCIDescriptors.hpp"
#include "../../Logging/Logging.hpp"
#include "../Core/IsochEventGroup.hpp"

#include <span>

namespace ASFW::Isoch::Rx {

kern_return_t IsochRxDmaRing::SetupRings(Memory::IIsochDMAMemory& dma,
                                        size_t numDescriptors,
                                        size_t maxPacketSizeBytes) noexcept {
    if (numDescriptors < 2 || numDescriptors > UINT32_MAX || maxPacketSizeBytes == 0) {
        return kIOReturnBadArgument;
    }
    if (maxPacketSizeBytes > 0xFFFFu) {
        return kIOReturnBadArgument;
    }

    // Keep allocations across sessions; rebuild the entire bounded program
    // only while the context is quiesced. No receive storage is reallocated.
    if (bufferRing_.Capacity() != 0) {
        if (bufferRing_.Capacity() != numDescriptors || bufferRing_.BufferSize() != maxPacketSizeBytes) {
            return kIOReturnUnsupported;
        }
        bufferRing_.BindDma(&dma);
        return ResetForStart();
    }

    if (numDescriptors > SIZE_MAX / sizeof(Async::HW::OHCIDescriptor) ||
        numDescriptors > SIZE_MAX / maxPacketSizeBytes) {
        return kIOReturnBadArgument;
    }

    const size_t descriptorsSize = numDescriptors * sizeof(Async::HW::OHCIDescriptor);
    const size_t buffersSize = numDescriptors * maxPacketSizeBytes;

    auto descRegion = dma.AllocateDescriptor(descriptorsSize);
    if (!descRegion) {
        return kIOReturnNoMemory;
    }

    auto bufRegion = dma.AllocatePayloadBuffer(buffersSize);
    if (!bufRegion) {
        return kIOReturnNoMemory;
    }

    auto descSpan = std::span<Async::HW::OHCIDescriptor>(
        reinterpret_cast<Async::HW::OHCIDescriptor*>(descRegion->virtualBase),
        numDescriptors);
    auto bufSpan = std::span<uint8_t>(bufRegion->virtualBase, buffersSize);

    if (!bufferRing_.Initialize(descSpan, bufSpan, numDescriptors, maxPacketSizeBytes)) {
        return kIOReturnInternalError;
    }

    bufferRing_.BindDma(&dma);
    if (!bufferRing_.Finalize(descRegion->deviceBase, bufRegion->deviceBase)) {
        return kIOReturnInternalError;
    }

    maxPacketSizeBytes_ = maxPacketSizeBytes;
    return ResetForStart();
}

kern_return_t IsochRxDmaRing::ResetForStart() noexcept {
    // The caller has established Stopped/ACTIVE-clear before rewriting any
    // command. Starting after Stop without Configure must reset the old anchor
    // and moving terminal too, not only the software completion cursor.
    if (bufferRing_.Capacity() < 2 || maxPacketSizeBytes_ == 0) {
        return kIOReturnNotReady;
    }
    const uint32_t count = static_cast<uint32_t>(bufferRing_.Capacity());
    const uint16_t reqCount = static_cast<uint16_t>(maxPacketSizeBytes_);

    for (uint32_t i = 0; i < count; ++i) {
        auto* desc = bufferRing_.GetDescriptor(i);
        if (!desc) {
            return kIOReturnInternalError;
        }

        const uint8_t interruptBits =
            ASFW::Isoch::Core::IsTimingGroupBoundary(i) ? Async::HW::OHCIDescriptor::kIntAlways : Async::HW::OHCIDescriptor::kIntNever;

        uint32_t control = Async::HW::OHCIDescriptor::BuildControl({
            .reqCount = reqCount,
            .command = Async::HW::OHCIDescriptor::kCmdInputLast,
            .key = Async::HW::OHCIDescriptor::kKeyStandard,
            .interruptBits = interruptBits,
            .branchBits = Async::HW::OHCIDescriptor::kBranchAlways,
        });
        control |= (1u << (Async::HW::OHCIDescriptor::kStatusShift + Async::HW::OHCIDescriptor::kControlHighShift));
        desc->control = control;

        const uint64_t dataIOVA = bufferRing_.GetElementIOVA(i);
        if (dataIOVA == 0 || dataIOVA > 0xFFFFFFFFULL) {
            return kIOReturnInternalError;
        }
        desc->dataAddress = static_cast<uint32_t>(dataIOVA);

        const uint64_t nextIOVA = bufferRing_.GetDescriptorIOVA((i + 1) % count);
        if (nextIOVA == 0 || nextIOVA > 0xFFFFFFFFULL || (nextIOVA & 0xF) != 0) {
            return kIOReturnInternalError;
        }

        // OHCI 1.1 section 10.1.3 requires an IR program's last command
        // to have branchAlways and Z=0. Hardware must not lap unread buffers.
        desc->branchWord = Async::HW::MakeBranchWordAR(static_cast<uint32_t>(nextIOVA), i + 1 < count);
        Async::HW::AR_init_status(*desc, reqCount);
    }

    bufferRing_.PublishAllDescriptorsOnce();

    lastProcessedIndex_ = 0;
    terminalIndex_ = count - 1;
    consumedAnchor_.reset();
    wakeRequired_ = false;

    return kIOReturnSuccess;
}

void IsochRxDmaRing::RecycleConsumed(Memory::IIsochDMAMemory& dma, uint32_t index) noexcept {
    auto* descriptor = bufferRing_.GetDescriptor(index);
    // Completion of a successor proves hardware no longer needs this
    // descriptor for a WAKE branch reread. Its payload was copied earlier.
    descriptor->branchWord &= ~uint32_t{0xF};
    Async::HW::AR_init_status(*descriptor, static_cast<uint16_t>(maxPacketSizeBytes_));
    dma.PublishToDevice(descriptor, sizeof(*descriptor));
    ::ASFW::Driver::WriteBarrier();

    // Append only after the new terminal is device-visible. Do not publish
    // the old tail's status word: hardware may still be completing it.
    auto* terminal = bufferRing_.GetDescriptor(terminalIndex_);
    terminal->branchWord |= uint32_t{1};
    dma.PublishToDevice(terminal, offsetof(OHCIDescriptor, statusWord));
    ::ASFW::Driver::WriteBarrier();
    terminalIndex_ = index;
    wakeRequired_ = true;
}

uint32_t IsochRxDmaRing::Descriptor0IOVA() const noexcept {
    const uint64_t iova = bufferRing_.GetDescriptorIOVA(0);
    if (iova == 0 || iova > 0xFFFFFFFFULL) {
        return 0;
    }
    return static_cast<uint32_t>(iova);
}

uint32_t IsochRxDmaRing::InitialCommandPtrWord() const noexcept {
    const uint32_t base = Descriptor0IOVA();
    if (base == 0 || (base & 0xF) != 0) {
        return 0;
    }
    return base | 1u; // Z=1 (fetch 1 descriptor)
}

} // namespace ASFW::Isoch::Rx
