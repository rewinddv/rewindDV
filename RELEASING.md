# Releases and source provenance

The canonical project is [rewinddv/rewindDV](https://github.com/rewinddv/rewindDV).
It retains repository ID 1382559648, formerly named rewindDV-LAB, including its
release history and fork network. The reviewed public source history was merged
without squashing into that repository. The pre-consolidation source repository
is retained at [rewindDV-source-history](https://github.com/rewinddv/rewindDV-source-history).
There is no separate active LAB channel.

## Existing releases

Existing tags, releases and binary assets are preserved. Renaming or integrating
source does not rebuild, re-sign, republish or newly qualify a binary.

| Historical tag | Download status | Source archive meaning |
| --- | --- | --- |
| `alpha-0.0.81` | Engineering prerelease; app 0.0.81, retained Driver Build183 | Original hub snapshot; application source pinned at `da62378ad47bb769a3bf7230f1d80e7fce5104e3` |
| `alpha-0.0.77` | Historical engineering prerelease, superseded by 0.0.81 | Original documentation hub snapshot, not corresponding application source |
| `alpha-0.0.63` | Driver B178 distribution withdrawn; no assets currently available | Original hub snapshot; withdrawal remains in effect |

The 0.0.81 source commit is present in this repository's merged public ancestry.
See [source provenance](SOURCE-PROVENANCE.txt) and [release notes](RELEASE-NOTES.md)
for source and binary distinctions. Versions 0.0.78–0.0.80 were intermediate
development builds, not public releases. Do not infer unavailable historical
bytes or final download counters for previously withdrawn assets.

Historical release records and files under `release/` retain prior evidence and
may use the former LAB name. Old LAB web and Git links redirect to this project;
that name must not be recreated. GitHub does not redirect hosted action references.

## Future releases

Publish future releases directly here, with tags pointing to the actual reviewed
public source commit used for that release and binaries/checksums attached as
release assets. Record application version, driver build, public source revision,
signing/distribution restrictions and the scope of validation separately.
Use [Releases](https://github.com/rewinddv/rewindDV/releases), including prereleases,
instead of assuming a latest stable release exists.

Never move an existing release tag or replace an existing asset. A correction
that changes bytes requires a separately reviewed release identity. Keep required
reviews and checks, personal-information preflight, notices, offline validation
and hardware qualification distinctions intact. Do not publish private development
history, research, captures, credentials or local diagnostic receipts.

The retained `alpha081-candidate.yml` and `alpha081-publish.yml` workflows and
their tooling are historical, version-specific publication records. They are
disabled during consolidation and remain retired: they refer to a completed
release, old repository routing and pinned artifacts. Do not re-enable or reuse
them to publish a future version. Review new tooling and its repository ID,
destination, triggers and permissions before enabling any automatic publication.
No release is created as part of consolidation.
