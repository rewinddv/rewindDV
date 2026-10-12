# Build the source package

Use Xcode 27 and its installed Apple SDKs on macOS. Preserve the project's
per-target architectures and deployment settings. The app deployment floor is
macOS 26.0; that setting alone is not a qualification claim for every OS release.
Beta 0.1.22 uses an app-only identity that retains signed Driver203. Source
verification therefore compiles only the host. The driver target rejects this
reuse reservation rather than rebuilding an unchanged driver. A fresh driver
uses a separately reserved component identity and the full archive workflow.
Public distribution builds are prepared independently; retained artifacts stay immutable.

Clone `https://github.com/rewinddv/rewindDV.git` and run from its root.
The automatic source archives on historical LAB release tags are hub snapshots;
see [release provenance](RELEASING.md) before selecting a source revision. Selected root ASFWDriver
and host-test sources are required alongside Foundation. Do not substitute the
historical root project generator or packaging scripts.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
build_root=$(mktemp -d /private/tmp/rewinddv-build.XXXXXX)
export TMPDIR="$build_root/tmp/"
export CLANG_MODULE_CACHE_PATH="$build_root/clang-cache"
export SWIFT_MODULECACHE_PATH="$build_root/swift-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
python3 -B - "$PWD/Foundation/RewindDV.xcodeproj/project.pbxproj" "$build_root" <<'PY'
import sys, plistlib
from pathlib import Path
sys.path.insert(0, str(Path.cwd() / "Foundation/Tools"))
from driver_reuse import app_only_project
output = Path(sys.argv[2]) / "AppOnly.xcodeproj"
output.mkdir()
(output / "project.pbxproj").write_bytes(plistlib.dumps(app_only_project(Path(sys.argv[1]))))
PY
xcodebuild -project "$build_root/AppOnly.xcodeproj" -target RewindDV \
  SRCROOT="$PWD/Foundation" PROJECT_DIR="$PWD/Foundation" \
  -configuration Release SYMROOT="$build_root/Products" \
  OBJROOT="$build_root/Intermediates" \
  CLANG_MODULE_CACHE_PATH="$build_root/Modules" CODE_SIGNING_ALLOWED=NO build
```

Keep full logs and the actual exit status. For a Debug check, use Debug and a
separate output directory. The source export retains portable signing settings,
privacy-safe synthetic fixtures, required notices and the cassette app icon.
Installed SDK headers, generated IIG/plist outputs, caches, signed applications
and development profiles are not distributed as source inputs.

Follow [TESTING](TESTING.md) for offline validation. Older version-specific
packaging scripts are retained only where static tests require them; they are
not instructions for signing, installing or activating this source snapshot.
An unsigned build cannot establish driver activation, distribution eligibility
or hardware qualification. See [INSTALLATION-PLAN](INSTALLATION-PLAN.md).

## Developer ID and Debug signing

The full release uses the [manual Developer ID archive workflow](Foundation/Docs/DeveloperIDSigning.md).
Supply your own eligible Apple team, certificate and explicit host/DEXT profiles;
no credentials or standalone profiles belong in source Git. Do not use automatic
export thinning for this arm64e DEXT. Build from a clean committed public checkout
and retain exact toolchain and source provenance. For a reuse reservation, use
`Foundation/Tools/build-app-only.py` with the exact pinned signed DEXT and its
original public-source receipt; see [retained-driver packaging](Foundation/Docs/UnchangedDriverPackaging.md)
and [the release workflow](RELEASING.md). An arbitrary installed driver is not a
valid substitute. The unsigned compile above contains no driver and is not a
distribution or acquisition-qualified app.

For a fresh-driver Apple Development Debug build, retain Automatic target signing and pass
`CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=YOUR_TEAM_ID` with isolated outputs.
The default Debug compile check leaves signing disabled. Verify actual host and
embedded driver signatures after a signed build.

Compile the normal CLI without `REWINDDV_OFFLINE_DISTRIBUTION`:

```sh
xcrun swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
  Foundation/Sources/RewindDVMonitorCore/ProductIdentity.swift \
  Foundation/Tools/RewindDVCommandCLI/main.swift -o "$build_root/rewinddv-cli"
```

The normal CLI exposes 66 tools and routes to the normal app. Historical offline
compatibility exposes 57 tools through a separate identity/socket. Neither a CLI
inventory nor signing verification qualifies physical operations.
