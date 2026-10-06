#include "LabelAllocator.hpp"

#include <bit>
#include "../../Common/FWCommon.hpp"
#include "../../Logging/Logging.hpp"
#include "../../Logging/LogConfig.hpp"

namespace ASFW::Async {

LabelAllocator::LabelAllocator()
    : ownershipLock_(IOLockAlloc()), bitmap_(0), generation_(0), next_label_(0) {}

LabelAllocator::~LabelAllocator() { if (ownershipLock_) IOLockFree(ownershipLock_); }

void LabelAllocator::Reset() {
    if (HasAnyLabelsInUse()) return;
    bitmap_.store(0, std::memory_order_relaxed);
    generation_.store(0, std::memory_order_relaxed);
    next_label_.store(0, std::memory_order_relaxed);
}

uint8_t LabelAllocator::Allocate() {
    if (!ownershipLock_) return kInvalidLabel;
    // Round-robin allocator: start from next_label_ cursor, scan for a free bit.
    uint8_t start = next_label_.load(std::memory_order_relaxed);
    uint64_t snapshot = bitmap_.load(std::memory_order_relaxed);

    for (unsigned int attempt = 0; attempt < kMaxLabels; ++attempt) {
        const uint8_t idx = static_cast<uint8_t>((start + attempt) & 0x3F);
        const uint64_t mask = ASFW::FW::bit<uint64_t>(idx);
        if (snapshot & mask) {
            continue;  // in use
        }

        const uint64_t desired = snapshot | mask;
        if (bitmap_.compare_exchange_weak(snapshot,
                                          desired,
                                          std::memory_order_acq_rel,
                                          std::memory_order_acquire)) {
            const uint8_t next = static_cast<uint8_t>((idx + 1) & 0x3F);
            next_label_.store(next, std::memory_order_relaxed);
            ASFW_LOG_V3(Async, "LabelAllocator::Allocate: label=%u bitmap=0x%016llx→0x%016llx next=%u",
                        idx, snapshot, desired, next);
            return idx;
        }
        // CAS failed; snapshot updated with current bitmap, retry loop.
    }

    ASFW_LOG_V0(Async, "LabelAllocator::Allocate: no free labels (bitmap=0x%016llx)", snapshot);
    return kInvalidLabel;
}

uint8_t LabelAllocator::NextLabel() noexcept {
    // IEEE-1394 tLabel is 6-bit (0-63), must wrap properly.
    // Use compare-exchange to ensure both returned value AND stored counter wrap at 63→0.
    uint8_t current = next_label_.load(std::memory_order_relaxed);
    uint8_t next;

    do {
        next = (current + 1) & 0x3F;  // Wrap at 64 (6-bit field)
    } while (!next_label_.compare_exchange_weak(
        current,
        next,
        std::memory_order_relaxed,
        std::memory_order_relaxed
    ));

    return current;  // Return the label we reserved (before increment)
}

void LabelAllocator::Free(uint8_t label) {
    CompleteLogical(label, false);
}

void LabelAllocator::ReleaseIfTerminal(uint8_t label) {
    auto& record = ownership_[label];
    if (!record.logicalDone || record.atPending || record.uncertainWire) return;
    record = {};
    bitmap_.fetch_and(~ASFW::FW::bit<uint64_t>(label), std::memory_order_release);
}

void LabelAllocator::BindOperation(uint8_t label, uint32_t operation) {
    if (label >= 64 || !ownershipLock_) return;
    IOLockLock(ownershipLock_);
    ownership_[label] = Ownership{.operation = operation};
    IOLockUnlock(ownershipLock_);
}

uint32_t LabelAllocator::Operation(uint8_t label) const {
    if (label >= 64 || !ownershipLock_) return 0;
    IOLockLock(ownershipLock_);
    const auto operation = ownership_[label].operation;
    IOLockUnlock(ownershipLock_);
    return operation;
}

bool LabelAllocator::Matches(uint32_t operation) const {
    return operation && operation < 0x80000000u &&
        Operation(static_cast<uint8_t>((operation - 1) & 63)) == operation;
}

bool LabelAllocator::MarkPosted(uint32_t operation) {
    if (!operation || !ownershipLock_) return false;
    IOLockLock(ownershipLock_);
    auto& record = ownership_[(operation - 1) & 63];
    const bool admitted = record.operation == operation && !record.logicalDone;
    if (admitted && !record.posted) { record.posted = true; record.atPending = true; }
    IOLockUnlock(ownershipLock_);
    return admitted;
}

void LabelAllocator::AbandonUnposted(uint32_t operation) {
    if (!operation || !ownershipLock_) return;
    IOLockLock(ownershipLock_);
    const auto label = static_cast<uint8_t>((operation - 1) & 63);
    auto& record = ownership_[label];
    if (record.operation == operation) {
        record.atPending = false;
        record.posted = false;
        record.uncertainWire = false; // Caller proves no hardware publication occurred.
        record.logicalDone = true;
        ReleaseIfTerminal(label);
    }
    IOLockUnlock(ownershipLock_);
}

bool LabelAllocator::RetireAT(uint32_t operation) {
    if (!operation || !ownershipLock_) return false;
    IOLockLock(ownershipLock_);
    const auto label = static_cast<uint8_t>((operation - 1) & 63);
    auto& record = ownership_[label];
    const bool accepted = record.operation == operation && record.atPending;
    if (accepted) { record.atPending = false; ReleaseIfTerminal(label); }
    IOLockUnlock(ownershipLock_);
    return accepted;
}

void LabelAllocator::RetireStoppedAT() {
    if (!ownershipLock_) return;
    IOLockLock(ownershipLock_);
    for (uint8_t label = 0; label < 64; ++label) {
        ownership_[label].atPending = false;
        ReleaseIfTerminal(label);
    }
    IOLockUnlock(ownershipLock_);
}

bool LabelAllocator::HasUncertainWire() const {
    if (wireFault_.load(std::memory_order_acquire)) return true;
    if (!ownershipLock_) return true;
    IOLockLock(ownershipLock_);
    bool uncertain = false;
    for (const auto& record : ownership_) uncertain |= record.uncertainWire;
    IOLockUnlock(ownershipLock_);
    return uncertain;
}

void LabelAllocator::CompleteLogical(uint8_t label, bool uncertainWire) {
    if (label >= kMaxLabels) {
        return;
    }
    if (!ownershipLock_) return;
    IOLockLock(ownershipLock_);
    auto& record = ownership_[label];
    record.logicalDone = true;
    record.uncertainWire |= uncertainWire && record.posted;
    ReleaseIfTerminal(label);
    IOLockUnlock(ownershipLock_);
}

void LabelAllocator::ClearBitmap() {
    if (!ownershipLock_) return;
    IOLockLock(ownershipLock_);
    for (const auto& record : ownership_) {
        if (record.operation) { IOLockUnlock(ownershipLock_); return; }
    }
    IOLockUnlock(ownershipLock_);
    const uint64_t before = bitmap_.exchange(0, std::memory_order_release);
    next_label_.store(0, std::memory_order_relaxed);
    ASFW_LOG(Async, "LabelAllocator::ClearBitmap: bitmap=0x%016llx→0x0000000000000000", before);
}

bool LabelAllocator::HasAnyLabelsInUse() const noexcept {
    return bitmap_.load(std::memory_order_acquire) != 0;
}

void LabelAllocator::BumpGeneration() {
    uint16_t current = generation_.load(std::memory_order_relaxed);
    while (!generation_.compare_exchange_weak(current,
                                              static_cast<uint16_t>((current + 1) & kGenerationMask),
                                              std::memory_order_relaxed,
                                              std::memory_order_relaxed)) {
        // retry until generation is updated atomically
    }
}

void LabelAllocator::SetGeneration(uint16_t newGen) {
    generation_.store(newGen & kGenerationMask, std::memory_order_release);
}

uint16_t LabelAllocator::CurrentGeneration() const {
    return generation_.load(std::memory_order_acquire) & kGenerationMask;
}

bool LabelAllocator::IsLabelInUse(uint8_t label) const {
    if (label >= kMaxLabels) {
        return false;
    }
    const uint64_t mask = ASFW::FW::bit<uint64_t>(label);
    return (bitmap_.load(std::memory_order_acquire) & mask) != 0;
}

} // namespace ASFW::Async
