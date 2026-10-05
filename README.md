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
**Current development:** Alpha 0.0.87 / Driver B188. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/eca8ebfd5bc8a5096441cf3c1b67d2a48a1cdb66).

**Latest public download:** [Alpha 0.0.81 / Driver B183](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.81) — engineering prerelease, ad-hoc signed and not notarized. Installation requires disabling SIP, which reduces macOS security.

Development source and bounded tests do not approve a new download. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## Download and install

Choose an engineering prerelease from [Releases](https://github.com/rewinddv/rewindDV/releases)
and verify its attached ZIP against its checksum. Read [installation](INSTALL.md)
and [removal, rollback and security restoration](UNINSTALL.md) before proceeding.

**The current engineering binaries are ad-hoc signed and not notarized.
Installation requires disabling System Integrity Protection (SIP), which reduces
macOS security.** They are intended for experienced users and dedicated test
systems. Developer ID signing, notarization and normal SIP-on distribution remain
future work. These releases are not a production-readiness claim.

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
exporter tests do not extend hardware qualification. The packaged ad-hoc releases
have not been installed or newly physically qualified. See
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
