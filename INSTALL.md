# rewindDV LAB — engineering alpha 0.0.63

Start here. This is an experimental, ad-hoc-signed, non-notarized test build,
not a generally approved production release. It includes the Build178 driver
and needs no Apple Developer account, device registration or Xcode.

## Before agreeing to test

- Use a backed-up, non-production **Apple Silicon Mac running macOS 26**.
  Intel is unsupported. The app targets macOS 26 and later and was built with
  Xcode 27, but macOS 27 runtime is not yet qualified by this package.
- This build matches the FireWire OHCI controller **PCI 11c1:5901**, used in
  the tested Apple Thunderbolt-to-FireWire adapter chain. A USB-to-FireWire
  cable is not a substitute. Other controller IDs are not supported here.
- Administrator access and access to macOS Recovery are required. Managed
  Macs may prohibit these changes. Do not bypass organizational policy.
- **SIP must remain disabled during this engineering test.** System-extension
  developer mode is also required. This lowers security system-wide. Do not
  use your primary/work computer if that risk is unacceptable. Waiting for
  the production-signed release is the safe alternative.
- Have a non-critical, known-good recorded DV tape, preferably write-protected.
  This app has no tape RECORD/erase control. Hardware faults/tape wear are
  still possible. Keep physical STOP accessible throughout the first tests.
- Only one FireWire driver stack should own the controller.
- This is a publicly available **engineering test**, not an Apple-approved
  distribution method. Fresh-Mac installation of this repackaged ad-hoc build
  still needs qualification. If you cannot accept these limits, wait for a
  properly entitled, Developer ID-signed and notarized release.

## 1 — Check the package

Keep the ZIP and its `.sha256` together. In Terminal, type `cd `, drag their
containing folder onto Terminal, press Return, then run:

```sh
shasum -a 256 -c rewindDV-LAB-Alpha-0.0.63-AdHoc.zip.sha256
```

