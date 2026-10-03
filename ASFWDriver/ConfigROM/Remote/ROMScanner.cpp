// Modified for RewindDV: accepted-only scan admission callback for reset-scoped exports.
#include "../ROMScanner.hpp"
#include "../ROMReader.hpp"

#include "../../Logging/LogConfig.hpp"
#include "../../Logging/Logging.hpp"
#include "ROMScanSession.hpp"

#include <utility>

namespace ASFW::Discovery {

ROMScanner::ROMScanner(Async::IFireWireBus& bus, SpeedPolicy& speedPolicy,
                       const ROMScannerParams& params, OSSharedPtr<IODispatchQueue> dispatchQueue)
    : bus_(bus), speedPolicy_(speedPolicy), params_(params),
      dispatchQueue_(std::move(dispatchQueue)),
      reader_(std::make_shared<ROMReader>(bus_, dispatchQueue_)) {}

ROMScanner::~ROMScanner() {
    (void)RetireDeferredWork();
}

bool ROMScanner::RetireDeferredWork() {
    const bool readerQuiesced = reader_->RetireDeferredWork();
    sessionWorkEpoch_->Retire();
    const bool sessionQuiesced = sessionWorkEpoch_->Quiesced();
    if (!readerQuiesced || !sessionQuiesced) return false;
    if (session_) {
        session_->Abort();
        session_.reset();
    }
    return true;
}

void ROMScanner::SetTopologyManager(Driver::TopologyManager* topologyManager) {
    topologyManager_ = topologyManager;
}

bool ROMScanner::IsBusyFor(Generation gen) const {
    if (!session_) {
        return false;
    }
    return session_->GetGeneration() == gen;
}

bool ROMScanner::Start(const ROMScanRequest& request, ScanCompletionCallback completion,
                       ScanAdmissionCallback admission) {
    auto epoch = sessionWorkEpoch_;
    Shared::PostedWorkEpoch::Lease lease(*epoch);
    if (!lease) return false;
    if (IsBusyFor(request.gen)) {
        ASFW_LOG_V2(ConfigROM, "ROMScanner::Start: scan already in progress for gen=%u",
                    request.gen.value);
        return false;
    }

    if (session_) {
        session_->Abort();
        session_.reset();
    }

    ASFW_LOG_V2(ConfigROM, "ROMScanner::Start gen=%u localNode=%u topologyNodes=%zu targets=%zu",
                request.gen.value, request.localNodeId, request.topology.physical.nodes.size(),
                request.targetNodes.size());

    auto session = std::make_shared<ROMScanSession>(bus_, speedPolicy_, params_, reader_,
                                                    dispatchQueue_, topologyManager_, request.gen, sessionWorkEpoch_);
    session_ = session;

    // The admission callback runs only after the busy decision and replacement
    // of an older session, but before Start() can synchronously complete. This
    // closes both the rejected-busy and response-before-return authority races.
    if (admission && !admission()) {
        session_->Abort();
        session_.reset();
        return false;
    }

    const std::weak_ptr<ROMScanSession> weakSession = session;
    ScanCompletionCallback wrapped = [this, weakSession, completion = std::move(completion)](
                                         Generation gen, std::vector<ConfigROM> roms,
                                         bool hadBusyNodes) mutable {
        if (auto strongSession = weakSession.lock(); strongSession && session_ == strongSession) {
            session_.reset();
        }
        if (completion) {
            completion(gen, std::move(roms), hadBusyNodes);
        }
    };

    session->Start(request, std::move(wrapped));
    return true;
}

void ROMScanner::Abort(Generation gen) {
    if (!session_) {
        return;
    }
    if (session_->GetGeneration() != gen) {
        return;
    }

    session_->Abort();
    session_.reset();
}

} // namespace ASFW::Discovery
