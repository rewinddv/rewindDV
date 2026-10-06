#include <gtest/gtest.h>

#include "ASFWDriver/Discovery/DeviceRegistry.hpp"
#include "ASFWDriver/Discovery/FWDevice.hpp"
#include "ASFWDriver/Protocols/AVC/FCPTransport.hpp"
#include "DeferredFireWireBus.hpp"
#include "FakeSessionScheduler.hpp"

namespace {

using ASFW::Async::AsyncStatus;
using ASFW::Async::Testing::DeferredFireWireBus;
using ASFW::Discovery::ConfigROM;
using ASFW::Discovery::DeviceRecord;
using ASFW::Discovery::DeviceRegistry;
using ASFW::Discovery::FWDevice;
using ASFW::FW::Generation;
using ASFW::Protocols::AVC::FCPCompletion;
using ASFW::Protocols::AVC::FCPFrame;
using ASFW::Protocols::AVC::FCPStatus;
using ASFW::Protocols::AVC::FCPTransport;
using ASFW::Protocols::AVC::FCPTransportConfig;
using ASFW::Testing::FakeSessionScheduler;

constexpr uint64_t kMillisecondNs = 1'000'000ULL;
constexpr uint64_t kGuid = 0x0001020304050607ULL;

FCPFrame MakeUnitInfoCommand() {
    FCPFrame command{};
    command.length = 3;
    command.data[0] = 0x00;  // STATUS
    command.data[1] = 0xFF;  // unit subunit address
    command.data[2] = 0x30;  // UNIT_INFO
    return command;
}

std::array<uint8_t, 3> MakeAcceptedUnitInfoResponse() {
    return {0x09, 0xFF, 0x30};  // ACCEPTED, unit, UNIT_INFO
}

// Models callbacks already extracted by the native scheduler before Cancel.
class ExtractedTimerScheduler final : public ASFW::Scheduling::ITimerScheduler {
public:
    ASFW::Scheduling::TimerToken ScheduleAfter(uint64_t, std::function<void()> fn) override {
        callbacks.push_back(std::move(fn));
        return callbacks.size();
    }
    void Cancel(ASFW::Scheduling::TimerToken) override {}
    std::vector<std::function<void()>> callbacks;
};

class FCPTransportTests : public ::testing::Test {
protected:
    [[nodiscard]] static ConfigROM MakeROM(Generation generation, uint16_t nodeId) {
        ConfigROM rom{};
        rom.bib.guid = kGuid;
        rom.gen = generation;
        rom.nodeId = nodeId;
        return rom;
    }

    void RebindRoute(Generation generation, uint16_t nodeId) {
        routes_.InvalidateLiveMappingsForBusReset();
        (void)routes_.UpsertFromROM(MakeROM(generation, nodeId), {});
    }

    void SetUp() override {
        DeviceRecord record{};
        record.guid = kGuid;
        record.nodeId = 2;
        record.gen = Generation{1};
        const auto rom = MakeROM(record.gen, record.nodeId);
        device_ = FWDevice::Create(routes_.UpsertFromROM(rom, {}), rom);
        ASSERT_NE(device_, nullptr);

        config_.timeoutMs = 10;
        config_.interimTimeoutMs = 25;
        config_.maxRetries = 0;
        transport_ = std::make_shared<FCPTransport>();
        ASSERT_TRUE(transport_->init(&bus_, &bus_, device_.get(), routes_, scheduler_, config_));
    }

    void TearDown() override {
        if (transport_) {
            transport_->Shutdown();
        }
    }

