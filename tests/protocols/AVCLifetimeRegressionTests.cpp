#include <gtest/gtest.h>

#include "ASFWDriver/Discovery/DeviceManager.hpp"
#include "ASFWDriver/Audio/Model/ASFWAudioDevice.hpp"
#include "ASFWDriver/Protocols/AVC/AVCDiscovery.hpp"
#include "ASFWDriver/Protocols/AVC/Music/MusicSubunit.hpp"
#include "ASFWDriver/Protocols/AVC/StreamFormats/AVCStreamFormatCommands.hpp"
#include "DeferredFireWireBus.hpp"
#include "FakeSessionScheduler.hpp"

#include <deque>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace {
using namespace ASFW::Protocols::AVC;
using namespace ASFW::Protocols::AVC::StreamFormats;
using ASFW::Async::AsyncStatus;

// Private access is enabled only for this host target. The fixture seeds the
// real ownership graph; all submissions, callbacks and reset handling are real.
class AVCLifetimeRegressionTests : public ::testing::Test {
protected:
    void SetUp() override {
        ASFW::Discovery::ConfigROM rom{};
        rom.bib.guid = 0x0001020304050607;
        rom.gen = ASFW::FW::Generation{1};
        rom.nodeId = 2;
        rom.rootDirMinimal = {
            {ASFW::Discovery::CfgKey::Unit_Spec_Id, 0x00A02D, 0, 0},
            {ASFW::Discovery::CfgKey::Unit_Sw_Version, 0x010001, 0, 0}};
        const auto record = registry.UpsertFromROM(rom, {});
        device = manager.UpsertDevice(record, rom);
        ASSERT_TRUE(device);
        ASSERT_FALSE(device->GetUnits().empty());
        unit = std::make_shared<AVCUnit>(device, device->GetUnits().front(),
                                       registry, bus, bus, scheduler);
        music = std::make_shared<Music::MusicSubunit>(AVCSubunitType::kMusic0C, 0);
        unit->subunits_.push_back(music);
    }
    void TearDown() override { if (unit) unit->Shutdown(); }
    void Respond(std::vector<uint8_t> response) {
        ASSERT_TRUE(bus.CompleteNextWrite(AsyncStatus::kSuccess));
        unit->GetFCPTransport().OnFCPResponse(2, 1, response);
    }
    ASFW::Async::Testing::DeferredFireWireBus bus;
    ASFW::Testing::FakeSessionScheduler scheduler;
    ASFW::Discovery::DeviceRegistry registry;
    ASFW::Discovery::DeviceManager manager;
    std::shared_ptr<ASFW::Discovery::FWDevice> device;
    std::shared_ptr<AVCUnit> unit;
    std::shared_ptr<Music::MusicSubunit> music;
    int completions{0};
};

class DescriptorFallbackLifetimeTests : public AVCLifetimeRegressionTests,
                                        public ::testing::WithParamInterface<bool> {};

TEST_P(DescriptorFallbackLifetimeTests, DeferredChunksRetainAccessorAndUnit) {
    auto completion = [this](bool) { ++completions; };
    if (GetParam()) music->ParseCapabilities(*unit, completion);
    else music->ReadStatusDescriptor(*unit, completion);
    ASSERT_EQ(bus.PendingWriteCount(), 1u);
    const auto open = bus.PendingWriteAt(0).data;
    ASSERT_GE(open.size(), 3u);
    ASSERT_EQ(open[2], 0x08); // real descriptor OPEN
    Respond({0x0A, music->GetAddress(), 0x08}); // device rejects OPEN
    ASSERT_EQ(bus.PendingWriteCount(), 1u);
    EXPECT_EQ(bus.PendingWriteAt(0).data[2], 0x09);
    auto transport = unit->GetFCPTransportShared();
    std::weak_ptr<AVCUnit> unitLifetime = unit;
    unit.reset();
    ASSERT_FALSE(unitLifetime.expired());
    const auto respond = [&](std::vector<uint8_t> response) {
        ASSERT_TRUE(bus.CompleteNextWrite(AsyncStatus::kSuccess));
        transport->OnFCPResponse(2, 1, response);
    };
    // Return from OPEN's callback, then deliver a two-chunk direct READ.
    // A zero advertised length uses the existing status-based termination.
    respond({0x09, music->GetAddress(), 0x09, 0x80, 0x11, 0xFF,
             0, 2, 0, 0, 0, 0});
    ASSERT_EQ(bus.PendingWriteCount(), 1u);
    respond({0x09, music->GetAddress(), 0x09, 0x80, 0x10, 0xFF,
             0, 2, 0, 2, 0, 0});
    EXPECT_EQ(completions, 1);
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
    EXPECT_TRUE(unitLifetime.expired());
}
INSTANTIATE_TEST_SUITE_P(StatusAndCapabilities, DescriptorFallbackLifetimeTests,
                        ::testing::Bool());

