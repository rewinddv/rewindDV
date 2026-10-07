# Current development validation

Alpha 0.0.93 / app188 / Driver B190 public source passes 273 Swift Testing
cases, 14 XCTest cases, native app/driver/CLI Release builds, 38 release-tool
regressions, 10 status tests and 10 disclosure tests. The restored public ZIP
passes exact manifest/hash/mode checks, strict ad-hoc signature verification
and architecture checks. The packaged client responds to read-only app status
and enumerates all 66 MCP tools.

Automated disclosure findings were retained and manually reviewed: a
nonsemantic binary-byte collision, generic documented volume examples and
structured signature resources. The reviewed package contains no personal
signing identity or provisioning profiles. No fresh physical qualification or
installation of this exact package was performed.

## Retained Alpha 0.0.89 validation

Alpha 0.0.89 / app188 / Driver B190 has completed source-bound offline validation:
464 Swift Testing cases, 14 XCTest cases, 26 host/integration gates, 22 native
playback runs, Debug/Release builds, and focused DMA, callback, transaction-identity
and sanitizer regressions. These are software results for accepted development.
Fresh public source and distribution-build checks are recorded with the public
package provenance; they do not extend hardware qualification.

Five bounded NTSC DV captures on one Sony HVR-M15U setup passed normal capture
STOP/retirement and re-entry while the driver stayed loaded. The longest saved
DV was 238.038 seconds. See [COMPATIBILITY](COMPATIBILITY.md) for actual durations
and retained continuity observations. Live global unload remains unqualified.
The public ad-hoc package is not newly installed or physically qualified.

## Retained earlier test report

# rewindDV alpha test report

- Application version (About rewindDV):
- Driver build (separate from application version):
- Canonical release tag/URL or full public source commit:
- Physical hardware test or synthetic/offline test:
- Mac model / Apple chip / macOS version:
- FireWire adapter chain, controller topology and cables (no unique IDs):
- Deck/camcorder manufacturer and exact model / firmware if known:
- Deck remote/output settings; DV vs HDV:
- Recorded format (DV / DVCAM / Digital8 / HDV):
- System mode: NTSC/PAL, SP/LP where applicable:
- Destination SSD / connection / filesystem / free space:
- Local date, time and time zone of test:
- Was optional system logging running?
- Steps performed, in order:
- Actual test duration / whole-tape or bounded test:
- Success/failure stage (connection, playback, capture, finalization, verification, export):
- Expected result:
- Actual result (picture/audio/timecode/meters/transport):
- PLAY/STOP repeated successfully?
- Manual capture result and reported loss counters:
- Whole-tape rewind, start, gaps, natural stop, verification, notification:
- Did exported clip play correctly?
- Was there a hang, crash, reboot or physical STOP intervention?
- Sanitized error/loss summary (no raw logs):
- Support ZIP retained locally? (Do not post it or its identifying filename.)
- Manifest omissions/warnings, if any:
- Additional comments:

- [ ] No private footage, raw logs, support archives, personal paths, serials/GUIDs or credentials are included in this public report.

Public reports contain sanitized summaries only. Request a private transfer
channel before sharing detailed evidence; follow [PRIVACY.md](PRIVACY.md).
A result applies only to the tested configuration and duration. Synthetic/offline
tests are not physical hardware qualification. A successful hash check is not
proof of flawless source tape.
