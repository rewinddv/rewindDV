// Host execution of the production receive context with fake MMIO/DMA only.
#include <cassert>
#include <cstdio>
#include "Isoch/IsochService.hpp"
#include "Hardware/HardwareInterface.hpp"
#include "Hardware/OHCIConstants.hpp"

using ASFW::Driver::HardwareInterface;
using ASFW::Driver::IsochService;
using ASFW::Driver::Register32;
using ASFW::Isoch::IRPolicy;

struct Consumer final : ASFW::Isoch::IIsochReceiveConsumer {
    unsigned activated{}, quiesced{}, batches{}, packets{}, telemetry{};
    void OnReceiveActivated() noexcept override { ++activated; }
    void OnReceiveQuiesced() noexcept override { ++quiesced; }
    void BeginReceiveBatch(const ASFW::Isoch::IsochReceiveBatch&) noexcept override { ++batches; }
    void ConsumePacket(const ASFW::Isoch::IsochReceiveBatch&,
                       const ASFW::Isoch::IsochReceivePacket&) noexcept override { ++packets; }
    void DrainReceiveTelemetry(uint32_t) override { ++telemetry; }
    void DrainPayloadTelemetry() override { ++telemetry; }
    void LogTransmitTimingTrace() override { ++telemetry; }
};

struct Fixture {
    HardwareInterface hardware;
    Consumer consumer;
    IsochService isoch;
    void Start() {
        assert(isoch.StartPacketReceive(2, hardware, &consumer) == kIOReturnSuccess);
        assert(consumer.activated == 1);
    }
};

int main() {
    const auto control = static_cast<Register32>(DMAContextHelpers::IsoRcvContextControlSet(0));
    {
        Fixture f;
        f.Start();
        auto delayedPollOwner = f.isoch.CopyReceiveContext();
        // Model a descriptor completed after the last interrupt poll but before
        // ACTIVE clears. Stop must publish it to the raw consumer before detach.
        auto* finalDescriptor = delayedPollOwner->TestDescriptorAt(0);
        auto* finalPayload = delayedPollOwner->TestPayloadAt(0);
        assert(finalDescriptor && finalPayload);
        finalPayload[0] = 0x5a;
        finalDescriptor->statusWord = (0x11u << 16) | 4095; // Successful completion, one byte.
        assert(f.isoch.ReleaseQuiescedReceiveContexts() == kIOReturnBusy);
        f.hardware.SetTestRegister(control, 0);
        assert(f.isoch.StopPacketReceive(&f.consumer) == kIOReturnSuccess);
        assert(f.consumer.quiesced == 1);
        assert(f.consumer.packets == 1 && f.consumer.batches == 1);
        assert(f.isoch.ReleaseQuiescedReceiveContexts() == kIOReturnSuccess);
        assert(f.isoch.ReceiveContext() == nullptr);
        // A fresh provider context is constructed only after the old DMA graph
        // has been released while its original hardware owner is still alive.
        f.hardware.Detach();
        assert(f.hardware.Attach(nullptr, nullptr) == kIOReturnSuccess);
        assert(f.isoch.StartPacketReceive(3, f.hardware, &f.consumer) == kIOReturnSuccess);
        assert(f.isoch.CopyReceiveContext() != delayedPollOwner);
        const auto operationsBeforeLatePoll = f.hardware.CopyTestOperations().size();
        assert(delayedPollOwner->Poll() == 0);
        delayedPollOwner->DrainZtsTelemetry(1);
        delayedPollOwner->DrainPayloadWriterTelemetry();
        delayedPollOwner->LogTxSytTrace();
        assert(f.hardware.CopyTestOperations().size() == operationsBeforeLatePoll);
        assert(f.consumer.batches == 1 && f.consumer.telemetry == 0);
        delayedPollOwner.reset();
        f.hardware.SetTestRegister(control, 0);
        assert(f.isoch.StopPacketReceive(&f.consumer) == kIOReturnSuccess);
        assert(f.isoch.ReleaseQuiescedReceiveContexts() == kIOReturnSuccess);
        assert(f.consumer.activated == 2 && f.consumer.quiesced == 2);
    }
    for (unsigned failure = 0; failure != 3; ++failure) {
        // Quarantined graphs deliberately survive to process exit, matching
        // the production retention contract. No fake free is a DMA barrier.
        auto* f = new Fixture;
        f->Start();
        if (failure == 0) f->hardware.SetTestRegister(control, ASFW::Driver::ContextControl::kActive);
        if (failure == 1) f->hardware.SetTestRegister(control, 0xffffffffu);
        if (failure == 2) f->hardware.LatchProviderRevokedAndDrain();
        const auto expected = failure == 0 ? kIOReturnTimeout : kIOReturnNotReady;
        assert(f->isoch.StopPacketReceive(&f->consumer) == expected);
        assert(f->consumer.quiesced == 0);
        assert(f->isoch.ReceiveContext()->GetState() == IRPolicy::State::Stopping);
        const auto operations = f->hardware.CopyTestOperations().size();
        assert(f->isoch.StopAll() == expected);
        assert(f->isoch.ReleaseQuiescedReceiveContexts() == kIOReturnBusy);
        assert(f->isoch.StartPacketReceive(2, f->hardware, &f->consumer) == kIOReturnBusy);
        assert(f->isoch.ReceiveContext()->Poll() == 0);
        assert(f->consumer.batches == 0 && f->consumer.quiesced == 0);
        assert(f->hardware.CopyTestOperations().size() == operations);
    }
    std::puts("Foundation receive lifecycle tests passed: normal stop/rebuild, ACTIVE timeout, all-ones, provider revocation, retained owner and no retry");
}
