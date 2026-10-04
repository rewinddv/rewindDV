rewindDV
Copyright 2026 Rewind Digital, LLC

This is a modified downstream project based on ASFireWire.
Copyright 2024-2026 ASFireWire Project Contributors
https://github.com/mrmidi/ASFireWire
Retained baseline: ac8a124a683d2f8201cd14ee0d2de8265e4834f0

The Apache-2.0 license and pertinent upstream attribution are retained in ../LICENSE
and App/Resources/ASFireWire-NOTICE.txt. Modified files retain their change notices.
Independent downstream address, diagnostic and timing implementations and
metadata/reporting modifications are identified in this prospective snapshot.

Selected MediaInfoLib decoder adaptations retain BSD-2-Clause terms.
Selected DVRescue geometry and the retained schema retain BSD-3-Clause terms.
Selected video-tools consumer enumeration vocabulary retains MIT terms.
Complete copyright, conditions and disclaimers are in App/Resources/ThirdPartyNotices.txt. These terms are not replaced by the Apache-2.0 project license.

No upstream endorsement or physical qualification is implied. Project names,
logos and the Azimuth Mark are separate from the software license.

Selectively adapted response-before-next-command ordering from ASFireWire
commit de53e4c00e0e22a5194e7acc52601cbc9a090ae0 (2026-10-02).
rewindDV uses a synchronous response-submission boundary, retains response
receipt evidence on submission failure, and preserves its existing FCP policy.
No upstream endorsement or physical qualification is implied.

Selective reset-ingress adaptation from ASFireWire commit
aeb1388c07360bd4188ae1e7c5aba7848d9cd5ad: immediate busReset masking,
same-snapshot Self-ID retention, and single IRQ ownership of Self-ID W1C.
The wider upstream MSI drain/retrigger implementation is not imported.
Host regressions do not establish physical hardware qualification.

RewindDV Foundation Build187 modifies reset recovery scheduling to use the
existing cancellable timer service, retires obsolete Self-ID recovery only
after valid topology, refreshes late-completion timing, and keeps async
transmit quiesced when no generation has been accepted. These downstream
changes do not establish physical qualification or uninterrupted capture.

RewindDV Foundation Build188 prepares the shared control timer before the
controller copies its dependencies. Alpha 0.0.87 adds direct Settings navigation
for driver approval. Startup and capture qualification remain separate.
