#include "../../../ASFWDriver/Shared/Completion/NativeSourceRetirement.hpp"

#include <Block.h>
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

using ASFW::Shared::NativeCallbackDrain;
using ASFW::Shared::RetireNativeSource;

namespace {
struct FakeAction final : OSAction {
    explicit FakeAction(int& released) : released_(released) {}
    ~FakeAction() override { ++released_; }
    int& released_;
};

// This models the documented DriverKit completion protocol, not native OS
// scheduling. Actual production adapter code is compiled against this source.
struct FakeSource final : OSObject {
    explicit FakeSource(int& released) : released_(released) {}
    ~FakeSource() override { if (callback_) Block_release(callback_); ++released_; }
    kern_return_t Cancel(void (^callback)(void)) {
        ++requests;
        callback_ = Block_copy(callback);
        if (inlineCompletion) callback_();
        return result;
    }
    kern_return_t SetEnableWithCompletion(bool enabled, void (^callback)(void)) {
        assert(!enabled);
        return Cancel(callback);
    }
    void FireTwice() {
        assert(activeCallbacks == 0); // Native completion is the borrower barrier.
        auto callback = Block_copy(callback_);
        callback();
        callback();
        Block_release(callback);
    }
    int& released_;
    void (^callback_)(void){nullptr};
    bool inlineCompletion{false};
    kern_return_t result{kIOReturnSuccess};
    unsigned requests{0};
    unsigned activeCallbacks{0};
};

void AdapterDeferredAndDuplicate() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* raw = source.get();
    RetireNativeSource(source, action, drain);
    drain->Seal();
    assert(!source && !action && !drain->AllTerminal());
    assert(sources == 0 && actions == 0);
    raw->FireTwice();
    assert(drain->AllTerminal() && !drain->Quarantined());
    assert(sources == 1 && actions == 1);
}

// A copied native block must own the ledger independently of the caller's
// shared_ptr variable. Existing fixtures kept that variable unchanged until
// callback delivery and therefore missed reference captures in C++ Blocks.
void AdapterCallerReferenceChanges(bool disable) {
    int sources = 0, actions = 0;
    auto owner = std::make_shared<NativeCallbackDrain>();
    auto callerReference = owner;
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* raw = source.get();
    if (disable) ASFW::Shared::DisableNativeSource(raw, callerReference);
    else RetireNativeSource(source, action, callerReference);
    owner->Seal();
    callerReference.reset();
    raw->FireTwice();
    assert(owner->AllTerminal() && !owner->Quarantined());
    if (disable) {
        assert(source && action && sources == 0 && actions == 0);
        action.reset(); source.reset();
    }
    assert(sources == 1 && actions == 1);
}

void AdapterCallerScopeEnds(bool disable) {
    int sources = 0, actions = 0;
    std::weak_ptr<NativeCallbackDrain> ledger;
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* raw = source.get();
    {
        auto caller = std::make_shared<NativeCallbackDrain>();
        ledger = caller;
        if (disable) ASFW::Shared::DisableNativeSource(raw, caller);
        else RetireNativeSource(source, action, caller);
        caller->Seal();
    }
    // The copied native completion, not a surviving caller variable, owns it.
    assert(!ledger.expired());
    std::thread delayedCompletion([raw] { raw->FireTwice(); });
    delayedCompletion.join();
    if (disable) { action.reset(); source.reset(); }
    assert(ledger.expired() && sources == 1 && actions == 1);
}

struct BorrowedRuntime {
    explicit BorrowedRuntime(int& destroyed) : destroyed_(destroyed) {}
    ~BorrowedRuntime() { ++destroyed_; }
    int& destroyed_;
    int callbacks{0};
};

void StopWhileCallbackBorrowsRuntime() {
    int sources = 0, actions = 0, graphs = 0;
    auto runtime = std::make_unique<BorrowedRuntime>(graphs);
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* raw = source.get();
    auto* borrower = runtime.get();
    raw->activeCallbacks = 1;
    RetireNativeSource(source, action, drain); // Stop closes admission, requests Cancel.
    drain->Seal();
    assert(raw->requests == 1 && !drain->AllTerminal());
    assert(drain->RegisteredSources() == 1 && drain->TerminalSources() == 0);
    assert(drain->RetainedOwnerReferences() == 2);
    // Cancel return cannot release the graph while the admitted callback runs.
    assert(graphs == 0 && sources == 0 && actions == 0);
    ++borrower->callbacks;
    assert(borrower->callbacks == 1);
    raw->activeCallbacks = 0;
    raw->FireTwice(); // Platform reports terminal only after borrower return.
    assert(drain->AllTerminal() && drain->RetainedOwnerReferences() == 0);
    assert(drain->TerminalSources() == 1 && sources == 1 && actions == 1);
    runtime.reset();
    assert(graphs == 1);
}

