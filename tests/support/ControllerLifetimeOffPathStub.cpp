// This fixture has no reset coordinator. Any policy unexpectedly requesting a
// reset is a test failure, not a successful simulated hardware operation.
#include <cstdlib>
#include "ASFWDriver/Bus/BusResetCoordinator.hpp"
namespace ASFW::Driver {
void BusResetCoordinator::RequestRolePolicyReset(uint8_t, bool, std::optional<uint8_t>,
                                                 std::optional<bool>, std::string) {
    std::abort();
}
uint64_t BusResetCoordinator::MonotonicNow() noexcept {
    return ASFW::Testing::HostMonotonicNow();
}
}
