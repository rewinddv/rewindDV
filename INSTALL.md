# rewindDV distribution and installation

Read [PROJECT-STATUS.json](PROJECT-STATUS.json) and the release's own instructions
to identify the actual published download. Source availability does not imply a
matching hardware-capable binary has been published.

## Alpha 0.0.94 offline-only candidate

Read [offline distribution instructions](Foundation/OFFLINE-DISTRIBUTION.md).
This separately labelled package uses reduced app entitlements, includes no
DriverKit extension, and disables discovery, activation, deck control and
physical acquisition. App and CLI are ad-hoc signed with hardened runtime and
are not notarized. Offline operations require no SIP change. The offline CLI
locally excludes hardware commands, even when a different app owns its socket.

Keep the previous app for rollback. Open the extracted app without replacing
installed hardware software or interrupting a capture. Follow the package's
checksum, signature, macOS approval and sandbox-grant instructions.

## Earlier full hardware packages

The Alpha 0.0.93 / Driver B190 download bundled an ad-hoc app, DriverKit extension
and CLI, with no provisioning profiles. Its documented test-system workflow
used SIP disabled and system-extension developer mode. Disabling SIP reduces
macOS security. The exact public app's SIP-on startup and physical installation
were not qualified. Offline operation does not activate a driver, but the full
ad-hoc app still carries restricted DriverKit entitlements and may fail before
startup with SIP enabled.

For that historical package, use its immutable
[installation instructions](https://github.com/rewinddv/rewindDV/blob/alpha-0.0.93/INSTALL.md)
and [removal instructions](https://github.com/rewinddv/rewindDV/blob/alpha-0.0.93/UNINSTALL.md).
The new full Alpha 0.0.94 candidate failed restricted-entitlement startup on a
SIP-enabled host and was not published. Do not apply historical driver-install
steps to the offline-only package.

## Source builds

The complete source retains independent Driver192 and the normal app's hardware
functionality. See [BUILDING.md](BUILDING.md). Development signing with valid
Apple profiles is distinct from ad-hoc public distribution. Developer ID signing,
notarization and normal SIP-on DriverKit distribution remain future work.

Keep original captures and private diagnostic evidence separate. Report sanitized
issues at https://github.com/rewinddv/rewindDV/issues or info@rewinddv.com.
