# RewindDV Foundation driver policy

This layer is active only when the driver target defines
`REWINDDV_FOUNDATION`. It closes the inherited ASFireWire user-client surface
before handler dispatch, then admits read-only identity, health, and log queries
plus three baseline typed transport commands:

- PLAY: `00 20 C3 75`
- STOP: `00 20 C4 60`
- REWIND: `00 20 C4 65`

FAST FORWARD (`00 20 C4 75`) is a fourth typed command, but it is not a
baseline permission and remains rejected until the same driver lifetime has
received a positive exact-route Specific Inquiry for `02 20 C4 75`.

Build160 adds the separately reviewed receive-only interface described in
`FoundationReceiveWire.hpp`: start 68, stop 69, status 70, acknowledgement 71,
read-only mapping type 2. Legacy filtered receive 50/51 and mapping 1 remain
closed. Capability bit 9 identifies raw receive; archival-unavailable bit 8
remains set. See `../Qualification/BUILD160-LIVE-RECEIVE.md` for qualification
and the supervised hardware boundary.

Receive start binds an exact route and discovers an already active broadcast
or P2P oPCR channel through fixed reads. It never guesses a channel, changes
PCR/IRM connections, starts the tape, transmits isochronous data, or replays a
deck command. A session retains its ring through terminal status until its
owner closes, allowing complete final evidence draining. Unknown quiescence
quarantines the driver graph rather than destroying DMA-visible resources.

The app copies raw records and synchronizes local storage before interpreting
CIP/DIF or acknowledging the ring. Preview drops under UI backpressure are
separate from recorded raw-ring losses; hardware continuity remains unknown.
This is local diagnostic receive preservation, not finalized archival capture.

Managed receive reservation now applies a validated Self-ID slowest-PHY path
ceiling in addition to the existing oMPR, oPCR, stored discovery policy, and
S400 limits. The topology decision is copied at exact-route receive admission;
generation, local-node, and reciprocal-link evidence must agree. Successfully
learned speed may clamp that ceiling downward but can never raise it. The DV
bandwidth formula is unchanged. FCP and IRM control traffic remain explicitly
S100.

Allocation diagnostics preserve the frozen numeric `AllocationStatus` values
while separately identifying channel occupied, insufficient bandwidth,
confirmed CAS contention exhaustion, route invalidation, transport failure or
uncertainty, and rollback failure. Fixed 32-byte internal evidence marks every
observed value with validity bits and records primary, cleanup, compare, and
terminal stages. Receive emits bounded transition-only `alloc-input`,
`alloc-plan`, `alloc-result`, and `alloc-cas` LogRing records; broadcast and
existing P2P observation is explicitly `not_allocated_here`. These records are
queryable through the existing log selectors and unified-log support bundle,
but are not automatically durable in each capture flight. Receive wire version
1 and its fixed status/ring sizes are unchanged.

The typed, read-only Device Inspector is additive and does not change the
24-byte Foundation capability reply. Selector 72 returns a separate 40-byte
inspector capability record; selector 73 accepts one exact 72-byte request and
returns a request ID; selector 74 polls with request/operation/attempt IDs and
returns one immutable 1,284-byte result. The query allowlist is UNIT INFO,
SUBUNIT INFO page 0 through 7, unit PLUG INFO subfunction 00, tape MEDIUM INFO,
tape transport state, absolute track number, and TIME CODE. The new TIME CODE
kind is numeric value 7 and its driver-owned STATUS frame is exactly:

- `01 20 51 71 FF FF FF FF`

The inventory frames remain:

- `01 FF 30 FF FF FF FF FF`
- `01 FF 31 (page << 4 | 07) FF FF FF FF`
- `01 FF 02 00 FF FF FF FF`

TIME CODE accepts only an exact eight-byte correlated response. A stable `0C`
response retains raw bytes in frame, second, minute, hour order. Frame `7F`
means unsupported and sets no decoded field; other stable values must be
packed BCD. The fixed decoded wire remains unchanged. TIME CODE is excluded
while receive or control is active and shares the single inspector owner. It
uses a time-code-only 250 ms display-budget response deadline, zero automatic
retry, zero INTERIM allowance, and non-queuing FCP admission. The ordinary FCP
and inspector deadlines are unchanged. This 250 ms policy is not a statement
that a compliant device must respond within 250 ms: a slower deck simply makes
optional telemetry unavailable. No optional query is queued ahead of STOP, but
an already-issued read-only request can occupy the single FCP transport until
its response or deadline, so zero added STOP latency is not claimed.

