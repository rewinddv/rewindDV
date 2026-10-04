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

## Release identities and authority

Future releases belong only to `rewinddv/rewindDV`, repository ID **1382559648**.
Never recreate `rewindDV-LAB`. The source-history repository is an archived
reference, not a publication destination. Private development must enter through
the reviewed public export path; never merge or push private Git ancestry here.

Every future release follows this chain:

`reviewed public source commit → exact tag → release metadata → bundle identities → final archive → SHA-256 → provenance and validation`

The source must already be an ancestor of canonical public `main`. A tag must
peel to that exact full commit, including for annotated tags. The commit must
contain and build the application and driver at their normal source paths.
Documentation-only hub snapshots, unrelated roots/merges, private ancestry and
packages built from a different commit fail the gates. A documentation change on
a complete source tree does not change which committed tree is actually built.
GitHub-generated source archives are not a substitute for verified application
source provenance. Historical embedded lineage strings and SOURCE-PROVENANCE.txt
are historical evidence; the new receipt identifies the actual build commit.

Run `python3 -B tools/release_candidate.py versions` on a Mac with Xcode 27.
The tool reads existing sources; it adds no independently maintained version file:

| Identity | Authority |
| --- | --- |
| Application version | `Foundation/Config/AlphaVersion.txt`, embedded as `RewindDVAlphaVersion` |
| App bundle build and marketing version | Effective Release `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` for the app target |
| Driver build and marketing version | The same effective settings for the driver target, verified against its built Info.plist |
| Source commit/tree | Git object identities of the clean, reviewed public checkout |
| Release tag | `alpha-VERSION`, `beta-VERSION`, `rc-VERSION`, or `vVERSION` for stable |

The app version and bundle marketing version currently have different meanings;
the validator preserves that distinction. App and driver build numbers are
independent even when equal. Do not increment the driver merely to match an app
release. Do not change any version just to exercise this tooling. If a version's
tag already exists, preparation refuses it; another real release requires its
own reviewed version and authorization.

## Stage A: prepare and verify, without publication

Use a fresh full public clone with canonical `origin`, detached at the intended
full source SHA. Keep outputs and private disclosure configuration outside it.
Tracked, untracked and ignored inputs must all be clean. There is no dirty-source
or packaging-only exception. Source symlinks and Git submodules are refused until
a separate provenance policy exists for them. Build both app and driver from this one source tree;
this workflow cannot splice in a historical or separately signed driver.

The reviewed consolidation commit is the ancestry trust boundary. All new parent
histories must descend from it; unrelated/private roots and branches based before
that boundary are refused. New source paths, including subsequently deleted paths,
and new blob content are checked for private/generated inputs and common leakage
markers. New top-level source areas need an explicit policy review. These guards
do not prove that arbitrary commits descending from public history are nonprivate:
the reviewed export, content inspection and independent review remain required.

Preparation uses Python 3.9+ standard libraries, Git, Xcode 27 and Apple tools.
Build commands use a fixed system tool path and selected Xcode, with isolated
caches and no inherited compiler, signing or external xcconfig overrides.
It performs public metadata reads only and never downloads existing binaries.
No release credentials are needed. A rate limit or unavailable identity/tag check
fails closed rather than assuming permission or provenance.

Choose `source`, `tag`, `channel`, a new external `output` directory, and an external
`private_config` as described in [privacy preflight](PRIVACY.md). Do not put private
values in shell history, Git or the candidate directory. Run:

```sh
python3 -B tools/release_candidate.py prepare \
  --source "$source" --tag "$tag" --channel "$channel" \
  --output "$output" --dry-run
python3 -B tools/release_candidate.py prepare \
  --source "$source" --tag "$tag" --channel "$channel" \
  --output "$output" --private-config "$private_config"
```

Dry-run performs identity, public reachability, history, clean-source, version and
unused-tag checks without building or creating candidate files. Real preparation
runs release-tooling tests, disclosure-checker tests, the complete Swift package
suite and an unsigned Release app/dependent-driver build. It preserves full logs,
actual exit statuses and log hashes in `private-work/`; these logs are local
review evidence and must not be uploaded automatically. Also run the relevant
[offline regression harnesses](TESTING.md) for changed runtime paths and retain
separate physical qualification for actual hardware claims.

The final package name is derived, never typed independently:

`rewindDV-CHANNEL-APPVERSION-DriverDRIVERBUILD-AppBuildAPPBUILD-Unsigned.zip`

The packager reads the built app and embedded driver plists and rejects mismatched
versions. It retains licenses/notices, records every file's mode/size/SHA-256,
creates a deterministic ZIP layout, then hashes the final archive bytes and writes
the matching sidecar. Deterministic layout is not a claim of reproducible compiler
output. It creates `candidate/` containing exactly the ZIP, its `.sha256`,
`manifest.json` and `provenance.json`. Existing outputs are never overwritten.

The provenance receipt binds repository ID, commit/tree, tag/channel, independent
version fields, toolchain, validation results and the final archive/manifest hashes.
Keep its printed SHA-256 independently with the review decision. The receipt is
hash-bound evidence, not a signature or attestation from a trusted build service.
The archive is never rebuilt during verification or publication.

