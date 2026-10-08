#!/usr/bin/env python3
"""Bounded offline regressions against the real RewindDVInspect executable.

Only new synthetic FIFOs under the supplied scratch directory are created.
Each probe is a child process so a blocking open cannot hang the test suite.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

if len(sys.argv) != 3:
    raise SystemExit("Usage: verify-dv-nonregular-input.py RewindDVInspect scratch-directory")
inspect = str(Path(sys.argv[1]).resolve(strict=True))
scratch = Path(sys.argv[2])
scratch.mkdir(parents=True, exist_ok=True)
failed = False
for command, name in [("export-closed-flight", "flight.ndjson"),
                      ("resume-publication", "verification.json.partial")]:
    with tempfile.TemporaryDirectory(prefix="dv-nonregular-", dir=scratch) as directory:
        os.mkfifo(Path(directory) / name, 0o600)
        try:
            result = subprocess.run([inspect, command, directory], capture_output=True,
                                    text=True, timeout=3, check=False)
        except subprocess.TimeoutExpired:
            print(f"FAIL: {command} blocked opening {name}", flush=True)
            failed = True
            continue
        if result.returncode != 1 or "source is not a regular file" not in result.stderr:
            print(f"FAIL: {command}: exit {result.returncode}: {result.stderr}", flush=True)
            failed = True
        else:
            print(f"PASS: {command} promptly rejects FIFO {name}", flush=True)
raise SystemExit(1 if failed else 0)
