# Bounded compatibility evidence

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