    // ASFireWire 0b628948: survives TestBody so Shutdown in TearDown can
    // complete deliberately stranded requests without touching dead locals.
    int outstandingCompletionCount_{0};
    class FencedBus : public DeferredFireWireBus {
    public:
        void FenceUncertainResponse() noexcept override { ++fenceCount; }
        unsigned fenceCount{0};
    } bus_;
    FakeSessionScheduler scheduler_;
    DeviceRegistry routes_;
    std::shared_ptr<FWDevice> device_;
    std::shared_ptr<FCPTransport> transport_;
    FCPTransportConfig config_{};
};

TEST_F(FCPTransportTests, AcceptsResponseBeforeCommandWriteCompletion) {
    int completionCount = 0;
    FCPStatus completionStatus = FCPStatus::kTransportError;
    const auto command = MakeUnitInfoCommand();
    const auto response = MakeAcceptedUnitInfoResponse();

    const auto handle = transport_->SubmitCommand(
        command, [&completionCount, &completionStatus](FCPStatus status, const FCPFrame&) {
            ++completionCount;
            completionStatus = status;
        });
    ASSERT_TRUE(handle.IsValid());
    ASSERT_EQ(bus_.PendingWriteCount(), 1U);

    transport_->OnFCPResponse(2, 1, response);
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(completionStatus, FCPStatus::kOk);

    // AR Request is drained before AR Response. Once the target's FCP write
    // proves delivery, the queued local write acknowledgement is stale.
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(completionStatus, FCPStatus::kOk);
}

TEST_F(FCPTransportTests, IgnoresResponseFromDifferentGeneration) {
    int completionCount = 0;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; })
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));

    const auto response = MakeAcceptedUnitInfoResponse();
    transport_->OnFCPResponse(2, 2, response);
    EXPECT_EQ(completionCount, 0);

    transport_->OnFCPResponse(2, 1, response);
    EXPECT_EQ(completionCount, 1);
}

TEST_F(FCPTransportTests, RejectsResponseForInvalidatedRouteAfterRebind) {
    int& completionCount = outstandingCompletionCount_;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; })
                    .IsValid());
    ASSERT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.WriteAt(0).nodeId.value, 2U);
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));

    // A rebind invalidates the old token. No callback from the prior route may
    // complete the logical operation, even if its node/generation are retained.
    RebindRoute(Generation{2}, 3);

    const auto response = MakeAcceptedUnitInfoResponse();
    transport_->OnFCPResponse(3, 1, response);
    EXPECT_EQ(completionCount, 0);

    transport_->OnFCPResponse(2, 1, response);
    EXPECT_EQ(completionCount, 0);
}

TEST_F(FCPTransportTests, RejectsWriteCompletionFromInvalidatedRoute) {
    int& completionCount = outstandingCompletionCount_;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; })
                    .IsValid());
    ASSERT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.WriteAt(0).nodeId.value, 2U);
    EXPECT_EQ(bus_.WriteAt(0).generation.value, 1U);

    // The write was issued against the old token. A rebind before completion
    // makes both that completion and its later response stale.
    RebindRoute(Generation{2}, 3);

    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    EXPECT_EQ(bus_.fenceCount, 1U);
    const auto response = MakeAcceptedUnitInfoResponse();
    transport_->OnFCPResponse(3, 2, response);
    EXPECT_EQ(completionCount, 1);

    transport_->OnFCPResponse(2, 1, response);
    EXPECT_EQ(completionCount, 1);
}

TEST_F(FCPTransportTests, ExtractedTimerCannotExpireExtendedOrReplacementCommand) {
    transport_->Shutdown();
    ExtractedTimerScheduler extracted;
    transport_ = std::make_shared<FCPTransport>();
    ASSERT_TRUE(transport_->init(&bus_, &bus_, device_.get(), routes_, extracted, config_));
    int first = 0;
    int second = 0;
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { EXPECT_EQ(status, FCPStatus::kOk); ++first; }).IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    ASSERT_EQ(extracted.callbacks.size(), 1u);
    const auto oldDeadline = extracted.callbacks[0];
    const std::array<uint8_t, 3> interim{0x0F, 0xFF, 0x30};
    transport_->OnFCPResponse(2, 1, interim);
    ASSERT_EQ(extracted.callbacks.size(), 2u);
    oldDeadline();
    EXPECT_EQ(first, 0);
    EXPECT_EQ(bus_.fenceCount, 0u);
    const auto accepted = MakeAcceptedUnitInfoResponse();
    transport_->OnFCPResponse(2, 1, accepted);
    ASSERT_EQ(first, 1);
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { EXPECT_EQ(status, FCPStatus::kOk); ++second; }).IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    oldDeadline();
    extracted.callbacks[1]();
    EXPECT_EQ(second, 0);
    EXPECT_EQ(bus_.fenceCount, 0u);
    transport_->OnFCPResponse(2, 1, accepted);
    EXPECT_EQ(second, 1);
    transport_->Shutdown();
    transport_.reset(); // injected scheduler outlives its borrower
}