void MissingCompletionKeepsOwnersAndQuarantine() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* rawSource = source.get(); auto* rawAction = action.get();
    RetireNativeSource(source, action, drain);
    drain->Seal();
    drain->Quarantine(); // Independent supervisor's missing-completion outcome.
    assert(!drain->AllTerminal() && drain->Quarantined());
    assert(drain->TerminalSources() == 0 && drain->RetainedOwnerReferences() == 2);
    assert(sources == 0 && actions == 0);
    // Fixture disposal only. Production retains these owners and refuses restart.
    rawAction->release(); rawSource->release();
}

void OwnerTelemetryPublishesAfterRelease() {
    NativeCallbackDrain drain;
    unsigned releases = 0;
    const auto ticket = *drain.BeginSource([&] {
        assert(!drain.AllTerminal());
        assert(drain.RetainedOwnerReferences() == 2);
        ++releases;
    }, 2);
    drain.RequestReturned(ticket, true); drain.Seal();
    drain.CompletionObserved(ticket); drain.CompletionObserved(ticket);
    assert(releases == 1 && drain.AllTerminal());
    assert(drain.TerminalSources() == drain.RegisteredSources());
    assert(drain.RetainedOwnerReferences() == 0);
}

void AdapterInline() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    source->inlineCompletion = true;
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    RetireNativeSource(source, action, drain);
    drain->Seal();
    assert(drain->AllTerminal());
    assert(sources == 1 && actions == 1);
}

void AdapterFailure(bool inlineCompletion) {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* rawSource = source.get();
    auto* rawAction = action.get();
    source->result = kIOReturnError;
    source->inlineCompletion = inlineCompletion;
    RetireNativeSource(source, action, drain);
    drain->Seal();
    rawSource->FireTwice();
    assert(drain->Quarantined() && !drain->AllTerminal());
    assert(sources == 0 && actions == 0);
    // Only the fixture reclaims the deliberately quarantined references.
    // Production preserves the full runtime and never offers restart.
    rawAction->release();
    rawSource->release();
}

void DisablePreservesRegistration() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    ASFW::Shared::DisableNativeSource(source.get(), drain);
    drain->Seal();
    assert(!drain->AllTerminal());
    source->FireTwice();
    assert(drain->AllTerminal() && source && action);
    assert(sources == 0 && actions == 0);
}

void DisableFailureKeepsRegistration() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    source->result = kIOReturnError;
    ASFW::Shared::DisableNativeSource(source.get(), drain);
    drain->Seal(); source->FireTwice();
    assert(drain->Quarantined() && !drain->AllTerminal());
    assert(drain->RetainedOwnerReferences() == 0); // Registration owners stayed outside ledger.
    assert(source && action && sources == 0 && actions == 0);
}

void LedgerDeadlineAndLateCompletion() {
    int releases = 0;
    NativeCallbackDrain drain;
    auto ticket = *drain.BeginSource([&] { ++releases; });
    drain.RequestReturned(ticket, true);
    drain.Seal();
    assert(drain.SourceState(ticket) == NativeCallbackDrain::State::Draining);
    drain.Quarantine();
    assert(!drain.AllTerminal() && releases == 0);
    drain.CompletionObserved(ticket);
    assert(drain.AllTerminal() && releases == 1);
    assert(drain.Quarantined()); // late proof never becomes restart permission
}

void LedgerCompletesOnlyAfterSealAndAllSources() {
    NativeCallbackDrain drain;
    int releases = 0;
    for (uint8_t i = 0; i < NativeCallbackDrain::kCapacity; ++i) {
        const auto ticket = *drain.BeginSource([&] { ++releases; });
        drain.RequestReturned(ticket, true);
        drain.CompletionObserved(ticket);
        assert(!drain.AllTerminal());
    }
    drain.Seal();
    assert(drain.AllTerminal() && releases == NativeCallbackDrain::kCapacity);
    assert(!drain.BeginSource([] {}));
    assert(drain.Quarantined());
}

void LedgerRequestCompletionRace() {
    for (unsigned repeat = 0; repeat < 10000; ++repeat) {
        NativeCallbackDrain drain;
        std::atomic<unsigned> releases{0};
        const auto ticket = *drain.BeginSource([&] { releases.fetch_add(1); });
        drain.Seal();
        std::thread a([&] { drain.RequestReturned(ticket, true); });
        std::thread b([&] { drain.CompletionObserved(ticket); drain.CompletionObserved(ticket); });
        a.join(); b.join();
        assert(drain.AllTerminal() && releases.load() == 1);
    }
}

