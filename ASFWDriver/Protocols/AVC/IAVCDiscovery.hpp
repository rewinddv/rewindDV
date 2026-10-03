// Modified for RewindDV Foundation Build159; see Foundation/NOTICE.md and candidate provenance.
//
//  IAVCDiscovery.hpp
//  ASFWDriver
//
//  Interface for AV/C Discovery
//  Decouples AVCHandler from concrete AVCDiscovery for testing.
//

#pragma once

#include <vector>
#include <cstdint>
#include <memory>
#include <optional>
#include "../../Discovery/DeviceRouteToken.hpp"

namespace ASFW::Protocols::AVC {

class AVCUnit;
class FCPTransport;

struct FCPControlLease {
    std::shared_ptr<AVCUnit> unit;
    std::shared_ptr<FCPTransport> transport;

    [[nodiscard]] explicit operator bool() const noexcept {
        return unit != nullptr && transport != nullptr;
    }
};

class IAVCDiscovery {
public:
    virtual ~IAVCDiscovery() = default;

    /**
     * @brief Get all AV/C units
     * @return Vector of pointers to AVCUnit instances
     */
    virtual std::vector<AVCUnit*> GetAllAVCUnits() = 0;

    /// Retained snapshot for callers that dereference units after the
    /// discovery lock is released.
    virtual std::vector<std::shared_ptr<AVCUnit>> AcquireAllAVCUnits() = 0;

    /**
     * @brief Re-scan all AV/C units
     * Triggers re-initialization for all discovered units.
     */
    virtual void ReScanAllUnits() = 0;

    /// Resolve live FCP transport for a node ID.
    virtual FCPTransport* GetFCPTransportForNodeID(uint16_t nodeID) = 0;

    /// Acquire a transport lease for asynchronous response delivery. The caller
    /// keeps the returned owner until it has finished using the transport.
    virtual std::shared_ptr<FCPTransport> AcquireFCPTransportForNodeID(uint16_t nodeID) = 0;

    /// Acquire retained unit and transport ownership for a GUID while holding
    /// the discovery lock. The caller releases that lock before submission.
    virtual FCPControlLease AcquireFCPControlLeaseForGuid(uint64_t guid) = 0;

    virtual std::optional<Discovery::DeviceRouteToken> CopyCurrentRouteForGuid(uint64_t guid) = 0;

    [[nodiscard]] virtual uint64_t GetFoundationDriverInstanceID() const noexcept = 0;
};

} // namespace ASFW::Protocols::AVC
