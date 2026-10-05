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
