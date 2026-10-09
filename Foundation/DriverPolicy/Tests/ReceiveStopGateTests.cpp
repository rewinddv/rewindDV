// Host contract tests of the production slow gate, with deterministic clocks.
#include "../../../ASFWDriver/Isoch/Receive/ReceiveStopGate.hpp"
#include <cassert>
#include <cstdio>
#include <cstdint>

int main() {
    using ASFW::Isoch::Detail::AcquireReceiveStopGate;
    std::atomic_flag gate = ATOMIC_FLAG_INIT;
    assert(!gate.test_and_set());
    uint64_t elapsed = 0;
    unsigned yields = 0;
    // Owner progresses during a yield. Only the successful waiter owns release.
    assert(AcquireReceiveStopGate(gate, [&] { return elapsed >= 100; }, [&] {
        ++yields; elapsed += 17; gate.clear(std::memory_order_release);
    }));
    assert(yields == 1 && gate.test());
    gate.clear();
    assert(!gate.test_and_set());
    elapsed = 0; yields = 0;
    assert(!AcquireReceiveStopGate(gate, [&] { return elapsed >= 100; }, [&] {
        ++yields; elapsed += 37;
    }));
    assert(yields == 3 && gate.test()); // No iteration-count timing assumption.
    // Late owner release cannot turn an expired attempt into ownership.
    gate.clear();
    assert(!AcquireReceiveStopGate(gate, [&] { return true; }, [&] { assert(false); }));
    assert(!gate.test());
    assert(AcquireReceiveStopGate(gate, [&] { return false; }, [&] { assert(false); }));
    assert(gate.test());
    gate.clear();
    std::puts("Receive Stop gate: deterministic progress, elapsed deadline, foreign-lock retention, late release and retry passed");
}
