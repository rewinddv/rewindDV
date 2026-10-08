// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <new>
#include <utility>

namespace ASFW::Common {

// DriverKit's libc++ config sets _LIBCPP_HAS_THREADS=0: std::shared_ptr's
// reference counts are ordinary loads/stores there. Use explicit atomics for
// owners copied across dispatch queues. Publication of the same owner variable
// still needs a lock; independently retained copies may release concurrently.
// No weak references, aliasing, allocation on copy, or platform ABI override.
template <typename T>
class AtomicSharedOwner final {
    static_assert(std::atomic<size_t>::is_always_lock_free,
                  "Cross-queue DriverKit ownership requires native atomic counts");
    struct Control {
        std::atomic<size_t> references{1};
        T* object;
        explicit Control(T* value) noexcept : object(value) {}
        ~Control() { delete object; }
    };
    Control* control_{};

    void Retain() noexcept {
        if (control_) control_->references.fetch_add(1, std::memory_order_relaxed);
    }
    void Release() noexcept {
        if (control_ && control_->references.fetch_sub(1, std::memory_order_acq_rel) == 1)
            delete control_;
    }

public:
    AtomicSharedOwner() noexcept = default;
    explicit AtomicSharedOwner(std::unique_ptr<T> object) noexcept {
        if (!object) return;
        control_ = new (std::nothrow) Control(object.get());
        if (control_) (void)object.release();
    }
    AtomicSharedOwner(const AtomicSharedOwner& other) noexcept : control_(other.control_) { Retain(); }
    AtomicSharedOwner(AtomicSharedOwner&& other) noexcept
        : control_(std::exchange(other.control_, nullptr)) {}
    ~AtomicSharedOwner() { Release(); }
    AtomicSharedOwner& operator=(AtomicSharedOwner other) noexcept {
        std::swap(control_, other.control_);
        return *this;
    }
    void reset() noexcept { AtomicSharedOwner{}.swap(*this); }
    void swap(AtomicSharedOwner& other) noexcept { std::swap(control_, other.control_); }
    T* get() const noexcept { return control_ ? control_->object : nullptr; }
    T* operator->() const noexcept { return get(); }
    explicit operator bool() const noexcept { return get() != nullptr; }
    friend bool operator==(const AtomicSharedOwner& left, const AtomicSharedOwner& right) noexcept {
        return left.get() == right.get();
    }
};

} // namespace ASFW::Common
