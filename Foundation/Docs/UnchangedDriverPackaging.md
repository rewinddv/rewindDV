# Unchanged driver packaging

GUI-only updates must retain the exact verified signed driver when the driver's
implementation, compiled inputs, signing requirements and compatibility contract
are unchanged. This supersedes the full-component candidate policy introduced
by the canonical version migration. App and product identities advance for a
changed delivered app; the reused driver keeps its own existing identity.

Before delivering an app-only candidate:

- Identify the retained driver by its original source revision, bundle versions,
  signature and full bundle manifest. Compare relevant driver inputs and the
  app/driver contract against that source; do not infer equivalence from a version
  number or an app-only filename.
- Copy the entire retained signed DEXT without modification or re-signing. Verify
  every retained file, symlink and mode against the original manifest and verify
  its signature independently before and after outer-app signing and packaging.
- Record the new app's source and identity separately from the retained driver's
  source and identity. Preserve required-driver compatibility and test the actual
  negotiation. An app product version must not relabel the retained driver.
- Do not request driver activation when the intended compatible driver is already
  running. Confirm actual active identity independently of registration. Existing
  pending macOS replacement requests remain a separate installation condition;
  never cancel them with forced removal or reset procedures.

`ProductIdentity.json` may reserve an app-only successor with a `driver_reuse`
binding to the retained driver's original version, channel, reviewed source and
full signed-bundle manifest digest. The app/product advance; the driver build
must equal the latest prior reservation, or an older build with an identical
previously pinned reuse binding in history. The latter supports local app updates
without replacing a still-installed driver. This does not reserve or build a new
older driver, permit arbitrary rollback, or relax the exact runtime admission
gate. Repeated reuse of a build retains the same source and manifest binding. Signed host metadata carries the required
driver version independently of the host version.

Use `Tools/build-app-only.py` with the retained DEXT, its source/manifest receipt,
the app distribution profile, certificate and team. It verifies unchanged driver
implementation, build contract and entitlements; derives a temporary host-only
project by removing the driver dependency and embed phase; builds the host;
copies the pinned driver; and signs only the outer app. Preserve the projection
and command receipts. The normal full-component archive rejects reuse identities,
as does the driver target's identity check.

The host-only build supplies supported Clang file/debug prefix maps and Swift
file/debug and serialized-debugging prefix maps for source and build directories.
These neutralize compiler-emitted build paths; they do not substitute a false
source commit. Swift's file map covers debug/coverage/index information, not an
explicit `#filePath` string. Keep absolute-path literals out of shipped diagnostic
code and inspect actual final binaries separately. The compiler fixture exercises
real Swift debug information and `#fileID`, and C `__FILE__`, including source
directories with spaces and filesystem aliases.

The historical `Tools/package-app-only.py` remains retired. Do not advance an
unchanged driver, disable validation, reuse an app identity for changed bytes, or
relabel the retained driver. Verify the final notarized ZIP extraction against
the pinned driver manifest before release. Package validation and recorded UI
checks do not imply new physical capture qualification.