It must say `OK`. Download only from the official
[rewindDV LAB releases](https://github.com/rewinddv/rewindDV-LAB/releases).
A checksum included with a ZIP detects corruption, not replacement of both files.
Expand the ZIP. Open Terminal in the extracted `rewindDV-LAB-Alpha-0.0.63` folder:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Every file must pass. Stop if any file fails or is missing.
After verification, authorize only the bundled support executable for local use
(still in that extracted folder):

```sh
xattr -d com.apple.quarantine './rewindDV-support'
codesign --verify --strict --verbose=2 './rewindDV-support'
```

`No such xattr` means it was not quarantined; the signature check must still pass.
This is a per-file download exception, not a global Gatekeeper change.

## 2 — Prepare macOS (manual, deliberate changes)

1. Save work and back up. Stop the tape and disconnect FireWire before installation.
2. Shut down. Hold the Mac's power button until startup options appear. Select
   **Options → Continue**. Authenticate if requested. Choose **Utilities → Terminal**.
3. Run `csrutil disable`. Follow macOS prompts, then restart normally.
4. In normal macOS Terminal, run:

   ```sh
   csrutil status
   sudo systemextensionsctl developer on
   ```

   SIP must report disabled. The `sudo` prompt is for your Mac's administrator
   password; Terminal does not display characters as you type. Never send us passwords.

Do not disable Gatekeeper globally, change AMFI/boot arguments, or modify other
security settings. If these steps are insufficient, collect a report and stop.

## 3 — Install

If `/Applications/rewindDV.app` or an older RewindDV app already exists, use
`REMOVE AND RESTORE SECURITY.md` first; do not overwrite an active old driver.

1. Drag **rewindDV.app** from this package into **Applications**.
2. Only after verifying this trusted package, remove quarantine from that app:

   ```sh
   sudo xattr -dr com.apple.quarantine "/Applications/rewindDV.app"
   codesign --verify --deep --strict --verbose=2 "/Applications/rewindDV.app"
   ```

   Expect `valid on disk` and `satisfies its Designated Requirement`.
   This is an ad-hoc integrity check, not Apple notarization or developer identity.
3. Open `/Applications/rewindDV.app`. In **Diagnostics**, click **Activate Driver…**
   once, confirm, and follow macOS approval prompts. Approvals may appear under
   **System Settings → General → Login Items & Extensions → Driver Extensions**
   or **Privacy & Security**, depending on macOS version.
4. Reboot your Mac. Reopen the app, reconnect your FireWire adapter and
   powered-on deck with tape stopped. Check **Diagnostics** says Build178 is
   attached and responding. Activation acceptance alone is NOT driver readiness.
5. About rewindDV must show **Alpha 0.0.63**, Build178, engineering ad-hoc revision.

If activation or connection fails, **do not repeatedly activate or reboot**.
Use `Collect Support.command` as described below. Do not proceed
to tape motion with driver mismatch or lockout warnings.

No local signing, developer-account registration, Xcode installation, or
provisioning-profile download is required. The app and driver are already
ad-hoc signed. Do not re-sign them: that invalidates the published checksums.

## 4 — First smoke test (one step at a time)

For the fullest driver evidence, start `Start System Log.command` BEFORE testing.
To run a `.command` without changing global security settings, in Terminal type
`/bin/zsh ` then drag the command file into Terminal and press Return. This also
works if Finder will not open a downloaded command. Read its prompt before agreeing.

1. Wait for deck discovery/handshake with the recorded tape stopped. Record
   deck model, output mode (DV, not HDV), NTSC/PAL, adapter chain and Mac model.
   Where applicable use the deck's REMOTE/IEEE1394 control setting.
2. GUI PLAY for about 10 seconds, then GUI STOP. Verify picture, audio, meters
   and advancing timecode. If Stop fails, use physical STOP; do not retry blindly.
3. Repeat once. Test short rewind/fast-forward only while supervised.
4. Manual Capture to a local/external SSD for 30 seconds, then STOP. Wait for
   reconstruction and reread to finish. Do not quit/unplug while processing.
5. Play the result. Check the verification summary and actual playback. Hash
   verification proves saved-byte consistency, not flawless tape content.
6. Only after those pass, test **Automated Whole Tape Capture**. Choose a
   writable local SSD (APFS/HFS+/exFAT); avoid FAT32 and network volumes. Allow
   at least 40 GB free per SP hour for raw evidence + native DV + reports,
   with additional headroom. Keep the Mac powered, awake and connected.
   There is no guaranteed remaining-time estimate. Blank footage/missing
   timecode is not EOT; receiving should continue until observed tape stop.
7. Watch the first full run, final processing, notification and verification.
   Notifications require macOS permission and can be suppressed by Focus.
   Never disconnect storage until processing has finished.

Do not treat this as already qualified on your deck. Report even apparently
successful tests; they extend our physical compatibility evidence.

## 5 — Send evidence

**Normal route:** after capture/verification, open **Diagnostics**, describe the
problem and time, optionally **Include capture folder…**, then **Export support ZIP…**.
The **Alpha testing** menu also offers export if the sidebar is locked out.
The current capture folder is included automatically when still available.
After reopening the app, choose the relevant capture/WholeTape folder explicitly.

**Extended/failure route:** stop the optional system logger with Control-C, then
run **Collect Support.command**. It works even when the app will not launch.
Optionally provide your capture/WholeTape folder. It creates a support ZIP on
Desktop including app reports, saved system-log segments, recent related macOS
logs, extension status and matching crash reports. It never sends tape commands,
activates/removes drivers or uploads anything. Some macOS logs may be private,
unavailable or empty; command outcomes and export omissions remain visible.

Review the ZIP and send it over the private channel you arranged.
If you do not have a private channel, open a minimal, sanitized
[GitHub issue](https://github.com/rewinddv/rewindDV-LAB/issues) to request one.
**Never attach support ZIPs, raw logs, private paths, deck serials/GUIDs or
footage to a public GitHub issue.**
Also complete `TEST REPORT.md`. Reports can contain usernames/paths, deck GUIDs,
timecodes, dates and other tape metadata. Extended reports may list installed
extensions and crash-process details. **No video/audio or raw receive payload
files are collected automatically.** Preserve the original capture folders;
we may separately request a specific sample with your consent.

## Recorder coverage and limits

Session status is recorded automatically at approximately one-second intervals,
off the capture thread; detailed control/inspector/receive/job flights remain
separate. Five-second flush cadence means abrupt power loss can lose the latest
samples. It is not a wire-level analyzer and cannot prove every absent packet.
The unchanged driver retains its existing trace/counter limits.

Session journals rotate at 4 MiB, stop visibly at 128 MiB per session, and refuse
new sessions once retained session files exceed 512 MiB. No old evidence is
automatically deleted. Capture does not stop if this supplemental recorder fails.
Export/archive older session diagnostics before resuming tests after such a warning.
Keep an eye on free space: raw monitor/capture flights are separate and can be large.

The JSON/NDJSON part of support exports is bounded to 128 MiB, 8 MiB per file,
20,000 inspected entries, newest files first within each source. Oversized files
have explicitly marked head/tail ranges; unavailable/omitted files are listed in
`manifest.json`. The system logger caps each run at 256 MiB; segments can split a
JSON line and should be concatenated in sequence for parsing. Limits preserve
capture resources and make omissions explicit—not a claim of complete logging.
The standalone collector can additionally retain bounded system-command output
and matching crash reports, so its complete ZIP can exceed 128 MiB.

## References

- Apple development testing: https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions
- Apple SIP guidance: https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection
- ASFireWire experimental installation model: https://github.com/mrmidi/ASFireWire/wiki/Installing

rewindDV incorporates ASFireWire-derived components under Apache-2.0; licenses
and notices are included. This package does not include ASFireWire's audio/SCSI
product features. Do not apply upstream installation commands to rewindDV.
