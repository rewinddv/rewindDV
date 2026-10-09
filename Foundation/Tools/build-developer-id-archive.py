#!/usr/bin/env python3
"""Build and verify a hardware-capable Developer ID archive with supplied profiles.

No Apple credentials are accepted. No notarization, launch, installation, remote
Git write or publication is performed. Existing profiles are never replaced.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parents[1]
spec = importlib.util.spec_from_file_location("distribution_verifier", TOOLS / "verify-developer-id-candidate.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-profile", type=Path, required=True)
    parser.add_argument("--driver-profile", type=Path, required=True)
    parser.add_argument("--certificate-sha1", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Expected a ten-character Apple team identifier")
    out = args.output.resolve()
    if out == REPO or REPO in out.parents:
        parser.error("Build output must be outside the checkout")
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
               PYTHONDONTWRITEBYTECODE="1")
    git = lambda *words: subprocess.check_output(["git", *words], cwd=REPO, env=env, text=True).strip()
    if git("status", "--porcelain", "--untracked-files=all"):
        parser.error("Commit the source and build tools before creating a distribution archive")
    source = git("rev-parse", "HEAD")
    source_tree = git("rev-parse", "HEAD^{tree}")
    profiles = {}
    now = datetime.datetime.now(datetime.timezone.utc)
    store = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    for kind, path, bundle in (("app", args.app_profile, verifier.APP_ID),
                              ("driver", args.driver_profile, verifier.DRIVER_ID)):
        raw = path.read_bytes()
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)]))
        checks = verifier.profile_checks(profile, bundle, args.certificate_sha1, now, args.team_id)
        if not all(checks.values()):
            parser.error(kind + " profile rejected: " + json.dumps(checks))
        expected = plistlib.loads((REPO / "Foundation/Config" /
                                  ("App.entitlements" if kind == "app" else "Driver.Release.entitlements")).read_bytes())
        for key, value in expected.items():
            if key in profile["Entitlements"]:
                if not verifier.authorized(value, profile["Entitlements"][key]):
                    parser.error(kind + " profile does not authorize " + key)
            elif key not in {"com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write"}:
                parser.error(kind + " profile is missing " + key)
        target = store / (profile["UUID"] + ".provisionprofile")
        if target.exists() and target.read_bytes() != raw:
            parser.error("Refusing to replace existing profile " + str(target))
        profiles[kind] = {"name": profile["Name"], "uuid": profile["UUID"],
                          "sha256": hashlib.sha256(raw).hexdigest(), "input": str(path.resolve())}
    out.mkdir(parents=True, exist_ok=False)
    for name in ["tmp", "clang", "swift", "logs"]:
        (out / name).mkdir()
    env.update(TMPDIR=str(out / "tmp"), CLANG_MODULE_CACHE_PATH=str(out / "clang"),
               SWIFT_MODULECACHE_PATH=str(out / "swift"))
    # Add only the selected, verified profiles to Xcode's normal profile store.
    store.mkdir(parents=True, exist_ok=True)
    for kind, path in (("app", args.app_profile), ("driver", args.driver_profile)):
        target = store / (profiles[kind]["uuid"] + ".provisionprofile")
        if not target.exists():
            with target.open("xb") as f:
                f.write(path.read_bytes())
    commands = []

    def run(label, command):
        log = out / "logs" / (label + ".log")
        start = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with log.open("wb") as f:
            result = subprocess.run(command, cwd=REPO, env=env, stdout=f, stderr=subprocess.STDOUT)
        commands.append({"command": command, "cwd": str(REPO), "start_utc": start,
                         "exit": result.returncode, "log_sha256": verifier.sha256(log)})
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise SystemExit(label + " failed; inspect " + str(log))

    archive = out / "RewindDV.xcarchive"
    run("archive", ["xcodebuild", "-project", "Foundation/RewindDV.xcodeproj", "-scheme", "RewindDV",
                    "-configuration", "Release", "DEVELOPMENT_TEAM=" + args.team_id, "-destination", "generic/platform=macOS",
                    "-derivedDataPath", str(out / "derived"), "-archivePath", str(archive),
                    "REWINDDV_APP_DISTRIBUTION_PROFILE=" + profiles["app"]["name"],
                    "REWINDDV_DRIVER_DISTRIBUTION_PROFILE=" + profiles["driver"]["name"],
                    "CLANG_MODULE_CACHE_PATH=" + str(out / "clang"),
                    "SWIFT_MODULECACHE_PATH=" + str(out / "swift"), "archive"])
    app = archive / "Products/Applications/RewindDV.app"
    run("verify", [sys.executable, "-B", str(TOOLS / "verify-developer-id-candidate.py"),
                   str(app), str(out / "verification"), "--certificate-sha1", args.certificate_sha1, "--team-id", args.team_id])
    verification = json.loads((out / "verification/verification.json").read_text())
    for row in verification["targets"]:
        if row["profile_sha256"] != profiles[row["target"]]["sha256"]:
            raise SystemExit("Embedded profile differs from the selected input: " + row["target"])
    if git("rev-parse", "HEAD") != source or git("status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("Source changed during build; candidate is not accepted")
    result = {"source_commit": source, "source_tree": source_tree, "branch": git("branch", "--show-current"),
              "clean_source": True, "archive": str(archive), "profiles": profiles,
              "certificate_sha1": args.certificate_sha1.upper(), "team_id": args.team_id,
              "verification": verification,
              "notarized": False, "installed": False}
    (out / "provenance.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Verified Developer ID archive:", archive)
    print("Source:", source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
