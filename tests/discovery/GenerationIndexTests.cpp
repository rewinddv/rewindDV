#include <gtest/gtest.h>

#include "ASFWDriver/ConfigROM/ConfigROMStore.hpp"
#include "ASFWDriver/Discovery/DeviceManager.hpp"
#include "ASFWDriver/Discovery/DeviceRegistry.hpp"

namespace {
using namespace ASFW::Discovery;
constexpr Generation kOld{0};
constexpr Generation kCurrent{0x01000000};
constexpr uint8_t kNode = 2;
ConfigROM MakeROM(Generation generation, Guid64 guid) {
    ConfigROM rom{};
    rom.gen = generation;
    rom.nodeId = kNode;
    rom.bib.guid = guid;
    rom.rawQuadlets = {0x31333934};
    return rom;
}
}

TEST(GenerationIndexTests, ROMHistoryPreservesFullRequestIdentity) {
    ConfigROMStore store;
    store.Insert(MakeROM(kOld, 1));
    store.Insert(MakeROM(kCurrent, 2));
    const auto old = store.CopyByNode(kOld, kNode, true);
    const auto current = store.CopyByNode(kCurrent, kNode, true);
    ASSERT_TRUE(old);
    ASSERT_TRUE(current);
    EXPECT_EQ(old->bib.guid, 1u);
    EXPECT_EQ(old->gen, kOld);
    EXPECT_EQ(current->bib.guid, 2u);
    EXPECT_EQ(current->gen, kCurrent);
}

TEST(GenerationIndexTests, RegistryDoesNotAuthorizeTruncatedGeneration) {
    DeviceRegistry registry;
    (void)registry.UpsertFromROM(MakeROM(kCurrent, 2), {});
    EXPECT_FALSE(registry.SnapshotByNode(kOld, kNode));
    const auto current = registry.SnapshotByNode(kCurrent, kNode);
    ASSERT_TRUE(current);
    EXPECT_EQ(current->gen, kCurrent);
}

TEST(GenerationIndexTests, DeviceManagerDoesNotAuthorizeTruncatedGeneration) {
    DeviceRegistry registry;
    DeviceManager manager;
    const auto rom = MakeROM(kCurrent, 2);
    const auto record = registry.UpsertFromROM(rom, {});
    const auto device = manager.UpsertDevice(record, rom);
    ASSERT_TRUE(device);
    EXPECT_EQ(manager.GetDeviceByNode(kOld, kNode), nullptr);
    EXPECT_EQ(manager.GetDeviceByNode(kCurrent, kNode), device);
}

namespace {
ConfigROM PersonaROM() {
    auto rom = MakeROM(Generation{1}, 0x1122334455667788);
    rom.rootDirMinimal = {{CfgKey::VendorId, 1, 0, 0}, {CfgKey::ModelId, 2, 0, 0},
                         {CfgKey::Unit_Spec_Id, 0x00a02d, 0, 0},
                         {CfgKey::Unit_Sw_Version, 0x010001, 0, 0}};
    rom.modelName = "before";
    return rom;
}
}

TEST(DevicePersonaTests, SameROMResetPreservesDeviceAndUnit) {
    DeviceRegistry registry;
    DeviceManager manager;
    auto rom = PersonaROM();
    const auto device = manager.UpsertDevice(registry.UpsertFromROM(rom, {}), rom);
    const auto unit = device->GetUnits().front();
    const auto oldRoute = registry.CurrentRoute(rom.bib.guid);
    registry.InvalidateLiveMappingsForBusReset();
    manager.SuspendAllForBusReset();
    rom.gen = Generation{2}; rom.nodeId = 3; rom.state = ROMState::Validated;
    rom.firstSeen = Generation{1}; rom.lastValidated = Generation{2};
    const auto resumed = manager.UpsertDevice(registry.UpsertFromROM(rom, {}), rom);
    EXPECT_EQ(resumed, device);
    EXPECT_EQ(resumed->GetUnits().front(), unit);
    EXPECT_EQ(registry.CurrentRoute(rom.bib.guid)->deviceIncarnation, oldRoute->deviceIncarnation);
    EXPECT_NE(registry.CurrentRoute(rom.bib.guid)->routeEpoch, oldRoute->routeEpoch);
    EXPECT_FALSE(registry.IsCurrent(*oldRoute));
}

