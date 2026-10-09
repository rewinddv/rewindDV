#!/usr/bin/env python3
"""Inspect a Developer ID app and DEXT independently of the archive build.

Only public certificates and profile diagnostics are written. Private keys and
notarization credentials are never read. Does not launch or install the app.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
from pathlib import Path
import plistlib
import subprocess
import sys

APP_ID = "net.rewinddigital.RewindDV"
DRIVER_ID = APP_ID + ".Driver"
PCI = [{"IOPCIPrimaryMatch": "0x590111C1"}]
MACH_MAGIC = {bytes.fromhex(x) for x in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca")}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def authorized(actual, allowed):
    if isinstance(actual, dict):
        return isinstance(allowed, dict) and all(
            k in allowed and authorized(v, allowed[k]) for k, v in actual.items())
    if isinstance(actual, list):
        return isinstance(allowed, list) and all(
            any(authorized(v, candidate) for candidate in allowed) for v in actual)
    if isinstance(actual, str):
        return isinstance(allowed, str) and fnmatch.fnmatchcase(actual, allowed)
    return type(actual) is type(allowed) and actual == allowed


def profile_checks(profile, bundle_id, certificate_sha1, now, expected_team):
    grants = profile.get("Entitlements", {})
    expected_id = expected_team + "." + bundle_id
    utc = lambda value: value.replace(tzinfo=datetime.timezone.utc)
    dates_valid = (isinstance(profile.get("CreationDate"), datetime.datetime)
                   and isinstance(profile.get("ExpirationDate"), datetime.datetime)
                   and utc(profile["CreationDate"]) <= now < utc(profile["ExpirationDate"]))
    return {
        "team": profile.get("TeamIdentifier") == [expected_team]
                and grants.get("com.apple.developer.team-identifier") == expected_team,
        "explicit_app_id": grants.get("com.apple.application-identifier") == expected_id,
        "macos_distribution": profile.get("Platform") == ["OSX"],
        "all_devices": profile.get("ProvisionsAllDevices") is True
                       and "ProvisionedDevices" not in profile,
        "dates": dates_valid,
        "certificate": certificate_sha1.upper() in [
            hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])],
        "no_debug_grants": not grants.get("get-task-allow", False)
                           and not grants.get("com.apple.security.get-task-allow", False),
        "approved_pci": bundle_id != DRIVER_ID or
                        grants.get("com.apple.developer.driverkit.transport.pci") == PCI,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--certificate-sha1", required=True)
    parser.add_argument("--team-id", required=True)
    args = parser.parse_args()
    expected_team = args.team_id
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team):
        parser.error("Expected a ten-character Apple team identifier")
    repo = Path(__file__).resolve().parents[2]
    out = args.output.resolve()
    if out == repo or repo in out.parents:
        parser.error("Verification output must be outside the checkout")
    out.mkdir(parents=True, exist_ok=False)
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    commands = []

    def run(label, command):
        result = subprocess.run(command, capture_output=True)
        (out / (label + ".stdout")).write_bytes(result.stdout)
        (out / (label + ".stderr")).write_bytes(result.stderr)
        commands.append({"command": command, "exit": result.returncode,
                         "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                         "stderr_sha256": hashlib.sha256(result.stderr).hexdigest()})
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        return result

    now = datetime.datetime.now(datetime.timezone.utc)
    from product_identity import check, bundle_identity
    identity = check(repo)
    expected_alpha = identity['product_version']
    expected_driver = str(identity['driver_build'])
    expected_app = str(identity['app_build'])
    bundle_identity(args.app.resolve(), identity)
    app = args.app.resolve()
    driver = app / "Contents/Library/SystemExtensions" / (DRIVER_ID + ".dext")
    rows = []
    for kind, bundle, bundle_id, ent_name, plist_path, profile_path, exe, arch, platform in (
        ("driver", driver, DRIVER_ID, "Driver.Release.entitlements", driver / "Info.plist",
         driver / "embedded.provisionprofile", driver / DRIVER_ID, "arm64e", "DRIVERKIT"),
        ("app", app, APP_ID, "App.entitlements", app / "Contents/Info.plist",
         app / "Contents/embedded.provisionprofile", app / "Contents/MacOS/RewindDV", "arm64", "MACOS"),
    ):
        strict = run(kind + "-strict", ["codesign", "--verify", "--strict", "--verbose=4", str(bundle)])
        signature = run(kind + "-signature", ["codesign", "-d", "--verbose=4", str(bundle)])
        text = (signature.stdout + signature.stderr).decode(errors="replace")
        ent = run(kind + "-entitlements", ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)])
        signed = plistlib.loads(ent.stdout)
        decoded = run(kind + "-profile", ["security", "cms", "-D", "-i", str(profile_path)])
        profile = plistlib.loads(decoded.stdout)
        info = plistlib.loads(plist_path.read_bytes())
        source = plistlib.loads((repo / "Foundation/Config" / ent_name).read_bytes())
        expected_signed = dict(source, **{
            "com.apple.application-identifier": expected_team + "." + bundle_id,
            "com.apple.developer.team-identifier": expected_team})
        checks = profile_checks(profile, bundle_id, args.certificate_sha1, now, expected_team)
        checks["exact_signed_entitlements"] = signed == expected_signed
        checks["signed_entitlements_authorized"] = all(
            authorized(value, profile["Entitlements"][key]) if key in profile["Entitlements"]
            else key in {"com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write"}
            for key, value in signed.items())
        cert_prefix = str(out / (kind + "-certificate-"))
        extraction = run(kind + "-certificates", ["codesign", "-d", "--extract-certificates=" + cert_prefix, str(bundle)])
        cert = Path(cert_prefix + "0")
        leaf_sha1 = hashlib.sha1(cert.read_bytes()).hexdigest().upper()
        trust = run(kind + "-certificate-trust", ["security", "verify-cert", "-p", "codeSign", "-c", str(cert)])
        metadata = run(kind + "-certificate-metadata", ["openssl", "x509", "-inform", "DER", "-in", str(cert), "-noout", "-subject", "-issuer", "-dates"])
        arches = run(kind + "-architectures", ["lipo", "-archs", str(exe)])
        build = run(kind + "-platform", ["xcrun", "vtool", "-show-build", str(exe)])
        checks.update({
            "strict_signature": strict.returncode == 0,
            "certificate_trust": trust.returncode == 0,
            "expected_certificate": extraction.returncode == 0 and leaf_sha1 == args.certificate_sha1.upper(),
            "developer_id": "Authority=Developer ID Application:" in text and "Signature=adhoc" not in text,
            "team_signature": "TeamIdentifier=" + expected_team in text,
            "hardened_runtime": "(runtime)" in text,
            "secure_timestamp": "Timestamp=" in text,
            "bundle_id": info["CFBundleIdentifier"] == bundle_id,
            "build": info["CFBundleVersion"] == (expected_app if kind == "app" else expected_driver),
            "architecture": arches.stdout.decode().strip() == arch,
            "platform": "platform " + platform in build.stdout.decode(),
        })
        if kind == "app":
            checks.update(alpha=info.get("RewindDVAlphaVersion") == expected_alpha,
                          driver_requirement=str(info.get("RewindDVRequiredDriverBuild")) == expected_driver,
                          hardware_capable="RewindDVOfflineOnly" not in info)
        else:
            personality = info["IOKitPersonalities"]["RewindDVFoundationController"]
            checks.update(effective_device_match=int(personality["IOPCIMatch"], 16) == 0x590111C1,
                          driver_marker=str(personality["FoundationBuildNumber"]) == expected_driver)
        rows.append({"target": kind, "bundle": str(bundle), "checks": checks,
                     "executable_sha256": sha256(exe), "profile_sha256": sha256(profile_path),
                     "profile_uuid": profile["UUID"], "profile_name": profile["Name"],
                     "profile_expiration": str(profile["ExpirationDate"]),
                     "certificate_sha1": leaf_sha1, "signed_entitlements": signed,
                     "profile_entitlements": profile["Entitlements"]})
    nested = []
    for p in sorted(app.rglob("*")):
        if not p.is_file() or p.is_symlink():
            continue
        with p.open("rb") as f:
            magic = f.read(4)
        if magic not in MACH_MAGIC:
            continue
        result = run("nested-" + str(len(nested)), ["codesign", "--verify", "--strict", "--verbose=4", str(p)])
        nested.append({"path": str(p.relative_to(app)), "sha256": sha256(p), "exit": result.returncode})
    deep = run("app-deep", ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)])
    expected_executables = {"Contents/MacOS/RewindDV",
                            "Contents/Library/SystemExtensions/" + DRIVER_ID + ".dext/" + DRIVER_ID}
    known_nested = {item["path"] for item in nested} == expected_executables
    success = known_nested and all(all(row["checks"].values()) for row in rows) and bool(nested) and all(
        x["exit"] == 0 for x in nested) and deep.returncode == 0
    report = {"result": "PASS" if success else "FAIL", "checked_utc": now.isoformat(),
              "targets": rows, "nested_executables": nested, "only_expected_nested_executables": known_nested,
              "scope": "Static Developer ID signing/profile verification; no installation or hardware qualification"}
    (out / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
