# rewindDV Alpha 0.0.94 · Driver B192

Engineering alpha. Ad-hoc signed and not notarized.

The application, included DriverKit extension and CLI are signed ad hoc,
not with an Apple Developer ID, and are not notarized. Offline playback,
inspection and supported archive operations require no DriverKit activation
or SIP change. Activating the included ad-hoc DriverKit extension may require
disabling System Integrity Protection (SIP), which significantly reduces macOS
security. Normal SIP-on driver installation is not qualified for this package.

This engineering alpha is intended for experienced users and dedicated/test
systems. Driver activation testing may require administrator and macOS Recovery access. Follow
your organization's device policy. This is experimental software; preserve
original media and keep backups.

Canonical source: https://github.com/rewinddv/rewindDV

## Compatibility and limits

Use an Apple silicon Mac. The app's deployment floor is macOS 26; existing
bounded runtime evidence is on macOS 27.0.1 with recorded NTSC DV and a Sony
HVR-M15U. This does not establish compatibility with every macOS version, deck,
format or adapter. The app is arm64 and the driver is arm64e.

The driver matches FireWire OHCI PCI controller 11c1:5901, as used by the tested
Apple Thunderbolt-to-FireWire adapter chain. A USB-to-FireWire cable is not a
substitute. Other controller IDs are unsupported by this build.

Live extension unload/hot replacement and reboot-free removal are unqualified. Use the shutdown/restart procedure in UNINSTALL.md. Normal capture STOP keeps the driver loaded; earlier bounded B190 receive-retirement evidence is separate from this Driver192 package.

Natural end-of-tape, full-length endurance, physical PAL DV capture, HDV playback/capture, active-capture
disconnect and power loss remain unqualified. Blank video or missing timecode
does not establish end-of-tape. Unknown continuity, missing-frame counts and
unresolved content-quality markers remain unknown. Saved-byte hashes establish
byte consistency, not flawless audiovisual content. Keep physical STOP available.

This app was built from the published Alpha 0.0.94 source with ad-hoc signing.
Both the app and B192 extension are freshly built from the exact published source and signed ad hoc.
Offline checks passed;
the exact packaged ad-hoc app/driver have not been installed or newly physically qualified. Earlier bounded B190 development-signed capture evidence is described in COMPATIBILITY.md.
Fresh-system installation and broader compatibility remain unverified.

## Verify the download

Download the ZIP and its checksum sidecar together from
https://github.com/rewinddv/rewindDV/releases/tag/alpha-0.0.94.
Open Terminal in their containing folder and run:

```sh
shasum -a 256 -c rewindDV-Alpha-0.0.94-Driver192-AppBuild188-AdHoc.zip.sha256
```

Expect `OK`. Stop if verification fails. A sidecar detects corruption; it does
not authenticate a replacement of both files. Expand the ZIP and verify:

```sh
codesign --verify --deep --strict --verbose=2 './RewindDV.app'
codesign -d --verbose=4 './RewindDV.app'
codesign -d --verbose=4 './RewindDV.app/Contents/Library/SystemExtensions/net.rewinddigital.RewindDV.Driver.dext'
```

Verify the included CLI as well:

```sh
codesign --verify --strict './rewinddv'
codesign -d --verbose=4 './rewinddv'
```

App, driver and CLI signatures must report `Signature=adhoc` and `TeamIdentifier=not set`.
Ad-hoc signing provides an integrity check, not an Apple-verified publisher or
notarization. No developer account, device registration, profile download or
local re-signing is required. Re-signing changes the released bytes.

## Prepare and install

1. Save work and back up. Finish capture verification, stop tape motion and quit capture applications. Do not unplug an active driver or use live extension disable. Shut down normally, disconnect FireWire while powered off, then start with it disconnected. If an older rewindDV app/driver is installed, follow
   `UNINSTALL.md` first; retain a separately verified previous package if you
   need rollback. Do not overwrite an active older driver.
2. Shut down the Mac. Hold power until startup options appear; select
   **Options → Continue**. Authenticate if requested and open
   **Utilities → Terminal**. Run `csrutil disable`, follow the prompts, then
   restart normally.
3. In normal macOS Terminal, run:

   ```sh
   csrutil status
   sudo systemextensionsctl developer on
   ```

   SIP must report disabled. Do not change AMFI, boot arguments or global
   Gatekeeper settings. Stop if this supported interim workflow is insufficient.
4. Copy **RewindDV.app** into **Applications**. After verifying the package,
   make the download exception only for this app:

   ```sh
   sudo xattr -dr com.apple.quarantine '/Applications/RewindDV.app'
   codesign --verify --deep --strict --verbose=2 '/Applications/RewindDV.app'
   ```

   The signature check must pass. Open the app. In **Diagnostics**, select
   **Activate Driver…** once, confirm and follow macOS approval prompts.
   Approval may appear in **General → Login Items & Extensions → Driver
   Extensions** or **Privacy & Security**, depending on macOS.
5. Restart. Open the app, reconnect the adapter and powered-on deck with tape
   stopped, and verify Diagnostics shows **B192** attached and responding.
   About rewindDV must show **Alpha 0.0.94**. Activation acceptance alone does
   not establish readiness. Stop if versions mismatch or a lockout appears.

If activation or connection fails, avoid repeated activation/reboot attempts.
Request help through a minimal, sanitized issue at
https://github.com/rewinddv/rewindDV/issues or contact info@rewinddv.com.
Review diagnostic exports privately; never post raw logs, support ZIPs,
personal paths, device identities or footage to public issues.

## CLI / MCP

The ZIP includes an arm64 `rewinddv` executable and `CLIAndMCP.md`. Keep the
verified client in a convenient directory, start the app, accept its alpha notice,
and run `./rewinddv status`. Use `./rewinddv mcp` as a local stdio MCP server.
If macOS applies download quarantine to the verified CLI, remove it only from
that executable with `xattr -d com.apple.quarantine ./rewinddv`, then repeat the
signature check. Do not change global Gatekeeper or AMFI settings.

Playback, Surgery and offline inspection work without activating the driver.
External source/destination paths need a GUI sandbox grant for the current
session. Driver activation and supervised physical recovery remain interactive.
The ad-hoc package is not notarized or a normal SIP-on distribution.

## Remove or roll back

Follow `UNINSTALL.md`. Remove the registered driver before its containing app.
Restore SIP when testing ends. Rollback requires separately verified prior
software and its own instructions; this ZIP does not contain a rollback binary.

## Future distribution

Normal Developer-ID-signed, notarized, SIP-on distribution remains future work
dependent on Apple distribution prerequisites. It is separate from this interim
engineering alpha. No Apple endorsement is implied.

Apple references:
- https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions
- https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection

Applicable licenses and third-party notices are retained inside the app's
`Contents/Resources` directory and in the canonical source repository.