The supplied Stage A deliberately produces an **unsigned, unqualified candidate**.
It neither signs nor notarizes and does not install, activate or operate hardware.
Static binary/image/profile inspection and disclosure review are explicit manual
gates. Known disclosure findings abort; binary/visual inspection gaps remain
visible for the reviewer. Never upload private-work, private configuration or raw
checker findings. A signed/installable distribution needs separately reviewed
packaging and qualification support; do not re-sign these bytes and keep using the
old receipt. Signing or any other byte change invalidates the candidate.

## Stage B: guarded manual publication

There is no automated publisher or write-enabled release job. Preparation is not
publication approval. Perform this procedure only after a separately authorized
release decision, independent source/artifact/disclosure review, and explicit
agreement about the artifact's unsigned status and installation restrictions.
Stable distribution is not qualified by these tools; stable publication additionally
requires the separate distribution and hardware acceptance process.

1. Review the exact candidate and retain the reviewed provenance SHA-256 outside
   the candidate directory. Retain all local validation logs and build invocation.
   Use a dedicated canonical public checkout at the receipt's source commit.
2. Run the verifier before creating a tag. It re-resolves repository ID and name,
   rechecks public source reachability/versions, refuses an existing release or tag,
   and rehashes all final bytes:

   ```sh
   python3 -B tools/release_candidate.py verify \
     --candidate "$candidate" --receipt-sha256 "$reviewed_receipt_sha256" \
     --tag-state absent
   ```

3. Re-resolve numeric ID `1382559648` and `rewinddv/rewindDV` immediately before
   every remote write. Both must identify the same active public repository.
   Recheck that the intended tag is absent. Use the project-local Git identity
   `rewindDV <git@rewinddv.com>` to create an annotated tag at the exact source
   SHA. Push only that tag with an explicit canonical destination, without force:

   ```sh
   git tag -a "$tag" "$source" -m "Reviewed public source for $tag"
   git push git@github.com:rewinddv/rewindDV.git "refs/tags/$tag:refs/tags/$tag"
   python3 -B tools/release_candidate.py verify \
     --candidate "$candidate" --receipt-sha256 "$reviewed_receipt_sha256" \
     --tag-state present
   ```

   Never push all tags. The present-tag check accepts only the exact peeled source
   SHA. If a tag already exists before this procedure, stop; do not adopt, move or
   recreate it. The tag must remain immutable. No script in this task creates tags.
4. Write reviewed release notes containing the exact source/tag, application and
   bundle/driver identities, archive SHA-256, signing/notarization/installation
   restrictions, test results and bounded hardware qualifications. Alpha/beta/RC
   must use `prerelease=true`; only separately qualified stable releases use false.
   Do not infer an installable build or SIP-on support from an unsigned build pass.
5. Resolve identity again, verify no release exists for this tag, and create one
   **draft** release on canonical with the existing tag, explicit full source SHA
   as target, reviewed notes and correct prerelease state. Use GitHub's verify-tag
   option if using `gh release create`; do not allow implicit tag creation.
   Stop if another writer has created a release. Never edit a historical release.
6. Reverify the local sealed bytes immediately before upload. The verifier refuses
   existing releases, so complete its last present-tag run immediately before draft
   creation, then compare the independently retained hashes again with `shasum -a
   256` before uploading. List draft assets first: upload each ZIP, checksum,
   manifest and provenance exactly once, with **no clobber/overwrite option**.
   An existing same-name asset is a stop condition. Never rebuild during upload.
7. Before publishing the draft, compare live asset IDs, names, sizes, states and
   GitHub SHA-256 digests with the reviewed local files. Recheck the tag's peeled
   commit, repository ID, source and prerelease state, notes and qualification
   scope. Resolve identity again before publishing the draft. Record release and
   asset IDs and all four hashes in local evidence. Missing digests or disagreement
   blocks publication; do not download assets to paper over missing evidence.
8. Verify public release metadata and links after publication, using metadata or
   HEAD requests where sufficient. Avoid GET/download-based asset checks: download
   counts represent download events, not unique users, and checks may affect them.
   Retain final metadata and counters without attempting to control/reset them.

No credentials are passed to PR code. A future automated publisher would require a
separate security review and an explicit manual job with only repository contents
write permission; it must consume the already-reviewed bytes. It must never use
`pull_request_target`, organization-wide grants, historical asset downloads, or
untrusted code with write credentials. Current CI uses a hosted runner, read-only
contents permission, no persisted checkout credential, a SHA-pinned first-party
checkout action, and synthetic tests only. Real preparation stays on the supported
Mac/Xcode toolchain rather than silently selecting a different hosted SDK.

## Abort, recovery and immutable evidence

A failure leaves local evidence for investigation and grants no release approval.
Before any remote publication, abandon a failed candidate and use a new output
directory after fixing the cause. Any input change invalidates the old review.
After tag or draft creation, pause and inspect concurrent activity; never roll
back by moving/deleting a tag or replacing an asset. Resolve partial publication
through explicit maintainer review and prefer a new release identity when bytes
change. Never replace already-published assets. If an artifact must change, publish
a new reviewed version/release; do not silently substitute bytes.

The retained `alpha081-candidate.yml`, `alpha081-publish.yml`, their scripts and
files under `release/` are historical records and remain disabled/retired. Their
old routing, retained-binary downloads, tag-at-tooling-commit behavior and signed
artifact assumptions are not part of the new process. Never re-enable or reuse
them. No software release, tag or binary upload is created by this cleanup.

API semantics: [GitHub releases](https://docs.github.com/en/rest/releases/releases),
[annotated tags](https://docs.github.com/en/rest/git/tags), and
[workflow token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).
