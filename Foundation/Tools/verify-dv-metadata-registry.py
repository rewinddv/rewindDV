#!/usr/bin/env python3
"""Public source geometry audit; no private registry or standards corpus required."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/RewindDVArchiveCore/DVPackCatalog.swift").read_text()
pattern = r'Geometry\(pack: (0x[0-9A-Fa-f]+), byte: (\d+), mask: (0x[0-9A-Fa-f]+), shift: (\d+), width: (\d+), aggregate: (true|false), id: "([^"]+)"'
actual = {}
for pack, byte, mask, shift, width, aggregate, identifier in re.findall(pattern, source):
    assert identifier not in actual, f"Duplicate component {identifier}"
    actual[identifier] = (int(pack, 16), int(byte), int(mask, 16), int(shift), int(width), aggregate == "true")
# The sealed 210-row corpus is immutable historical evidence. Six additive
# VAUX text-header coordinates have separate reconciliation provenance.
assert len(actual) == 216
added = {key: value for key, value in actual.items() if key.startswith("68.")}
assert added == {
    "68.tdp_low_raw": (0x68, 1, 0xFF, 0, 8, False),
    "68.tdp_high_raw": (0x68, 2, 0x01, 0, 1, False),
    "68.option_raw": (0x68, 2, 0x0E, 1, 3, False),
    "68.text_type_raw": (0x68, 2, 0xF0, 4, 4, False),
    "68.text_code_raw": (0x68, 3, 0xFF, 0, 8, False),
    "68.pc4_uninterpreted_raw": (0x68, 4, 0xFF, 0, 8, False),
}
assert sum(value[-1] for value in actual.values()) == 2
for pack in {value[0] for value in actual.values()}:
    for byte in range(1, 5):
        covered = 0
        for candidate, pc, mask, shift, width, aggregate in actual.values():
            if candidate != pack or pc != byte or aggregate:
                continue
            assert mask == ((1 << width) - 1) << shift
            assert not covered & mask, f"Overlap {pack:02X} PC{byte}"
            covered |= mask
        assert covered == 0xFF, f"Unaccounted bits {pack:02X} PC{byte}"
print("PASS: 216 source geometries; complete disjoint payload coverage; six provisional VAUX text coordinates")
print("Private historical registry seals/dispositions are excluded; this audit establishes software geometry only.")
