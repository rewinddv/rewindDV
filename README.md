<p align="center">
  <img src="assets/rewinddv-icon.png" alt="rewindDV cassette app icon" width="180" height="180">
</p>

<h1 align="center">rewindDV</h1>
<p align="center"><strong>Preserve the tape. Inspect the evidence.</strong><br>Native FireWire DV/HDV preservation for modern macOS.</p>

<p align="center">
  <a href="https://github.com/rewinddv/rewindDV/releases">Engineering releases</a> ·
  <a href="INSTALL.md">Install</a> ·
  <a href="COMPATIBILITY.md">Compatibility</a> ·
  <a href="https://github.com/rewinddv/rewindDV/issues">Report a result</a> ·
  <a href="BUILDING.md">Build</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

rewindDV brings tape acquisition, native DV playback, metadata inspection and
preservation evidence into one Mac workspace. This repository contains the
application and driver source, engineering downloads, documentation, issues and
contributions. Visit [rewinddv.com](https://rewinddv.com) for the project website.

<!-- project-status:start -->
**Current development:** rewindDV 0.1.1 (Alpha). App build 191; driver build 194. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/abb0fbc9947f965f3a08fd8a95227211beff2b84).

**Latest public download:** [Alpha 0.0.96 / Driver B193](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.96) — engineering prerelease, Developer ID-signed and notarized. App build 190 includes the matching driver. Use normal macOS approval; no SIP change is required. Offline playback, Surgery and inspection require no driver activation. Hardware qualification remains bounded.

Development source and downloads have separate identities and qualification. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## Current cumulative engineering source

The cumulative source includes the integrated IEC pack classifier, interpretation provenance and epoch-aware mixed NTSC/PAL archive model. Software inventory covers all 256 pack IDs and 274 layout variants, including reserved, unassigned and opaque cases; this is not complete semantic support or IEC certification. Raw pack bytes, conflicting observations and unknown regions remain preserved. VAUX 0x61 fixed-bit interpretation remains unresolved.

Source-bound epochs carry physical ordinals, byte extents and rational cadence through acquisition maps, metadata reports, review ranges and filmstrip/contact-sheet consumers. Lossless reviewed-range exports split at recording-system boundaries and preserve ordered source bytes. Mixed-system single-file merge and film/container output reject with a segmented-export alternative. HDV uses a separate representation and gains no physical qualification from DV archive tests.

The source retains receive ownership/lifecycle and storage safeguards, the manual Developer ID archive pipeline, and the M1 preview inspector layout correction. Source tests and native offline archive/playback checks have separate receipts from final artifact verification. Physical PAL/HDV capture, full-tape endurance, broader device compatibility and the new package’s app-driver negotiation remain unqualified. The release provenance identifies the exact public-source build; earlier M1 observations do not qualify a rebuilt driver.


## Download and install

