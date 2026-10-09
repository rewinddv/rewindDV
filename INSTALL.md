# Full signed engineering release installation

Use [PROJECT-STATUS.json](PROJECT-STATUS.json) and the matching release’s four
assets to identify the published package. Verify the ZIP against its `.sha256`
file and retain `manifest.json` and `provenance.json`. A source commit alone is
not evidence that a package has been published.

The full package contains `RewindDV.app`, its matching embedded DriverKit
extension, and the normal `rewinddv-cli`. It uses Developer ID Application
signing, hardened runtime and Apple notarization. Keep the embedded profiles
and sealed bundle contents intact. Apple silicon is required; the app deployment
floor is macOS 26. Broader OS/deck qualification remains open.

1. Finish any capture and leave the deck stopped. Preserve your previous app
   and record its driver identity for rollback before replacing anything.
2. Extract the verified ZIP. Open the app using normal macOS approval. Do not
   disable SIP, enable system-extension developer mode or bypass Gatekeeper.
   If macOS rejects it, stop and retain the message and package identity.
3. Saved-file playback, metadata, Surgery and offline review need no driver
   activation. Open source files through the native chooser to grant access for
   the current sandbox session; originals remain read-only.
4. For the supported FireWire controller, use Diagnostics → Activate Driver…
   and approve the normal macOS Driver Extensions prompt. If requested, find it
   in System Settings → General → Login Items & Extensions. Authenticate
   locally. Follow a requested restart; do not attempt a live unload workaround.
5. Verify that Diagnostics reports the required driver build and readiness
   before any separately supervised deck/capture test. The approved PCI match
   is `0x590111C1` (vendor `11c1`, device `5901`). This grant is not general
   controller, deck or tape certification.

The new package’s physical acquisition and replacement/rollback workflow remain
unqualified. Prior bounded M1 SIP-on observations used earlier app/driver bytes.
A saved capture that plays smoothly does not establish transport continuity or
source quality. Do not interrupt an active job or replace a loaded extension
for testing. See [compatibility](COMPATIBILITY.md) and [limitations](KNOWN-LIMITATIONS.md).

## Rollback and removal

Preserve the previous verified app and original captures. Finish work first.
Use the app’s normal deactivation/removal request only when offered, follow
macOS restart instructions, and verify registered driver identity afterward.
Live unload/replacement is unqualified. If normal removal or approval stalls,
stop and request support rather than weakening security or deleting system
extension directories. Restoring an old app alone does not prove the matching
old driver is active. No script in this package automatically installs or removes
an extension.

## Historical releases

[Alpha 0.0.94 offline instructions](https://github.com/rewinddv/rewindDV/blob/alpha-0.0.94/Foundation/OFFLINE-DISTRIBUTION.md)
remain authoritative for that ad-hoc, no-driver package. Earlier full ad-hoc
releases retain their tagged instructions; do not apply their security-changing
workflow to the current signed package. Historical tags and assets are unchanged.

Report sanitized issues at https://github.com/rewinddv/rewindDV/issues or
info@rewinddv.com. Keep private support ZIPs and capture footage out of public issues.
