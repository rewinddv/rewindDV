// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "FoundationReceiveWire.hpp"
#include "../../ASFWDriver/Common/AtomicSharedOwner.hpp"
#include "../../ASFWDriver/Async/FireWireBusImpl.hpp"
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <functional>
#include <memory>
namespace ASFW::Driver { class IsochService; class HardwareInterface; }
namespace ASFW::Discovery { class DeviceRegistry; }
namespace ASFW::CMP { class CMPClient; }
namespace ASFW::IRM { class IRMClient; }

namespace RewindDV::Foundation::Receive {
class Service final {
public:
    Service();
    ~Service();
    Service(const Service&) = delete;
    Service& operator=(const Service&) = delete;
    kern_return_t Start(uint64_t owner, const DriverPolicy::FoundationRouteWire& route,
        uint64_t driverInstance, ASFW::Driver::IsochService& isoch,
        std::shared_ptr<ASFW::Driver::HardwareInterface> hardware,
        std::shared_ptr<ASFW::Discovery::DeviceRegistry> registry,
        std::shared_ptr<ASFW::CMP::CMPClient> cmp,
        std::shared_ptr<ASFW::IRM::IRMClient> irm,
        ASFW::Async::FireWireBusImpl::LinkSpeedDecision speedDecision,
        std::function<void()> quarantine, SessionWire& output);
    kern_return_t Stop(uint64_t owner, uint64_t epoch);
    kern_return_t StopAll(bool busReset = false);
    kern_return_t ReleaseOwner(uint64_t owner);
    kern_return_t Snapshot(uint64_t owner, uint64_t epoch, StatusWire& output) const;
    kern_return_t Acknowledge(uint64_t owner, uint64_t epoch, uint64_t through);
    kern_return_t CopyMemory(uint64_t owner, uint64_t* options, IOMemoryDescriptor** memory) const;
private:
    struct Session;
    mutable IOLock* lock_{};
    using SessionOwner = ASFW::Common::AtomicSharedOwner<Session>;
    SessionOwner session_;
    uint64_t nextEpoch_{1};
};
} // namespace RewindDV::Foundation::Receive
