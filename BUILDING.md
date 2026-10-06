# Build the source package

Use Xcode 27 and its installed Apple SDKs on macOS. Preserve the project's
per-target architectures and deployment settings. The app deployment floor is
macOS 26.0; that setting alone is not a qualification claim for every OS release.
Source verification uses an unsigned Release build of the app and dependent
driver. Public distribution builds are prepared independently; local development artifacts remain immutable.

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
xcodebuild -project Foundation/RewindDV.xcodeproj -target RewindDV \
  -configuration Release SYMROOT="$build_root/Products" \
  OBJROOT="$build_root/Intermediates" \
  CLANG_MODULE_CACHE_PATH="$build_root/Modules" CODE_SIGNING_ALLOWED=NO build
```

Keep full logs and the actual exit status. For a Debug check, use Debug and a
separate output directory. The source export retains portable signing settings,
privacy-safe synthetic fixtures, required notices and the generic system icon.
Installed SDK headers, generated IIG/plist outputs, caches, signed applications
and development profiles are not distributed as source inputs.

Follow [TESTING](TESTING.md) for offline validation. Older version-specific
packaging scripts are retained only where static tests require them; they are
not instructions for signing, installing or activating this source snapshot.
An unsigned build cannot establish driver activation, distribution eligibility
or hardware qualification. See [INSTALLATION-PLAN](INSTALLATION-PLAN.md).
