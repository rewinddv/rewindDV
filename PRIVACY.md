# Privacy & support evidence

The bundled diagnostic tools save reports locally. They do not automatically
upload them. You decide whether to export and share a support ZIP.

## What reports can contain

- App/driver version, Mac model, OS version, connection and transport results.
- Usernames and file paths, device GUIDs, tape timecodes and recording dates.
- Receive counters, integrity results, job transitions and bounded trace evidence.
- With the optional standalone collector: related macOS logs, installed system
  extension listings, matching crash reports and diagnostic command outcomes.

Automatic support collection excludes video/audio media and raw receive-payload
files. JSON/NDJSON documents can still contain sensitive metadata. Review every
export before sharing. A bounded snapshot is not a complete wire-level record;
unavailable, truncated and omitted evidence is identified in the manifest.

The app's session journals and capture raw evidence are separate. A support ZIP
is **not** a backup of your tape capture. Keep the original acquisition folder.

## Share safely

1. Finish capture and verification; do not unplug storage during processing.
2. In Diagnostics, export a support ZIP and include the relevant capture folder
   if requested. If the app will not launch, follow the kit's standalone collector
   instructions instead.
3. Inspect the ZIP. Arrange a private transfer with the maintainer before sending it.
4. Post only a sanitized summary in public GitHub issues. Do not attach raw logs,
   support ZIPs, private footage, serials/GUIDs, personal paths or credentials.

If you have no established private channel, open a public issue asking how to
transfer evidence privately, **without the evidence attached**. Never post a
password, API key, signing identity or unredacted system report.

Downloading through GitHub and using an eventual external payment link are
subject to those services' own privacy policies. This document describes the
rewindDV tester kit, not those external services.

## Source publication preflight

The local checker is a preflight, not anonymity certification:

```sh
python3 tools/check-publication-content.py SOURCE_OR_ZIP   --private-config /private/tmp/release-private-config.json   --output /private/tmp/release-content-findings.json
```

Supply a private JSON object with `terms` and `private_values` arrays. Keep actual values outside Git and outside every publication tree. The checker records redacted locations/categories, checks common text encodings, plist and ZIP metadata, and reports unsupported/manual-review gaps. Do not commit the private configuration or raw findings. Synthetic tests are in `tools/test-publication-content.py`.

Review the exact final source tree, archives, image metadata and pixels, signing certificates/profiles, binary strings, and intended Git author/committer/tag metadata separately. Any changed input invalidates the approval. No command here uploads a report, checks credentials with a service, or grants permission to publish.
