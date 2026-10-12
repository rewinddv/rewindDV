# Recorded metadata decoding boundaries

The 0.1.18 completion pass uses PRIMARY_STANDARD IEC 61834-4:1998 with AMD1:2010,
SMPTE ST 314M-2005, ST 12-1:2014 and ST 309:2012. The supplied national adoption
is the effective Part 4 reference. Retained MediaInfoLib d49c3bf and DVRescue
 e32862853120fbefcd8866ea22037fdbec6f4564 are implementation evidence, not primary
standards. All raw observations remain available. A reserved code or a recorded
no-information sentinel is not an omitted known setting.

| Field or payload | What remains unresolved | Evidence needed |
| --- | --- | --- |
| Camera 0x70 automatic gain control | Final IEC dB equation is absent. Recorded code is shown; Sony patent conversion is provisional. | Verified equation/erratum or established device calibration; IEC §10.1. |
| Camera 0x71 horizontal pan, 0x77 detail, 0x7E knee slope | Disputed range/endpoint/encoding in supplied text; ordinary undisputed values remain supported. | Authoritative erratum or explicitly selected corroborated profile; IEC §§10.2, 10.8, 10.15. |
| Professional pedestal/gamma/detail/flare presets and professional shutter selection | Absolute preset calibration and consumer/professional selection are not established by arbitrary SD bytes. | Recorded application profile and calibration; IEC camera clauses. |
| Consumer shutter exposure | Horizontal-period count is known. Seconds from a matching SD profile are a provisional cross-standard inference. | Independently acquired applicable IEC Part 2 timing/profile. |
| User bits: arbitrary data and page/line multiplex | Arbitrary bytes have no universal meaning. ST 262 page/line contents and active ISO 2022 designation are not established. | Referenced ST 262 and recorded encoding profile. |
| ST 309 dates / VISC | Date century absent; MJD prose/table disagree. VISC physical unit absent; interpolation is qualified. | Century evidence, erratum and a primary unit definition, respectively. |
| National, ISO 2022, font and graphic text | Only complete printable US-primary queues are rendered. Other glyph/control states remain raw. | Applicable national/ISO character tables and state model; IEC §3.9 and text clauses. |
| Captions and teletext | Caption bytes/parity/presence are known. Full rendered captions, subsequent teletext packet boundaries and glyphs are unresolved. | Applicable EIA/EBU/teletext packet and character references. First established teletext ID/information is supported. |
| Transparent VBI Video ID / wide-screen signalling / EDTV2 | Stored widths and signal bits are extracted; referenced broadcast signal meanings are unresolved. | Applicable VBI signal tables/profile; IEC §9.7. |
| ISRC country/owner | Five six-bit character codes lack a retained alphabet. Recorded year suffix and five-digit serial are supported. | ISO 3901 code mapping applicable to this representation; IEC §4.8. |
| MPEG SB_SIZE / SB_LEAK_RATE / STREAM_TYPE / SERVICE_ID | Raw layouts remain; external descriptor units, stream vocabulary and service-byte significance are not qualified for SD frame inspection. | ETS 300 468, ISO/IEC 13818-1 and applicable recorded MPEG/PMT profile; IEC amendment §§13.1, 13.2, 13.6. |
| Topic/0x9B/0xFF source discrepancies | Conflicting enumeration, diagram/prose or OPTION/padding allocation remain explicit. | Authoritative erratum/profile resolving the conflict. |
| Manufacturer code/options and cassette random number | Assignments, payload meaning and numbering procedure are not defined by Part 4. | Manufacturer documentation and recorded profile. |
| Memory-in-cassette queues / HDV ETN and MPEG metadata | Lower-level layouts do not establish transport/application context; this scanner inspects SD DIF frames. | Separate acquisition/profile support and relevant referenced specifications. |
| LTC/VITC modulation-specific clock flag | DV bytes do not establish LTC/VITC modulation. | Original clock modulation/profile evidence; ST 12-1. |

A field also remains unselected when its companion is absent, invalid, from
another recording area, or contradictory. That boundary protects recorded truth;
it must not be filled using another frame, majority voting or an assumed device.
Whole-file continuity and concealment findings require temporal assessment and
remain separate from a single-frame camera inspector. Manufacturer model and
capture transport state never establish camera settings that were not recorded.