TEST(DevicePersonaTests, ChangedParsedROMReplacesAndTerminatesOldUnits) {
    DeviceManager manager;
    DeviceRecord record{}; record.guid = 1; record.gen = Generation{1}; record.nodeId = 2;
    auto rom = PersonaROM();
    const auto first = manager.UpsertDevice(record, rom);
    const auto oldUnit = first->GetUnits().front();
    manager.SuspendAllForBusReset();
    record.gen = Generation{2}; record.modelId = 99;
    rom.rootDirMinimal.back().value = 0x010002;
    const auto replacement = manager.UpsertDevice(record, rom);
    ASSERT_NE(replacement, first);
    EXPECT_TRUE(first->IsTerminated());
    EXPECT_TRUE(oldUnit->IsTerminated());
    EXPECT_EQ(replacement->GetModelID(), 99u);
    EXPECT_EQ(replacement->GetUnits().front()->GetUnitSwVersion(), 0x010002u);
}

TEST(DevicePersonaTests, IdentityFieldsAndRawBytesEachInvalidatePersona) {
    DeviceRecord record{}; record.guid = 1;
    const auto original = PersonaROM();
    auto device = FWDevice::Create(record, original);
    auto changed = original; changed.rawQuadlets.back() ^= 1;
    EXPECT_FALSE(device->MatchesROM(changed));
    changed = original; changed.bib.maxRec = 9;
    EXPECT_FALSE(device->MatchesROM(changed));
    changed = original; changed.modelName = "new";
    EXPECT_FALSE(device->MatchesROM(changed));
    changed = original; changed.unitDirectories.push_back(UnitDirectory{.unitSpecId = 1});
    EXPECT_FALSE(device->MatchesROM(changed));
    changed = original; changed.rootDirMinimal.back().entryType = 3;
    EXPECT_FALSE(device->MatchesROM(changed));
    device->Terminate();
}

TEST(DevicePersonaTests, RapidReplacementDoesNotRetainRemovedOwners) {
    DeviceRegistry registry;
    DeviceManager manager;
    auto rom = PersonaROM();
    auto device = manager.UpsertDevice(registry.UpsertFromROM(rom, {}), rom);
    for (uint32_t n = 0; n != 128; ++n) {
        std::weak_ptr<FWDevice> previous = device;
        const auto oldRoute = *registry.CurrentRoute(rom.bib.guid);
        registry.InvalidateLiveMappingsForBusReset();
        manager.SuspendAllForBusReset();
        registry.RetireDevice(rom.bib.guid);
        manager.TerminateDevice(rom.bib.guid);
        rom.gen = Generation{n % 2}; // Raw generation wrap/repetition is not identity.
        rom.rawQuadlets[0] = n;
        device = manager.UpsertDevice(registry.UpsertFromROM(rom, {}), rom);
        EXPECT_TRUE(previous.expired());
        EXPECT_FALSE(registry.IsCurrent(oldRoute));
        EXPECT_GT(registry.CurrentRoute(rom.bib.guid)->deviceIncarnation, oldRoute.deviceIncarnation);
        EXPECT_EQ(registry.SnapshotAll().size(), 1u);
    }
}

TEST(DevicePersonaTests, MissingIdentityDoesNotInheritPreviousObservation) {
    DeviceRegistry registry;
    auto rom = PersonaROM();
    const auto first = registry.UpsertFromROM(rom, {});
    ASSERT_EQ(first.modelId, 2u);
    rom.rootDirMinimal.clear();
    const auto next = registry.UpsertFromROM(rom, {});
    EXPECT_EQ(next.modelId, 0u);
    EXPECT_EQ(next.vendorId, 0u);
}

TEST(DevicePersonaTests, ClearAndReconnectCannotAliasRetainedRoute) {
    DeviceRegistry registry;
    const auto rom = PersonaROM();
    (void)registry.UpsertFromROM(rom, {});
    const auto old = *registry.CurrentRoute(rom.bib.guid);
    registry.Clear();
    (void)registry.UpsertFromROM(rom, {});
    EXPECT_FALSE(registry.IsCurrent(old));
    EXPECT_GT(registry.CurrentRoute(rom.bib.guid)->deviceIncarnation, old.deviceIncarnation);
    EXPECT_GT(registry.CurrentRoute(rom.bib.guid)->routeEpoch, old.routeEpoch);
}
