// Modified for RewindDV: accepted-only scan admission callback for reset-scoped exports.
#pragma once

#include "../Shared/Completion/PostedWorkEpoch.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

#ifdef ASFW_HOST_TEST
#include "../Testing/HostDriverKitStubs.hpp"
#else
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/OSSharedPtr.h>
#endif

#include "../Controller/ControllerTypes.hpp"
#include "../Discovery/DiscoveryTypes.hpp"
#include "../Discovery/SpeedPolicy.hpp"
#include "../Bus/Role/RolePolicy.hpp"

namespace ASFW::Async {
class IFireWireBus;
}

namespace ASFW::Driver {
class TopologyManager;
}

namespace ASFW::Discovery {

class ROMReader;
class ROMScanSession;

/**
 * @brief Represents a request to scan configuration ROMs across nodes in the current topology
 * generation.
 */
struct ROMScanRequest {
    Generation gen{0};
    Driver::TopologySnapshot topology;
    uint8_t localNodeId{0xFF};

    // If empty: scan all remote nodes (excluding local node, and skipping link-inactive nodes).
    // If non-empty: scan only these node IDs (local node is always skipped).
    std::vector<uint8_t> targetNodes;

    // Optional FW-8 callback: emits root BIB/CMC evidence while the normal full
    // discovery scan continues unchanged.
    std::function<void(Driver::Role::RootCapabilityEvidence)> rootCapabilityCallback;
};

using ScanCompletionCallback =
    std::function<void(Generation gen, std::vector<ConfigROM> roms, bool hadBusyNodes)>;
using ScanAdmissionCallback = std::function<bool()>;

/**
 * @class ROMScanner
 * @brief Session-driven ROM scanner with bounded concurrency and retry logic.
 *
 * Coordinates the reading of IEEE 1212 Configuration ROMs across multiple
 * remote nodes. Optionally validates IRM behavior by performing a Read + CompareSwap
 * on `CHANNELS_AVAILABLE_63_32` at S100, to avoid treating a broken IRM as usable.
 *
 * Uses FSM states to track progress: Idle -> ReadingBIB -> VerifyingIRM ->
 * ReadingRootDir -> Complete/Failed. Each admitted scan completes once unless
 * explicitly aborted, replaced, or retired during owner shutdown.
 */
class ROMScanner {
  public:
    /**
     * @brief Constructs a new ROMScanner.
     * @param bus Reference to the IFireWireBus interface for async reads.
     * @param speedPolicy Defines initial speeds and fallback strategies for reading.
     * @param params Limits for concurrency and retries.
     * @param dispatchQueue Optional dispatch queue.
     */
    explicit ROMScanner(Async::IFireWireBus& bus, SpeedPolicy& speedPolicy,
                        const ROMScannerParams& params,
                        OSSharedPtr<IODispatchQueue> dispatchQueue = nullptr);
    ~ROMScanner();
    // Runtime shutdown aborts the scan and revokes its reader before releasing
    // the borrowed bus. False requires retaining the runtime dependencies.
    [[nodiscard]] bool RetireDeferredWork();

    /**
     * @brief Starts a scan for a given generation request.
     *
     * A successful Start completes exactly once unless Abort, replacement, or
     * owner shutdown cancels it. Cancellation retires ownership synchronously;
     * no completion callback is owed. A rejected Start never calls completion.
     * @param request Target generation and nodes.
     * @param completion Completion callback.
     * @return true if the scan started successfully.
     */
    [[nodiscard]] bool Start(const ROMScanRequest& request, ScanCompletionCallback completion,
                             ScanAdmissionCallback admission = {});

    /**
     * @brief Cancels the scan for the given generation.
     * @param gen The generation to abort (must match the current active session).
     */
    void Abort(Generation gen);

    /**
     * @brief Sets the TopologyManager, used to update IRM node characteristics.
     */
    void SetTopologyManager(Driver::TopologyManager* topologyManager);

  private:
    [[nodiscard]] bool IsBusyFor(Generation gen) const;

    Async::IFireWireBus& bus_;
    SpeedPolicy& speedPolicy_;
    ROMScannerParams params_;
    OSSharedPtr<IODispatchQueue> dispatchQueue_;
    Driver::TopologyManager* topologyManager_{nullptr};
    std::shared_ptr<Shared::PostedWorkEpoch> sessionWorkEpoch_{
        std::make_shared<Shared::PostedWorkEpoch>()};

    std::shared_ptr<ROMReader> reader_;
    std::shared_ptr<ROMScanSession> session_;
};

} // namespace ASFW::Discovery
