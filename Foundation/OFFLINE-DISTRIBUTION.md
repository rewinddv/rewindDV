# rewindDV Alpha 0.0.94 — offline-only engineering prerelease

App build188. Apple silicon arm64; macOS26 or later. Built with Xcode27.
The app and arm64 CLI are signed ad hoc with hardened runtime, not with an Apple
Developer ID, and are not notarized. This experimental package includes no
DriverKit extension. It disables driver discovery, activation, deck control and
physical acquisition. The source independently retains Driver192; it is not a
packaged hardware feature here. Offline operations require no SIP change.

Download the ZIP, matching SHA256 sidecar, manifest.json and provenance.json from
https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.94.
Run `shasum -a 256 -c rewindDV-Alpha-0.0.94-AppBuild188-Offline-AdHoc.zip.sha256`
from their folder. Expect OK. A sidecar verifies consistency, not publisher trust.
Verify `codesign --verify --deep --strict RewindDV.app` and the CLI signature.

Keep the existing app for rollback. Do not interrupt capture or tape motion to
change apps. Open this app from the extracted folder; replacing an installed
hardware-capable app is unnecessary. macOS may block downloaded unnotarized apps;
use its normal Privacy & Security Open Anyway review if you choose to proceed.
Do not disable SIP or other system security for this offline package.
Removal is quitting this app and moving its extracted copy to Trash; restore your
preserved app if you replaced it yourself. No driver activation/removal is needed.

Playback, raw metadata inspection, evidence maps/review and supported archive
exports remain available. Start the app and accept its alpha notice. The CLI/MCP
uses the running app; external paths require a GUI sandbox grant for this session.
Only one app-owned CLI command server runs at a time. The packaged CLI locally excludes hardware commands before connecting, even if another app owns the socket. Its MCP list contains 57 offline tools.
Read CLIAndMCP.md; its general hardware interfaces are unavailable in this build.

Mixed NTSC/PAL archives use source-bound epochs and ordered lossless segmented
exports. Mixed-system single-file merge and film/container output reject with a
segmented-export alternative. Raw metadata/conflicts/unknown regions remain
preserved. VAUX0x61 interpretation is unresolved; complete IEC certification is
not claimed. HDV playback and the full signed-app UI remain unqualified. Software
build/tests and startup do not establish complete workflow or hardware qualification.
Never overwrite original captures. Keep source bytes and backups separate.
