# Known limitations

Alpha 0.0.94 / application build 188 / independent Driver B192 includes the integrated IEC pack classifier, interpretation provenance and epoch-aware mixed NTSC/PAL archive model. Software inventory covers all 256 pack IDs and 274 layout variants, including reserved, unassigned and opaque cases; this is not complete semantic support or IEC certification. Raw pack bytes, conflicting observations and unknown regions remain preserved. VAUX 0x61 fixed-bit interpretation remains unresolved.

Source-bound epochs carry physical ordinals, byte extents and rational cadence through acquisition maps, metadata reports, review ranges and filmstrip/contact-sheet consumers. Lossless reviewed-range exports split at recording-system boundaries and preserve ordered source bytes. Mixed-system single-file merge and film/container output reject with a segmented-export alternative. HDV uses a separate representation and gains no physical qualification from DV archive tests.

The accepted source passed 527 Swift Testing tests and 14 XCTest cases, receive ownership/lifecycle and storage tests, and an unsigned Release app/driver build. Native mixed playback and all-frame archive/export validation were measured offline. Rendered archive/metadata components were exercised in an isolated host; the full signed application UI, exact signed app-driver negotiation, Driver192 physical acquisition, PAL/HDV capture and full-tape endurance remain unqualified. Publication tests and artifact provenance report the exact public-source reruns separately.

CLI/MCP external path grants are session-scoped. Physical recovery and driver activation remain interactive.

See [current development and latest public download](README.md) for independent
lifecycle identities. Current bounded development evidence is summarized in
[COMPATIBILITY](COMPATIBILITY.md). The earlier B183 evidence below remains
historical; neither establishes full-tape endurance nor qualifies the downloadable
artifact.

Normal capture STOP has bounded positive receive-retirement evidence in earlier
B190 development. Live DriverKit extension disable/unload, hot replacement and
reboot-free removal remain unqualified. Follow the shutdown/restart maintenance
procedure; never use global extension disable as a capture-session STOP.

Startup/reset behavior, earlier device disappearance, full-tape endurance,
provider-loss during capture, sleep/wake and physical PAL/HDV capture remain open
areas. No continuing reset or active uncertainty occurred during the current
bounded captures. Retained gaps and unknown source quality remain authoritative.

- Saved raw DV25 NTSC/PAL playback and transitions are validated offline. Physical
  PAL capture, HDV playback and broader device/audio-format transitions remain
  unqualified. Invalid DV boundaries are rejected rather than guessed past.
- Inspector source fields share an identified sampled frame (twice per second
  while playing, immediately invalidated at a system change). Pause to inspect
  the selected frame. Missing or conflicting metadata remains unavailable.
- Post-capture DV/HDV processing bounds temporary lifetimes. This does not promise
  a fixed total app footprint or zero system swap. The cancelled receive-task
  Stop path can suppress intermediate processing progress; the final result
  still arrives.

The targeted Alpha 0.0.77 scenarios passed on the configuration in
[COMPATIBILITY](COMPATIBILITY.md). This is not complete driver qualification.

- Physical observer/query overlap with reserved capture ownership was
  unexercised. Physical cancellation while waiting was not run because no
  waiting state was encountered. One-second snapshots cannot exclude a shorter
  transient wait. Deterministic regressions and the isolated native UI check
  cover these paths offline.
- The exact owner responsible for the earlier Alpha 0.0.76 startup rejection
  remains unresolved. The independently reproduced admission race correction
  does not establish the historical incident's cause.
- Natural end-of-tape, hour-long endurance, other hardware/formats and
  active-capture disconnect/power loss remain unqualified. Blank video or absent
  timecode does not establish EOT.
- Current source includes reviewed driver ownership and cancellation-lifetime
  hardening. Live global unload and broader physical timing coverage remain
  unqualified; compilation and host tests do not establish them.
- The existing bounded diagnostic journal normally synchronizes every five
  seconds and uses one-second UI observations. Export requests a flush; recent
  records can still be lost in a crash or power failure. Support ZIPs have size
  limits and may omit or truncate records; consult their manifests.

Every clip in the targeted retest retained two DBC changes after empty packets
and one terminal partial frame. Reported host-ring drops and raw transport-gap
events were zero, but hardware continuity and exact missing-frame counts remain
unknown. These counters do not prove pristine content or universal lossless capture.

The first clip's frame 5 (about 0.167 seconds) contains 380 nonzero video STA
blocks and 961 active audio-error sentinel observations, plus conflicting
metadata/recorded-label transitions. Its cause remains unresolved. The operator
noticed no visible or audible problem around it. An earlier Alpha 0.0.76 long
clip's frame 3597 (about 120.020 seconds) is a separate unresolved marked-frame
observation. Neither is automatically evidence for or against the admission fix.

Saved-byte/per-frame hashes establish byte consistency, not flawless audiovisual
content. Preview, source metadata, raw transport evidence and human playback
observations remain distinct. Unknown metadata is not silently repaired or
selected by majority. Performance superiority has not been established.

An ad-hoc engineering alpha is available from this repository’s [releases](https://github.com/rewinddv/rewindDV/releases). It is
not notarized. Activating its ad-hoc DriverKit extension may require disabling SIP, which reduces macOS security; ordinary offline operations require no driver activation. The
repackaged artifact has not been installed or newly physically qualified.
See [INSTALLATION-PLAN](INSTALLATION-PLAN.md) for artifact-specific instructions.