Requests carry the same full driver-instance and route token used by typed deck
control. Submission uses FCP's exact expected-route comparison, never-retry
policy, non-queuing busy rejection, and a zero-INTERIM budget. Only a correlated
eight-byte IMPLEMENTED/STABLE (`0C`) response with the exact unit address,
opcode, and query-specific echo is a protocol success. NOT IMPLEMENTED,
REJECTED, ACCEPTED (invalid for STATUS), IN TRANSITION (invalid for these
queries), CHANGED, timeout, and mismatch remain distinct outcomes. Transport
`kOk` alone is not an inspector success.

Inspector evidence retains at most two owned 512-byte raw response events,
preserving the first event and the latest terminal event with a saturating
overflow count. Result storage is capped at 128 without eviction; admitted
attempt IDs use the existing 4,096-entry lifetime no-replay ledger. A strict
decoded record recognizes only non-extended SUBUNIT entries (unique types,
maximum ID 0 through 4, no entries after `FF`) and unit PLUG counts 0 through
31. Unsupported extended or malformed stable data remains available raw but
does not set the decoded-valid bit.

The process-wide activity gate is reader/exclusive: receive and deck control
retain their existing ability to overlap, so STOP remains available during live
receive. Inspector is exclusive with both. Receive retains inspector exclusion
through terminal ring snapshot/acknowledgement drain and releases it only when
the owner releases the session; quarantine retains exclusion. Inspector and
deck tokens release after FCP completion and the synchronous submission
publication barrier, independent of later evidence consumption. Internal AV/C
discovery is not gated; its pending FCP traffic causes the inspector's
non-queuing submission to terminate busy without reaching the bus.

The transport-capability catalog is additive and leaves selector 64's 24-byte
reply unchanged (`permittedDeckCommands == 0x7`). Selector 75 returns a fixed
176-byte catalog containing exactly PLAY, STOP, REWIND, FAST FORWARD, FORWARD
PICTURE SEARCH, and REVERSE PICTURE SEARCH; every
entry contains a driver-owned four-byte Specific Inquiry and corresponding
four-byte CONTROL frame. Selector 76 accepts one fixed 72-byte request carrying
only a catalog command ID and the full route token; it never accepts caller
frames, opcodes, operands, or ctypes. Selector 77 polls with the immutable
request/operation/attempt IDs and returns one 1,264-byte evidence record.

The inquiry frames are identical to their controls except for ctype `02`, as
required by AV/C General 4.0 section 9.3. A response must be exactly four bytes,
must echo the tape-subunit address, opcode, and operand, and may establish only
IMPLEMENTED (`0C`) or NOT IMPLEMENTED (`08`). Any `09`, `0A`, `0F`, other
response code, wrong route/source/generation, wrong operand, or wrong length is
retained but cannot authorize control. In particular, `0C` means the exact
control form is implemented; it does not predict whether a later CONTROL will
be accepted or prove tape motion.

Capability probes share inspector's exclusive activity token, use exact-route
FCP binding, reject rather than queue behind any FCP request, allow no INTERIM,
and set retry class to never. Receive and deck control retain their prior
ability to overlap; therefore STOP remains available during live receive. The
probe result is published only after the terminal callback and synchronous
`SubmitCommand` observers have closed. Two owned raw response events, 128
results, and 4,096 lifetime attempt IDs are hard caps with no implicit eviction
or replay.

Conditional command authorization is driver-global rather than user-client-owned,
so a probe client may close before a separate control client opens. FAST FORWARD
retains WIND `00 20 C4 75`; picture search uses the AV/C Tape Recorder/Player
PLAY fastest operands, forward/CUE `00 20 C3 3F` and reverse/REVIEW
`00 20 C3 4F`. An admitted conditional-command reprobe revokes only that
command's prior proof before submission. Only a fully published, zero-retry,
exact-route `0C` result installs a replacement proof. PLAY, STOP, and REWIND
remain the only baseline commands advertised by selector 64.
The proof key includes driver-instance ID, GUID, device incarnation, route
epoch, generation, and node. Deck admission requires the exact key and
`FCPTransport` compares the same route again immediately before bus I/O;
restart/reset/rebind and every failed, unsupported, mismatched, timed-out, or
otherwise uncertain reprobe therefore fail closed with no automatic replay.

