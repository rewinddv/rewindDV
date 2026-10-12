# DVRescue interoperability fixtures

Source: https://github.com/mipops/dvrescue
Commit: `5cead7a5dae4ec7ffdf24115c8e3bc6d9c05c033`

Unmodified copies:

- `dvrescue.xsd`: `tools/dvrescue.xsd`, schema version 1.2.1.
- `upstream-many-attributes.xml`:
  `Source/GUI/dvrescue/dvrescue.qmltests/testdata/many_attributes.dv.dvrescue.xml`.

BSD-3-Clause; full license and attribution in Foundation/NOTICE.md and bundled
ThirdPartyNotices.txt. The fixture contains the upstream author's source-path
string; it is inert reference data, not a path to access.

Tests validate our exported NTSC/PAL XML using `/usr/bin/xmllint --nonet` and this
pinned schema. The schema is not downloaded at runtime and the app does not
shell out to xmllint. External imports use bounded, no-entity structural parsing;
they are not represented as full-XSD-certified or independently proven findings.

The identifying upstream report remains private and byte-for-byte unchanged.
The importer regression now uses `synthetic-many-attributes.xml`, newly authored
by Rewind Digital under Apache-2.0 with invented values and the schema vocabulary.
It covers every attribute name present in the retained report, sparse frame groups,
continuity/concealment flags, and frame aggregates versus per-DIF detail.
The synthetic creator label does not claim DVRescue generated this report.
The original report is excluded from the proposed source export.
