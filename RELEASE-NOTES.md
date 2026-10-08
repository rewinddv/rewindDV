# Development and releases

<!-- project-status:start -->
**Current development:** Alpha 0.0.94 / Driver B192. App build 188. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/9cda6d14c9c551e1d1bc7457f26d2fe550b0f9fc).

**Latest public download:** [Alpha 0.0.93 / Driver B190](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.93) — engineering prerelease, ad-hoc signed and not notarized. Driver installation requires disabling SIP, which reduces macOS security. Offline playback, Surgery and inspection require no driver activation.

Development source and downloads have separate identities and qualification. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## Alpha 0.0.94 engineering source

Alpha 0.0.94 / application build 188 / independent Driver B192 includes the integrated IEC pack classifier, interpretation provenance and epoch-aware mixed NTSC/PAL archive model. Software inventory covers all 256 pack IDs and 274 layout variants, including reserved, unassigned and opaque cases; this is not complete semantic support or IEC certification. Raw pack bytes, conflicting observations and unknown regions remain preserved. VAUX 0x61 fixed-bit interpretation remains unresolved.

Source-bound epochs carry physical ordinals, byte extents and rational cadence through acquisition maps, metadata reports, review ranges and filmstrip/contact-sheet consumers. Lossless reviewed-range exports split at recording-system boundaries and preserve ordered source bytes. Mixed-system single-file merge and film/container output reject with a segmented-export alternative. HDV uses a separate representation and gains no physical qualification from DV archive tests.

The accepted source passed 527 Swift Testing tests and 14 XCTest cases, receive ownership/lifecycle and storage tests, and an unsigned Release app/driver build. Native mixed playback and all-frame archive/export validation were measured offline. Rendered archive/metadata components were exercised in an isolated host; the full signed application UI, exact signed app-driver negotiation, Driver192 physical acquisition, PAL/HDV capture and full-tape endurance remain unqualified. Publication tests and artifact provenance report the exact public-source reruns separately.


## Historical Alpha 0.0.93 / Driver B190 public download

Saved-DV opening presents the first frame without a whole-file index. Rapid
scrubbing prioritizes the latest request, and detailed metadata follows the
selected frame after gesture release. Exact coordinates and full-file forensic
assessment remain explicit scans; preview duration and ordinals are estimates.
Mixed-format seek metadata association remains an unresolved limitation.

A native `rewinddv` CLI also serves 66 MCP tools over stdio, using the running
app's same-user local socket and existing operation guards. Playback, Surgery,
archive inspection, evidence maps, review, multi-pass comparison and recovery-plan
preparation are available without the driver. External paths require a GUI
sandbox grant for the current session. Driver activation and physical supervised
recovery remain attended. See [CLI/MCP](Foundation/CLIAndMCP.md).

The Alpha 0.0.93 source passed offline package tests, native app/CLI builds and
read-only CLI/MCP/socket checks. These changes do not add physical capture
qualification. The separately built and verified latest downloadable
package is Alpha 0.0.93 / Driver B190, including the native arm64 CLI/MCP client.
The app, driver and CLI are ad-hoc signed with hardened runtime and are not
notarized. Driver activation is unnecessary for offline playback and Surgery.
The exact public package has not been installed or physically qualified.

ZIP SHA-256: `1d72e36932700230d2be98e66dc8718e514761576a9e2c6ae867861cdbff23e8`.

## Retained Alpha 0.0.89 / Driver B190 source changes

The retained Alpha 0.0.89 source hardened DMA retirement and transaction identity, device-generation
lifetimes, dispatch and callback ownership, user-client runtime binding, and
native cancellation completion lifetimes. Failed or unproved retirement retains
ownership and blocks reuse. The application requires the exact independent driver
build; app188 and driver190 are not coupled counters. The source also includes
lossless reviewed Surgery assembly and bounded archive/export cancellation.

Software validation and bounded NTSC capture/STOP/re-entry evidence are recorded
in [TEST-REPORT](TEST-REPORT.md) and [COMPATIBILITY](COMPATIBILITY.md). Shared driver
services remain loaded after normal capture STOP. Live extension unload remains
unqualified; [UNINSTALL](UNINSTALL.md) uses a shutdown/restart boundary.

A public ad-hoc package is prepared separately from the tested development-signed
installation. Check the explicit latest-download status above for the artifact
actually published. No normal SIP-on, notarized, broad hardware or full-tape claim
is made. Earlier release identities remain unchanged.

## Historical Alpha 0.0.87 / B188 source changes