At button admission, read-only selector 67 returns a 48-byte snapshot containing
the driver-instance identity and the registry's full route token for one GUID.
Each 72-byte typed request carries non-zero operation/attempt identities plus
that driver instance, GUID, device incarnation, route epoch, generation, and
node. `FCPTransport` requires the token to equal `CurrentRoute` immediately
before `busOps`; a reset/rebind mismatch completes with zero write and no replay.
The driver-instance value is allocated for each new `AVCDiscovery` runtime, so
a stopped/recreated driver graph cannot accept an authorization from its prior
incarnation; retained prior result records are not cleared or overwritten.
The driver accepts one mutating request at a time across clients,
consumes every admitted attempt ID even when submission fails, and explicitly
submits FCP with the never-retry policy. The consumed-attempt ledger is bounded
at 4,096 entries; saturation refuses every later command for that driver
lifetime. Entries are never evicted because eviction would re-enable replay.
Raw FCP, raw CSR transactions, bus reset, IRM/CMP tests, audio control,
storage/SBP-2, isochronous transmit, and the inherited filtered DV capture path
are unavailable through the public Foundation user client. Foundation runtime
wiring also omits automatic audio owners and SBP-2 address spaces, sessions,
login bridges, and nub publication. Selector 16 is the identity source;
selectors 22-24 are closed because their inherited AV/C probe caches are mutable.
In Foundation builds selector 16 serializes locked `DeviceRegistry::SnapshotAll`
value copies and omits mutable unit records (`unitCount == 0`).

The command-specific FCP response classifier requires the retained four-byte
Sony shape and exact subunit, opcode, and operand. It records raw mismatches and
INTERIM events, distinguishes terminal ACCEPTED (`09`), REJECTED (`0A`), NOT
IMPLEMENTED (`08`), and other terminal response types, and prevents a late STOP
response from completing REWIND (both use opcode `C4`). A Foundation command is
atomically rejected if the FCP transport already has pending or queued work; it
is never queued behind discovery traffic. One INTERIM is allowed to extend the
response deadline; a second terminates Timeout without retry, so a target cannot
hold the global mutation gate indefinitely.

The capability result reports archival capture as unavailable. The inherited
`DVCaptureSink`/shared-ring path remains source history and is not represented
as a raw-preserving archive interface. Discovery's internal bus/FCP operations
are not affected by the external selector gate.

The 2,324-byte control result distinguishes admission, acceptance by the public
FCP transport, response receipt, exact correlation, terminal classification,
and completion. Up to four owned raw 512-byte response events are retained;
overflow saturates its counter and preserves the first three events plus the
latest event, reserving terminal truth. Result storage is bounded to 256 and
refuses admission at saturation rather than evicting evidence. Polling requires
the immutable request, operation, and attempt IDs and consumes only after output
allocation succeeds, so closing a user client cannot orphan/cancel or authorize
another client through a reused pointer.

Result route fields come from the exact write attempt inside `FCPTransport` after its
registry token is validated: FCP attempt ID, GUID, device incarnation, route
epoch, generation, node ID, route-bind time, and public async-handle return time.
`routeState` is tri-state: unknown, current when bound for submission, or
invalidated by an observed bus reset. Transport removal/failure is not promoted
to positive route-current or route-invalidated evidence. The `prepared` and
`outbound write submitted` stage bits remain reserved and clear: a valid async
handle proves neither descriptor publication nor wire transmission. Transport
`kOk` means correlated terminal delivery, and response byte `09` means AV/C
acceptance only; neither proves physical tape motion.

The local request wiring admits both quadlet and block writes. For a quadlet
write, `LocalRequestDispatch` retains two deliberately distinct views: a
host-order numeric scalar for CSR consumers and the byte-exact four-byte data
field for framed protocols. `FCPInboundLocalHandler` passes the byte-exact view
to `FCPResponseRouter`; it never reconstructs an FCP frame from the scalar. The
retained Sony lab AR record contains canonical `09 20 C3 75` at Q3, while scalar
reconstruction produced the observed reversed `75 C3 20 09`. The strict response
classifier remains unchanged and rejects that reversed form. The full-GUID ABI
fixture separately confirms that the driver wire record and Swift parser agree.

