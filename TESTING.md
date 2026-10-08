# Offline verification

Run from the extracted source root with Xcode 27 selected. These checks do not
install an application, activate a driver or operate a deck.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
test_root=$(mktemp -d /private/tmp/rewinddv-tests.XXXXXX)
export TMPDIR="$test_root/tmp/"
export CLANG_MODULE_CACHE_PATH="$test_root/clang-cache"
export SWIFT_MODULECACHE_PATH="$test_root/swift-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
xcrun swift test --package-path Foundation \
  --scratch-path "$test_root/package" --cache-path "$test_root/cache" \
  --config-path "$test_root/config" --security-path "$test_root/security"
for name in admission boundary manual orchestration quit; do
  mkdir -p "$test_root/$name"
done
zsh Foundation/Tools/run-capture-admission-regression.zsh "$test_root/admission"
zsh Foundation/Tools/run-capture-admission-boundary-regression.zsh "$test_root/boundary"
zsh Foundation/Tools/run-manual-stop-tail-regression.zsh "$test_root/manual"
zsh Foundation/Tools/run-gentle-recovery-regression.zsh "$test_root/orchestration"
zsh Foundation/Tools/run-quit-supervision-regression.zsh "$test_root/quit"
xcrun swiftc -swift-version 6 -parse-as-library \
  Foundation/Tools/PlayCallbackBindingRegression.swift -o "$test_root/play-callback"
"$test_root/play-callback"
```

Run the complete package suite without skip/filter options. An already sandboxed
automation environment may add SwiftPM `--disable-sandbox` to avoid a nested
sandbox; this does not require changing system security. Record actual executed
test counts, failures and omissions rather than copying earlier totals.

The admission harness extracts production scheduling/guard code and substitutes
a fake bridge and controlled query completion/clock. The boundary harness compiles
the complete production receive-begin method with connection/filesystem shims.
The monitor and orchestration harnesses use synthetic ownership/STOP evidence.
The quit harness links production types but does not create the app or call its
bridge. The PLAY harness checks the real callback call-site binding and guard
matrix. These are offline tests, not device qualification.

Prior baseline failures reproduced the observer restart/admission race and
unowned cleanup after rejection. The corrected-source tests cover cancellation,
exactly-once submission, ownership exclusions, route changes, startup-budget
placement, retained STOP obligations and finalization. Existing host suites under
Foundation/DriverPolicy/Tests remain available with their documented prerequisites;
they are not silently included in the commands above.

Native UI rendering, physical query overlap, natural end-of-tape, active-capture
disconnect and extended hardware endurance need separate evidence. No private
recording or standards corpus is required by this package. The identifying XML
report is excluded; its importer coverage uses a first-party synthetic fixture.

## Current source and publication checks

For the receive/reset/FCP changes in the current source, also run:

```sh
sh Foundation/DriverPolicy/Tests/run-receive-lifecycle-tests.sh
zsh Foundation/Tools/verify-fcp-response-ordering.zsh "$test_root/fcp-ordering"
```

The OHCI hardening harness is
`Foundation/Tools/verify-ohci-hardening.zsh`; supply an existing GoogleTest source
checkout and an external output directory as its two arguments. This optional
host-test prerequisite is not an application/driver dependency. These harnesses
are offline; their success does not qualify physical reset/disconnect behavior.

`python3 -B tools/test_project_status.py` tests independent app, driver and release
identities. `python3 -B tools/project_status.py` verifies all manifested public
inputs and generated current-status blocks; add `--live` to verify the latest
GitHub download. Run `tools/test_release_candidate.py` and
`tools/test-publication-content.py` for release/provenance and disclosure regressions.


## Alpha 0.0.93 playback and automation

`OfflinePlaybackOpenRegression.swift` checks first-picture readiness, repeated
play/pause/stop, rapid seek convergence and close/reopen cancellation without
automatic full-file indexing. `OfflinePlaybackScrubRegression.swift` checks 120
rapid requests, selected-frame metadata and final-frame seeks using a finished
raw DV file of at least 30 seconds. They exercise the native playback model and
need a separately provided DV fixture; no private footage is distributed.
The complete package suite covers exact/estimated timeline and metadata rules.

Build the native CLI with `xcrun swift build --package-path Foundation --product
rewinddv` using the same external scratch/cache paths. With a running app, MCP
`initialize`, `tools/list`, `ping`, and read-only `status` validate the local
interface without operating tape. See [CLI/MCP](Foundation/CLIAndMCP.md) for
session-scoped sandbox path grants and attended hardware workflows. A build,
tool listing or offline pass does not qualify physical capture or recovery.

## Alpha 0.0.94 metadata and archive regressions

The full package suite includes IEC decoder/sequence/property witnesses, legacy
metadata schemas, epoch validation, mixed NTSC/PAL reviewed-range segment export,
empty-plan/empty-snapshot rejection, and unknown/damaged-region preservation.
Run the receive lifecycle script above for Driver192 atomic owner and Blocks
retirement checks. All fixtures are original synthetic or minimal byte witnesses;
no private capture or standards document is needed.

```sh
python3 -B Foundation/Tools/verify-dv-metadata-registry.py
xcrun swift run --package-path Foundation --scratch-path "$test_root/package" RewindDVInspect iec-field-inventory > "$test_root/iec-inventory.json"
python3 -B Foundation/Tools/verify-iec-field-inventory.py "$test_root/iec-inventory.json"
```

The first audit checks the published software geometry only. Historical private
registry seals/disposition evidence are intentionally excluded. The executable
IEC inventory audits all256 allocations and274 layouts, not normative correctness.
Source-bound archive/export tests do not establish physical capture qualification
or complete signed-application UI qualification. VAUX0x61 remains unresolved.
