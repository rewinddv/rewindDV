#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <utility>

namespace ASFW::Shared {

// A fixed-capacity ledger for native source cancellation. The owner closes
// callback admission before populating this ledger, retains the entire runtime,
// and never releases it until AllTerminal(). A failed request or deadline is
// permanent quarantine, including when a late completion is subsequently seen.
// This is an ownership barrier, not a second runtime admission authority.
class NativeCallbackDrain final {
public:
    static constexpr uint8_t kCapacity = 8;
    using Ticket = uint8_t;
    enum class State { Admitted, Active, CancelRequested, Draining, Terminal, Quarantined };

    // Registration and Seal run on the lifecycle queue. Completion and request
    // return can race or occur inline; neither alone authorizes a release.
    [[nodiscard]] std::optional<Ticket> BeginSource(std::function<void()> release, uint8_t retainedOwnerReferences = 0) {
        if (sealed_.load(std::memory_order_acquire) || count_ == kCapacity) {
            Quarantine();
            return std::nullopt;
        }
        const Ticket ticket = count_++;
        entries_[ticket].release = std::move(release);
        entries_[ticket].retainedOwnerReferences = retainedOwnerReferences;
        retainedOwners_.fetch_add(retainedOwnerReferences, std::memory_order_relaxed);
        entries_[ticket].flags.store(kRequested, std::memory_order_release);
        return ticket;
    }

    void RequestReturned(Ticket ticket, bool success) noexcept {
        if (ticket >= kCapacity) { Quarantine(); return; }
        entries_[ticket].flags.fetch_or(kReturned | (success ? kAccepted : kFailed),
                                       std::memory_order_acq_rel);
        if (!success) Quarantine();
        TryRetire(ticket);
    }

    void CompletionObserved(Ticket ticket) noexcept {
        if (ticket >= kCapacity) { Quarantine(); return; }
        entries_[ticket].flags.fetch_or(kObserved, std::memory_order_acq_rel);
        TryRetire(ticket);
    }

    void Seal() noexcept {
        registered_.store(count_, std::memory_order_release);
        sealed_.store(true, std::memory_order_release);
        Notify();
    }

    [[nodiscard]] bool AllTerminal() const noexcept {
        return sealed_.load(std::memory_order_acquire) &&
            terminal_.load(std::memory_order_acquire) == registered_.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool Quarantined() const noexcept {
        return quarantined_.load(std::memory_order_acquire);
    }
    void Quarantine() noexcept {
        quarantined_.store(true, std::memory_order_release);
        Notify();
    }
    [[nodiscard]] State SourceState(Ticket ticket) const noexcept {
        if (ticket >= kCapacity || Quarantined()) return State::Quarantined;
        const auto flags = entries_[ticket].flags.load(std::memory_order_acquire);
        if (flags & kRetired) return State::Terminal;
        if (flags & kReturned) return State::Draining;
        if (flags & kRequested) return State::CancelRequested;
        return State::Active;
    }
    [[nodiscard]] State AggregateState() const noexcept {
        if (Quarantined()) return State::Quarantined;
        if (AllTerminal()) return State::Terminal;
        if (sealed_.load(std::memory_order_acquire)) return State::Draining;
        return State::Admitted;
    }

    // Published ledger telemetry, not OSObject reference counts. Registration
    // is published by Seal; owner counts cover only references transferred to
    // these entries and fall only after the actual release callback returns.
    [[nodiscard]] uint8_t RegisteredSources() const noexcept {
        return registered_.load(std::memory_order_acquire);
    }
    [[nodiscard]] uint8_t TerminalSources() const noexcept {
        return terminal_.load(std::memory_order_acquire);
    }
    [[nodiscard]] uint32_t RetainedOwnerReferences() const noexcept {
        return retainedOwners_.load(std::memory_order_acquire);
    }

    // Set once before any source is registered. The notifier must not access a
    // borrowed runtime and must remain valid even after a timeout.
    void SetNotifier(std::function<void()> notifier) { notifier_ = std::move(notifier); }

private:
    static constexpr uint32_t kRequested = 1u << 0;
    static constexpr uint32_t kReturned = 1u << 1;
    static constexpr uint32_t kAccepted = 1u << 2;
    static constexpr uint32_t kObserved = 1u << 3;
    static constexpr uint32_t kRetired = 1u << 4;
    static constexpr uint32_t kFailed = 1u << 5;
    struct Entry {
        std::atomic<uint32_t> flags{0};
        std::function<void()> release;
        uint8_t retainedOwnerReferences{0};
    };

    void TryRetire(Ticket ticket) noexcept {
        auto& entry = entries_[ticket];
        auto flags = entry.flags.load(std::memory_order_acquire);
        for (;;) {
            if ((flags & (kReturned | kAccepted | kObserved)) !=
                    (kReturned | kAccepted | kObserved) || (flags & (kFailed | kRetired))) return;
            if (entry.flags.compare_exchange_weak(flags, flags | kRetired,
                                                  std::memory_order_acq_rel,
                                                  std::memory_order_acquire)) break;
        }
        if (entry.release) entry.release();
        entry.release = {};
        retainedOwners_.fetch_sub(entry.retainedOwnerReferences, std::memory_order_release);
        terminal_.fetch_add(1, std::memory_order_release);
        Notify();
    }
    void Notify() noexcept { if (notifier_) notifier_(); }

    std::array<Entry, kCapacity> entries_{};
    uint8_t count_{0};
    std::atomic<uint8_t> registered_{0};
    std::atomic<uint8_t> terminal_{0};
    std::atomic<uint32_t> retainedOwners_{0};
    std::atomic<bool> sealed_{false};
    std::atomic<bool> quarantined_{false};
    std::function<void()> notifier_;
};

} // namespace ASFW::Shared