Choose an engineering prerelease from [Releases](https://github.com/rewinddv/rewindDV/releases)
and verify its attached ZIP against its checksum. Read [installation](INSTALL.md)
and [removal, rollback and security restoration](UNINSTALL.md) before proceeding.

The current full-release pipeline produces a Developer ID-signed and notarized
app with its matching DriverKit extension and normal CLI. Verify the exact
published package in the status above. Normal macOS approval does not require
changing SIP. The preserved Alpha 0.0.94 offline package remains separately
labelled. Engineering releases are not a production-readiness claim.

Application version, source revision and driver build are separate identities.
[Release notes](RELEASE-NOTES.md) record the available releases and withdrawal
status. Historical LAB tags still point to their original hub snapshots: their
automatic “Source code” archives are not the corresponding application source.
See [release provenance and future releases](RELEASING.md).

## Preserve and inspect

- Manual ingest and whole-tape capture retain received bytes and transport evidence.
  Missing timecode or a blank stretch alone does not establish end-of-tape.
- Live monitoring and bounded deck controls support the tested DV workflow.
- Saved raw DV playback supports offline-validated NTSC/PAL transitions, seeking,
  frame stepping and source-frame inspector values. Preview controls do not
  rewrite captured media.
- Frame-local file opening and latest-request scrubbing avoid automatic full-file
  indexing. Exact coordinates remain an explicit scan, and preview estimates
  stay labeled. Sampled playback-clock values retain explicit display-association limits.
- [Native CLI and 66 local MCP tools](Foundation/CLIAndMCP.md) control playback,
  Surgery and offline review through the running app's operation guards.
  External sandbox paths require a GUI grant for the current session.
- Metadata, tape maps, reports and recovery tools preserve unknown, invalid and
  conflicting observations. Recovery derivatives remain separate from originals.
- Local diagnostic evidence helps investigate failures without automatically
  uploading footage or logs.

Matching saved-byte hashes do not prove pristine pictures or sound, lossless
transport or successful recovery. Preserve original tapes and acquisition evidence.

## Compatibility and limits

Apple silicon is the supported architecture; Intel is unsupported. The app's
deployment floor is macOS 26 and source builds use Xcode 27. Bounded runtime
evidence covers macOS 27.0.1, NTSC DV and one Sony HVR-M15U setup using the
supported PCI 11c1:5901 controller and tested adapter chain.

Broader OS, deck, adapter and storage compatibility, physical PAL/HDV capture,
HDV playback and full-length endurance remain unqualified. Offline source and
exporter tests do not extend hardware qualification. The new package has not been physically qualified. See
[compatibility](COMPATIBILITY.md) and [known limitations](KNOWN-LIMITATIONS.md).
No RECORD or tape-erasure control is provided.

## Report, build and contribute

Use [issues](https://github.com/rewinddv/rewindDV/issues) for sanitized bug reports
and compatibility results. The [test report](TEST-REPORT.md) and issue template
ask for the app version, driver build, hardware route and observed result.
**Do not attach support ZIPs, raw logs, private footage, personal paths or device
identifiers publicly.** Request a private transfer channel first; see
[privacy and support](PRIVACY.md). Public project contact: info@rewinddv.com.

Start with [building](BUILDING.md), [offline testing](TESTING.md) and
[contributing](CONTRIBUTING.md). The application lives under `Foundation/` and
uses selected root `ASFWDriver/` dependencies. An unsigned source build does not
install or activate a driver. [Source provenance](SOURCE-PROVENANCE.txt) records
the imported source identities.

## Attribution and support

rewindDV builds on modified [ASFireWire](https://github.com/mrmidi/ASFireWire)
and selected adaptations from MediaInfoLib, DVRescue and video-tools.
First-party software uses Apache-2.0; retained portions preserve their Apache,
BSD and MIT terms. Read [LICENSE](LICENSE), [NOTICE](NOTICE),
[third-party notices](ThirdPartyNotices.txt), [acknowledgments](ACKNOWLEDGMENTS.md)
and [license texts](licenses/). No upstream endorsement or project trademark
rights are implied. The generic source-build icon is intentional.

[Support rewindDV on Ko-fi](https://ko-fi.com/rewinddv). Funds raised go toward
purchasing IEC standards to research tape metadata and expand what rewindDV can
decode. Support does not buy guaranteed compatibility, recovery, Apple approval
or a release date; purchased standards are not redistributed.

## Historical Alpha 0.0.94 offline distribution

The preserved Alpha0.0.94 download uses reduced app entitlements and includes no DriverKit extension. Driver discovery/activation, deck control and physical acquisition are disabled by an explicit bundle distribution flag. That historical package excludes the driver. Current full distribution instructions are in INSTALL.md. Playback, metadata inspection, supported archive/export and CLI/MCP remain available without a SIP change. Read [offline distribution instructions](Foundation/OFFLINE-DISTRIBUTION.md). An earlier full ad-hoc candidate was rejected on a SIP-enabled host because of restricted DriverKit app entitlements; it was not published.