class DeferredSubmitter final : public IAVCCommandSubmitter {
public:
    void SubmitCommand(const AVCCdb& cdb, AVCCompletion completion) override {
        pending.emplace_back(cdb, std::move(completion));
        ++submitted;
    }
    void Complete(bool success) {
        auto [response, completion] = std::move(pending.front());
        pending.pop_front(); // fixture must not retain completed callbacks
        EXPECT_EQ(response.opcode, 0xBF);
        EXPECT_EQ(response.operands[0], 0xC1);
        if (success) {
            const uint8_t format[] = {0x90, 0x40, 0x04, 0x02, 0x01, 0x02, 0x06};
            std::copy(std::begin(format), std::end(format), response.operands.begin() + 8);
            response.operandLength = 15;
            response.ctype = 0x0C;
            completion(AVCResult::kImplementedStable, response);
        } else {
            completion(AVCResult::kNotImplemented, response);
        }
    }
    std::deque<std::pair<AVCCdb, AVCCompletion>> pending;
    size_t submitted{0};
};

class FormatContinuationLifetimeTests : public ::testing::TestWithParam<int> {};
TEST_P(FormatContinuationLifetimeTests, TerminalOutcomeReleasesEveryContinuation) {
    const bool outer = GetParam() >= 3;
    const int mode = GetParam() % 3; // empty, failure, full 16-entry enumeration
    for (int cycle = 0; cycle < 100; ++cycle) {
        DeferredSubmitter submitter;
        Music::MusicSubunit music(AVCSubunitType::kMusic0C, 0);
        auto retained = std::make_shared<int>(cycle);
        std::weak_ptr<int> lifetime = retained;
        int completions = 0;
        if (outer) {
            if (mode != 0) {
                PlugInfo plug{};
                plug.plugID = 0;
                plug.direction = PlugDirection::kInput;
                music.plugs_.push_back(plug);
            }
            music.QuerySupportedFormats(submitter, [retained, &completions](bool ok) {
                EXPECT_TRUE(ok);
                ++completions;
            });
        } else {
            QueryAllSupportedFormats(submitter, 0x60, 0, true,
                [retained, &completions, mode](std::vector<AudioStreamFormat> formats) {
                    EXPECT_EQ(formats.size(), mode == 2 ? 16u : 0u);
                    ++completions;
                }, mode == 0 ? 0 : 16);
        }
        retained.reset();
        for (size_t step = 0; !submitter.pending.empty() && step < 17; ++step)
            submitter.Complete(mode == 2);
        ASSERT_TRUE(submitter.pending.empty());
        EXPECT_EQ(submitter.submitted, mode == 0 ? 0u : mode == 1 ? 1u : 16u);
        EXPECT_EQ(completions, 1);
        ASSERT_TRUE(lifetime.expired()) << "mode=" << GetParam() << " cycle=" << cycle;
    }
}
INSTANTIATE_TEST_SUITE_P(InnerAndOuterTerminalPaths, FormatContinuationLifetimeTests,
                        ::testing::Range(0, 6));