TEST_F(FCPTransportTests, StartsTimeoutOnlyAfterCommandWriteCompletes) {
    int completionCount = 0;
    FCPStatus completionStatus = FCPStatus::kOk;

    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount, &completionStatus](FCPStatus status, const FCPFrame&) {
                                 ++completionCount;
                                 completionStatus = status;
                             })
                    .IsValid());

    scheduler_.Advance(config_.timeoutMs * 2ULL * kMillisecondNs);
    EXPECT_EQ(completionCount, 0);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);

    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    ASSERT_EQ(scheduler_.PendingCount(), 1U);
    scheduler_.Advance(config_.timeoutMs * kMillisecondNs - 1);
    EXPECT_EQ(completionCount, 0);

    scheduler_.Advance(1);
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(completionStatus, FCPStatus::kTimeout);
}

TEST_F(FCPTransportTests, CancellingCommandCancelsItsTimeout) {
    int completionCount = 0;
    const auto handle = transport_->SubmitCommand(
        MakeUnitInfoCommand(), [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; });
    ASSERT_TRUE(handle.IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    ASSERT_EQ(scheduler_.PendingCount(), 1U);

    EXPECT_TRUE(transport_->CancelCommand(handle));
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);

    scheduler_.Advance(config_.timeoutMs * kMillisecondNs);
    EXPECT_EQ(completionCount, 1);

    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completionCount, 1);
}

TEST_F(FCPTransportTests, WriteFailureCompletesWithoutArmingResponseTimeout) {
    FCPStatus completionStatus = FCPStatus::kOk;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionStatus](FCPStatus status, const FCPFrame&) {
                                 completionStatus = status;
                             })
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kTimeout));

    EXPECT_EQ(completionStatus, FCPStatus::kTransportError);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);
}

TEST_F(FCPTransportTests, SynchronousWriteAdmissionFailureCompletesExactlyOnce) {
    bus_.FailNextWriteBlock();
    int completionCount = 0;
    FCPStatus completionStatus = FCPStatus::kOk;

    const auto handle = transport_->SubmitCommand(
        MakeUnitInfoCommand(),
        [&completionCount, &completionStatus](FCPStatus status, const FCPFrame&) {
            ++completionCount;
            completionStatus = status;
        });

    EXPECT_FALSE(handle.IsValid());
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(completionStatus, FCPStatus::kTransportError);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);
}

TEST_F(FCPTransportTests, InterimResponseExtendsDeadlineWithoutCompletingCommand) {
    int completionCount = 0;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; })
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    ASSERT_EQ(scheduler_.PendingCount(), 1U);

    constexpr std::array<uint8_t, 3> interim{0x0F, 0xFF, 0x30};
    transport_->OnFCPResponse(2, 1, interim);
    EXPECT_EQ(completionCount, 0);
    EXPECT_EQ(scheduler_.PendingCount(), 1U);

    scheduler_.Advance(config_.timeoutMs * kMillisecondNs);
    EXPECT_EQ(completionCount, 0);
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completionCount, 1);
}

