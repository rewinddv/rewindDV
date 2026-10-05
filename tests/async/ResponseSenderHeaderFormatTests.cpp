// Modified by Rewind Digital for RewindDV Foundation, September 2026; see Foundation/NOTICE.md.
// ResponseSenderHeaderFormatTests.cpp

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <span>

#include <gtest/gtest.h>

#include "ASFWDriver/Async/Tx/ATResponseHeader.hpp"
#include "ASFWDriver/Async/Tx/DescriptorBuilder.hpp"
#include "ASFWDriver/Async/Tx/ResponseSender.hpp"
#include "ASFWDriver/Hardware/HardwareInterface.hpp"
#include "ASFWDriver/Hardware/OHCIDescriptors.hpp"
#include "ASFWDriver/Shared/Memory/DMAMemoryManager.hpp"
#include "ASFWDriver/Shared/Rings/DescriptorRing.hpp"

namespace ASFW::Async::Tx {
namespace {

using ASFW::Async::HW::OHCIDescriptor;
using ASFW::Async::HW::OHCIDescriptorImmediate;
using ASFW::Driver::HardwareInterface;
using ASFW::Shared::DescriptorRing;
using ASFW::Shared::DMAMemoryManager;

constexpr uint8_t kWriteResponse = 0x2;
constexpr uint8_t kReadQuadletResponse = 0x6;
constexpr uint8_t kReadBlockResponse = 0x7;
constexpr uint8_t kLockResponse = 0xB;
constexpr uint8_t kTLabel = 31;

constexpr uint16_t MakeReceiveStatus(uint8_t speedCode,
                                     uint8_t eventCode = ATResponseHeader::kAckPendingEvent,
                                     uint16_t otherBits = 0) noexcept {
    return static_cast<uint16_t>(
        otherBits |
        (static_cast<uint16_t>(speedCode & 0x07u) << ATResponseHeader::kReceiveSpeedShift) |
        static_cast<uint16_t>(eventCode & ATResponseHeader::kEventMask));
}

uint8_t Q0Speed(uint32_t q0) {
    return static_cast<uint8_t>((q0 >> 16) & 0x07u);
}

uint8_t Q0Retry(uint32_t q0) {
    return static_cast<uint8_t>((q0 >> 8) & 0x03u);
}

uint8_t Q0TLabel(uint32_t q0) {
    return static_cast<uint8_t>((q0 >> 10) & 0x3Fu);
}

uint8_t Q0TCode(uint32_t q0) {
    return static_cast<uint8_t>((q0 >> 4) & 0x0Fu);
}

uint16_t Q1Destination(uint32_t q1) {
    return static_cast<uint16_t>(q1 >> 16);
}

uint8_t Q1ResponseCode(uint32_t q1) {
    return static_cast<uint8_t>((q1 >> 12) & 0x0Fu);
}

struct DescriptorRig {
    static constexpr size_t kCapacity = 8;

    bool Initialize() {
        if (!dma.Initialize(hardware, 4096)) {
            return false;
        }
        descriptorsRegion = dma.AllocateRegion(kCapacity * sizeof(OHCIDescriptor));
        payloadRegion = dma.AllocateRegion(64);
        if (!descriptorsRegion || !payloadRegion) {
            return false;
        }
        descriptors = reinterpret_cast<OHCIDescriptor*>(descriptorsRegion->virtualBase);
        if (!ring.Initialize(std::span<OHCIDescriptor>{descriptors, kCapacity}) ||
            !ring.Finalize(descriptorsRegion->deviceBase)) {
            return false;
        }
        builder = std::make_unique<DescriptorBuilder>(ring, dma);
        return true;
    }

