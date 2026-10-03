# rewindDV — Alpha 0.0.81 source snapshot

> **Help fund the standards behind tape metadata.** Funds raised go toward
> purchasing IEC standards to research all the metadata these tapes can contain
> and expand what rewindDV can decode.
> [**Support on Ko-fi →**](https://ko-fi.com/rewinddv)

This is the canonical open-source repository for rewindDV. Visit the
[project website](https://rewinddv.com) or the
[testing and release hub](https://github.com/rewinddv/rewindDV-LAB).
An interim [Alpha 0.0.81 / Driver Build183 engineering alpha](https://github.com/rewinddv/rewindDV-LAB/releases/tag/alpha-0.0.81) is available separately. It is ad-hoc signed, not notarized, and requires disabling SIP, which reduces macOS security. See [installation scope](INSTALLATION-PLAN.md).

rewindDV is a macOS FireWire DV/HDV preservation project. This package contains
the tested Alpha 0.0.81 application source and unchanged Build183 driver inputs.
It is a source package, not an official installable binary release.

Alpha 0.0.81 adds bounded-memory DV/HDV post-capture processing, raw DV25
NTSC/PAL playback transitions, source-frame inspector values and a fixed playback
viewport. These improvements are offline validated; they do not extend physical
PAL/HDV qualification. See [current release notes](Foundation/Docs/Alpha081ReleaseNotes.md).

The application reserves capture-start ownership before waiting for an existing
device query. A cancelled waiting request cannot later start capture. Rejection
before receiving does not clean up another session, reuse its final counters,
claim saved media or create a new STOP warning. Existing STOP obligations remain
visible until supported evidence resolves them.

Bounded tests on one Sony HVR-M15U NTSC DV setup passed first-attempt manual
starts, whole-tape cancellation/final accounting, a subsequent capture and an
idle reconnect. This does not establish every timing interaction, device or
format. Read [COMPATIBILITY](COMPATIBILITY.md) and
[KNOWN-LIMITATIONS](KNOWN-LIMITATIONS.md) before drawing broader conclusions.

Capture preserves received bytes and records integrity, continuity and source
quality observations. Matching saved-byte hashes do not prove pristine pictures
or sound, lossless transport or successful recovery. Unknown and conflicting
observations remain distinct from confirmed facts.

- [BUILDING](BUILDING.md): native unsigned source build.
- [TESTING](TESTING.md): complete package and focused offline checks.
- [RELEASE-NOTES](RELEASE-NOTES.md): scope and bounded results.
- [SOURCE-PROVENANCE](SOURCE-PROVENANCE.txt): exact source identities.
- [INSTALLATION-PLAN](INSTALLATION-PLAN.md): separate binary distribution scope.

First-party software uses Apache-2.0. Retained Apache, BSD-2-Clause, BSD-3-Clause
and MIT portions keep their applicable notices and terms. See [LICENSE](LICENSE),
[NOTICE](NOTICE), [ThirdPartyNotices](ThirdPartyNotices.txt),
[ACKNOWLEDGMENTS](ACKNOWLEDGMENTS.md) and [license texts](licenses/).
The generic source-build icon is intentional; the software license grants no
project trademark rights. No upstream endorsement is claimed.

See [CONTRIBUTING](CONTRIBUTING.md), [PRIVACY](PRIVACY.md) and
[BRANDING-AND-FUNDING](BRANDING-AND-FUNDING.md). Optional project support is available through [Ko-fi](https://ko-fi.com/rewinddv).
