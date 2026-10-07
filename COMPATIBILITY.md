# Bounded compatibility evidence

<!-- project-status:start -->
**Current development:** Alpha 0.0.93 / Driver B190. App build 188. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/482cf2fcdee763535dd5e69a658886accce20f36).

**Latest public download:** [Alpha 0.0.93 / Driver B190](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.93) — engineering prerelease, ad-hoc signed and not notarized. Driver installation requires disabling SIP, which reduces macOS security. Offline playback, Surgery and inspection require no driver activation.

Development source and bounded tests do not approve a new download. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## Current Alpha 0.0.89 / Driver B190 development

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
