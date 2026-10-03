import Foundation
import CoreFoundation
import Testing
@testable import RewindDVMonitorCore

@Test func alphaDisclaimerRequiresExplicitCurrentHostAcceptance() {
  let domain = "net.rewinddigital.tests.disclaimer." + UUID().uuidString
  defer {
    for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
      CFPreferencesSetValue(AlphaDisclaimer.preferenceKey as CFString, nil,
        domain as CFString, kCFPreferencesCurrentUser, host)
      _ = CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, host)
    }
  }
  #expect(!AlphaDisclaimer.isAccepted(domain: domain))
  let receipt: [String: Any] = ["noticeVersion": AlphaDisclaimer.noticeVersion,
    "acceptedAt": Date(), "alphaVersion": "test-only"]
  // An ordinary migrated/any-host preference must not unlock this host.
  CFPreferencesSetValue(AlphaDisclaimer.preferenceKey as CFString, receipt as CFDictionary,
    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
  #expect(!AlphaDisclaimer.isAccepted(domain: domain))
  #expect(AlphaDisclaimer.accept(domain: domain, alphaVersion: "test-only"))
  #expect(AlphaDisclaimer.isAccepted(domain: domain))
  #expect(!AlphaDisclaimer.isAccepted(domain: domain + ".different"))
  // Re-read persisted acceptance independently, without an in-memory UI flag.
  #expect(CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost))
  #expect(AlphaDisclaimer.isAccepted(domain: domain))
  var stale = receipt; stale["noticeVersion"] = AlphaDisclaimer.noticeVersion - 1
  CFPreferencesSetValue(AlphaDisclaimer.preferenceKey as CFString, stale as CFDictionary,
    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
  #expect(!AlphaDisclaimer.isAccepted(domain: domain))
  CFPreferencesSetValue(AlphaDisclaimer.preferenceKey as CFString, true as CFBoolean,
    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
  #expect(!AlphaDisclaimer.isAccepted(domain: domain))
  #expect(!AlphaDisclaimer.accept(domain: domain, alphaVersion: ""))
}
