# Canonical product identity migration

The next development candidate is **rewindDV 0.1.1 (Alpha)**, app build191 and
driver build194. This unifies the historical Alpha0.0.96 and macOS marketing0.1.0
series. It is an engineering identity reservation, not a downloadable release or
production-readiness claim. The published alpha-0.0.96 / App190 / Driver193 ZIP
and its SHA-256 `3d470dcc90eae1b3893dce6e8df6accf8b80860121faf4088fe902dec8c604f8`
remain unchanged.

## Authority and consumers

`Config/ProductIdentity.json` is the single writable current authority. Run
`python3 Foundation/Tools/product_identity.py --generate` only as an explicit
reviewed source operation. Commit its deterministic outputs. Ordinary builds
and `--check` never advance counters or mutate tracked inputs. The read-only gate
rejects stale generated files and Xcode identity overrides/missing target bindings.
Both native targets check before compiling/processing metadata, with declared
sandbox inputs and a derived host plist output. SwiftPM and standalone CLI
compilations consume the same generated Swift identity.

| Identity | Historical published package | New development source |
| --- | --- | --- |
| Product | Alpha 0.0.96 | 0.1.1 (Alpha) |
| App macOS short version | 0.1.0 | 0.1.1 |
| App build | 190 | 191 |
| Driver short version | 0.1.0 | 0.1.1 |
| Driver build / host requirement | 193 | 194 |

In both Debug and Release, the app uses AppBuild.xcconfig and the DEXT uses
DriverBuild.xcconfig for component counters; both include ProductIdentity.xcconfig for numeric
marketing version. Driver C++ metadata and app/CLI/MCP presentation derive from
that authority. About details, Copy Diagnostics and additive diagnostic fields
retain separate component IDs. The old AlphaVersion.txt/RewindDVAlphaVersion
fields remain derived aliases. Historical reports retain their old meanings.
Schema, protocol, source commit and executable/signing hashes remain independent.
There is no application updater to migrate.

The allocation audit inspected all relevant identity-changing Git history,
recorded qualification/candidate metadata and public releases/tags. The observed
high-water values were marketing0.1.0, App190 and Driver193; no proposed identity
reservation was found in that inventory. IdentityHistory.json retains these
prior high-water records. Future reservations must append the old current
identity, check external usage, and allocate monotonic unused counters explicitly.
Changed circulated artifacts cannot reuse a component build. Current packaging
requires fresh full app/DEXT components; the obsolete generic same-build app-only
splicing command is retired. Historical build-pinned scripts remain historical.

## Replacement and preservation

Apple's [replacement delegate documentation](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/request(_:actionforreplacingextension:withextension:))
(`MANUFACTURER_REFERENCE`, accessed 2026-10-09) identifies conflicts using both
bundle version fields, including same-version callbacks in developer mode.
Numeric ordering is local policy, not an Apple qualification claim. Replacement
requires the exact incoming driver build and product short version, a lower
installed build and a nondecreasing numeric short version. Malformed, newer and
same-build identities fail closed. Matching product versions alone never admit
a wrong driver. Equal IDs do not authenticate equal bytes; packaging also checks
executable hashes against a supplied previous manifest.

The accepted ASFireWire successor remains an ancestor; this migration changes no
transport, MMIO, DMA, ownership, cancellation, archival, IEC or preview behavior.
Immediate terminal fencing, bounded receive Stop retry, failed-session ownership
containment and permanent quarantine remain. Team, bundle IDs, exact PCI grant,
entitlements, Debug development and Release manual Developer ID settings remain.

## Validation and release handoff

Independent numeric/build/bundle fixtures, generated-file/configuration negatives,
compiled CLI/MCP output, full Swift/XCTest, signing negative tests, metadata
inventories and native offline regressions accompany the unsigned app/DEXT build.
The task's external receipts bind exact clean source, commands, exits, effective
settings, actual bundle metadata and executable hashes. Retained failed attempts
are distinguished from corrected reruns. Independent review and final private,
public-source and website identities are recorded in the external closeout.

No binary, tag, signing, notarization, installation, extension activation or
physical deck operation is part of this migration. For a separately authorized
release, follow [Developer ID signing](DeveloperIDSigning.md) with the canonical
reserved identity, new full Release build and exact manual distribution profiles.
Verify source/bundle/required-driver/package provenance before fresh notarization;
staple and verify the newly extracted artifact, signatures and exact entitlement
array. Never reuse the old Driver193 ticket or relabel its bundle.

Supervised testing must cover193→194 replacement, equal/newer/malformed identity
rejection, exact app-driver negotiation and ordinary capture STOP/reentry before
separately authorized removal/unload experiments. M1 live preview, physical
capture, endurance and teardown remain unqualified for this candidate. Permanent
quarantine is not successful unload. The old Alpha0.0.96 artifact remains the
unchanged rollback download. Development source/status and downloadable release
identity must be displayed separately throughout public documentation and website.
