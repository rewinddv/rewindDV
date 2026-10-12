# Recorded DV metadata and native inspector

Capture and Playback use the same immutable, frame-local metadata report. The
native inspector exposes all observed fields supported by the current decoder,
with readable names such as Auto exposure mode, Automatic gain control and White
balance mode. Optional packs, unavailable values, reserved codes and conflicting
observations remain explicit; another frame never supplies a missing setting.

Overview orders General, Video, Apple presentation geometry, Audio, recorded
camera packs 0x70/0x71/0x7F, Recorded motion / lens, then Source error summary.
Additional technical and sequence sections are individually expandable.
Metadata provides category filtering, readable-name/value/pack/reference search,
optional format checks and bounded pages. Evidence retains original bytes,
source positions, validity, recording context and interpretation provenance.
Inspector tabs, searches, filters and pages persist across responsive resizing.
The Playback file chooser owns its presentation and permits retry and selection
without restarting the application.

The catalog classifies all 256 pack IDs and 274 layout variants. Classification
coverage is distinct from complete semantic decoding or IEC certification.
Interpretation version 6 includes supported recorded camera/motion/lens fields,
SMPTE binary-group/clock/date companions, qualified shutter timing, bounded user
text, line and teletext information, catalogue pairs and partial ISRC data.
Complementary coordinate, catalogue, ISRC and shading forms have separate conflict
scopes; contradictory copies within one form still produce warnings.

Evidence uses PRIMARY_STANDARD IEC 61834-4:1998 with AMD1:2010, SMPTE ST 314M-2005,
ST 12-1:2014 and ST 309:2012; manufacturer references and corroborated open-source
behavior remain separately identified. MediaInfo and DVRescue implementation
behavior does not replace a primary standard. No licensed standards documents,
private reference corpus or captured footage are distributed with this source.

See [the remaining decoding boundaries](MetadataDecodingLimits.md). Temporal
continuity/concealment analysis requires a source sequence and remains distinct
from a single-frame inspector. Metadata and preview never rewrite original DV.
