# Alpha 0.0.77 / Driver Build183

Engineering alpha. Ad-hoc signed and not notarized.
Installation requires disabling System Integrity Protection (SIP),
which reduces macOS security.

Alpha 0.0.77 / Driver Build183 is intended for experienced users and dedicated/test systems.

- Canonical source: https://github.com/rewinddv/rewindDV
- [Installation and checksum verification](https://github.com/rewinddv/rewindDV-LAB/blob/main/INSTALL.md)
- [Uninstall, rollback and restore security](https://github.com/rewinddv/rewindDV-LAB/blob/main/UNINSTALL.md)
- [Sanitized issue reports](https://github.com/rewinddv/rewindDV-LAB/issues)

Download **rewindDV-Alpha-0.0.77-Build183-AdHoc.zip** and its `.sha256` sidecar.
GitHub's automatic source archives contain this testing hub's documentation, not the application.

```sh
shasum -a 256 -c rewindDV-Alpha-0.0.77-Build183-AdHoc.zip.sha256
```

ZIP SHA-256: `5b8e2787f3b48485fb54392a40fca3c5ea688ef944dbc61ba7c38f72dff31d77`.

The package contains the app and reviewed installation/removal documents. The app and DriverKit extension are ad-hoc signed; no development provisioning profile is included. No local re-signing or developer-account registration is required.

Offline validation passed: 427 Swift Testing tests, 14 XCTest tests, admission, boundary, manual-stop-tail, whole-tape/recovery orchestration, PLAY callback and quit-supervision regressions, Release build and strict signature/bundle checks. The exact archive passed the personal-information audit.

Existing bounded runtime evidence covers Apple silicon, macOS 27.0.1, recorded NTSC DV and a Sony HVR-M15U. This repackaged ad-hoc artifact has not been installed or newly physically qualified. Fresh-system installation, broader macOS/deck/adapter compatibility, PAL/HDV capture, full-length endurance, natural end-of-tape and active-capture disconnect/power loss remain unverified. The supported controller match is PCI 11c1:5901. Unknown continuity and unresolved content-quality markers remain unknown; saved-byte hashes do not establish flawless audiovisual content.

Normal Developer-ID-signed, notarized, SIP-on distribution remains future work dependent on Apple distribution prerequisites. No Apple endorsement is implied.

Alpha 0.0.63 / Driver B178 remains withdrawn. Do not post support ZIPs, raw logs, personal paths, device identities or footage in public issues. Project contact: info@rewinddv.com.

## Previous release

Alpha 0.0.63 / Driver B178 is an older development build and has been withdrawn from distribution.