    HardwareInterface hardware;
    DMAMemoryManager dma;
    DescriptorRing ring;
    std::optional<DMAMemoryManager::Region> descriptorsRegion;
    std::optional<DMAMemoryManager::Region> payloadRegion;
    OHCIDescriptor* descriptors{nullptr};
    std::unique_ptr<DescriptorBuilder> builder;
};

struct SubmissionCapture {
    uint32_t count{0};
    std::array<uint32_t, 4> immediateData{};
    uint8_t descriptorBlocks{0};
    uint16_t deadline{0};
    uint32_t terminalDataAddress{0};
    uint16_t terminalRequestCount{0};
};

void CaptureSubmission(const void* firstDescriptor,
                       uint8_t descriptorBlocks,
                       void* context) noexcept {
    auto* capture = static_cast<SubmissionCapture*>(context);
    const auto* immediate = static_cast<const OHCIDescriptorImmediate*>(firstDescriptor);
    ++capture->count;
    std::copy(std::begin(immediate->immediateData),
              std::end(immediate->immediateData),
              capture->immediateData.begin());
    capture->descriptorBlocks = descriptorBlocks;
    capture->deadline = immediate->common.timeStamp;
    if (descriptorBlocks == 3) {
        const auto* blocks = static_cast<const OHCIDescriptor*>(firstDescriptor);
        capture->terminalDataAddress = blocks[2].dataAddress;
        capture->terminalRequestCount = blocks[2].reqCount;
    }
}

ARPacketView MakeRequest(std::array<uint8_t, 16>& header,
                         uint8_t requestTCode,
                         uint16_t xferStatus,
                         uint8_t tLabel = kTLabel) {
    return ARPacketView{
        .header = std::span<const uint8_t>{header},
        .payload = {},
        .tCode = requestTCode,
        .sourceID = 0xFFC1,
        .destID = 0xFFC0,
        .tLabel = tLabel,
        .xferStatus = xferStatus,
        .timeStamp = 0x025Cu,
    };
}

void SendPublicResponse(ResponseSender& sender,
                        const ARPacketView& request,
                        uint8_t responseTCode,
                        uint64_t payloadAddress = 0) {
    switch (responseTCode) {
        case kWriteResponse:
            sender.SendWriteResponse(request, ResponseCode::Complete);
            break;
        case kReadQuadletResponse:
            sender.SendReadQuadletResponse(request, ResponseCode::Complete, 0xA1B2C3D4u);
            break;
        case kReadBlockResponse:
            sender.SendReadBlockResponse(request, ResponseCode::Complete, payloadAddress, 4u);
            break;
        case kLockResponse:
            // Busy requires no scratch payload and still exercises the real
            // lock-response header path.
            sender.SendLockResponse(request, ResponseCode::Busy, 0u);
            break;
        default:
            FAIL() << "unhandled response tCode=" << unsigned(responseTCode);
    }
}

TEST(ResponseSenderHeaderFormatTest, JVCObservedS100AckPendingBuildsS100Retry1Response) {
    // Exact Build164 receive trailer: xferStatus=0x8412. Bits [7:5] are
    // receive speed 0/S100 and event [4:0] is ACK_PENDING.
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    SubmissionCapture capture;
    ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
    std::array<uint8_t, 16> header{};
    const auto request = MakeRequest(header, /*block-write request*/ 0x1, 0x8412u);

    sender.SendWriteResponse(request, ResponseCode::Complete);

    ASSERT_EQ(capture.count, 1u);
    EXPECT_EQ(Q0Speed(capture.immediateData[0]), 0u);
    EXPECT_EQ(Q0Retry(capture.immediateData[0]), ATResponseHeader::kRetry1);
    EXPECT_EQ(Q0TLabel(capture.immediateData[0]), kTLabel);
    EXPECT_EQ(Q0TCode(capture.immediateData[0]), kWriteResponse);
    EXPECT_EQ(Q1Destination(capture.immediateData[1]), request.sourceID);
    EXPECT_EQ(Q1ResponseCode(capture.immediateData[1]),
              static_cast<uint8_t>(ResponseCode::Complete));
    EXPECT_EQ(capture.immediateData[2], 0u);
    EXPECT_EQ(capture.descriptorBlocks, 2u);
    EXPECT_EQ(capture.deadline, 0x425Cu);
}

TEST(ResponseSenderHeaderFormatTest, EveryResponseTypeMirrorsEverySupportedReceiveSpeed) {
    constexpr std::array<uint8_t, 4> kSpeeds{0, 1, 2, 3};
    constexpr std::array<uint8_t, 4> kResponseTCodes{
        kWriteResponse,
        kReadQuadletResponse,
        kReadBlockResponse,
        kLockResponse,
    };

    for (const uint8_t speed : kSpeeds) {
        for (const uint8_t tCode : kResponseTCodes) {
            const auto q0 = ATResponseHeader::Build(MakeReceiveStatus(speed), kTLabel, tCode);
            ASSERT_TRUE(q0.valid) << "speed=" << unsigned(speed) << " tCode=" << unsigned(tCode);
            EXPECT_EQ(Q0Speed(q0.value), speed);
            EXPECT_EQ(Q0Retry(q0.value), ATResponseHeader::kRetry1);
            EXPECT_EQ(Q0TLabel(q0.value), kTLabel);
            EXPECT_EQ(Q0TCode(q0.value), tCode);
        }
    }
}

TEST(ResponseSenderHeaderFormatTest, S400CompatibilityPreservesReceivedSpeed) {
    // Mechanism-level preservation for existing S400 peers, including the
    // previously qualified Sony path; this is not hardware qualification.
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    SubmissionCapture capture;
    ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
    std::array<uint8_t, 16> header{};
    const auto request = MakeRequest(header, /*block-write request*/ 0x1, MakeReceiveStatus(2), 17);

    sender.SendWriteResponse(request, ResponseCode::Complete);

    ASSERT_EQ(capture.count, 1u);
    EXPECT_EQ(Q0Speed(capture.immediateData[0]), 2u);
    EXPECT_EQ(Q0Retry(capture.immediateData[0]), ATResponseHeader::kRetry1);
}

TEST(ResponseSenderHeaderFormatTest, MixedConsecutiveRequestsDoNotLatchPriorSpeed) {
    constexpr std::array<uint8_t, 8> kSequence{2, 0, 1, 3, 0, 2, 1, 0};
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    SubmissionCapture capture;
    ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
    std::array<uint8_t, 16> header{};

    for (const uint8_t speed : kSequence) {
        const auto request = MakeRequest(header, /*block-write request*/ 0x1, MakeReceiveStatus(speed), 9);
        sender.SendWriteResponse(request, ResponseCode::Complete);
        EXPECT_EQ(Q0Speed(capture.immediateData[0]), speed);
    }
    EXPECT_EQ(capture.count, kSequence.size());
}

TEST(ResponseSenderHeaderFormatTest, UnsupportedOrUnavailableReceiveMetadataFailsClosed) {
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    SubmissionCapture capture;
    ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
    std::array<uint8_t, 16> header{};
    std::array<std::byte, DescriptorRig::kCapacity * sizeof(OHCIDescriptor)> before{};
    std::memcpy(before.data(), rig.descriptors, before.size());
    const size_t headBefore = rig.ring.Head();
    const size_t tailBefore = rig.ring.Tail();

    for (uint8_t speed = 4; speed <= 7; ++speed) {
        const auto request = MakeRequest(header, 0x1, MakeReceiveStatus(speed), 1);
        sender.SendWriteResponse(request, ResponseCode::Complete);
    }
    sender.SendWriteResponse(MakeRequest(header, 0x1, 0x0000u, 1), ResponseCode::Complete);
    sender.SendWriteResponse(MakeRequest(header, 0x1, 0xFFFFu, 1), ResponseCode::Complete);
    sender.SendWriteResponse(MakeRequest(header,
                                         0x1,
                                         MakeReceiveStatus(0, /*ACK_COMPLETE*/ 0x11),
                                         1),
                             ResponseCode::Complete);

    EXPECT_EQ(capture.count, 0u);
    EXPECT_EQ(rig.ring.Head(), headBefore);
    EXPECT_EQ(rig.ring.Tail(), tailBefore);
    EXPECT_EQ(std::memcmp(before.data(), rig.descriptors, before.size()), 0)
        << "rejected receive metadata must not publish descriptors";
}

TEST(ResponseSenderHeaderFormatTest, MissingProductionContextFailsBeforeDescriptorConstruction) {
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    // A null host capture follows the production admission path. The host
    // constructor intentionally provides no AT response context or submitter.
    ResponseSender sender(*rig.builder, nullptr, nullptr);
    std::array<uint8_t, 16> header{};
    std::array<std::byte, DescriptorRig::kCapacity * sizeof(OHCIDescriptor)> before{};
    std::memcpy(before.data(), rig.descriptors, before.size());
    const size_t headBefore = rig.ring.Head();
    const size_t tailBefore = rig.ring.Tail();

    sender.SendWriteResponse(MakeRequest(header, 0x1, MakeReceiveStatus(0)),
                             ResponseCode::Complete);

    EXPECT_EQ(rig.ring.Head(), headBefore);
    EXPECT_EQ(rig.ring.Tail(), tailBefore);
    EXPECT_EQ(std::memcmp(before.data(), rig.descriptors, before.size()), 0)
        << "missing production dependencies must fail before descriptor construction";
}

TEST(ResponseSenderHeaderFormatTest, NonSpeedStatusBitsDoNotAlterResponseHeader) {
    const auto plain = ATResponseHeader::Build(MakeReceiveStatus(0), 5, kWriteResponse);
    const auto build164 = ATResponseHeader::Build(MakeReceiveStatus(
                                                      0,
                                                      ATResponseHeader::kAckPendingEvent,
                                                      0x8400u),
                                                  5,
                                                  kWriteResponse);

    ASSERT_TRUE(plain.valid);
    ASSERT_TRUE(build164.valid);
    EXPECT_EQ(build164.value, plain.value);
}

TEST(ResponseSenderHeaderFormatTest, PublicResponseMethodsPublishExactBuiltQ0ForAllTypesAndSpeeds) {
    constexpr std::array<uint8_t, 4> kResponseTCodes{
        kWriteResponse,
        kReadQuadletResponse,
        kReadBlockResponse,
        kLockResponse,
    };

    for (uint8_t speed = 0; speed <= 3; ++speed) {
        for (const uint8_t tCode : kResponseTCodes) {
            DescriptorRig rig;
            ASSERT_TRUE(rig.Initialize());
            SubmissionCapture capture;
            ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
            std::array<uint8_t, 16> header{};
            const uint8_t requestTCode = static_cast<uint8_t>(tCode - 2u);
            const auto request = MakeRequest(header, requestTCode, MakeReceiveStatus(speed));

            SendPublicResponse(sender, request, tCode, rig.payloadRegion->deviceBase);

            ASSERT_EQ(capture.count, 1u);
            EXPECT_EQ(Q0Speed(capture.immediateData[0]), speed);
            EXPECT_EQ(Q0Retry(capture.immediateData[0]), ATResponseHeader::kRetry1);
            EXPECT_EQ(Q0TLabel(capture.immediateData[0]), kTLabel);
            EXPECT_EQ(Q0TCode(capture.immediateData[0]), tCode);
            EXPECT_EQ(Q1Destination(capture.immediateData[1]), request.sourceID);
            const auto expectedRCode = tCode == kLockResponse
                ? ResponseCode::Busy
                : ResponseCode::Complete;
            EXPECT_EQ(Q1ResponseCode(capture.immediateData[1]),
                      static_cast<uint8_t>(expectedRCode));
            EXPECT_EQ(capture.immediateData[2], 0u);

            if (tCode == kReadQuadletResponse) {
                EXPECT_EQ(capture.immediateData[3], 0xA1B2C3D4u);
            } else if (tCode == kReadBlockResponse) {
                EXPECT_EQ(capture.immediateData[3], 4u << 16);
            } else if (tCode == kLockResponse) {
                // This test intentionally exercises the no-payload Busy lock
                // response; successful lock payload DMA is outside this seam.
                EXPECT_EQ(capture.immediateData[3], 0u);
            }

            EXPECT_EQ(capture.descriptorBlocks,
                      tCode == kReadBlockResponse ? 3u : 2u);
            EXPECT_EQ(capture.deadline, 0x425Cu);
            if (tCode == kReadBlockResponse) {
                EXPECT_EQ(capture.terminalDataAddress,
                          static_cast<uint32_t>(rig.payloadRegion->deviceBase));
                EXPECT_EQ(capture.terminalRequestCount, 4u);
            }
        }
    }
}

TEST(ResponseSenderHeaderFormatTests, WriteDispositionDistinguishesQueuedAbsentAndFailedResponse) {
    using Disposition = ResponseSender::WriteDisposition;
    DescriptorRig rig;
    ASSERT_TRUE(rig.Initialize());
    SubmissionCapture capture;
    ResponseSender sender(*rig.builder, &CaptureSubmission, &capture);
    std::array<uint8_t, 16> header{};
    EXPECT_EQ(sender.SendWriteResponse(MakeRequest(header, 0x1, MakeReceiveStatus(0)),
                                      ResponseCode::Complete), Disposition::Submitted);
    EXPECT_EQ(capture.count, 1U);
    EXPECT_EQ(sender.SendWriteResponse(MakeRequest(header, 0x1, MakeReceiveStatus(0, 0x11)),
                                      ResponseCode::Complete), Disposition::NotRequired);
    auto broadcast = MakeRequest(header, 0x1, MakeReceiveStatus(0));
    broadcast.destID = 0xFFFF;
    EXPECT_EQ(sender.SendWriteResponse(broadcast, ResponseCode::Complete), Disposition::NotRequired);
    for (uint16_t status : {uint16_t{0}, uint16_t{0xFFFF}, MakeReceiveStatus(4)}) {
        EXPECT_EQ(sender.SendWriteResponse(MakeRequest(header, 0x1, status),
                                          ResponseCode::Complete), Disposition::Failed);
    }
    ResponseSender unavailable(*rig.builder, nullptr, nullptr);
    EXPECT_EQ(unavailable.SendWriteResponse(MakeRequest(header, 0x1, MakeReceiveStatus(0)),
                                           ResponseCode::Complete), Disposition::Failed);
    EXPECT_EQ(capture.count, 1U);
}

} // namespace
} // namespace ASFW::Async::Tx
