# Bounded compatibility evidence

<!-- project-status:start -->
**Current development:** rewindDV 0.1.13 (Beta). App build 203; driver build 203. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/28a500cb57f9f3f1ffeab16386cf9f1943d4d8ab).

**Latest public download:** [Beta 0.1.12 / Driver B203](https://github.com/rewinddv/rewindDV/releases/tag/beta-0.1.12) — engineering prerelease, Developer ID-signed and notarized. App build 202 retains Driver B203 (driver version 0.1.11) unchanged. Use normal macOS approval; no SIP change is required. Offline playback, Surgery and inspection require no driver activation. Hardware qualification remains bounded.

Development source and downloads have separate identities and qualification. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## Current cumulative engineering source

The current Beta source includes the accepted reconnection and app-readiness fixes, bounded evidence retention, held-timecode classification, capture startup/tail classification and source-bound viewing ranges. Captured source bytes and damage evidence remain preserved; playback does not repair the tape. The cassette icon, preferred 16:9 initial window, inspector navigation and Beta naming are integrated.

The capture and playback inspectors show every observed pack using a classifier/catalog covering 256 allocations and 274 layout variants, with decoded labels, field validity, interpretation provenance, references and raw bytes. Inventory coverage includes reserved, unassigned and opaque entries; it is not a claim of complete semantic decoding or IEC certification. Mixed NTSC/PAL recording epochs and lossless segmented exports preserve source ordering and unknown regions. HDV remains separately represented and physically unqualified.

Successful PAL captures and a completed whole-tape workflow are documented below with their actual earlier builds. Later Driver199 reconnect/capture and Driver200 reread checks, plus Driver202 idle stability, have separate bounded evidence. The current public package has its own software, signing and distribution validation; these earlier results do not establish a fresh physical test of Driver203.


## Successful PAL and whole-tape captures

**EMPIRICAL_EVIDENCE — retained capture verification and job records, reviewed 2026-10-11.** These successful physical acquisition results on the Sony HVR-M15U apply to the named earlier builds.

| Workflow | Tested build | Saved result | Verification |
| --- | --- | --- | --- |
| PAL-dominant DV capture | Alpha 0.0.77 / Driver183 | 78,581 PAL frames within 78,635 total frames; approximately 52:25 of mixed-system DV | Saved-byte integrity, final acknowledgement and native DV reread passed; operator stopped the job |
| Automated whole-tape NTSC DV capture | Alpha 0.0.81 / Driver183 | 112,412 complete frames; approximately 62:30.8 of media | Observed stop, receive drain, saved-byte verification, native reread and final acknowledgement passed |
| Additional PAL DV capture | Alpha 0.0.87 / Driver188 | 11,761 PAL frames, approximately 7:50 of PAL media | Receive closed and saved-data verification passed; operator canceled the job |

The whole-tape job completed rewind, inferred start, capture, observed stop, inferred end, drain and verification. Boundaries came from observed transport behavior; absolute physical tape-end coverage was not independently established. The PAL records establish successful PAL capture, rather than completed whole-tape PAL coverage.

The longer PAL and whole-tape records each retain three CIP/DBC discontinuities after empty packets and one terminal partial frame. Known packet drops, host-ring drops and raw transport-gap counters were zero. These counters and matching saved-byte hashes do not establish pristine audiovisual content or unknown hardware continuity. This audit inspected retained records; it did not rehash or view the original media anew.

## Later bounded reconnection and startup checks

Driver199 completed three controlled stopped-deck reconnects followed by a bounded NTSC capture, with app readiness recovering rather than staying locked out. Driver200's analysis established that the earlier distortion was already present in received DV bytes. The controlled reread was clean and did not trigger damaged-frame exclusion; startup instability versus intermittent tape-read damage remains unresolved. Exclusion behavior was verified offline on the original recording. Driver202's observed idle session remained stable for about 30 minutes without a reset storm or app lockout. These are bounded results, not permanent-lockout stress coverage, active-capture unplug testing, live unload qualification or a fresh physical test of Driver203.

## Bounded M1 SIP-on observation

An M1 MacBook Air running macOS 26.6.2 exercised Developer ID-signed App188
with Driver192 and a Sony HVR-M15U. SIP and authenticated-root protection were
enabled; system-extension developer-mode state remained unknown. The operator
approved normal extension activation and reseated the cable before deck discovery.

The retained capture contains 452 complete NTSC frames (15.0817 seconds), despite
the operator describing the interaction as a four-second capture. Saved-byte and
final acknowledgement checks passed. Host ring drops, oversized/rejected packets
and raw transport-gap events were zero; two DBC discontinuities after empty
packets and one terminal partial frame remained recorded. Exact lost frames and
source quality remain unknown. The operator reported a stuttery preview but
smooth saved-file playback.

A later App189 inspector layout correction and paced saved-frame replay passed
offline on that M1. No physical live-preview retest followed. Its Open DV chooser
was not visible over Screen Sharing; a direct local comparison was unavailable.
The current combined app’s chooser and saved playback worked on the development
Mac, which does not resolve that M1-only observation. Preserve this limitation
when testing the new release. The final new package has different app/driver
bytes and does not inherit those earlier installation or acquisition results.

## Historical Alpha 0.0.89 / Driver B190 development evidence

On one Sony HVR-M15U setup using Apple silicon, macOS 27.0.1 and the supported
Apple adapter chain, the development-signed candidate passed stationary startup
and sixty-second idle observation, short NTSC DV capture, same-app capture
re-entry, capture after a normal app quit/reopen, approximately sixty seconds of
capture, and an operator-stopped four-minute automated capture job.

The five captures saved 79, 300, 119, 1,789 and 7,134 complete NTSC frames.
Saved durations were 2.636, 10.010, 3.971, 59.693 and 238.038 seconds. The first
two differed from the nominal four-second target; actual durations are retained.
Each had positive capture-owned receive retirement, final acknowledgement and
independent saved-byte hash verification. The driver remained loaded throughout.

All five reported zero host-ring drops, oversized packets and rejected packets.
Each retained two continuity-counter changes after empty packets and one terminal
partial frame; none of those changes discarded a partial frame. Exact missing
frames, hardware continuity and source recording quality remain unknown.

These observations apply to the tested development-signed runtime. The separately
built public ad-hoc package has not been installed or physically qualified.
Its signatures and offline checks are separate evidence. A successful capture
STOP does not unload the extension; live unload/replacement remains unqualified.
Use the shutdown/restart-based maintenance procedure in [UNINSTALL](UNINSTALL.md).
The four-minute job was intentionally stopped by the operator, not completed to
end of tape. Full-tape completion/endurance, natural EOT, physical PAL/HDV capture,
provider-loss/reconnect, sleep/wake and broader hardware remain unqualified.

## Historical Alpha 0.0.87 / B188 development evidence

Earlier development had four bounded NTSC captures, including 609.442 seconds of
saved DV after a Mac-side adapter restart. That older result is not the current
candidate's endurance qualification. Its earlier device-disappearance cause
remains unresolved. Historical release and source identities are preserved.

## Historical Alpha 0.0.77 / retained B183 evidence

The 2026-10-02 targeted retest used Alpha 0.0.77 with the exact retained Build183
driver on macOS 27.0.1 (26A434), Apple silicon, a Sony HVR-M15U, recorded NTSC DV,
an Apple Thunderbolt-to-FireWire adapter and an additional USB-C/Thunderbolt
adapter whose exact model was not recorded. The app was arm64 and driver arm64e.

First attempts passed after launch/discovery, after a completed manual capture,
through normal whole-tape rewind/start followed by cancellation and a subsequent
capture, and after operator-performed idle disconnect/reconnect and rediscovery.
Five saved clips contained 1,138 complete frames, 37.9713 seconds and
136,560,000 DV bytes. All finalized with verified saved-byte/per-frame accounting.

The whole-tape job remained interrupted. Its historical progress of one frame
remained distinct from the final 225 verified frames. The UI and independently
reopened persisted summary agreed, including closed reception and STOP evidence.
The operator found no visible or audible issue in three representative clips,
including the new marked-frame vicinity. Two clips were not separately reviewed
by the operator; their integrity checks passed.

Earlier Build183 tests on Alpha 0.0.76 included a 197.898-second saved capture and
an observed bus-cycle wrap. That run followed a separately recorded initial
capture-start rejection. Its failure remains part of the history. The long run
and wrap campaign were not repeated with Alpha 0.0.77, and its success cannot
explain the original rejection.

Other decks, HDV capture, PAL DV, other adapter combinations, natural EOT,
full-length tapes and broader macOS versions are not established by these
results. Project scope and deployment settings are not a compatibility matrix.
See [KNOWN-LIMITATIONS](KNOWN-LIMITATIONS.md).

## Historical Alpha 0.0.94 offline distribution

The preserved Alpha0.0.94 download uses reduced app entitlements and includes no DriverKit extension. Driver discovery/activation, deck control and physical acquisition are disabled by an explicit bundle distribution flag. That historical package excludes the driver. Current full distribution instructions are in INSTALL.md. Playback, metadata inspection, supported archive/export and CLI/MCP remain available without a SIP change. Read [offline distribution instructions](Foundation/OFFLINE-DISTRIBUTION.md). An earlier full ad-hoc candidate was rejected on a SIP-enabled host because of restricted DriverKit app entitlements; it was not published.
