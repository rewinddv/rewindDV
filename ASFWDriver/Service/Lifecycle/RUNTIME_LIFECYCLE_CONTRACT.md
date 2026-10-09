# ASFW Runtime Lifecycle Contract

## Purpose

This document is the authority for the ASFWDriver root runtime lifecycle.
Implementation code may refine resource details, but it must not introduce a
second state machine, teardown path, or hardware-legality authority.


## Ownership

| Concern | Sole authority | Notes |
|---|---|---|
| DriverKit service incarnation | `IOService` / I/O Registry | `Start`, `Stop`, `Terminate`, provider and child lifetime |
| ASFW root runtime state | `ControllerStateMachine` | All admission decisions derive from this state |
| Runtime transition and teardown ordering | `RuntimeLifecycleCoordinator` | The only entry point for start, stop, suspend, revoke, failed start, and wake rebuild |
| Local OHCI MMIO legality | `HardwareAccessGate` | No MMIO outside an admitted batch scope |
| FireWire bus generation | `GenerationTracker` | Authoritative generation from controller/Self-ID flow |
| Remote device/route validity | `DeviceRegistry` | Issues and validates `DeviceRouteToken` values |
| Backend logical operation | Owning backend | Operation serial, exactly-once completion, rollback, restart |

## Legal state graph

```text
Stopped -> Starting -> Running -> Quiescing -> Stopped
               |          |              `-> Suspended -> Starting
               `-> Failed -> Quiescing

Starting | Running | Failed | Quiescing | Suspended -> Revoked -> Stopped
```

The following transitions are legal:

- `Stopped -> Starting`
- `Starting -> Running`
- `Starting -> Failed`
- `Starting -> Revoked`
- `Running -> Quiescing`
- `Running -> Revoked`
- `Failed -> Quiescing`
- `Failed -> Revoked`
- `Quiescing -> Stopped`
- `Quiescing -> Suspended`
- `Quiescing -> Revoked`
- `Suspended -> Starting`, `Quiescing`, or `Revoked`
- `Revoked -> Stopped`

A request for the current state is idempotent and does not create a new
transition record. Every other transition is rejected without changing state.

`Revoked` dominates all live-state teardown. If provider removal races a
planned quiesce, the coordinator transitions `Quiescing -> Revoked` and skips
every remaining hardware cleanup step.

`Reset()` is reserved for construction/test reuse when no runtime resources are
live. Runtime code must reach `Stopped` through legal transitions.

## Admission rules

- Only `Running` admits new normal control, async, isoch, discovery, or backend work.
- `Starting` admits only coordinator-owned bring-up work.
- `Quiescing`, `Suspended`, `Revoked`, `Failed`, and `Stopped` reject new work.
- Resource booleans may describe allocation state, but they must not override
  or compete with `ControllerStateMachine` for admission decisions.

## Single coordinator rule

All of these DriverKit paths delegate to `RuntimeLifecycleCoordinator`:

- driver `Start` / runtime start;
- driver `Stop`;
- power suspend and resume;
- provider termination notification;
- failed-start cleanup;
- wake verification and rebuild.

Duplicate stop, revoke, or failed-start requests are idempotent coordinator
requests. They must not execute independent teardown bodies.

`ASFWDriver::QuiesceRuntime`, `DriverWiring::CleanupStartFailure`, and
`ControllerCore::Stop` must not remain competing hardware teardown authorities
after the root cutover.

## Quiesce phase order

### Common admission closure

1. Request the legal state transition.
2. Close all new producer admission.
3. Invalidate remote route tokens.
4. Reject new backend operations.

### Planned stop

1. Enter `Quiescing` from `Running`.
2. Close producers.
3. Retire queued callback epochs and positively stop receive/isoch owners.
4. Close async submission and posted work, then stop control-plane producers.
5. Request terminal cancellation of every native callback source and await all
   acknowledgements while retaining the runtime, source/action references,
   queues, service and provider. No runtime restart is admitted during the drain.
6. Positively stop AT/AR DMA and clear/verify its command ownership, preserving
   the existing `AsyncSubsystem::Stop` release gate.
7. After producer shutdown and async cancellation, require no uncertain wire
   response. Otherwise quarantine this service and preserve its allocator;
   local DMA retirement does not authorize erasing that fence.
8. Perform final register cleanup, revoke/drain MMIO and close the provider.
9. Release software resources and enter `Stopped`; only then acknowledge Stop
   through its superclass implementation.

The exact context-specific point at which controller interrupts are masked is
validated against the local OHCI and Apple reference implementations; generic
lifecycle code must not assume DMA can always be stopped without interrupts.
The current Foundation AT/AR stop implementation polls hardware RUN/ACTIVE and
verifies CommandPtr retirement (`ATContextBase::Stop`/`WaitForQuiesce`,
`ContextManager::teardown`). It does not require dispatch callbacks to complete
that proof. This specific property permits step 6 after the native barrier;
changing the stop implementation requires reassessing that ordering.