TEST_F(FCPTransportTests, ResetFencesIssuedCommandDespiteIdempotentRetryPreference) {
    config_.allowBusResetRetry = true;
    config_.maxRetries = 1;
    transport_->Shutdown();
    transport_ = std::make_shared<FCPTransport>();
    ASSERT_TRUE(transport_->init(&bus_, &bus_, device_.get(), routes_, scheduler_, config_));

    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.retryClass = ASFW::Protocols::AVC::FCPRetryClass::kIdempotent;
    int completionCount = 0;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount](FCPStatus, const FCPFrame&) { ++completionCount; },
                             std::move(policy))
                    .IsValid());
    ASSERT_EQ(bus_.PendingWriteCount(), 1U);

    bus_.SetGeneration(Generation{2});
    routes_.InvalidateLiveMappingsForBusReset();
    transport_->OnBusReset(2);

    EXPECT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.PendingWriteCount(), 0U);
    EXPECT_EQ(completionCount, 1);

    // A new route is not proof that buffered old FCP responses retired.
    (void)routes_.UpsertFromROM(MakeROM(Generation{2}, 3), {});
    const auto route = routes_.CurrentRoute(kGuid);
    ASSERT_TRUE(route.has_value());
    transport_->OnRouteRevalidated(*route);
    EXPECT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.PendingWriteCount(), 0U);
    EXPECT_EQ(bus_.fenceCount, 1U);
    transport_->OnFCPResponse(3, 2, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completionCount, 1);
}

TEST_F(FCPTransportTests, ShutdownCompletesPendingAndQueuedCommandsExactlyOnce) {
    std::vector<FCPStatus> completions;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completions](FCPStatus status, const FCPFrame&) { completions.push_back(status); })
                    .IsValid());
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completions](FCPStatus status, const FCPFrame&) { completions.push_back(status); })
                    .IsValid());

    transport_->Shutdown();
    ASSERT_EQ(completions.size(), 2U);
    EXPECT_EQ(completions[0], FCPStatus::kTransportError);
    EXPECT_EQ(completions[1], FCPStatus::kTransportError);
    EXPECT_EQ(bus_.PendingWriteCount(), 0U);

    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completions.size(), 2U);
}

// PR #130's completion concern, exercised through public admission/observer
// seams rather than mutating private state into an unreachable configuration.
// Shared results remain alive even if an ASSERT exits before fixture teardown.
TEST_F(FCPTransportTests, UninitializedTransportRejectsWithoutStrandingCompletion) {
    auto uninitialized = std::make_shared<FCPTransport>();
    auto results = std::make_shared<std::vector<FCPStatus>>();
    const auto handle = uninitialized->SubmitCommand(
        MakeUnitInfoCommand(), [results](FCPStatus status, const FCPFrame&) {
            results->push_back(status);
        });
    EXPECT_FALSE(handle.IsValid());
    uninitialized->Shutdown();
    uninitialized.reset();
    EXPECT_EQ(*results, std::vector<FCPStatus>{FCPStatus::kTransportError});
    EXPECT_EQ(bus_.WriteCount(), 0U);
}

TEST_F(FCPTransportTests, AdmissionAfterShutdownCompletesOnceWithoutWriting) {
    transport_->Shutdown();
    auto results = std::make_shared<std::vector<FCPStatus>>();
    const auto handle = transport_->SubmitCommand(
        MakeUnitInfoCommand(), [results](FCPStatus status, const FCPFrame&) {
            results->push_back(status);
        });
    EXPECT_FALSE(handle.IsValid());
    transport_->Shutdown();
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    scheduler_.Advance(100 * kMillisecondNs);
    EXPECT_EQ(*results, std::vector<FCPStatus>{FCPStatus::kTransportError});
    EXPECT_EQ(bus_.WriteCount(), 0U);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);
}