TEST_F(AVCLifetimeRegressionTests, ResetRetiresRescanBeforeInlineAbortReentry) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    const auto guid = device->GetGUID();
    discovery->units_[guid] = unit;
    discovery->ScheduleRescan(guid, unit);
    scheduler.Advance(250'000'000);
    ASSERT_EQ(bus.PendingWriteCount(), 1u);
    ASSERT_EQ(bus.PendingWriteAt(0).data[0], 0x00); // CONTROL
    ASSERT_EQ(bus.PendingWriteAt(0).data[2], 0x08); // descriptor OPEN
    ASSERT_TRUE(bus.CompleteNextWrite(AsyncStatus::kSuccess));
    registry.InvalidateLiveMappingsForBusReset();
    discovery->OnBusReset(2); // abort reenters IsRescanCurrent synchronously
    EXPECT_TRUE(discovery->activeRescanSerialByGuid_.empty());
    EXPECT_TRUE(discovery->rescanTimersByGuid_.empty());
    EXPECT_EQ(scheduler.PendingCount(), 0u);
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
    discovery->Shutdown();
}
TEST_F(AVCLifetimeRegressionTests, OldUnitReferenceCannotResolveReplacement) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    discovery->units_[device->GetGUID()] = unit;
    const auto oldFWUnit = device->GetUnits().front();
    ASFW::Discovery::ConfigROM changed{};
    changed.bib.guid = device->GetGUID(); changed.gen = ASFW::FW::Generation{2}; changed.nodeId = 3;
    changed.rootDirMinimal = {{ASFW::Discovery::CfgKey::Unit_Spec_Id, 0x00a02d, 0, 0},
                             {ASFW::Discovery::CfgKey::Unit_Sw_Version, 0x010002, 0, 0}};
    registry.RetireDevice(device->GetGUID());
    manager.TerminateDevice(device->GetGUID());
    auto next = manager.UpsertDevice(registry.UpsertFromROM(changed, {}), changed);
    ASSERT_NE(next, device);
    EXPECT_EQ(discovery->GetAVCUnit(oldFWUnit), nullptr);
    EXPECT_NE(discovery->GetAVCUnit(next->GetUnits().front()), nullptr);
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, OldInitializationAndRescanCannotAdoptNewRoute) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    auto replacement = std::make_shared<AVCUnit>(device, device->GetUnits().front(),
                                                registry, bus, bus, scheduler);
    discovery->units_[device->GetGUID()] = replacement;
    discovery->HandleInitializedUnit(device->GetGUID(), unit);
    discovery->ScheduleRescan(device->GetGUID(), unit);
    EXPECT_TRUE(discovery->rescanTimersByGuid_.empty());
    EXPECT_TRUE(discovery->activeRescanSerialByGuid_.empty());
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, RemovalCancelsTimersAndRejectsLateTimerDelivery) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    const auto guid = device->GetGUID();
    discovery->units_[guid] = unit;
    discovery->ScheduleRescan(guid, unit);
    ASSERT_FALSE(discovery->rescanTimersByGuid_.empty());
    ASSERT_TRUE(discovery->RetireDeviceWork(guid));
    registry.RetireDevice(guid);
    discovery->OnUnitTerminated(device->GetUnits().front());
    EXPECT_TRUE(discovery->rescanTimersByGuid_.empty());
    EXPECT_TRUE(discovery->activeRescanSerialByGuid_.empty());
    scheduler.Advance(250'000'000);
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
    EXPECT_EQ(scheduler.PendingCount(), 0u);
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, ActiveUnitWorkBlocksReplacementUntilTerminal) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    const auto guid = device->GetGUID();
    discovery->units_[guid] = unit;
    {
        ASFW::Shared::PostedWorkEpoch::Lease callback(*unit->DeferredWorkEpoch());
        ASSERT_TRUE(callback);
        EXPECT_FALSE(discovery->RetireDeviceWork(guid));
        discovery->ScheduleRescan(guid, unit);
        EXPECT_TRUE(discovery->rescanTimersByGuid_.empty());
    }
    EXPECT_TRUE(discovery->RetireDeviceWork(guid));
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, EnteredRescanBlocksRuntimeReleaseAndQueuedWorkCannotReenter) {
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                  bus, bus, scheduler, nullptr);
    discovery->units_[device->GetGUID()] = unit;
    {
        ASFW::Shared::PostedWorkEpoch::Lease callback(*discovery->deferredWorkEpoch_);
        ASSERT_TRUE(callback);
        EXPECT_FALSE(discovery->RetireDeferredWork());
    }
    EXPECT_TRUE(discovery->RetireDeferredWork());
    discovery->ScheduleRescan(device->GetGUID(), unit);
    EXPECT_TRUE(discovery->rescanTimersByGuid_.empty());
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, ActualEnteredRescanPreventsDeviceAndRuntimeRetirement) {
    class BlockingBus final : public ASFW::Async::Testing::DeferredFireWireBus {
    public:
        ASFW::Async::AsyncHandle WriteBlock(ASFW::FW::Generation generation, ASFW::FW::NodeId node,
            ASFW::Async::FWAddress address, std::span<const uint8_t> bytes, ASFW::FW::FwSpeed speed,
            ASFW::Async::InterfaceCompletionCallback completion) override {
            {
                std::unique_lock guard(lock);
                entered = true;
                changed.notify_all();
                EXPECT_TRUE(changed.wait_for(guard, std::chrono::seconds(2), [&] { return released; }));
            }
            return DeferredFireWireBus::WriteBlock(generation, node, address, bytes, speed,
                                                   std::move(completion));
        }
        std::mutex lock;
        std::condition_variable changed;
        bool entered{false}, released{false};
    } blockingBus;
    auto activeUnit = std::make_shared<AVCUnit>(device, device->GetUnits().front(),
                                               registry, blockingBus, blockingBus, scheduler);
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
        blockingBus, blockingBus, scheduler, nullptr);
    const auto guid = device->GetGUID();
    discovery->units_[guid] = activeUnit;
    discovery->rescanQueue_ = OSSharedPtr<IODispatchQueue>(new IODispatchQueue(), OSNoRetain);
    discovery->rescanQueue_->SetManualDispatchForTesting(true);
    discovery->ScheduleRescan(guid, activeUnit);
    scheduler.Advance(250'000'000);
    std::thread delivery([&] { discovery->rescanQueue_->DrainAllForTesting(); });
    {
        std::unique_lock guard(blockingBus.lock);
        const bool entered = blockingBus.changed.wait_for(guard, std::chrono::seconds(2),
                                                          [&] { return blockingBus.entered; });
        EXPECT_TRUE(entered);
        if (entered) {
            EXPECT_FALSE(discovery->RetireDeviceWork(guid));
            EXPECT_FALSE(discovery->RetireDeferredWork());
        }
        blockingBus.released = true;
        blockingBus.changed.notify_all();
    }
    delivery.join();
    EXPECT_TRUE(discovery->RetireDeviceWork(guid));
    EXPECT_TRUE(discovery->RetireDeferredWork());
    discovery->Shutdown();
}