### Suspend

Use the planned-stop ordering while the provider is still valid, but preserve
only the DriverKit objects explicitly required for a safe resume. Finish in
`Suspended`, never in an independent `runtimeSuspended` authority.

### Provider revocation

1. Latch MMIO rejection, then drain any synchronous admitted access scope.
2. Enter `Revoked` and close producer admission through the coordinator.
3. Require receive retirement before entering native cancellation.
4. Cancel and drain DriverKit callback sources, preserving acknowledgments.
5. Require async/DMA retirement and wire certainty before resource release.
6. Tear down software state without final register cleanup only when every
   release gate succeeds; otherwise retain the complete quarantined graph.
7. Release provider resources and enter `Stopped` only after those gates.

No operation after step 1 may assume that OHCI registers respond. The software
revocation flag proves neither physical removal nor DMA isolation. Existing
initialized receive/async contexts normally cannot establish retirement after
access closes, so terminal containment can retain them indefinitely.

### Terminal service Stop

Native `IOService::Stop` can arrive before provider notification on Default. It
latches/drains MMIO before requesting the revoked coordinator path, including
when the lifecycle queue is unavailable. Ordinary capture STOP, AV/C tape STOP,
client disconnect, suspend and failed-start cleanup retain their own paths.

`CompleteServiceStop` owns one Default-serialized superclass completion receipt,
shared by the empty-resource path and native-drain finalizer. Service and original
provider references survive the superclass call; duplicate requests return the
recorded result and cannot complete it twice. Terminal completion forbids runtime
restart. This receipt is not another runtime state or evidence of DMA retirement.
Clean live unload and physical removal remain unqualified.

Receive Stop retains its nonblocking packet-consumption path and uses a 100 ms
monotonic uptime budget only when its control caller contends for the receive
gate. Scheduler delay/suspension can extend wall-clock return; it is not a hard
real-time deadline. Failure leaves the foreign gate, binding, descriptors and
context state untouched. An authorized Foundation session Stop records permanent
quarantine, closes outer admission outside its locks, and requests service
containment even if the receive context still reports Running. Late owner
completion or local context retirement cannot erase that session failure or
authorize resource cleanup/restart. Quiesced Start/binding and inactive Foundation
transmit paths are unchanged.

### Start failure

1. Enter `Failed` from `Starting`.
2. Enter `Quiescing` through the coordinator.
3. Cancel/drain only resources successfully created so far.
4. If hardware is still valid, perform the applicable bounded cleanup.
5. Revoke MMIO and release the provider.
6. Enter `Stopped`.

There is no independent `CleanupStartFailure` teardown implementation.

The coordinator owns a private `StartStage` resource ledger (`None`,
`DependenciesReady`, `QueueReady`, `ProviderOpened`, `InterruptSourceReady`,
`AsyncReady`, `ControllerReady`, `Running`). It records completed bring-up
stages solely to bound failed-start unwind work; it is not a second lifecycle
state machine and cannot admit work.

### Wake rebuild

1. Begin in `Suspended`.
2. Enter `Starting`.
3. Reopen the provider and MMIO gate only after attach succeeds.
4. Rebuild the same runtime pipeline used for cold start.
5. Enter `Running` on success.
6. On failure, use the normal `Starting -> Failed -> Quiescing -> Stopped` path.

These rebuild steps require the prior runtime to have passed the uncertain-wire
gate. Cancellation during teardown can itself raise the fence, so the root
checks it after `AsyncSubsystem::Stop` and before releasing or replacing the
runtime. `ServiceContext::Reset` repeats the check after its final AVC shutdown.
An uncertain service cannot automatically suspend/wake into a fresh allocator,
self-heal, or restart. This intentionally sacrifices availability when an issued
request's remote completion cannot be attributed safely.

No software operation currently proves that this wire fence may reopen. A local
OHCI soft reset, fresh Self-ID, native callback drain, or DMA idle proof does not
establish the absence of a later remote FCP response. Creating another service
or process is not such a proof either; external recovery requires separate
hardware/protocol qualification. Controller-specific FIFO behavior must not be
generalized to unsupported controllers or to remote response retirement.

## DriverKit completion barriers

Cancellation is not complete merely because cancellation was requested. Final
teardown uses the terminal `Cancel` completion of interrupt, timer, and
notification sources. The source and its OSAction retain their final references
until that completion executes, after all pending handlers return; only then are
they released.

