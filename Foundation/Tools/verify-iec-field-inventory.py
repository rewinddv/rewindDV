#!/usr/bin/env python3
"""Check executable IEC inventory geometry, not normative correctness or tape data.

Input: RewindDVInspect iec-field-inventory > inventory.json
"""
import collections
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    inventory = json.load(source)
packs = inventory["packs"]
assert sorted(p["header"] for p in packs) == list(range(256))
counts = collections.Counter(p["allocation"] for p in packs)
assert counts == {"named": 131, "reserved": 29, "unassigned": 80,
                  "maker-code": 1, "maker-defined": 15}, counts
variants = 0
for pack in packs:
    assert bool(pack["variants"]) == (pack["allocation"] not in ("reserved", "unassigned")), pack["header"]
    for variant in pack["variants"]:
        variants += 1
        covered = [0] * 5
        ids = set()
        for field in variant["layout"]:
            assert field["id"] not in ids, (pack["header"], field["id"])
            ids.add(field["id"])
            assert field["reference"].startswith("PRIMARY_STANDARD:"), field
            for part in field["slices"]:
                byte, shift, width = part["byte"], part["shift"], part["width"]
                assert 1 <= byte <= 4 and width > 0 and shift >= 0 and shift + width <= 8
                mask = ((1 << width) - 1) << shift
                # Intentional aliases: patent conversion and raw TAG_CONT parts.
                assert not covered[byte] & mask or (pack["header"], field["id"]) in {
                    (0x70, "AGC_DB_CANDIDATE"), (0x0f, "FMODE"), (0x0f, "RMODE")
                }, (pack["header"], field["id"], "overlap")
                covered[byte] |= mask
        assert covered[1:] == [255] * 4, (pack["header"], "unaccounted bits", covered)
print(f"PASS: 256 unique allocations; {variants} executable layout variants; all payload bits accounted; no unintended overlaps")
print("This checks layout coverage. Opaque containers and source disputes remain unresolved semantics.")