The Alpha 0.0.87 / B188 source adds DMA-safe handling of unaligned partial receive
completions, bounded reset-segment recovery and capture shutdown supervision,
FCP response submission before command progression, retention of reset-ingress
Self-ID evidence, cancellation of obsolete reset recovery, and nonblocking reset
processing. Control-timer setup now precedes controller dependency copying; the
app also offers a direct route to macOS driver approval settings.

The FCP and reset-ingress improvements derive from the reviewed ASFireWire
behavior, with downstream preservation and ownership constraints retained.
Original received bytes, gap accounting and unknown continuity remain authoritative;
recovery does not claim to reconstruct missing packets. License and modification
notices remain attached to the imported components.

Software validation covers the package suite, native Release compilation, receive
lifecycle/ownership, FCP ordering and OHCI host regressions. See
[bounded physical evidence](COMPATIBILITY.md) and [known limitations](KNOWN-LIMITATIONS.md).
There is no new public binary: the development-signed candidate is not an approved
public distribution artifact. Full-tape endurance and the disappearance cause remain
open. Intermediate development versions are not manufactured into releases.

---

# Alpha 0.0.81 · Driver B183 — engineering alpha

Ad-hoc signed and not notarized. Installation requires disabling System Integrity
Protection (SIP), which reduces macOS security. Intended for experienced users
and dedicated test systems. Developer ID signing, notarization and normal SIP-on
distribution remain future work.

## Changes since Alpha 0.0.77

- DV/HDV post-capture reconstruction and verification now bound temporary-object
  lifetimes during long recordings. Independent rereads, hashes, retained source
  evidence and exclusive publication checks remain intact. This is not a claim
  about total app RAM or a promise of zero system swap.
- Saved raw DV playback handles NTSC, PAL and transitions between them in one
  file. Seeking, stepping, duration and source-frame numbering use validated DV
  frame boundaries and each system's exact stored cadence. Native video decoding
  and frame-based PCM follow those boundaries; source timecode is not used to
  invent missing frames.
- Playback inspector format, dimensions, cadence, chroma, audio and recording
  metadata share one identified source-frame snapshot. Playing metadata is
  sampled twice per second; system changes clear stale values and pausing resolves
  the selected frame. Missing or conflicting metadata stays unavailable.
- Whole-file size and duration remain separate from sampled source properties.
  The playback viewport and controls keep a fixed layout across format changes.
- Read-only DV source auditing also drains per-frame temporary objects.

The retained Build183 driver is unchanged. These application changes have offline
validation; they do not extend physical PAL, HDV, device or endurance qualification.
The public binary uses the exact retained ad-hoc Build183 extension.

## Known limits

The cancelled receive-task Stop path can suppress intermediate reconstruction or
verification progress while processing continues; the final result still arrives.
Saved raw DV playback rejects incomplete or unordered frame boundaries rather
than guessing past damaged structure. HDV playback is not qualified by this work.
Existing capture, hardware, recovery and security limitations remain documented
in this repository. Original captures are never rewritten by playback.

Alpha 0.0.78–0.0.80 were intermediate development builds, not public releases.
Alpha 0.0.77 remains historical and is superseded by this engineering release.
B178 remains withdrawn.

Source: https://github.com/rewinddv/rewindDV
Downloads and installation: https://github.com/rewinddv/rewindDV
Contact: info@rewinddv.com

## Download verification and offline validation

Download the ZIP and checksum from [Alpha 0.0.81](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.81).
Read [installation](INSTALL.md) and [removal/security restoration](UNINSTALL.md).

ZIP SHA-256: `3da2b307e481548be3a51c2fcf9ff3cfcee892a85b8ae4b66ea1620622aaedae`.

Validation passed: 438 Swift Testing tests, 14 XCTest tests, Debug and Release
builds, a fresh Release build from the pinned public source, bounded-memory and
repeated-job regressions, mixed NTSC/PAL playback, storage, manual stop,
admission/boundary, whole-tape/recovery orchestration and quit supervision.
The candidate passed archive, signature, architecture, driver-identity and
personal-information checks. These are offline checks; the packaged ad-hoc app
has not been installed or newly physically qualified.

---

# Alpha 0.0.77 / Driver Build183 — historical, superseded

Engineering alpha. Ad-hoc signed and not notarized.
Installation requires disabling System Integrity Protection (SIP),
which reduces macOS security.

Alpha 0.0.77 / Driver Build183 is intended for experienced users and dedicated/test systems.

