#include "../../../ASFWDriver/Async/AsyncSubsystem.hpp"

#include <cassert>
#include <cstdio>
#include <memory>

int main() {
    auto epoch = std::make_shared<ASFW::Async::PostedWorkEpoch>();
    assert(epoch->TryEnter());
    assert(!epoch->Quiesced());
    epoch->Retire();
    assert(!epoch->TryEnter());
    epoch->Leave();
    assert(epoch->Quiesced());

    auto retiredBeforeEntry = std::make_shared<ASFW::Async::PostedWorkEpoch>();
    retiredBeforeEntry->Retire();
    assert(!retiredBeforeEntry->TryEnter());
    assert(retiredBeforeEntry->Quiesced());

    std::puts("Runtime callback epoch tests passed: entered work drains; retired queued work cannot enter");
}
