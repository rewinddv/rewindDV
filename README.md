<p align="center">
  <img src="assets/rewinddv-icon.png" alt="rewindDV cassette app icon" width="180" height="180">
</p>

<h1 align="center">rewindDV LAB</h1>
<p align="center"><strong>Preserve the tape. Inspect the evidence.</strong><br>Native MiniDV ingest, playback and preservation tools for Apple Silicon running macOS 26 Tahoe and beyond.</p>

<p align="center">
  <a href="https://github.com/rewinddv/rewindDV-LAB/releases">Releases</a> ·
  <a href="INSTALL.md">Installation</a> ·
  <a href="UNINSTALL.md">Remove & restore security</a> ·
  <a href="https://ko-fi.com/rewinddv"><strong>Support on Ko-fi</strong></a>
</p>

> **Help fund the standards behind tape metadata.** Funds raised go toward
> purchasing IEC standards to research all the metadata these tapes can contain
> and expand what rewindDV can decode.
> [**Support on Ko-fi →**](https://ko-fi.com/rewinddv)

## Release status

Alpha 0.0.63 / Driver B178 is an older development build and has been withdrawn from distribution.

**[Alpha 0.0.77 / Driver Build183 — engineering alpha](https://github.com/rewinddv/rewindDV-LAB/releases/tag/alpha-0.0.77)** is ad-hoc signed and not notarized.

rewindDV currently uses an ad-hoc-signed DriverKit extension.
Installation requires disabling System Integrity Protection (SIP).
Disabling SIP reduces macOS security.

Intended for experienced users and dedicated/test systems. Read the
[installation and checksum instructions](INSTALL.md) and
[removal/rollback instructions](UNINSTALL.md) before proceeding.

This is the testing and release hub for rewindDV. The
[canonical open-source repository](https://github.com/rewinddv/rewindDV) contains
the current source snapshot, build instructions, and qualification limits. Visit
the [project website](https://rewinddv.com) for more about the project.

This repository preserves project documentation and release history.
GitHub’s automatic “Source code” archives contain this hub’s documentation and
assets; they do not contain the application.

## What rewindDV does

**Apple removed built-in FireWire support with macOS 26 Tahoe in 2025.**
Apple now lists native FireWire support as requiring macOS Sequoia 15 or earlier,
leaving legacy DV decks and camcorders without that built-in connection path on
Tahoe and later macOS versions. [Apple's FireWire compatibility guidance](https://support.apple.com/en-us/109523#firewire)

rewindDV restores a DV-focused FireWire acquisition path for Apple Silicon,
so existing tapes and working decks can remain part of a modern preservation workflow.

rewindDV brings DV tape acquisition and careful inspection into one native Mac
workspace. It preserves received DV data and separates transport-loss evidence,
source-content defects and preview-only issues rather than hiding them behind
a single “success” message.

- **Capture:** manual ingest or whole tape automated rewind & capture.
  Missing timecode or a blank
  stretch does not, by itself, end capture. Physical stop observations are not
  infallible proof of BOT/EOT; hardware and operator intervention matter.
- **Live monitoring and deck control:** picture, audio meters, source timecode,
  approximate play elapsed time, Play/Stop, rewind/fast-forward and supported
  forward/reverse picture search. Physical deck controls and GUI controls work
  together on tested equipment.
- **Verify before disconnecting:** reconstruction/reread progress, saved-byte
  integrity checks, retained receive evidence and completion/attention
  notifications on your Mac. Notifications are local—not email or mobile push.
- **Native DV playback and inspection:** responsive scrubbing, field-oriented
  viewing options, 1×/2×/4×/8× zoom and navigator, preview-only 4:3/16:9 overrides,
  and measured highlight/shadow signal-limit overlays. These controls do not
  rewrite the captured DV. Signal limits do not prove unrecoverable clipping.
- **Metadata:** technical video/audio specifications, recorded date/time,
  timecode, aspect-ratio evidence and decoded DV metadata with raw provenance.
  Missing, invalid, conflicting and historical observations remain distinct.
- **Analysis & Recovery:** tape maps and frame/block inspection, portable
  reports, previewed scene segmentation, bounded recovery planning with wear
  accounting, and multi-pass comparison/verified merge tools. These are advanced
  alpha workflows with conservative eligibility checks—not guaranteed repair.
- **Local flight recorder:** bounded diagnostic evidence and support export
  to help explain failures without automatically uploading footage or logs.

## Compatibility and honest limits

| Area | Current scope |
|---|---|
| Mac | Apple Silicon only; Intel unsupported |
| macOS | Minimum 26; built with Xcode 27. bounded runtime evidence on macOS 27.0.1; broader compatibility remains unverified |
| FireWire controller | Current driver matches PCI **11c1:5901**, used in the tested Apple Thunderbolt-to-FireWire adapter chain |
| Source | DV25 over IEEE 1394 from a compatible deck/camcorder; select DV output (HDV coming soon; not included in this release) |
| Other FireWire products | Not an audio-interface or SCSI/storage driver |
| Destination | Local/external SSD recommended; APFS, HFS+ or exFAT. Avoid FAT32 and unqualified network volumes |

No RECORD or tape-erasure control is provided. Tape wear, deck faults, software
failures, storage stalls and source defects remain possible. Do not run another
experimental FireWire driver against the same controller at the same time.
Keep physical STOP accessible during initial tests.

**Verified saved bytes do not prove flawless source content or unconditional
lossless acquisition.** Known loss and uncertainty remain visible. Preserve
your original tapes and acquisition evidence; never replace a master with a
recovery derivative merely because it looks better.

## Existing installations and reports

For an existing installation, see [Remove & restore security](UNINSTALL.md).
The [test report template](TEST-REPORT.md) remains available for reports about
earlier tests.

Public [issues](https://github.com/rewinddv/rewindDV-LAB/issues) are for sanitized
bug summaries and compatibility reports. **Do not attach support ZIPs, raw logs,
private footage, personal paths or deck identifiers publicly.** Ask for a private
transfer channel first. See [Privacy & support evidence](PRIVACY.md).

## Built on open-source work

rewindDV uses a modified **[ASFireWire](https://github.com/mrmidi/ASFireWire)**
driver foundation. It also incorporates selected DV metadata mappings adapted
from **[MediaInfoLib](https://github.com/MediaArea/MediaInfoLib)** and nominal
DV-block geometry adapted from **[DVRescue](https://github.com/mipops/dvrescue)**.
Those contributions are credited explicitly; rewindDV is not an official
release of, or endorsed by, those projects.

See [Acknowledgments](ACKNOWLEDGMENTS.md), [Apache-2.0 license](ASFireWire-LICENSE.txt),
[ASFireWire notices](ASFireWire-NOTICE.txt) and [third-party notices and BSD terms](ThirdPartyNotices.txt).

## ♥ Sponsor this project

Funds raised go toward purchasing **IEC standards** to research all the metadata
these tapes can contain and expand what rewindDV can decode. These primary
references help us interpret recorded packs and fields against documented requirements.

### [Support rewindDV on Ko-fi →](https://ko-fi.com/rewinddv)

Contributions will not buy guaranteed compatibility, recovery,
Apple entitlement approval or a release date. Purchased standards will not be
redistributed through this repository.