Suspend preserves interrupt registration using the observed
`SetEnableWithCompletion(false, ...)` barrier. It cancels the other runtime
sources. The old interrupt action remains held by its source until a fresh
action is installed on wake; it is never used to enter the replacement runtime.
Lifecycle admission closes before requests are issued, and action identity is
checked at native handler entry.

The coordinator never blocks a dispatch queue waiting for its own completion
work. A separate reentrant supervisor queue uses `SleepWithDeadline`, which
releases that queue while asleep; cancellation completions wake it by dispatching
onto that same queue. The supervisor posts finalization back to Default.

`NativeCallbackDrain` is a fixed-capacity ownership ledger, not another runtime
state authority. Both a successful request return and an observed completion
are required before its source/action references can be released. Normal
retirement has six sources and one one-second supervision window. A stop or
revocation during a suspend drain can require a second window to terminally
cancel the disabled interrupt registration. Failed requests, missed deadlines,
queue setup failures, or an active shared-timer arm RPC latch permanent
quarantine. The entire borrowed graph remains owned, no superclass Stop or
unsafe power acknowledgement is sent, and late completion cannot authorize a
restart. Successful later native completions may release their own references;
they do not release the quarantined runtime.

If a LOCALONLY caller cannot obtain Default, it only latches atomic quarantine
and retains the service. It does not inspect or mutate the borrowed graph on the
caller queue. Root runtime getters and native work handlers reject quarantine.
Provider termination notification remains admitted to revoke hardware access.

## MMIO rule

No subsystem calls `HardwareInterface::Detach()`.

Only `RuntimeLifecycleCoordinator` may revoke the access gate and close the PCI
provider. Hardware users operate through one admitted `HardwareAccessScope` per
logical batch, not one lock/lease per register operation.

Audio real-time code never performs MMIO and never waits for lifecycle locks. It
consumes published immutable snapshots or atomic timing anchors.

`HardwareAccessScope` is move-only, stack-bound, and synchronous: it must not
be stored, captured by a callback, cross a dispatch boundary, or be held while
waiting. This prevents `RevokeAndDrain()` from waiting on a continuation that
cannot run until revocation has completed.

Route-token validation through `DeviceRegistry` is control-plane work only.
The audio packet path consumes an already-published atomic epoch or immutable
stream binding and never takes the registry lock.

Once `DeviceRegistry` becomes cross-queue synchronized, it exposes snapshots
or controlled access rather than unlocked mutable `DeviceRecord*` values. It
never calls listeners, backend code, nub publication, cancellation, or protocol
shutdown while holding its lock.

## Strict cutover rule

A phase is mergeable only when the superseded authority is deleted in the same
change set. The final branch must not contain both:

- old and new root teardown paths;
- direct and scope-gated public MMIO APIs;
- duplicate runtime admission flags;
- route tokens plus equivalent ad-hoc route-validity authorities.


## Escaping native completion ownership

Every escaping DriverKit/native completion block must retain or reference its
state through a lifetime mechanism independent of mutable caller-local owner
variables. Keeping the underlying object alive does not keep a caller's
`shared_ptr` variable alive or unchanged. C++ Blocks preserve reference captures:
copying a block that uses a `const shared_ptr&` parameter still borrows that
parameter's referent. Native source cancellation and disable adapters therefore
copy the ledger and ticket into value variables before capturing them.

Callback admission closes before cancellation. Cancellation requested and its
successful return are distinct from an in-flight borrower returning and the
native completion being observed. The ledger requires both accepted request and
completion, publishes terminal only after the source/action release callback,
and releases each entry once despite duplicate/racing completion. Source/action
owners, root service/provider retain, and the runtime graph remain valid across
that barrier. Only all-terminal without quarantine admits graph retirement;
DMA/CommandPtr retirement and deferred-borrower gates remain additional conditions.

A failed cancellation or missing completion quarantines the owner. A late
completion can release its proven-terminal source but cannot erase quarantine or
permit restart. Weak lookup in the supervisor notifier only requests a wake; it
is not terminal proof. A null check that skips required completion is not a fix.
Service/process disappearance and app quit are not evidence of native retirement.

Successful lifecycle telemetry reports sealed registered/terminal source counts
and references transferred into ledger release entries (`ledger_owner_refs`).
Those are not global OSObject retain counts, provider/service retain counts, or
all object references in the process. The count falls only after the release
callback returns. Disable-for-suspend transfers zero source/action references
because registration survives. The terminal log additionally reports whether
controller/hardware/async/scanner/AVC graph roots are empty after guarded Reset.
Offline tests cover caller reset and scope exit, in-flight borrowers, missing or
failed cancellation, duplicate/inline/late completion, provider delivery aliases,
10,000 request/completion races and 5,000 successful ownership-release cycles.
Physical qualification must correlate these logs with exact candidate/service
identity and native OS state; host protocol fixtures do not qualify DriverKit.
