# Known limits

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

Source availability is separate from official binary availability. The qualified
private candidate uses development signing and profiles and is not approved for
public distribution. See [INSTALLATION-PLAN](INSTALLATION-PLAN.md).
