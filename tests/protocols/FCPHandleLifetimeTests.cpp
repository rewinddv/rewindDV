#include <gtest/gtest.h>

#include "ASFWDriver/Async/Track/LabelAllocator.hpp"
#include "ASFWDriver/Discovery/FWDevice.hpp"
#include "ASFWDriver/Protocols/AVC/FCPTransport.hpp"
#include "DeferredFireWireBus.hpp"
#include "FakeSessionScheduler.hpp"

#include <map>

namespace {
using namespace ASFW;
using namespace ASFW::Protocols::AVC;

// Exercise the production allocator's 64-label reuse with the transport's real
// callbacks. The hardware boundary is deferred; release precedes completion as
// in TransactionCompletionHandler. No controller or MMIO is involved.
class RecyclingBus : public Async::Testing::DeferredFireWireBus {
public:
    Async::AsyncHandle WriteBlock(FW::Generation, FW::NodeId, Async::FWAddress,
                                  std::span<const uint8_t>, FW::FwSpeed,
                                  Async::InterfaceCompletionCallback callback) override {
        const auto label = labels.Allocate();
        if (label == Async::LabelAllocator::kInvalidLabel) return {};
        const Async::AsyncHandle handle{static_cast<uint32_t>(label + 1)};
        callbacks.emplace(handle.value, std::move(callback));
        writes.push_back(handle);
        if (inlineNext.has_value()) {
            const auto status = *inlineNext;
            inlineNext.reset();
            Complete(handle, status);
        }
        return handle;
    }

    bool Cancel(Async::AsyncHandle handle) override {
        cancellations.push_back(handle);
        return Complete(handle, Async::AsyncStatus::kAborted);
    }

    bool Complete(Async::AsyncHandle handle, Async::AsyncStatus status) {
        const auto it = callbacks.find(handle.value);
        if (it == callbacks.end()) return false;
        auto callback = std::move(it->second);
        callbacks.erase(it);
        labels.Free(static_cast<uint8_t>(handle.value - 1));
        if (callback) callback(status, {});
        return true;
    }

    Async::AsyncHandle SubmitOther(Async::InterfaceCompletionCallback callback = {}) {
        return WriteBlock(FW::Generation{1}, FW::NodeId{2}, {}, {},
                          FW::FwSpeed::S100, std::move(callback));
    }

    Async::AsyncHandle ReuseFirstHandle(Async::InterfaceCompletionCallback callback) {
        for (unsigned i = 0; i < 63; ++i) {
            const auto handle = SubmitOther();
            EXPECT_TRUE(Complete(handle, Async::AsyncStatus::kSuccess));
        }
        return SubmitOther(std::move(callback));
    }

    Async::LabelAllocator labels;
    std::map<uint32_t, Async::InterfaceCompletionCallback> callbacks;
    std::vector<Async::AsyncHandle> writes;
    std::vector<Async::AsyncHandle> cancellations;
    std::optional<Async::AsyncStatus> inlineNext;
};

struct Fixture {
    RecyclingBus bus;
    Testing::FakeSessionScheduler scheduler;
    Discovery::DeviceRegistry routes;
    std::shared_ptr<Discovery::FWDevice> device;
    std::shared_ptr<FCPTransport> transport = std::make_shared<FCPTransport>();
    static constexpr uint64_t guid = 0x1020304050607ULL;

    Fixture() {
        Discovery::DeviceRecord record{};
        record.guid = guid;
        record.nodeId = 2;
        record.gen = FW::Generation{1};
        Discovery::ConfigROM rom{};
        rom.bib.guid = guid;
        rom.nodeId = 2;
        rom.gen = FW::Generation{1};
        device = Discovery::FWDevice::Create(routes.UpsertFromROM(rom, {}), rom);
        FCPTransportConfig config{};
        config.timeoutMs = 10;
        config.maxRetries = 1;
        EXPECT_TRUE(transport->init(&bus, &bus, device.get(), routes, scheduler, config));
    }
    ~Fixture() { transport->Shutdown(); }