TEST_F(AVCLifetimeRegressionTests, RetainedFCPTransportCannotFollowReplacementIncarnation) {
    const auto guid = device->GetGUID();
    registry.RetireDevice(guid);
    ASFW::Discovery::ConfigROM replacement{};
    replacement.bib.guid = guid; replacement.gen = ASFW::FW::Generation{1}; replacement.nodeId = 2;
    (void)registry.UpsertFromROM(replacement, {});
    FCPFrame command{};
    command.length = 3; command.data[0] = 1; command.data[1] = 0xff; command.data[2] = 0x30;
    unsigned called = 0;
    (void)unit->GetFCPTransport().SubmitCommand(command, [&](FCPStatus status, const FCPFrame&) {
        ++called; EXPECT_NE(status, FCPStatus::kOk);
    });
    EXPECT_EQ(called, 1u);
    EXPECT_EQ(bus.PendingWriteCount(), 0u);
}

TEST_F(AVCLifetimeRegressionTests, DuetPublicationHoldsBothRetirementLeasesThroughListenerReturn) {
    class Listener final : public ASFW::Audio::IAVCAudioConfigListener {
    public:
        std::function<void()> callback;
        void OnAVCAudioConfigurationReady(uint64_t,
            const ASFW::Audio::Model::ASFWAudioDevice&) noexcept override { callback(); }
    } listener;
    auto discovery = std::make_shared<AVCDiscovery>(nullptr, registry, manager,
                                                   bus, bus, scheduler, &listener);
    const auto guid = device->GetGUID();
    discovery->units_[guid] = unit;
    auto operation = std::make_shared<AVCDiscovery::DuetPrefetchOperation>();
    operation->route = *registry.CurrentRoute(guid);
    operation->unit = unit;
    operation->state.clockVerified = true;
    discovery->activeDuetPrefetchByGuid_[guid] = operation;
    unsigned publications = 0;
    listener.callback = [&] {
        ++publications;
        EXPECT_FALSE(discovery->RetireDeviceWork(guid));
        EXPECT_FALSE(discovery->RetireDeferredWork());
    };
    ASFW::Audio::Model::ASFWAudioDevice config{};
    discovery->FinishDuetPrefetch(operation, config, "test");
    EXPECT_EQ(publications, 1u);
    EXPECT_TRUE(discovery->RetireDeviceWork(guid));
    EXPECT_TRUE(discovery->RetireDeferredWork());
    discovery->FinishDuetPrefetch(operation, config, "late-duplicate");
    EXPECT_EQ(publications, 1u);
    discovery->Shutdown();
}

}