TEST_F(FCPTransportTests, ShutdownBetweenRouteBindingAndWriteDrainsAdmittedAndQueued) {
    auto results = std::make_shared<std::vector<FCPStatus>>();
    const FCPCompletion completion = [results](FCPStatus status, const FCPFrame&) {
        results->push_back(status);
    };
    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.attemptObserver = [this, completion](auto evidence) {
        if (evidence.stage != ASFW::Protocols::AVC::FCPAttemptStage::kRouteBound) return;
        EXPECT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(), completion).IsValid());
        transport_->Shutdown();
    };
    const auto handle = transport_->SubmitCommand(MakeUnitInfoCommand(), completion, policy);
    EXPECT_FALSE(handle.IsValid());
    EXPECT_EQ(*results, (std::vector<FCPStatus>{FCPStatus::kTransportError,
                                               FCPStatus::kTransportError}));
    EXPECT_EQ(bus_.WriteCount(), 0U);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);
    transport_->Shutdown();
    scheduler_.Advance(100 * kMillisecondNs);
    EXPECT_EQ(results->size(), 2U);
}

TEST_F(FCPTransportTests, ShutdownDuringQueuedPromotionCompletesOnceWithoutSecondWrite) {
    auto results = std::make_shared<std::vector<FCPStatus>>();
    const FCPCompletion completion = [results](FCPStatus status, const FCPFrame&) {
        results->push_back(status);
    };
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(), completion).IsValid());
    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.attemptObserver = [this](auto evidence) {
        if (evidence.stage == ASFW::Protocols::AVC::FCPAttemptStage::kRouteBound)
            transport_->Shutdown();
    };
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(), completion, policy).IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(*results, (std::vector<FCPStatus>{FCPStatus::kOk, FCPStatus::kTransportError}));
    EXPECT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.PendingWriteCount(), 0U);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    scheduler_.Advance(100 * kMillisecondNs);
    EXPECT_EQ(results->size(), 2U);
}

TEST_F(FCPTransportTests, RouteLossBeforeWriteCompletesAndDoesNotBlockNextCommand) {
    auto results = std::make_shared<std::vector<FCPStatus>>();
    const FCPCompletion completion = [results](FCPStatus status, const FCPFrame&) {
        results->push_back(status);
    };
    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.attemptObserver = [this](auto evidence) {
        if (evidence.stage == ASFW::Protocols::AVC::FCPAttemptStage::kRouteBound)
            routes_.InvalidateLiveMappingsForBusReset();
    };
    EXPECT_FALSE(transport_->SubmitCommand(MakeUnitInfoCommand(), completion, policy).IsValid());
    EXPECT_EQ(*results, std::vector<FCPStatus>{FCPStatus::kTransportError});
    EXPECT_EQ(bus_.WriteCount(), 0U);
    EXPECT_EQ(scheduler_.PendingCount(), 0U);

    bus_.SetGeneration(Generation{2});
    RebindRoute(Generation{2}, 3);
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(), completion).IsValid());
    ASSERT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.WriteAt(0).generation.value, 2U);
    EXPECT_EQ(bus_.WriteAt(0).nodeId.value, 3U);
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    transport_->OnFCPResponse(3, 2, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(*results, (std::vector<FCPStatus>{FCPStatus::kTransportError, FCPStatus::kOk}));
}

TEST_F(FCPTransportTests, NonIdempotentCommandCompletesOnBusResetWithoutReplay) {
    FCPStatus completionStatus = FCPStatus::kOk;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionStatus](FCPStatus status, const FCPFrame&) {
                                 completionStatus = status;
                             })
                    .IsValid());
    ASSERT_EQ(bus_.WriteCount(), 1U);

    bus_.SetGeneration(Generation{2});
    transport_->OnBusReset(2);

    EXPECT_EQ(completionStatus, FCPStatus::kBusReset);
    EXPECT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.PendingWriteCount(), 0U);
}

TEST_F(FCPTransportTests, ControlCommandDoesNotRetryAfterTimeout) {
    config_.maxRetries = 1;
    transport_->Shutdown();
    transport_ = std::make_shared<FCPTransport>();
    ASSERT_TRUE(transport_->init(&bus_, &bus_, device_.get(), routes_, scheduler_, config_));

    FCPStatus completionStatus = FCPStatus::kOk;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionStatus](FCPStatus status, const FCPFrame&) {
                                 completionStatus = status;
                             })
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    scheduler_.Advance(config_.timeoutMs * kMillisecondNs);

    EXPECT_EQ(completionStatus, FCPStatus::kTimeout);
    EXPECT_EQ(bus_.WriteCount(), 1U);
}