    static FCPFrame Command() {
        FCPFrame command{};
        command.length = 3;
        command.data[0] = 1;
        command.data[1] = 0xff;
        command.data[2] = 0x30;
        return command;
    }
};

class FCPCompletedHandleTests : public ::testing::TestWithParam<std::tuple<bool, int>> {};

TEST_P(FCPCompletedHandleTests, CompletedWriteCannotCancelReusedLabel) {
    Fixture f;
    const auto [inlineCompletion, action] = GetParam();
    if (inlineCompletion) f.bus.inlineNext = Async::AsyncStatus::kSuccess;
    auto results = std::make_shared<std::vector<FCPStatus>>();
    FCPCommandPolicy policy{};
    policy.retryClass = action == 3 ? FCPRetryClass::kIdempotent : FCPRetryClass::kNever;
    const auto command = f.transport->SubmitCommand(
        Fixture::Command(), [results](auto status, const auto&) { results->push_back(status); }, policy);
    ASSERT_TRUE(command.IsValid());
    ASSERT_EQ(f.bus.writes.size(), 1U);
    const auto completedHandle = f.bus.writes.front();
    if (!inlineCompletion) ASSERT_TRUE(f.bus.Complete(completedHandle, Async::AsyncStatus::kSuccess));

    auto otherResults = std::make_shared<std::vector<Async::AsyncStatus>>();
    const auto other = f.bus.ReuseFirstHandle(
        [otherResults](auto status, auto) { otherResults->push_back(status); });
    ASSERT_EQ(other.value, completedHandle.value);
    switch (action) {
        case 0: EXPECT_TRUE(f.transport->CancelCommand(command)); break;
        case 1: f.transport->Shutdown(); break;
        case 2: f.transport->OnBusReset(2); break;
        case 3: f.scheduler.Advance(10'000'000); break;
    }
    EXPECT_TRUE(otherResults->empty());
    EXPECT_TRUE(f.bus.cancellations.empty());
    ASSERT_TRUE(f.bus.Complete(other, Async::AsyncStatus::kSuccess));
    EXPECT_EQ(*otherResults, std::vector{Async::AsyncStatus::kSuccess});
    if (action == 3) {
        EXPECT_EQ(f.bus.writes.size(), 65U); // timeout fences instead of replaying
        EXPECT_TRUE(f.transport->CopyUncertainResponseEvidence().admissionFenced);
    }
    EXPECT_EQ(results->size(), 1U);
    f.transport->Shutdown();
    EXPECT_EQ(results->size(), 1U);
}

INSTANTIATE_TEST_SUITE_P(DeferredAndInline, FCPCompletedHandleTests,
                        ::testing::Combine(::testing::Bool(), ::testing::Range(0, 4)));

TEST(FCPHandleLifetimeTests, FailedWriteFencesWithoutRetryOrCancelOfCompletedAttempt) {
    for (bool inlineCompletion : {false, true}) {
        Fixture f;
        if (inlineCompletion) f.bus.inlineNext = Async::AsyncStatus::kTimeout;
        auto results = std::make_shared<std::vector<FCPStatus>>();
        FCPCommandPolicy policy{};
        policy.retryClass = FCPRetryClass::kIdempotent;
        (void)f.transport->SubmitCommand(Fixture::Command(),
            [results](auto status, const auto&) { results->push_back(status); }, policy);
        if (!inlineCompletion) {
            ASSERT_TRUE(f.bus.Complete(f.bus.writes.front(), Async::AsyncStatus::kTimeout));
        }
        ASSERT_EQ(f.bus.writes.size(), 1U);
        EXPECT_TRUE(f.bus.cancellations.empty());
        EXPECT_TRUE(f.transport->CopyUncertainResponseEvidence().admissionFenced);
        f.scheduler.Advance(10'000'000);
        EXPECT_EQ(*results, std::vector{FCPStatus::kTransportError});
    }
}

TEST(FCPHandleLifetimeTests, InlineCompletionThenObserverShutdownCannotCancelReusedLabel) {
    Fixture f;
    f.bus.inlineNext = Async::AsyncStatus::kSuccess;
    auto results = std::make_shared<std::vector<FCPStatus>>();
    auto otherResults = std::make_shared<std::vector<Async::AsyncStatus>>();
    Async::AsyncHandle other{};
    FCPCommandPolicy policy{};
    policy.attemptObserver = [&](const auto& evidence) {
        if (evidence.stage != FCPAttemptStage::kAsyncTransportAccepted) return;
        other = f.bus.ReuseFirstHandle(
            [otherResults](auto status, auto) { otherResults->push_back(status); });
        f.transport->Shutdown();
    };
    (void)f.transport->SubmitCommand(Fixture::Command(),
        [results](auto status, const auto&) { results->push_back(status); }, policy);
    EXPECT_TRUE(f.bus.cancellations.empty());
    EXPECT_TRUE(otherResults->empty());
    EXPECT_EQ(results->size(), 1U);
    EXPECT_TRUE(f.bus.Complete(other, Async::AsyncStatus::kSuccess));
}

TEST(FCPHandleLifetimeTests, RetiredSubmissionCannotWriteOrCompleteReplacement) {
    Fixture f;
    auto original = std::make_shared<std::vector<FCPStatus>>();
    auto replacement = std::make_shared<std::vector<FCPStatus>>();
    FCPCommandPolicy policy{};
    policy.attemptObserver = [&](const auto& evidence) {
        if (evidence.stage == FCPAttemptStage::kRouteBound) f.transport->OnBusReset(2);
    };
    const auto handle = f.transport->SubmitCommand(Fixture::Command(),
        [&](auto status, const auto&) {
            original->push_back(status);
            EXPECT_TRUE(f.transport->SubmitCommand(Fixture::Command(),
                [replacement](auto result, const auto&) { replacement->push_back(result); }).IsValid());
        }, policy);
    EXPECT_FALSE(handle.IsValid());
    EXPECT_EQ(*original, std::vector{FCPStatus::kBusReset});
    EXPECT_TRUE(replacement->empty());
    ASSERT_EQ(f.bus.writes.size(), 1U);
    EXPECT_TRUE(f.bus.cancellations.empty());
    ASSERT_TRUE(f.bus.Complete(f.bus.writes.back(), Async::AsyncStatus::kSuccess));
    f.scheduler.Advance(10'000'000);
    EXPECT_EQ(*replacement, std::vector{FCPStatus::kTimeout});
    f.transport->Shutdown();
}
} // namespace
