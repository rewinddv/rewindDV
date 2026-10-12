#include <gtest/gtest.h>

#include "ASFWDriver/ConfigROM/ROMReader.hpp"
#include "DeferredFireWireBus.hpp"

namespace {
using namespace ASFW;

class ROMReaderLifetimeTests : public ::testing::TestWithParam<int> {};

void BeginRead(Discovery::ROMReader& reader, int kind,
               Discovery::ROMReader::CompletionCallback completion) {
    switch (kind) {
        case 0:
            reader.ReadQuadletsBE(1, FW::Generation{1}, FW::FwSpeed::S100,
                                  0, 2, std::move(completion));
            break;
        case 1:
            reader.ReadBIB(1, FW::Generation{1}, FW::FwSpeed::S100, std::move(completion));
            break;
        case 2:
            reader.ReadRootDirQuadlets(1, FW::Generation{1}, FW::FwSpeed::S100,
                                      0, 0, std::move(completion));
            break;
    }
}

TEST_P(ROMReaderLifetimeTests, QueuedNextQuadletCannotUseRetiredBus) {
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    auto bus = std::make_unique<Async::Testing::DeferredFireWireBus>();
    bus->SetDefaultReadQuadlet(GetParam() == 1 ? 0x04000000 : 0x00020000);
    auto reader = std::make_unique<Discovery::ROMReader>(*bus, queue);
    unsigned completions = 0;
    BeginRead(*reader, GetParam(), [&](auto) { ++completions; });
    ASSERT_EQ(bus->ReadCount(), 1U);
    reader.reset();
    bus.reset();
    EXPECT_GT(queue->DrainReadyForTesting(), 0U);
    // Owner destruction cancels the scan and its notifications. It must not
    // re-enter the retired owner or turn a partial read into successful output.
    EXPECT_EQ(completions, 0U);
}

TEST_P(ROMReaderLifetimeTests, CurrentReadCompletesOnceAndReleasesCallbackState) {
    OSSharedPtr<IODispatchQueue> queue(new IODispatchQueue(), OSNoRetain);
    queue->SetManualDispatchForTesting(true);
    Async::Testing::DeferredFireWireBus bus;
    bus.SetDefaultReadQuadlet(GetParam() == 1 ? 0x04000000 : 0x00020000);
    Discovery::ROMReader reader(bus, queue);
    unsigned completions = 0;
    auto sentinel = std::make_shared<int>(1);
    std::weak_ptr<int> weak = sentinel;
    BeginRead(reader, GetParam(), [sentinel = std::move(sentinel), &completions](auto result) {
        EXPECT_TRUE(result.success);
        ++completions;
    });
    EXPECT_FALSE(weak.expired());
    while (queue->DrainReadyForTesting() != 0) {}
    EXPECT_EQ(completions, 1U);
    EXPECT_TRUE(weak.expired());
    EXPECT_EQ(queue->DrainReadyForTesting(), 0U);
}

TEST(ROMReaderLifetime, InlineCompletionCanReleaseReader) {
    Async::Testing::DeferredFireWireBus bus;
    bus.SetDefaultReadQuadlet(0);
    auto reader = std::make_unique<Discovery::ROMReader>(bus);
    unsigned completions = 0;
    reader->ReadQuadletsBE(1, FW::Generation{1}, FW::FwSpeed::S100, 0, 1,
        [&](auto result) { EXPECT_TRUE(result.success); ++completions; reader.reset(); });
    EXPECT_EQ(completions, 1U);
    EXPECT_FALSE(reader);
}

TEST(ROMReaderLifetime, RetiredReadFinishesAbortedWithoutSubmission) {
    Async::Testing::DeferredFireWireBus bus;
    Discovery::ROMReader reader(bus);
    ASSERT_TRUE(reader.RetireDeferredWork());
    unsigned completions = 0;
    reader.ReadQuadletsBE(1, FW::Generation{1}, FW::FwSpeed::S100, 0, 1,
        [&](auto result) {
            EXPECT_FALSE(result.success);
            EXPECT_EQ(result.status, Async::AsyncStatus::kAborted);
            ++completions;
        });
    EXPECT_EQ(completions, 1U);
    EXPECT_EQ(bus.ReadCount(), 0U);
}

INSTANTIATE_TEST_SUITE_P(QuadletsBIBAndRoot, ROMReaderLifetimeTests, ::testing::Range(0, 3));
} // namespace
