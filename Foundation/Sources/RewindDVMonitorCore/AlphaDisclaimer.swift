// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreFoundation

/// Host/user-scoped acknowledgement, separate from build numbering. Increment
/// noticeVersion whenever the risk notice changes materially. No cloud sync.
public enum AlphaDisclaimer {
  public static let noticeVersion = 2
  public static let title = "Alpha software — use at your own risk"
  public static let message = """
    rewindDV LAB is experimental alpha software intended for supervised testing. It may contain defects, crash, interrupt tape operation, or produce incomplete, corrupted or lost captures. Compatibility and reliable operation are not guaranteed.

    Tape playback and winding involve mechanical wear and can damage fragile tapes or equipment. Test with non-critical, write-protected tapes first; keep independent backups and verify every capture. Do not rely on this alpha as your only preservation copy.

    Stay nearby while tape transport is active and keep the deck's physical STOP accessible. Do not quit the app or disconnect the deck, power or destination drive during capture, draining or verification. Recording and erasure of tape are not offered by rewindDV.

    This alpha is provided “as is,” without warranties. You choose to use it at your own risk.

    By clicking Accept, you acknowledge these risks and choose to continue. Cancel quits the app. Your acceptance is saved locally for this macOS user on this Mac; it is not uploaded.
    """

  public static let preferenceKey = "AlphaRiskAcknowledgement"

  public static func isAccepted(domain: String) -> Bool {
    guard let receipt = CFPreferencesCopyValue(preferenceKey as CFString,
      domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [String: Any],
      receipt["noticeVersion"] as? Int == noticeVersion,
      let date = receipt["acceptedAt"] as? Date, date.timeIntervalSince1970.isFinite,
      let build = receipt["alphaVersion"] as? String, !build.isEmpty else { return false }
    return true
  }

  /// Called only after the explicit Accept action. A failed save leaves the
  /// launch gate closed; a subsequent launch must never infer acceptance.
  public static func accept(domain: String, alphaVersion: String, at date: Date = Date()) -> Bool {
    guard !alphaVersion.isEmpty, date.timeIntervalSince1970.isFinite else { return false }
    let receipt: [String: Any] = ["noticeVersion": noticeVersion,
      "acceptedAt": date, "alphaVersion": alphaVersion]
    CFPreferencesSetValue(preferenceKey as CFString, receipt as CFDictionary,
      domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else {
      CFPreferencesSetValue(preferenceKey as CFString, nil, domain as CFString,
        kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
      _ = CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
      return false
    }
    return isAccepted(domain: domain)
  }
}
