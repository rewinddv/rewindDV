# Support and publication privacy

DRAFT — NOT PUBLISHED.

Review attachments before sharing. Logs, journals, XML reports, file paths, device identifiers, provisioning profiles, media, screenshots, archives and Git metadata can expose identity even when the visible page looks anonymous. Preserve original captures privately and share a reviewed derivative only when authorized.

Use generic labels such as “test operator” and “Test system A” in examples. Remove identifying names, local home paths, personal email, machine/device identifiers and account/signing metadata from proposed public copies. Preserve required third-party copyright and license text; if it conflicts with a privacy requirement, stop and resolve the publication scope instead of deleting the notice silently.

The verified existing reporting process is to request private transfer arrangements through the project's issue channel, without posting sensitive evidence in the request. There is no verified dedicated private email in this draft. A report with confidential data must wait for an agreed channel.

The local checker is a preflight, not anonymity certification:

```sh
python3 tools/check-publication-content.py SOURCE_OR_ZIP   --private-config /private/tmp/release-private-config.json   --output /private/tmp/release-content-findings.json
```

Supply a private JSON object with `terms` and `private_values` arrays. Keep actual values outside Git and outside every publication tree. The checker records redacted locations/categories, checks common text encodings, plist and ZIP metadata, and reports unsupported/manual-review gaps. Do not commit the private configuration or raw findings. Synthetic tests are in `tools/test-publication-content.py`.

Review the exact final source tree, archives, image metadata and pixels, signing certificates/profiles, binary strings, and intended Git author/committer/tag metadata separately. Any changed input invalidates the approval. No command here uploads a report, checks credentials with a service, or grants permission to publish.