## Native source and test inputs

Add `Foundation/DriverPolicy/FoundationDriverPolicy.cpp` to the DriverKit
target, plus `Foundation/DriverPolicy/FoundationReceiveService.cpp` for Build160.
`FoundationActivityGate.hpp` is header-only and requires no target source entry.
Connected behavior also uses the target's existing
`FCPTransport.cpp`, `AVCDiscovery.cpp`, `DeviceRegistry.cpp`,
`DeviceDiscoveryHandler.cpp`, `DriverContext.cpp`, `ASFWDriverUserClient.cpp`,
and `AVCHandler.cpp`; no additional generated source or third-party test
dependency is introduced.

The tests are standalone Apple Clang programs with `assert`; they do not use
CMake or GoogleTest:

```sh
xcrun --sdk macosx clang++ -std=c++23 -Wall -Wextra -Werror \
  Foundation/DriverPolicy/FoundationDriverPolicy.cpp \
  Foundation/DriverPolicy/Tests/FoundationDriverPolicyTests.cpp \
  -o /tmp/rewinddv-foundation-driver-policy-tests
/tmp/rewinddv-foundation-driver-policy-tests

xcrun --sdk macosx clang++ -std=c++23 -Wall -Wextra -Werror \
  Foundation/DriverPolicy/Tests/FoundationWireABITests.cpp \
  -o /tmp/rewinddv-foundation-wire-abi-tests
/tmp/rewinddv-foundation-wire-abi-tests

xcrun --sdk macosx clang++ -std=c++23 -DASFW_HOST_TEST \
  -I. -IASFWDriver -IASFWDriver/Testing -Itests/mocks -Itests/support \
  -Idocs -IAppleHeaders -Wall -Wextra -Werror \
  -Wno-unused-parameter -Wno-missing-field-initializers \
  -Wno-character-conversion -Wno-deprecated-copy \
  Foundation/DriverPolicy/FoundationDriverPolicy.cpp \
  Foundation/DriverPolicy/Tests/FoundationFCPTransportTests.cpp \
  ASFWDriver/Protocols/AVC/FCPTransport.cpp \
  ASFWDriver/Discovery/DeviceRegistry.cpp \
  ASFWDriver/Discovery/FWDevice.cpp ASFWDriver/Discovery/FWUnit.cpp \
  tests/support/LoggingStubs.cpp ASFWDriver/Logging/LogRing.cpp \
  -o /tmp/rewinddv-foundation-fcp-tests
/tmp/rewinddv-foundation-fcp-tests

zsh Foundation/Tools/verify-fcp-response-ordering.zsh /private/tmp/rewinddv-fcp-ordering

sh Foundation/DriverPolicy/Tests/run-receive-lifecycle-tests.sh
ruby Foundation/DriverPolicy/Tests/FoundationInspectorObserverSourceTests.rb
ruby Foundation/DriverPolicy/Tests/FoundationTransportCapabilitySourceTests.rb
```

These tests prove source-level admission/ABI plus connected host-side FCP queue,
classifier, route-evidence, response-ordering, bounded-INTERIM, shutdown, and
inspector exact frames/route rejection/wrong-source evidence, exact transport
Specific Inquiry frames, conditional FAST FORWARD authorization, reader-exclusive
activity admission, retained receive-drain exclusion, and the retained physical
write-quadlet byte pipeline through the production FCP
local handler. They do not prove the corrected DriverKit binary completes FCP
on the Sony, deck motion, or hardware qualification.

The connected FCP pipeline runner links the production response descriptor builder
and captures its final hardware-submission seam. A required write response must
be submitted before an FCP observer, terminal completion, or FIFO successor runs.
If submission fails, the raw response event remains observable and the pending
command retains its existing bounded deadline and no-replay policy. The three
Foundation observers only retain evidence; arbitrary observer callbacks that
cancel or submit work are outside the failed-submission guarantee. Submission
is not proof of on-wire acknowledgement or physical deck qualification.