TEST_F(FCPTransportTests, IdempotentCommandDoesNotReplayUncertainTimedOutResponse) {
    config_.maxRetries = 1;
    transport_->Shutdown();
    transport_ = std::make_shared<FCPTransport>();
    ASSERT_TRUE(transport_->init(&bus_, &bus_, device_.get(), routes_, scheduler_, config_));

    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.retryClass = ASFW::Protocols::AVC::FCPRetryClass::kIdempotent;
    FCPStatus completionStatus = FCPStatus::kTransportError;
    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionStatus](FCPStatus status, const FCPFrame&) {
                                 completionStatus = status;
                             },
                             std::move(policy))
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    scheduler_.Advance(config_.timeoutMs * kMillisecondNs);
    ASSERT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.fenceCount, 1U);
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completionStatus, FCPStatus::kTimeout);
}

TEST_F(FCPTransportTests, CommandSpecificMatcherRejectsSameOpcodeStaleResponse) {
    int completionCount = 0;
    FCPStatus completionStatus = FCPStatus::kTransportError;
    ASFW::Protocols::AVC::FCPCommandPolicy policy{};
    policy.responseMatcher = [](std::span<const uint8_t>, std::span<const uint8_t> response) {
        return response.size() >= 4U && response[3] == 0xA5U;
    };

    ASSERT_TRUE(transport_->SubmitCommand(
                             MakeUnitInfoCommand(),
                             [&completionCount, &completionStatus](FCPStatus status, const FCPFrame&) {
                                 ++completionCount;
                                 completionStatus = status;
                             },
                             std::move(policy))
                    .IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));

    constexpr std::array<uint8_t, 4> stale{0x09, 0xFF, 0x30, 0x00};
    transport_->OnFCPResponse(2, 1, stale);
    EXPECT_EQ(completionCount, 0);

    constexpr std::array<uint8_t, 4> matching{0x09, 0xFF, 0x30, 0xA5};
    transport_->OnFCPResponse(2, 1, matching);
    EXPECT_EQ(completionCount, 1);
    EXPECT_EQ(completionStatus, FCPStatus::kOk);
}

TEST_F(FCPTransportTests, QueuesCommandsFifoAndAllowsQueuedCancellation) {
    std::vector<uint32_t> completions;
    const auto first = transport_->SubmitCommand(
        MakeUnitInfoCommand(), [&completions](FCPStatus, const FCPFrame&) { completions.push_back(1); });
    const auto second = transport_->SubmitCommand(
        MakeUnitInfoCommand(), [&completions](FCPStatus status, const FCPFrame&) {
            completions.push_back(status == FCPStatus::kOk ? 2U : 20U);
        });
    const auto third = transport_->SubmitCommand(
        MakeUnitInfoCommand(), [&completions](FCPStatus status, const FCPFrame&) {
            completions.push_back(status == FCPStatus::kTransportError ? 3U : 30U);
        });

    ASSERT_TRUE(first.IsValid());
    ASSERT_TRUE(second.IsValid());
    ASSERT_TRUE(third.IsValid());
    EXPECT_NE(first.transactionID, second.transactionID);
    EXPECT_EQ(bus_.WriteCount(), 1U);

    EXPECT_TRUE(transport_->CancelCommand(third));
    EXPECT_EQ(completions, std::vector<uint32_t>{3});

    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completions, (std::vector<uint32_t>{3, 1}));
    EXPECT_EQ(bus_.WriteCount(), 2U);

    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(completions, (std::vector<uint32_t>{3, 1, 2}));
    EXPECT_EQ(bus_.WriteCount(), 2U);
}

