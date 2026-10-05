# Bounded compatibility evidence

<!-- project-status:start -->
**Current development:** Alpha 0.0.87 / Driver B188. [Reviewed public source](https://github.com/rewinddv/rewindDV/tree/eca8ebfd5bc8a5096441cf3c1b67d2a48a1cdb66).

**Latest public download:** [Alpha 0.0.81 / Driver B183](https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.81) — engineering prerelease, ad-hoc signed and not notarized. Installation requires disabling SIP, which reduces macOS security.

Development source and bounded tests do not approve a new download. Application versions and driver builds advance independently. [Machine-readable status](PROJECT-STATUS.json).
<!-- project-status:end -->

## 2026-10-04 development candidate: bounded physical evidence

On 2026-10-04, the unchanged Alpha 0.0.87 / B188 development candidate passed
four bounded recorded-NTSC-DV captures on Apple silicon, macOS 27.0.1 and one
Sony HVR-M15U with the existing tested adapter chain (PCI 11c1:5901).
After a Mac-side adapter restart, the captures contained 763, 717, 18,265 and
765 complete frames. The longest saved DV was 609.442 seconds; receive ownership
was 613.448 seconds. Saved hashes, frame accounting, stopped-state observations,
quiesced receive close and normal app shutdown checks passed.

These are empirical results for that development installation, not installation
or hardware qualification of the downloadable ad-hoc package. Each capture
retained two counter discontinuities after empty packets and one terminal partial
frame. Zero reported host-ring drops does not prove uninterrupted hardware
continuity or pristine audiovisual content. The long preview had two unusable-PCM
frame observations; subjective saved-playback acceptance remains pending.

The earlier device disappearance remains unexplained. Reconnecting the Mac-side
adapter recreated the attachment and restored bounded operation; it does not
isolate the cause or establish a permanent fix. Full tapes, natural EOT, induced
resets during capture, physical PAL/HDV capture and HDV playback remain unqualified.
The app deployment floor is macOS 26; broader OS/hardware/storage support remains
unverified. App arm64 and driver arm64e target Apple silicon; Intel is unsupported.

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
