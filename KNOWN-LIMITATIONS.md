# Known limits

Current: Alpha 0.0.81 / Build183. The earlier hardware evidence below is retained
as historical scope, not expanded qualification.

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
- Historical independent controller/coordinator teardown, completion lifetime
  and AV/C reset/ownership review gaps remain open. Compilation and host tests
  do not close those gaps or establish every real-device timing behavior.
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

A separately packaged ad-hoc engineering alpha is available through LAB. It is
not notarized and requires disabling SIP, which reduces macOS security. The
repackaged artifact has not been installed or newly physically qualified.
See [INSTALLATION-PLAN](INSTALLATION-PLAN.md) for artifact-specific instructions.
