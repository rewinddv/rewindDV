# Alpha 0.0.78 · Driver B183 — engineering alpha

This engineering candidate is ad-hoc signed and not notarized. Existing
installation requirements and security limitations continue to apply. It is
prepared for review; no public release has been published by this hotfix task.

This app update bounds memory used after capture stops, while reconstructing and
verifying DV and HDV recordings. Temporary read and metadata objects are released
throughout processing instead of accumulating over a long recording.

All independent hashes, metadata, loss evidence and exclusive publication checks
remain in place. Original recordings are never automatically repaired or replaced.
The exact signed Build183 driver is retained without rebuilding or re-signing it.

Optimized offline tests reduced a 256 MiB production export from 794.5 MiB to
5.9 MiB peak physical footprint; a 4 GiB export stayed at 9.2 MiB. Repeated jobs
through the real app finalization code stayed below 17 MiB. These figures describe
the controlled validation workloads, not total system memory or a zero-swap promise.

The package suite, storage and finalization regressions, and native app build
checks passed. No new hardware qualification, installation or tape operation was
performed. Existing alpha limitations remain. In particular, cancelling the
receive task can suppress intermediate verification progress even though export
continues and the completed report is delivered.

Project: https://github.com/rewinddv/rewindDV
Testing and releases: https://github.com/rewinddv/rewindDV-LAB
Contact: info@rewinddv.com
