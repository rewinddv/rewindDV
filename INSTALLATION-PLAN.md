# Current distribution plan

Use the manual full Developer ID pipeline in [RELEASING.md](RELEASING.md) and the
artifact-specific normal macOS procedure in [INSTALL.md](INSTALL.md). The approved
Release PCI match is `0x590111C1`. Signing/notarization does not certify a hardware
matrix. Current source and published artifact identities are separate in
[PROJECT-STATUS.json](PROJECT-STATUS.json).

Historical unsigned/ad-hoc and offline plans remain in their immutable release
tags; they must not be applied to the current full signed package. Preserve old
apps and original captures. No security weakening or unattended hardware test is
part of release validation.
