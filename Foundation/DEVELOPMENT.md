# Current development: Alpha 0.0.93 / Driver B190

App build188 and independent Driver B190 remain unchanged. Alpha 0.0.93 adds
frame-local saved-DV opening and metadata, latest-request scrubbing, and the
native local CLI / stdio MCP interface documented in [CLIAndMCP.md](CLIAndMCP.md).
Full-file coordinate indexing and forensic source assessment are explicit
operations rather than prerequisites for playback. Preview coordinates are
estimates until an exact scan establishes them; original captures stay intact.

The CLI exposes 66 app-owned tools. It uses a same-user local socket, bounded
worker I/O, GUI operation guards and the existing supervised STOP policy.
External sandbox path grants are session-scoped. Driver activation and physical
recovery remain interactive. Mixed-format seek metadata association remains an
open issue; a successful seek does not establish a matching inspector snapshot.

Development validation includes the complete offline package suite, native app
and CLI Release builds, operation-policy tests, socket idle/backpressure/shutdown
checks, and installed CLI/MCP initialization, listing and read-only status.
These are software checks. Earlier bounded B190 NTSC capture evidence remains
scoped to its tested development installation; no new physical qualification
is claimed for Alpha 0.0.93. Live driver unload and full-tape endurance remain
unqualified.

The public source is a reviewed content projection with portable signing and
privacy transformations. Canonical public PROJECT-STATUS.json records source
progress independently from the latest downloadable engineering package.
Development signing does not establish notarized or SIP-on distribution.