void IndependentIncarnations() {
    NativeCallbackDrain old, replacement;
    int oldReleases = 0, newReleases = 0;
    const auto oldTicket = *old.BeginSource([&] { ++oldReleases; });
    old.RequestReturned(oldTicket, true);
    old.Seal();
    const auto newTicket = *replacement.BeginSource([&] { ++newReleases; });
    replacement.RequestReturned(newTicket, true);
    replacement.Seal();
    old.CompletionObserved(oldTicket);
    old.CompletionObserved(oldTicket);
    assert(old.AllTerminal() && oldReleases == 1);
    assert(!replacement.AllTerminal() && newReleases == 0);
    replacement.CompletionObserved(newTicket);
    assert(replacement.AllTerminal() && newReleases == 1);
}

void AdapterDeadlineThenLateCompletion() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
    auto* raw = source.get();
    RetireNativeSource(source, action, drain);
    drain->Seal();
    drain->Quarantine();
    assert(sources == 0 && actions == 0 && !drain->AllTerminal());
    raw->FireTwice();
    assert(sources == 1 && actions == 1 && drain->AllTerminal());
    assert(drain->Quarantined());
}

void AggregateKeepsPartialDrainClosed() {
    NativeCallbackDrain drain;
    int releases = 0;
    std::array<NativeCallbackDrain::Ticket, 6> tickets;
    for (auto& ticket : tickets) {
        ticket = *drain.BeginSource([&] { ++releases; });
        drain.RequestReturned(ticket, true);
    }
    drain.Seal();
    for (size_t i = 0; i + 1 < tickets.size(); ++i) {
        drain.CompletionObserved(tickets[i]);
        assert(!drain.AllTerminal());
    }
    assert(releases == 5);
    drain.CompletionObserved(tickets.back());
    assert(releases == 6 && drain.AllTerminal());
}

void RepeatedSuccessfulRetirementHasNoLiveOwners() {
    int sources = 0, actions = 0;
    for (unsigned repeat = 1; repeat <= 5000; ++repeat) {
        auto drain = std::make_shared<NativeCallbackDrain>();
        OSSharedPtr<FakeSource> source(new FakeSource(sources), OSNoRetain);
        OSSharedPtr<OSAction> action(new FakeAction(actions), OSNoRetain);
        auto* raw = source.get();
        RetireNativeSource(source, action, drain);
        drain->Seal();
        std::weak_ptr<NativeCallbackDrain> weak = drain;
        raw->FireTwice();
        assert(drain->AllTerminal() && drain->RetainedOwnerReferences() == 0);
        drain.reset();
        assert(weak.expired());
        assert(sources == repeat && actions == repeat);
    }
}

void ProviderDeliveryAliasesSurviveUntilRootRelease() {
    int sources = 0, actions = 0;
    auto drain = std::make_shared<NativeCallbackDrain>();
    OSSharedPtr<FakeSource> deliverySource(new FakeSource(sources), OSNoRetain);
    OSSharedPtr<OSAction> deliveryAction(new FakeAction(actions), OSNoRetain);
    auto retirementSource = deliverySource;
    auto retirementAction = deliveryAction;
    RetireNativeSource(retirementSource, retirementAction, drain);
    drain->Seal();
    // A queued provider handler can still resolve its exact source and action.
    assert(deliverySource && deliveryAction && !drain->AllTerminal());
    deliverySource->FireTwice();
    assert(drain->AllTerminal() && sources == 0 && actions == 0);
    deliveryAction.reset();
    deliverySource.reset();
    assert(sources == 1 && actions == 1);
}
} // namespace

int main() {
    const auto started = std::chrono::steady_clock::now();
    AdapterDeferredAndDuplicate();
    AdapterInline();
    AdapterCallerReferenceChanges(false);
    AdapterCallerReferenceChanges(true);
    AdapterCallerScopeEnds(false);
    AdapterCallerScopeEnds(true);
    StopWhileCallbackBorrowsRuntime();
    MissingCompletionKeepsOwnersAndQuarantine();
    OwnerTelemetryPublishesAfterRelease();
    AdapterFailure(false);
    AdapterFailure(true);
    DisablePreservesRegistration();
    DisableFailureKeepsRegistration();
    LedgerDeadlineAndLateCompletion();
    LedgerCompletesOnlyAfterSealAndAllSources();
    LedgerRequestCompletionRace();
    IndependentIncarnations();
    AdapterDeadlineThenLateCompletion();
    AggregateKeepsPartialDrainClosed();
    RepeatedSuccessfulRetirementHasNoLiveOwners();
    ProviderDeliveryAliasesSurviveUntilRootRelease();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::cout << "Native callback drain: 21 host contract scenarios passed; 10000 concurrent interleavings; "
              << "5000 successful owner-release cycles; ledger_bytes=" << sizeof(NativeCallbackDrain)
              << " elapsed_ms=" << elapsed << "; no native/hardware qualification\n";
}