- Canonical source: https://github.com/rewinddv/rewindDV
- [Installation and checksum verification](https://github.com/rewinddv/rewindDV/blob/alpha-0.0.77/INSTALL.md)
- [Uninstall, rollback and restore security](https://github.com/rewinddv/rewindDV/blob/alpha-0.0.77/UNINSTALL.md)
- [Sanitized issue reports](https://github.com/rewinddv/rewindDV/issues)

Download **rewindDV-Alpha-0.0.77-Build183-AdHoc.zip** and its `.sha256` sidecar.
This historical tag's automatic source archives contain the former hub snapshot, not the application's source. See [release provenance](RELEASING.md).

```sh
shasum -a 256 -c rewindDV-Alpha-0.0.77-Build183-AdHoc.zip.sha256
```

ZIP SHA-256: `5b8e2787f3b48485fb54392a40fca3c5ea688ef944dbc61ba7c38f72dff31d77`.

The package contains the app and reviewed installation/removal documents. The app and DriverKit extension are ad-hoc signed; no development provisioning profile is included. No local re-signing or developer-account registration is required.

Offline validation passed: 427 Swift Testing tests, 14 XCTest tests, admission, boundary, manual-stop-tail, whole-tape/recovery orchestration, PLAY callback and quit-supervision regressions, Release build and strict signature/bundle checks. The exact archive passed the personal-information audit.

Existing bounded runtime evidence covers Apple silicon, macOS 27.0.1, recorded NTSC DV and a Sony HVR-M15U. This repackaged ad-hoc artifact has not been installed or newly physically qualified. Fresh-system installation, broader macOS/deck/adapter compatibility, PAL/HDV capture, full-length endurance, natural end-of-tape and active-capture disconnect/power loss remain unverified. The supported controller match is PCI 11c1:5901. Unknown continuity and unresolved content-quality markers remain unknown; saved-byte hashes do not establish flawless audiovisual content.

Normal Developer-ID-signed, notarized, SIP-on distribution remains future work dependent on Apple distribution prerequisites. No Apple endorsement is implied.

Alpha 0.0.63 / Driver B178 remains withdrawn. Do not post support ZIPs, raw logs, personal paths, device identities or footage in public issues. Project contact: info@rewinddv.com.

## Previous release

Alpha 0.0.63 / Driver B178 is an older development build and has been withdrawn from distribution.

---

## Historical Alpha 0.0.77 source release

# Alpha 0.0.77 source release notes

Application source: `02ebc9eec11448c951fbacdd62b179f28a920f45`.
Retained driver source: `67c5e03f8fd6387a34322d373523f32cf53dc2a5`, Build183.
The export's unsigned build is distinct from the unchanged qualified binaries.

The capture-start correction reserves foreground ownership before joining an
existing device query. It prevents background observation from overtaking that
reservation, rechecks cancellation and route, and submits receive once. The
receiver startup allowance begins after the query join. A rejected submission
does not clean up another session or borrow its final counters. Cancellation and
rejection wording avoid false saved-media and new STOP-obligation claims;
existing STOP uncertainty is preserved until appropriate proof resolves it.

The 2026-10-02 targeted retest passed the first-attempt manual, cancellation,
follow-up and idle-reconnect scenarios. Saved files finalized and representative
playback showed no operator-noticed audiovisual issue. Physical query overlap
and waiting cancellation were not exercised. The historical rejection owner and
marked-frame causes remain unresolved. Details and quality caveats are in
[COMPATIBILITY](COMPATIBILITY.md) and [KNOWN-LIMITATIONS](KNOWN-LIMITATIONS.md).

This snapshot retains the preceding address representation, interrupt formatter,
rational clock and metadata implementation work with required Apache/BSD/MIT
notices. The admission delta adds no third-party dependency or effective license
change. No original capture or historical qualification result is rewritten.

The source package keeps reviewed synthetic fixtures, portable signing
configuration and a generic icon. It contains no private Git history, signed
application, development profile or original recording. An initial public import
will be a new source snapshot, not the private development branches or tags.

## Offline-only distribution

The Alpha0.0.94 downloadable candidate uses reduced app entitlements and includes no DriverKit extension. Driver discovery/activation, deck control and physical acquisition are disabled by an explicit bundle distribution flag. The complete source retains independent Driver192; full hardware packages remain a separate qualification/signing task. Playback, metadata inspection, supported archive/export and CLI/MCP remain available without a SIP change. Read [offline distribution instructions](Foundation/OFFLINE-DISTRIBUTION.md). The corresponding full ad-hoc candidate was rejected on a SIP-enabled host because of restricted DriverKit app entitlements; it was not published.
