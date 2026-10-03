# Whole-tape cancellation accounting

The automation outcome and later cleanup evidence are separate. A cancelled job
remains `interrupted`; its `receivedFrames`, `manualStopRequired` and `entries`
are historical automation snapshots. These fields must not be used as the final
capture count or the current STOP resolution.

`WholeTapeJob.currentSummary` combines that history with optional `accounting`.
`WholeTapeJobJournal.readSummary(from:)` validates/replays persisted checkpoints;
the app's final interrupted-job status and the offline report use this same reader.
The existing UI and automation status export display the model's status string.

Read a job without changing it:

```
RewindDVInspect whole-tape-job /absolute/path/to/job/journal/JOB-UUID
```

The JSON includes the automation stage, explicitly historical values, current
accounting, and the same human-readable text used by the app. A syntactically torn
last checkpoint shows the validated earlier history with an explicit warning that
later accounting is unknown. Chain/identity/semantic corruption still fails closed.
Strict `recover` remains available for callers requiring an entirely valid chain.
No reader modifies files, migrates old captures, resumes work or sends commands.

## Evidence and durability

Version-1 automation checkpoints remain readable. Version-2 checkpoints carry one
accounting update and retain the same predecessor-hash chain. Existing checkpoint
bytes are never overwritten. Accounting updates bind the job UUID, full route and
one capture/session token with its job-relative directory. Replacing any identity
is rejected. Capture binding precedes final accounting; old jobs without it stay
explicitly incomplete and are not automatically upgraded.

STOP requested, accepted, two fresh device observations, and explicit operator
physical-STOP confirmation remain distinct receipt-backed observations. An accepted
command does not prove a stopped mechanism. These records consume the existing
control owner's results and never change live lockout or quit/transport authority.

Only the final verifier and matching saved report supply verified DV-frame counts
or HDV transport-packet/byte counts. Preview progress is historical. Missing/failed
verification has no invented final count; zero complete DV frames is not a blank-tape
claim. STOP proof, reception closure and saved-byte verification remain independent.
Continuity/loss warnings and terminal partial frames are retained in the original
verification report, copied as evidence into the job receipts, and summarized as
requiring review. No files are inserted into a sealed capture for reconciliation.

Equivalent checkpoint updates are no-ops; STOP evidence classes are bounded and
verified counts cannot regress or be replaced by conflicting final results. A failed
write poisons the writer and is surfaced in the app, including supervised recovery.
In-memory durable state advances only after persistence succeeds. Preserved capture
data is not discarded when summary persistence fails.

## Scope and validation

The deterministic app harness uses the real WholeTapeCaptureModel/journal with fake
bridge/receive dependencies; it never opens the installed driver. The initial six
frames → cancellation → later STOP → 1,899 verified frames sequence failed on the
original implementation. The corrected harness checks historical values, reopened
summary/UI agreement, zero/alternate counts, failed/missing verification, HDV,
pre-capture cancellation with a prior verifier present, and summary write failures.
Package tests additionally cover identity mismatch, ordering/duplicate delivery,
physical-vs-device STOP provenance, legacy records, torn tails and monotonicity.

Native GUI execution of a stopped whole-tape job remains a separate physical retest:
the driver-disabled app has no synthetic deck that can enter that UI state. Model
and report checks do not claim visible layout, real deck motion, or human A/V quality.
