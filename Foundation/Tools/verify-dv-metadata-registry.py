#!/usr/bin/env python3
"""Read-only reproducibility gate; no Downloads, standards PDFs or network needed."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[1]
research = root / "Qualification/DV-Metadata-v2"
raw = (research / "registry.json").read_bytes()
expected = "1b36c773d07c2e9bdec5efe04dcb75127bd87e06ab1beb58a74f44a2a838f063"
assert hashlib.sha256(raw).hexdigest() == expected, "Registry seal differs"
registry = json.loads(raw)
dispositions = json.loads((research / "dispositions.json").read_text())
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
for component in registry["field_layouts"]:
    geometry = (int(component["pack_id"], 16), component["pc_byte"], int(component["mask"], 16), component["shift"], component["width"], component["geometry_role"] == "aggregate_observation")
    assert actual[component["id"]] == geometry, component["id"]
allowed = {"implemented", "already supported", "provisional", "conflicted/raw-only", "missing with reason"}
for source_key, reviewed_key, count in [("field_layouts", "components", 210), ("semantic_rules", "semantic_rules", 29), ("non_pack_fields", "non_pack_fields", 20), ("non_pack_assembly", "non_pack_assembly", 3)]:
    rows = dispositions[reviewed_key]
    assert len(rows) == count
    assert len({row["id"] for row in rows}) == count
    assert {row["id"] for row in rows} == {row["id"] for row in registry[source_key]}
    assert all(row["disposition"] in allowed and row["note"] for row in rows)
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
print("PASS: sealed registry; 210 sealed geometries + 6 provisional VAUX text coordinates; complete 210/29/20/3 dispositions")
