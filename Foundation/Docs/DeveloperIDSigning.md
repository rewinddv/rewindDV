# Developer ID application and DriverKit signing

The complete hardware-capable Release app uses Developer ID Application signing
with separate, explicitly selected host and DEXT distribution profiles. Debug
retains automatic Apple Development signing and its existing development-only
PCI entitlement. Alpha and driver build numbers remain independent.

## Configuration

- Team: supply your eligible Apple Developer team with `--team-id TEAM_ID`.
- Host: `net.rewinddigital.RewindDV`; keep System Extension installation and
  UserClient Access for `net.rewinddigital.RewindDV.Driver`.
- DEXT: `net.rewinddigital.RewindDV.Driver`.
- Debug DEXT entitlements: `Config/Driver.entitlements`, with development match
  `0xFFFFFFFF&0x00000000`.
- Release DEXT entitlements: `Config/Driver.Release.entitlements`, with the
  approved `IOPCIPrimaryMatch` string `0x590111C1` and DriverKit entitlement.
- The runtime `IOPCIMatch` in `DriverInfo.plist` remains the same exact device.
- Release is manually provisioned; pass `REWINDDV_APP_DISTRIBUTION_PROFILE` and
  `REWINDDV_DRIVER_DISTRIBUTION_PROFILE` through the build tool below.
- Existing target architectures remain arm64 for the app and arm64e for the DEXT.

Use Developer ID Application profiles for both explicit App IDs, authorizing the
same available Developer ID certificate. The DEXT profile must contain the exact
approved PCI match. Preserve existing development profiles. Keep profiles,
certificates, credentials and local verification evidence outside Git.

## Build a verified archive

Start with clean, committed source and the two Apple-issued distribution profiles.
The certificate fingerprint is public metadata, obtained from
`security find-identity -v -p codesigning`; it pins verification and does not
replace Xcode's certificate-name signing selection.

```sh
python3 -B Foundation/Tools/test-developer-id-verification.py
python3 -B Foundation/Tools/build-developer-id-archive.py \
  --app-profile /absolute/path/to/host.provisionprofile \
  --driver-profile /absolute/path/to/driver.provisionprofile \
  --certificate-sha1 DEVELOPER_ID_CERTIFICATE_SHA1 \
  --team-id TEAM_ID \
  --output /private/tmp/rewinddv-developer-id-new-run
```

The output directory must be new and outside the checkout. The tool validates
profiles, adds missing profiles to Xcode's normal profile store without replacing
existing files, archives both targets, and runs an independent inspection of the
actual signed app and embedded DEXT. It records the clean source commit/tree,
commands, logs, entitlement/profile comparison, public certificate identity and
executable hashes. It does not launch, install, activate, notarize or publish.

The verifier requires Developer ID certificate trust, secure timestamps,
hardened runtime, exact source entitlements and bundle/build identities,
all-device macOS distribution profiles and matching certificate authorization.
It verifies nested executables and the outer resource seal. A successful Xcode
build alone is insufficient.

## Xcode 27 automatic attempt and manual fallback

Apple's Xcode 27 guidance supports separate Debug and Release entitlement files.
Automatic archiving uses Apple Development, followed by Developer ID export.
A direct automatic archive with a Developer ID identity conflicts with Xcode's
development signing mode. On the observed Xcode 27.0 (27A266a), standard Developer
ID export also attempted to thin the existing arm64e DEXT and failed architecture
eligibility before provisioning. The Release configuration therefore uses manual
Developer ID profiles to produce an already distribution-signed archive,
preserving the established target architectures. Complete diagnostics are kept
in local signing evidence. This does not establish installation compatibility.

References: [Kevin Elliott's DEXT signing guidance, including Xcode 27](https://developer.apple.com/forums/thread/809202),
[Apple's provisioning profile inspection guidance](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

## Notarization after verification

Use an authorized notarytool keychain profile. Set up authentication interactively
outside chat with `xcrun notarytool store-credentials PROFILE_NAME`; never place
passwords or API private keys in arguments, source, logs or this document.

```sh
ditto -c -k --keepParent /path/to/RewindDV.app /path/to/RewindDV-notary.zip
xcrun notarytool submit /path/to/RewindDV-notary.zip \
  --keychain-profile PROFILE_NAME --output-format json
xcrun notarytool info SUBMISSION_ID --keychain-profile PROFILE_NAME --output-format json
xcrun notarytool log SUBMISSION_ID --keychain-profile PROFILE_NAME /path/to/notary-log.json
# Only after Accepted:
xcrun stapler staple /path/to/RewindDV.app
xcrun stapler validate /path/to/RewindDV.app
syspolicy_check distribution /path/to/RewindDV.app
```

Retain the submitted ZIP hash, submission ID, complete service result and log.
After stapling, repeat signature/profile verification and record final hashes.
Notarization and static signing verification do not qualify SIP-on installation,
driver activation, app/driver negotiation or physical capture. Those require a
separately authorized installation and hardware qualification session. Do not
change SIP or enable system-extension developer mode to claim distribution
qualification.
