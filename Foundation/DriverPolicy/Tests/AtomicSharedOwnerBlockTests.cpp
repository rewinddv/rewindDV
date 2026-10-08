// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Native macOS Blocks/pthreads with the actual DriverKit libc++ headers.
// This is offline validation, not execution inside a DriverKit extension.
#include "ASFWDriver/Common/AtomicSharedOwner.hpp"
#include <Block.h>
#include <array>
#include <cassert>
#include <cstdio>
#include <pthread.h>

#if _LIBCPP_HAS_THREADS
#error This regression must use the threadless DriverKit libc++ headers
#endif

struct Context {
    std::atomic<unsigned>& destroyed;
    explicit Context(std::atomic<unsigned>& count) : destroyed(count) {}
    ~Context() { destroyed.fetch_add(1); }
};
using Owner = ASFW::Common::AtomicSharedOwner<Context>;
struct Work {
    Owner retained;
    std::atomic<bool>* begin;
    std::atomic<unsigned>* destroyed;
};

static auto MakeLastCallback(const Owner& root) -> void (^)(void) {
    const auto retained = root;
    return Block_copy(^{ assert(retained); });
}

static void* Worker(void* argument) {
    auto& work = *static_cast<Work*>(argument);
    while (!work.begin->load(std::memory_order_acquire)) {}
    for (unsigned i = 0; i < 100000; ++i) {
        // Match InterruptDispatcher's array copied into an escaping Block.
        const std::array<Owner, 4> owners{work.retained, work.retained,
                                          work.retained, work.retained};
        auto callback = Block_copy(^{
            for (const auto& owner : owners) assert(owner);
        });
        assert(callback);
        callback();
        Block_release(callback);
        assert(work.destroyed->load() == 0);
    }
    // All workers release independently, after the service root is gone.
    work.retained.reset();
    return nullptr;
}

int main() {
    std::atomic<unsigned> destroyed{0};
    std::atomic<bool> begin{false};
    Owner root(std::make_unique<Context>(destroyed));
    auto lastCallback = MakeLastCallback(root);
    std::array<Work, 8> work;
    std::array<pthread_t, 8> workers;
    for (unsigned i = 0; i < workers.size(); ++i) {
        work[i] = {root, &begin, &destroyed};
        assert(pthread_create(&workers[i], nullptr, Worker, &work[i]) == 0);
    }
    root.reset();
    begin.store(true, std::memory_order_release);
    for (auto worker : workers) assert(pthread_join(worker, nullptr) == 0);
    assert(destroyed.load() == 0);
    lastCallback();
    Block_release(lastCallback);
    assert(destroyed.load() == 1);
    std::puts("PASS: real DriverKit libc++ headers; 800000 concurrent native Block copy/release cycles; late callback retains retired root; exactly one destruction");
}
