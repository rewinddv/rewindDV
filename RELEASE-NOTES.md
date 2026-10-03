# Alpha 0.0.77 source release notes

Application source: `02ebc9eec11448c951fbacdd62b179f28a920f45`.
Retained driver source: `67c5e03f8fd6387a34322d373523f32cf53dc2a5`, Build183.
The export's unsigned build is distinct from the unchanged qualified binaries.

The capture-start correction reserves foreground ownership before joining an
existing device query. It prevents background observation from overtaking that
reservation, rechecks cancellation and route, and submits receive once. The
receiver startup allowance begins after the query join. A rejected submission
does not clean up another session or borrow its final counters. Cancellation and
rejection wording avoid false saved-media and new STOP-obligation claims;
existing STOP uncertainty is preserved until appropriate proof resolves it.

The 2026-10-02 targeted retest passed the first-attempt manual, cancellation,
follow-up and idle-reconnect scenarios. Saved files finalized and representative
playback showed no operator-noticed audiovisual issue. Physical query overlap
and waiting cancellation were not exercised. The historical rejection owner and
marked-frame causes remain unresolved. Details and quality caveats are in
[COMPATIBILITY](COMPATIBILITY.md) and [KNOWN-LIMITATIONS](KNOWN-LIMITATIONS.md).

This snapshot retains the preceding address representation, interrupt formatter,
rational clock and metadata implementation work with required Apache/BSD/MIT
notices. The admission delta adds no third-party dependency or effective license
change. No original capture or historical qualification result is rewritten.

The source package keeps reviewed synthetic fixtures, portable signing
configuration and a generic icon. It contains no private Git history, signed
application, development profile or original recording. An initial public import
will be a new source snapshot, not the private development branches or tags.
