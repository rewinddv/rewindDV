import Foundation
import Testing
@testable import RewindDVMonitorCore

@Test func canonicalHostMetadataFailsClosedOnComponentMismatch() {
  let info: [String: Any] = ["CFBundleShortVersionString":"0.1.22", "CFBundleVersion":"212",
    "RewindDVProductVersion":"0.1.22", "RewindDVReleaseChannel":"beta", "RewindDVRequiredDriverBuild":"203", "RewindDVRequiredDriverVersion":"0.1.11"]
  #expect(ProductIdentity.matchesHost(info))
  for (key, bad) in [("CFBundleVersion","190"), ("RewindDVRequiredDriverBuild","194"),
    ("RewindDVRequiredDriverVersion","0.1.10"),
    ("CFBundleShortVersionString","0.1.0"), ("RewindDVReleaseChannel","alpha")] {
    var changed = info; changed[key] = bad
    #expect(!ProductIdentity.matchesHost(changed))
    changed.removeValue(forKey: key)
    #expect(!ProductIdentity.matchesHost(changed))
  }
  #expect(ProductIdentity.display == "rewindDV 0.1.22 (Beta)")
  #expect(ProductIdentity.appBuild != ProductIdentity.driverBuild)
}
