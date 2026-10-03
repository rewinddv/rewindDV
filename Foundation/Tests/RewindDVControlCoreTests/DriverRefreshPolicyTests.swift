import Testing
@testable import RewindDVControlCore

@Suite("Automatic discovery must not disturb active work")
struct DriverRefreshPolicyTests {
  @Test func allStateCombinations() {
    for bits in 0..<64 {
      let active = bits & 1 != 0
      let busy = bits & 2 != 0
      let activation = bits & 4 != 0
      let receive = bits & 8 != 0
      let lockout = bits & 16 != 0
      let stop = bits & 32 != 0
      #expect(DriverRefreshPolicy.mayCheck(sceneActive: active, modelBusy: busy,
        activationInFlight: activation, receiveActive: receive, lockedOut: lockout,
        stopOutstanding: stop) == (bits == 1))
    }
  }
}
