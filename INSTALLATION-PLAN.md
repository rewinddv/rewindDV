# Source and binary installation scope

This repository provides source and unsigned build instructions. The separate
[Alpha 0.0.77 / Driver Build183 engineering alpha](https://github.com/rewinddv/rewindDV-LAB/releases/tag/alpha-0.0.77)
is ad-hoc signed and not notarized.

rewindDV currently uses an ad-hoc-signed DriverKit extension.
Installation requires disabling System Integrity Protection (SIP).
Disabling SIP reduces macOS security.

It is intended for experienced users and dedicated/test systems. Use only that
artifact's [installation/checksum instructions](https://github.com/rewinddv/rewindDV-LAB/blob/main/INSTALL.md)
and [uninstall/rollback instructions](https://github.com/rewinddv/rewindDV-LAB/blob/main/UNINSTALL.md).
The repackaged artifact passed offline checks; it has not been installed or
newly physically qualified. Existing bounded runtime evidence and broader
qualification limits remain as documented in this source snapshot.

An unsigned source build neither installs nor activates a driver. Do not apply
binary-installation steps to arbitrary source builds or re-sign a released app.
No system-security change or installation is performed by these build instructions.

Normal Developer-ID-signed, notarized, SIP-on distribution remains future work
dependent on Apple distribution prerequisites. That future path is separate
from the interim ad-hoc engineering alpha. No Apple endorsement is implied.