TEST_F(FCPTransportTests, TimedOutResponseCannotSatisfyIdenticalNewCommand) {
    unsigned timedOut = 0, nextSuccess = 0, nextRejected = 0;
    const auto old = transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { if (status == FCPStatus::kTimeout) ++timedOut; });
    ASSERT_TRUE(old.IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    scheduler_.Advance(10 * kMillisecondNs);
    EXPECT_EQ(timedOut, 1U);
    const auto next = transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) {
            if (status == FCPStatus::kOk) ++nextSuccess;
            if (status == FCPStatus::kTransportError) ++nextRejected;
        });
    EXPECT_FALSE(next.IsValid());
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(nextSuccess, 0U);
    EXPECT_EQ(nextRejected, 1U);
    EXPECT_EQ(bus_.WriteCount(), 1U);
    EXPECT_EQ(bus_.fenceCount, 1U);
    const auto evidence = transport_->CopyUncertainResponseEvidence();
    EXPECT_TRUE(evidence.admissionFenced);
    EXPECT_EQ(evidence.responsesObserved, 1U);
    ASSERT_TRUE(evidence.latestResponse.has_value());
    EXPECT_EQ(evidence.latestResponse->response.data[0], 0x09);
    EXPECT_EQ(evidence.latestResponse->classification,
              ASFW::Protocols::AVC::FCPResponseClassification::kMismatch);
}

TEST_F(FCPTransportTests, CancelIssuedCommandFencesAndCompletesQueuedCommandsOnce) {
    unsigned active = 0, queued = 0;
    const auto old = transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto, const auto&) { ++active; });
    const auto waiting = transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { EXPECT_EQ(status, FCPStatus::kTransportError); ++queued; });
    ASSERT_TRUE(old.IsValid()); ASSERT_TRUE(waiting.IsValid());
    EXPECT_TRUE(transport_->CancelCommand(old));
    EXPECT_EQ(active, 1U); EXPECT_EQ(queued, 1U);
    EXPECT_EQ(bus_.WriteCount(), 1U); EXPECT_EQ(bus_.fenceCount, 1U);
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    transport_->OnBusReset(2);
    transport_->Shutdown();
    EXPECT_EQ(active, 1U); EXPECT_EQ(queued, 1U);
    EXPECT_TRUE(transport_->CopyUncertainResponseEvidence().admissionFenced);
}

TEST_F(FCPTransportTests, SynchronouslyRejectedWriteDoesNotFenceFollowingCommand) {
    bus_.FailNextWriteBlock();
    unsigned rejected = 0;
    (void)transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { EXPECT_EQ(status, FCPStatus::kTransportError); ++rejected; });
    EXPECT_EQ(rejected, 1U); EXPECT_EQ(bus_.fenceCount, 0U);
    EXPECT_FALSE(transport_->CopyUncertainResponseEvidence().admissionFenced);
    unsigned success = 0;
    ASSERT_TRUE(transport_->SubmitCommand(MakeUnitInfoCommand(),
        [&](auto status, const auto&) { if (status == FCPStatus::kOk) ++success; }).IsValid());
    ASSERT_TRUE(bus_.CompleteNextWrite(AsyncStatus::kSuccess));
    transport_->OnFCPResponse(2, 1, MakeAcceptedUnitInfoResponse());
    EXPECT_EQ(success, 1U);
}

TEST_F(FCPTransportTests, PendingQueueHasFixedAdmissionBound) {
    unsigned completed = 0, busy = 0;
    for (unsigned i = 0; i < 66; ++i) {
        const auto handle = transport_->SubmitCommand(MakeUnitInfoCommand(),
            [&](auto status, const auto&) { ++completed; if (status == FCPStatus::kBusy) ++busy; });
        EXPECT_EQ(handle.IsValid(), i < 65);
    }
    EXPECT_EQ(busy, 1U);
    transport_->Shutdown();
    EXPECT_EQ(completed, 66U);
}

} // namespace
