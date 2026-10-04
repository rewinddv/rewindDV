#include <gtest/gtest.h>
#include "ASFWDriver/ConfigROM/ConfigROMStager.hpp"
#include "ASFWDriver/Hardware/HardwareInterface.hpp"

using namespace ASFW::Driver;

namespace {
class MappingDMA final : public IODMACommand {
public:
    IOAddressSegment segment{0x10000000, 1024};
    uint32_t prepareCount{0};
    uint32_t completeCount{0};
    uint64_t mappedAddress{0};
    bool mapped{false};

    kern_return_t PrepareForDMA(uint64_t, IOMemoryDescriptor*, uint64_t,
                               uint64_t, uint64_t*, uint32_t* count,
                               IOAddressSegment* output) override {
        // A later preparation is allowed to map the same memory elsewhere.
        mappedAddress = segment.address + (prepareCount++ * 0x1000);
        *count = 1;
        *output = {mappedAddress, segment.length};
        mapped = true;
        return kIOReturnSuccess;
    }
    kern_return_t CompleteDMA(uint64_t) override {
        ++completeCount;
        mapped = false;
        return kIOReturnSuccess;
    }
};
}

TEST(ConfigROMStagerTests, StagingRetainsThePublishedMappingUntilTeardown) {
    HardwareInterface hardware;
    auto dma = OSSharedPtr<MappingDMA>(new MappingDMA, OSNoRetain);
    hardware.SetTestDMACommand(OSSharedPtr<IODMACommand>(dma.get(), OSRetain));
    ConfigROMStager stager;
    ConfigROMBuilder image;
    image.Build(0, 0x1122334455667788ULL, 0, "Test");
    ASSERT_EQ(stager.Prepare(hardware), kIOReturnSuccess);
    for (int update = 0; update < 3; ++update) {
        image.UpdateGeneration(static_cast<uint8_t>(update + 2));
        EXPECT_EQ(stager.StageImage(image, hardware), kIOReturnSuccess);
        EXPECT_TRUE(dma->mapped);
        EXPECT_EQ(hardware.GetTestRegister(Register32::kConfigROMMap), dma->mappedAddress);
        EXPECT_EQ(dma->prepareCount, 1U);
        EXPECT_EQ(dma->completeCount, 0U);
        stager.RestoreHeaderAfterBusReset();
    }
    stager.Teardown(hardware);
    EXPECT_FALSE(dma->mapped);
    EXPECT_EQ(dma->completeCount, 1U);
    EXPECT_EQ(hardware.GetTestRegister(Register32::kConfigROMMap), 0U);
}

TEST(ConfigROMStagerTests, RejectsInvalidDMAExtentBeforeItCanBePublished) {
    for (const auto segment : {IOAddressSegment{0, 1024},
                               IOAddressSegment{0x100000000ULL, 1024},
                               IOAddressSegment{0xFFFFFC00ULL, 2048},
                               IOAddressSegment{0x10000000, 512}}) {
        HardwareInterface hardware;
        auto dma = OSSharedPtr<MappingDMA>(new MappingDMA, OSNoRetain);
        dma->segment = segment;
        hardware.SetTestDMACommand(OSSharedPtr<IODMACommand>(dma.get(), OSRetain));
        ConfigROMStager stager;
        const size_t capacity = segment.length == 2048 ? 2048 : 1024;
        EXPECT_NE(stager.Prepare(hardware, capacity), kIOReturnSuccess);
        EXPECT_FALSE(stager.Ready());
        EXPECT_FALSE(dma->mapped);
        EXPECT_EQ(hardware.GetTestRegister(Register32::kConfigROMMap), 0U);
        stager.Teardown(hardware);
    }
}
