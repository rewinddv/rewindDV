import Foundation
import Testing
@testable import RewindDVMonitorCore

@Test func canonicalHostMetadataFailsClosedOnComponentMismatch() {
  let info: [String: Any] = ["CFBundleShortVersionString":"0.1.1", "CFBundleVersion":"191",
    "RewindDVProductVersion":"0.1.1", "RewindDVReleaseChannel":"alpha", "RewindDVRequiredDriverBuild":"194"]
  #expect(ProductIdentity.matchesHost(info))
  for (key, bad) in [("CFBundleVersion","190"), ("RewindDVRequiredDriverBuild","193"),
    ("CFBundleShortVersionString","0.1.0"), ("RewindDVReleaseChannel","beta")] {
    var changed = info; changed[key] = bad
    #expect(!ProductIdentity.matchesHost(changed))
    changed.removeValue(forKey: key)
    #expect(!ProductIdentity.matchesHost(changed))
  }
  #expect(ProductIdentity.display == "rewindDV 0.1.1 (Alpha)")
  #expect(ProductIdentity.appBuild != ProductIdentity.driverBuild)
}
