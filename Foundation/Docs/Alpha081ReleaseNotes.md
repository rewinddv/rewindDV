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
in the canonical source and LAB. Original captures are never rewritten by playback.

Alpha 0.0.78–0.0.80 were intermediate development builds, not public releases.
Alpha 0.0.77 remains historical and is superseded by this engineering release.
B178 remains withdrawn.

Source: https://github.com/rewinddv/rewindDV
Downloads and installation: https://github.com/rewinddv/rewindDV-LAB
Contact: info@rewinddv.com
