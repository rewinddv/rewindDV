# Alpha 0.0.78 processing-memory hotfix

Offline validation on macOS 27.0.1 with Xcode 27.0, optimized native Swift builds.
Driver Build183 implementation, shared inputs, entitlements and packaged signed
extension are unchanged. No new hardware qualification is claimed.

## Cause and correction

DV/HDV reconstruction already streams its inputs, but Foundation read and
serialization temporaries could outlive each iteration of a long synchronous
background task. The retained working buffer alone did not bound physical
footprint. The fix adds synchronous autorelease scopes around each record's
read/assembly/metadata/write work, journal chunks and their JSON lines, and each
independent reread chunk. RecordReader refills also drain read temporaries while
retaining their owned Data. The bounded standalone magic/report reader has its
own scope. No scope crosses an await or thread transition.

Hash state, counters, journal terminal evidence, the current read buffer and
assembler state remain explicitly owned. Native output, raw input, journal and
frame/packet manifests are still independently reread. Resumed DV publication
uses the same corrected hash helper. Shared verified-copy publication uses
bounded POSIX reads and required no change. Exclusive publication, synchronization,
completion-marker ordering, loss accounting and unknown hardware continuity are
unchanged. App progress remains compact and uses its existing eight-value stream.

## Measurements

Physical footprint is distinct from resident memory. The harness records both
at 100 ms intervals and phase boundaries using task_vm_info, streaming observations
to disk with constant measurement storage. Initial scale runs report sampled
peaks; the final app harness also captures the kernel footprint high-water mark.
Post-job values are immediate completion observations, without trimming,
forced collection or restarting between jobs.

| Raw input | Path | Peak footprint MiB | Post-job MiB | Seconds |
| --- | --- | ---: | ---: | ---: |
| 256 MiB | Original production exporter | 794.49 | 794.49 | 1.10 |
| 256 MiB | Corrected production exporter | 5.94 | 5.94 | 1.13 |
| 1 GiB | Corrected exporter, ExFAT publication | 9.13 | 9.13 | 5.79 |
| 4 GiB | Corrected exporter, ExFAT publication | 9.19 | 9.19 | 25.86 |
| 3 × 256 MiB | Real app finalization, normal terminal status | 16.27 | 12.92 / 16.22 / 16.27 | 9.79 total |
| 3 × 256 MiB | Real app finalization, cancelled receive-task stop | 14.30 | 13.22 / 13.28 / 14.30 | 4.62 total |

Synthetic fixtures complete their last frame, so actual input slightly exceeds
requested size. They are generated one frame at a time with deterministic
pseudorandom video payloads, not sparse/zero-filled input. All runs include
reconstruction, metadata, every reread and publication. Timing is one run per
condition, not a throughput benchmark; storage differs between the small and
large cases.

The 256 MiB original/fixed comparison produced identical bytes for raw evidence,
journal, native DV, frame manifest and verification report. Native DV SHA-256:
`aae220109fff96ea96f249deda3274720af808af86ecaf11756775f416a33a03`.
Frame manifest SHA-256:
`8c3294a6ab2c16664c2c30c34c1b65b14c3b4e040c369302a75c8e5828437b90`.
No field was normalized or omitted.

The observed plateau is consistent with bounded buffers and allocator high-water
retention, not a capture-sized live collection. The earlier allocation inspection
also distinguished deferred temporary cleanup from allocator retention; neither
all resident pages nor all swap can be classified as permanent live leaks.

All runs retained normal system memory pressure. System swap was observed but
is shared with other applications; these results do not promise zero system swap.
No guardrail was breached. Initial baseline cap was 1.5 GiB; corrected exporter
runs used 128–256 MiB and app runs 256 MiB, all below the 2 GiB safety maximum.
The harness also stops its disposable process after 30 minutes, on non-normal
pressure, failed pressure/disk inspection, or less than 8 GiB scratch free space.
A practical regression ceiling is 64 MiB for the isolated exporter and 128 MiB
for the linked app harness, allowing platform variance above measured peaks.
Unexplained growth across sizes/jobs must be investigated, not accommodated by
raising those ceilings.

## Correctness and limits

Focused exporter/publication checks and the complete package suite passed:
430 Swift Testing tests and 14 XCTest tests. Cases cover empty/exact EOF, partial
chunks, truncated records/journal lines, invalid header bounds, legacy and resumed
publication, publication failures, and changed inputs/outputs between passes.
HDV cancellation is tested after positive reconstruction progress, retaining
nonempty partial output and original raw bytes without a completion marker.
Storage resilience and all 15 manual-stop-tail scenarios passed. Native Debug
and Release app-only compile checks passed. Final delivery additionally requires
a fresh-source Release build of the committed revision and sealed-artifact checks.

The app harness links the real LiveMonitorModel, task executor, progress stream
and completion state to a fake bridge, with audio muted and no production driver
client. Normal terminal completion delivered reconstruction, all reread phases,
publication and final completion; observed phase byte counts were monotonic.
The existing cancelled receive-task stop path suppresses intermediate AsyncStream
updates but still joins export and delivers its final result. Its memory results
are valid; it cannot provide intermediate phase attribution. That pre-existing
progress behavior is unchanged by this memory hotfix.

A bounded independent review found no production correctness defects. Its two
validation observations were addressed by adding normal-terminal progress
coverage and moving cancellation injection after partial HDV output exists.
These checks remain offline processing evidence, not capture/device qualification.

## Reproduction

Build `Foundation/Tools/run-post-capture-memory-regression.zsh` from the repository
root with an existing task-local output directory and the selected Xcode 27
toolchain. The script builds only. The executable accepts:

```
PostCaptureMemoryRegression generate NEW_LOG CEILING_MIB NEW_FLIGHT MIB
PostCaptureMemoryRegression export NEW_LOG CEILING_MIB DISPOSABLE_FLIGHT
PostCaptureMemoryRegression app NEW_LOG CEILING_MIB FLIGHT1 FLIGHT2 FLIGHT3
PostCaptureMemoryRegression app-stop NEW_LOG CEILING_MIB FLIGHT1 FLIGHT2 FLIGHT3
```

Use distinct new fixture/output directories; exporter destinations must not
already contain finalized outputs. Never run reconstruction against original
recordings. Obtain approval for removable-storage test destinations and budget
space for raw data, output and metadata. Keep larger fixtures off the internal
SSD. Preserve complete logs and exit statuses, including any failed guardrails.
