// Offline concurrency regression for the owner used by IRQ, watchdog and clients.
#include "ASFWDriver/Common/AtomicSharedOwner.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

struct Context {
    std::atomic<unsigned>& destroyed;
    explicit Context(std::atomic<unsigned>& value) : destroyed(value) {}
    ~Context() { destroyed.fetch_add(1); }
};

int main() {
    using Owner = ASFW::Common::AtomicSharedOwner<Context>;
    std::atomic<unsigned> destroyed{0};
    Owner root(std::make_unique<Context>(destroyed));
    Owner empty;
    assert(!empty && empty.get() == nullptr);
    root = root; // Self assignment retains the live root.
    std::array<Owner, 4> queued{root, root, root, root};
    std::atomic<bool> begin{false};
    std::vector<std::thread> workers;
    for (unsigned worker = 0; worker < 8; ++worker) {
        workers.emplace_back([retained = root, &begin, &destroyed] {
            while (!begin.load(std::memory_order_acquire)) {}
            for (unsigned i = 0; i < 100000; ++i) {
                Owner first = retained;
                Owner second = first;
                Owner moved = std::move(first);
                assert(!first && moved == retained && second == retained);
                second.reset();
                assert(destroyed.load() == 0);
            }
        });
    }
    begin.store(true, std::memory_order_release);
    // Clearing the published root cannot retire queued/in-flight owners.
    root.reset();
    for (auto& worker : workers) worker.join();
    assert(destroyed.load() == 0);
    for (auto& owner : queued) owner.reset();
    assert(destroyed.load() == 1);
    std::puts("PASS: 800000 concurrent copy/release cycles; root retirement retains queued owners; exactly one final destruction");
}
