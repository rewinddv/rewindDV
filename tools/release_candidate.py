#!/usr/bin/env python3
"""Read-only GitHub gates and candidate packaging. Never publishes or signs."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

sys.dont_write_bytecode = True
REPOSITORY = "rewinddv/rewindDV"
REPOSITORY_ID = 1382559648
# Reviewed consolidation boundary; never move this merely to make a gate pass.
PUBLIC_BASE = "926b33495ca111c6aa56fd1ef6b580748877aaaf"
HISTORICAL = {"alpha-0.0.63", "alpha-0.0.77", "alpha-0.0.81"}
PROJECT = "Foundation/RewindDV.xcodeproj"
APP_ID = "net.rewinddigital.RewindDV"
OFFLINE_APP_ID = APP_ID + ".Offline"
DRIVER_ID = APP_ID + ".Driver"
DEXT = "Contents/Library/SystemExtensions/" + DRIVER_ID + ".dext"
EMBEDDED_PROFILES = {"RewindDV.app/Contents/embedded.provisionprofile",
                     "RewindDV.app/" + DEXT + "/embedded.provisionprofile"}
EXECUTABLES = {"app": "RewindDV.app/Contents/MacOS/RewindDV",
               "driver": "RewindDV.app/" + DEXT + "/" + DRIVER_ID,
               "cli": "rewinddv-cli"}
ROOTS = set(".github .gitignore ACKNOWLEDGMENTS.md ASFWDriver ASFireWire-LICENSE.txt ASFireWire-NOTICE.txt BRANDING-AND-FUNDING.md BUILDING.md COMPATIBILITY.md CONTRIBUTING.md Foundation INSTALL.md INSTALLATION-PLAN.md KNOWN-LIMITATIONS.md LICENSE NOTICE PRIVACY.md README.md RELEASE-NOTES.md RELEASING.md SOURCE-PROVENANCE.txt PROJECT-STATUS.json SOURCE-MANIFEST.json TEST-REPORT.md TESTING.md ThirdPartyNotices.txt UNINSTALL.md assets licenses release tests tools".split())


class GateError(Exception):
    pass


def require(ok, message):
    if not ok:
        raise GateError(message)


def run(args, cwd=None, env=None):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True)
    require(p.returncode == 0, "Command failed: " + args[0] + " (inspect local logs/environment)")
    return p.stdout.decode().strip()


def git(root, *args):
    return run(["git", "--no-replace-objects", "-C", str(root), *args])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    with Path(path).open("x") as f:
        f.write(json.dumps(value, indent=2, sort_keys=True) + "\n")


def destination(name, repo_id):
    require(name == REPOSITORY and repo_id == REPOSITORY_ID, "Unexpected publication destination or repository ID")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def api(path, missing=False):
    # Only public metadata GETs. No assets, credentials, writes or redirects.
    req = urllib.request.Request("https://api.github.com/" + path, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "rewindDV-release-validation",
        "X-GitHub-Api-Version": "2026-03-10"})
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        if missing and e.code == 404:
            return None
        raise GateError("GitHub metadata unavailable; fail closed (HTTP " + str(e.code) + ")") from e


def remote_state():
    by_id = api("repositories/" + str(REPOSITORY_ID))
    by_name = api("repos/" + REPOSITORY)
    for repo in [by_id, by_name]:
        destination(repo["full_name"], repo["id"])
        require(not repo["private"] and not repo["archived"] and repo["default_branch"] == "main",
                "Canonical repository is not active public main")
    refs = {}
    for line in run(["git", "ls-remote", "https://github.com/" + REPOSITORY + ".git", "refs/heads/main", "refs/tags/*"]).splitlines():
        commit, ref = line.split()
        refs[ref] = commit
    require("refs/heads/main" in refs, "Public main unavailable")
    return refs


def source_guard(root, source, public_main=None):
    require(re.fullmatch(r"[0-9a-f]{40}", source), "Use a full committed source SHA")
    require(git(root, "rev-parse", "HEAD") == source, "Checkout HEAD differs from release source")
    require(git(root, "rev-parse", "--is-shallow-repository") == "false", "Full public history required")
    require(not git(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignored"),
            "Source checkout must be clean, including ignored/untracked inputs; use a fresh clone")
    require(git(root, "remote", "get-url", "origin") in {
        "https://github.com/" + REPOSITORY + ".git", "git@github.com:" + REPOSITORY + ".git"},
        "Use a dedicated canonical public clone")
    grafts = Path(git(root, "rev-parse", "--git-path", "info/grafts"))
    require(not (grafts if grafts.is_absolute() else root / grafts).exists(), "Git grafts are not release evidence")
    git(root, "merge-base", "--is-ancestor", PUBLIC_BASE, source)
    if public_main:
        git(root, "fetch", "--no-tags", "https://github.com/" + REPOSITORY + ".git", "main")
        require(git(root, "rev-parse", "FETCH_HEAD") == public_main, "Public main changed; restart verification")
        git(root, "merge-base", "--is-ancestor", source, public_main)
    # Every new parent must descend from the public boundary. This rejects
    # imported private/unrelated roots even if their files were later deleted.
    for line in git(root, "rev-list", "--parents", source, "^" + PUBLIC_BASE).splitlines():
        source_entries(root, line.split()[0])
        parents = line.split()[1:]
        require(parents, "Unexpected new history root")
        for parent in parents:
            git(root, "merge-base", "--is-ancestor", PUBLIC_BASE, parent)
    paths = source_entries(root, source)
    for path in [PROJECT + "/project.pbxproj", "Foundation/Config/AlphaVersion.txt",
                 "Foundation/Config/DriverInfo.plist", "Foundation/Package.swift", "LICENSE", "NOTICE"]:
        require(path in paths, "Source snapshot lacks required product input: " + path)
    # Check newly introduced historical paths too, not only the final tree.
    for path in git(root, "log", "-m", "--format=", "--name-only", PUBLIC_BASE + ".." + source).splitlines():
        if path:
            safe_source_path(path)
    for line in git(root, "rev-list", "--objects", source, "^" + PUBLIC_BASE).splitlines():
        obj = line.split(" ", 1)[0]
        if git(root, "cat-file", "-t", obj) == "blob":
            data = subprocess.check_output(["git", "--no-replace-objects", "-C", str(root), "cat-file", "blob", obj])
            inspect_source_blob(data)
    return git(root, "rev-parse", source + "^{tree}")



def inspect_source_blob(data):
    # Exact reviewed historical CLI usage document: its two generic mounted-
    # volume examples are not machine/user paths. The exception is bound to the
    # complete immutable blob, never a filename, prefix or arbitrary new text.
    blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if blob == "2e3a5ff50ac69caf59ae93ba8e8716f680dea716":
        for parts in [(b"", b"Volumes", b"DV", b"Capture 001.dv"),
                      (b"", b"Volumes", b"Derived")]:
            data = data.replace(b"/".join(parts), b"/absolute/example")
    for encoding in ["utf-8", "utf-16-le", "utf-16-be"]:
        text = data.decode(encoding, errors="ignore")
        require(not re.search(r"/(?:Users|home|Volumes)/[^\s/\"<>]+|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]+|\bgh[pousr]_[A-Za-z0-9]{30,}\b", text),
                "New public history contains a private-path or credential marker; review outside Git")


def source_entries(root, commit):
    paths = []
    for line in git(root, "ls-tree", "-r", commit).splitlines():
        metadata, path = line.split("\t", 1)
        mode, kind, _ = metadata.split()
        require(mode in {"100644", "100755"} and kind == "blob", "Source symlinks/submodules require separate provenance review")
        safe_source_path(path)
        paths.append(path)
    return paths


def safe_source_path(path):
    p = Path(path)
    require(not p.is_absolute() and ".." not in p.parts and p.parts[0] in ROOTS, "Unreviewed source path")
    require(not any(x.lower() in {"research", "private", "evidence", "captures", "__pycache__"} for x in p.parts),
            "Private/generated source path")
    require(p.suffix.lower() not in {".p12", ".key", ".pem", ".provisionprofile", ".dv", ".m2t", ".mov", ".mp4", ".zip", ".dmg", ".pkg"},
            "Credential, capture or packaged input is not public release source")


def versions_from_settings(root, settings):
    identity = json.loads(run(["python3", "-B", str(root / "Foundation/Tools/product_identity.py"), "--check"], cwd=root))
    alpha = identity["product_version"]
    selected = {}
    for t in settings:
        b = t["buildSettings"]
        if b.get("PRODUCT_BUNDLE_IDENTIFIER") in {APP_ID, DRIVER_ID}:
            key = b["PRODUCT_BUNDLE_IDENTIFIER"]
            require(key not in selected or all(selected[key].get(f) == b.get(f) for f in ["CURRENT_PROJECT_VERSION", "MARKETING_VERSION"]),
                    "Conflicting duplicate bundle settings")
            selected[key] = b
    require(set(selected) == {APP_ID, DRIVER_ID}, "App and driver build settings required")
    def value(bundle, field):
        v = selected[bundle][field]
        require(re.fullmatch(r"\d+(?:\.\d+)*", v), "Unresolved version setting")
        return v
    require(value(APP_ID, "CURRENT_PROJECT_VERSION") == str(identity["app_build"]) and value(DRIVER_ID, "CURRENT_PROJECT_VERSION") == str(identity["driver_build"]), "Component settings disagree with canonical identity")
    require(value(APP_ID, "MARKETING_VERSION") == alpha and value(DRIVER_ID, "MARKETING_VERSION") == alpha, "Marketing settings disagree with product identity")
    return {"product_version": alpha, "release_channel": identity["channel"], "application_version": alpha, "app_bundle_build": value(APP_ID, "CURRENT_PROJECT_VERSION"),
            "app_bundle_version": value(APP_ID, "MARKETING_VERSION"),
            "driver_build": value(DRIVER_ID, "CURRENT_PROJECT_VERSION"),
            "driver_bundle_version": value(DRIVER_ID, "MARKETING_VERSION")}


def versions(root, env):
    settings = json.loads(run(["xcodebuild", "-project", PROJECT, "-alltargets", "-configuration", "Release",
                               "-showBuildSettings", "-json"], cwd=root, env=env))
    return versions_from_settings(root, settings)


def release_identity(v, channel, tag, signing="unsigned", offline_only=False):
    require(channel in {"alpha", "beta", "rc", "stable"}, "Unknown release channel")
    if "release_channel" in v:
        require(channel == v["release_channel"], "Channel disagrees with canonical identity")
    expected = ("v" if channel == "stable" else channel + "-") + v["application_version"]
    require(tag == expected and tag not in HISTORICAL, "Tag/version mismatch or historical tag reuse")
    require(signing in {"unsigned", "ad-hoc", "developer-id"}, "Unknown artifact signing state")
    require(type(offline_only) is bool, "Explicit offline distribution boolean required")
    require(not offline_only or signing == "ad-hoc", "Offline distribution requires ad-hoc signing")
    suffix = "DeveloperID-Notarized" if signing == "developer-id" else ("AdHoc" if signing == "ad-hoc" else "Unsigned")
    if offline_only:
        return f"rewindDV-{channel.title()}-{v['application_version']}-AppBuild{v['app_bundle_build']}-Offline-{suffix}.zip"
    return f"rewindDV-{channel.title()}-{v['application_version']}-Driver{v['driver_build']}-AppBuild{v['app_bundle_build']}-{suffix}.zip"


def tag_guard(tag, source, refs, mode, release_exists=False):
    require(tag not in HISTORICAL, "Historical tag reuse refused")
    require(not release_exists, "An existing release must never be reused")
    ref = "refs/tags/" + tag
    if mode == "absent":
        require(ref not in refs, "Existing public tag reuse refused")
    else:
        require(ref in refs and refs.get(ref + "^{}", refs.get(ref)) == source,
                "Published tag must peel to the exact reviewed source")


def bundle_versions(read, v, offline_only=False):
    app = plistlib.loads(read("RewindDV.app/Contents/Info.plist"))
    expected = {"CFBundleIdentifier": OFFLINE_APP_ID if offline_only else APP_ID, "RewindDVAlphaVersion": v["application_version"],
                "CFBundleVersion": v["app_bundle_build"], "CFBundleShortVersionString": v["app_bundle_version"]}
    require(all(str(app.get(k)) == value for k, value in expected.items()), "Built app version identity mismatch")
    if "product_version" in v:
        require(v["product_version"] == v["application_version"] == v["app_bundle_version"] == v["driver_bundle_version"], "Canonical version disagreement")
        require(app.get("RewindDVProductVersion") == v["product_version"] and app.get("RewindDVReleaseChannel") == v["release_channel"], "Canonical app metadata disagreement")
    if offline_only:
        require(app.get("RewindDVOfflineOnly") is True, "Offline package must enforce offline runtime")
        return
    require("RewindDVOfflineOnly" not in app, "Full package must not carry an offline distribution marker")
    require(str(app.get("RewindDVRequiredDriverBuild")) == v["driver_build"], "App required driver differs from embedded driver")
    driver = plistlib.loads(read("RewindDV.app/" + DEXT + "/Info.plist"))
    expected = {"CFBundleIdentifier": DRIVER_ID, "CFBundleVersion": v["driver_build"],
                "CFBundleShortVersionString": v["driver_bundle_version"]}
    require(all(str(driver.get(k)) == value for k, value in expected.items()), "Built driver version identity mismatch")
    if "product_version" in v:
        require(driver.get("IOKitPersonalities", {}).get("RewindDVFoundationController", {}).get("FoundationBuildNumber") == v["driver_build"], "Driver registry build mismatch")


def profile_paths(paths, signing, offline_only):
    found = {p for p in paths if Path(p).suffix.lower() == ".provisionprofile"}
    require(found == (EMBEDDED_PROFILES if signing == "developer-id" and not offline_only else set()),
            "Unexpected or missing embedded distribution profile")


def validate_distribution(receipt, entries):
    if receipt.get("signing") != "developer-id":
        require(receipt.get("schema", 1) == 1, "New signed schema requires Developer ID")
        return
    require(receipt.get("schema") == 2, "Developer ID requires signed provenance schema")
    for field, expected in {"notarized": True, "offline_only": False, "driver_included": True,
                            "requires_sip_disabled": False, "hardware_qualified": False,
                            "publication_authorized": False}.items():
        require(receipt.get(field) is expected, "Invalid distribution flag: " + field)
    d = receipt["distribution"]
    require(d["certificate_type"] == "Developer ID Application" and d["verification"] == "PASS", "Unverified Developer ID distribution")
    require(d["pci_primary_match"] == "0x590111C1", "Unapproved PCI grant")
    require(re.fullmatch(r"[0-9a-f]{64}", d["verification_report_sha256"]), "Missing verifier evidence digest")
    require(set(d["executables"]) == set(EXECUTABLES), "Incomplete executable identities")
    for role, path in EXECUTABLES.items():
        row = d["executables"][role]
        require(row["path"] == path and row["sha256"] == entries[path]["sha256"], "Executable digest mismatch")
        require(row["architecture"] == ("arm64e" if role == "driver" else "arm64"), "Unexpected architecture")
        require(all(row.get(k) is True for k in ("strict_signature", "secure_timestamp", "hardened_runtime")), "Executable signing verification failed")
    require(len(d["profiles"]) == 2 and {p["path"] for p in d["profiles"]} == EMBEDDED_PROFILES, "Incomplete embedded profile identities")
    for row in d["profiles"]:
        require(row["sha256"] == entries[row["path"]]["sha256"], "Embedded profile digest mismatch")
    n = d["notarization"]
    require(n["status"] == "Accepted" and re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", n["submission_id"]), "Notarization not accepted")
    require(all(re.fullmatch(r"[0-9a-f]{64}", n[k]) for k in ("submitted_zip_sha256", "log_sha256")), "Missing notarization evidence digests")
    require(all(d.get(k) == "PASS" for k in ("staple", "gatekeeper", "distribution_policy")), "Distribution assessment incomplete")


def package(stage, output, name, v, offline_only=False, signing="unsigned"):
    require(not (output / name).exists(), "Never overwrite a candidate")
    bundle_versions(lambda path: (stage / path).read_bytes(), v, offline_only)
    if offline_only:
        require(not list(stage.rglob("*.dext")), "Offline package must not contain a DriverKit extension")
    profile_paths([p.relative_to(stage).as_posix() for p in stage.rglob("*") if p.is_file()], signing, offline_only)
    manifest = []
    with zipfile.ZipFile(output / name, "x", compression=zipfile.ZIP_STORED) as z:
        for p in sorted(stage.rglob("*")):
            require(not p.is_symlink(), "Symlinks need a separately reviewed packaging policy")
            if p.is_dir():
                continue
            require(p.is_file(), "Unexpected package entry")
            rel = p.relative_to(stage).as_posix()
            data = p.read_bytes()
            mode = stat.S_IMODE(p.stat().st_mode)
            entry = zipfile.ZipInfo(rel, (2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            z.writestr(entry, data)
            manifest.append({"path": rel, "mode": mode, "bytes": len(data), "sha256": sha(data)})
    digest = file_sha(output / name)
    (output / (name + ".sha256")).write_text(digest + "  " + name + "\n")
    write_json(output / "manifest.json", manifest)
    return {"name": name, "sha256": digest, "bytes": (output / name).stat().st_size,
            "manifest_sha256": file_sha(output / "manifest.json")}


def verify_artifact(candidate, receipt, expected_receipt_hash):
    if receipt.get("offline_only", False):
        require(receipt.get("driver_included") is False, "Offline provenance must exclude driver")
    else:
        require(receipt.get("driver_included", True) is True, "Full provenance must include driver")
    require(file_sha(candidate / "provenance.json") == expected_receipt_hash, "Reviewed provenance receipt changed")
    a = receipt["artifact"]
    name = release_identity(receipt["versions"], receipt["channel"], receipt["tag"], signing=receipt.get("signing", "unsigned"), offline_only=receipt.get("offline_only", False))
    require(a["name"] == name, "Artifact naming/version mismatch")
    archive = candidate / name
    require(not any(p.is_symlink() for p in candidate.iterdir()), "Candidate symlink refused")
    require({p.name for p in candidate.iterdir()} == {name, name + ".sha256", "manifest.json", "provenance.json"}, "Unexpected candidate files")
    require(archive.stat().st_size == a["bytes"] and file_sha(archive) == a["sha256"], "Final archive changed")
    require((candidate / (name + ".sha256")).read_text() == a["sha256"] + "  " + name + "\n", "Checksum sidecar mismatch")
    require(file_sha(candidate / "manifest.json") == a["manifest_sha256"], "Manifest changed")
    manifest = json.loads((candidate / "manifest.json").read_text())
    profile_paths([m["path"] for m in manifest], receipt.get("signing", "unsigned"), receipt.get("offline_only", False))
    require(len(manifest) == len({m["path"] for m in manifest}), "Duplicate manifest paths")
    validate_distribution(receipt, {m["path"]: m for m in manifest})
    with zipfile.ZipFile(archive) as z:
        require(z.testzip() is None and len(z.namelist()) == len(set(z.namelist())), "Invalid or duplicate ZIP entries")
        require(set(z.namelist()) == {m["path"] for m in manifest}, "Archive/manifest paths differ")
        for m in manifest:
            p = Path(m["path"])
            require(not p.is_absolute() and ".." not in p.parts, "Unsafe package path")
            info = z.getinfo(m["path"])
            require(stat.S_ISREG(info.external_attr >> 16) and stat.S_IMODE(info.external_attr >> 16) == m["mode"], "Package mode changed")
            data = z.read(info)
            require(len(data) == m["bytes"] and sha(data) == m["sha256"], "Package entry changed")
        if receipt.get("offline_only", False):
            require(not any(part.endswith(".dext") for path in z.namelist() for part in Path(path).parts), "Offline archive contains driver code")
        bundle_versions(z.read, receipt["versions"], receipt.get("offline_only", False))


def environment(work):
    # Do not inherit SDKROOT, XCODE_XCCONFIG_FILE, compiler/linker overrides,
    # signing credentials or injected search paths from the caller's shell.
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
    if "HOME" in os.environ:
        env["HOME"] = os.environ["HOME"]
    env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    for key, part in [("TMPDIR", "tmp"), ("CLANG_MODULE_CACHE_PATH", "clang-cache"), ("SWIFT_MODULECACHE_PATH", "swift-cache")]:
        p = work / part
        p.mkdir(parents=True, exist_ok=True)
        env[key] = str(p) + "/"
    return env


def checked_command(args, root, env, work, label):
    log = work / (label + ".log")
    with log.open("xb") as f:
        p = subprocess.run(args, cwd=root, env=env, stdout=f, stderr=subprocess.STDOUT)
    require(p.returncode == 0, label + " failed; retain local log and abort")
    return {"check": label, "exit": p.returncode, "log_sha256": file_sha(log)}


def prepare(args, root):
    root = root.resolve()
    destination(args.repository, args.repository_id)
    require(re.fullmatch(r"(?:alpha-|beta-|rc-|v)\d+\.\d+\.\d+", args.tag), "Invalid tag")
    refs = remote_state()
    tree = source_guard(root, args.source, refs["refs/heads/main"])
    output = Path(args.output).resolve()
    require(root != output and root not in output.parents and not output.exists(), "Use a new output directory outside source")
    with tempfile.TemporaryDirectory(prefix="rewinddv-release-metadata-") as tmp:
        v = versions(root, environment(Path(tmp)))
    name = release_identity(v, args.channel, args.tag)
    tag_guard(args.tag, args.source, refs, "absent", api("repos/" + REPOSITORY + "/releases/tags/" + args.tag, missing=True) is not None)
    if args.dry_run:
        print(json.dumps({"dry_run": True, "source": args.source, "versions": v, "tag": args.tag, "artifact": name, "prerelease": args.channel != "stable"}))
        return
    config = Path(args.private_config).resolve() if args.private_config else None
    require(config and config.is_file() and root not in config.parents and output not in config.parents,
            "Private disclosure config must exist outside source and outputs")
    output.mkdir()
    work = output / "private-work"
    work.mkdir()
    env = environment(work)
    toolchain = run(["xcodebuild", "-version"], env=env)
    require(toolchain.startswith("Xcode 27."), "Reviewed Xcode 27 toolchain required")
    checks = []
    commands = [
        ("release-tests", [sys.executable, "-B", "tools/test_release_candidate.py"]),
        ("disclosure-tests", [sys.executable, "-B", "tools/test-publication-content.py"]),
        ("swift-tests", ["xcrun", "swift", "test", "--package-path", "Foundation", "--disable-sandbox", "--scratch-path", str(work / "package"), "--cache-path", str(work / "cache"), "--config-path", str(work / "config"), "--security-path", str(work / "security")]),
        ("unsigned-release-build", ["xcodebuild", "-project", PROJECT, "-target", "RewindDV", "-configuration", "Release", "SYMROOT=" + str(work / "products"), "OBJROOT=" + str(work / "objects"), "CLANG_MODULE_CACHE_PATH=" + str(work / "modules"), "CODE_SIGNING_ALLOWED=NO", "build"]),
    ]
    for label, command in commands:
        checks.append(checked_command(command, root, env, work, label))
    source_guard(root, args.source)
    stage = work / "stage"
    stage.mkdir()
    shutil.copytree(work / "products/Release/RewindDV.app", stage / "RewindDV.app", symlinks=True)
    for doc in ["LICENSE", "NOTICE", "ThirdPartyNotices.txt"]:
        shutil.copy2(root / doc, stage / doc)
    shutil.copytree(root / "licenses", stage / "licenses")
    (stage / "READ-ME.txt").write_text("Unsigned source candidate. Not signed, notarized, installed or hardware-qualified.\nDo not use historical install instructions for this artifact.\nSource: https://github.com/" + REPOSITORY + "/commit/" + args.source + "\n")
    candidate = output / "candidate"
    candidate.mkdir()
    artifact = package(stage, candidate, name, v)
    spec = importlib.util.spec_from_file_location("disclosure", root / "tools/check-publication-content.py")
    disclosure = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(disclosure)
    privacy = disclosure.inspect(candidate / name, json.loads(config.read_text()))
    write_json(work / "disclosure.json", privacy)
    manual = [f for f in privacy["findings"] if f["category"] == "manual_format_metadata_or_visual_review_required"]
    require(len(manual) == len(privacy["findings"]), "Disclosure finding or inspection gap; candidate is blocked")
    receipt = {"schema": 1, "repository": REPOSITORY, "repository_id": REPOSITORY_ID,
               "source_commit": args.source, "source_tree": tree, "public_boundary": PUBLIC_BASE,
               "channel": args.channel, "tag": args.tag, "prerelease": args.channel != "stable",
               "versions": v, "artifact": artifact, "toolchain": toolchain, "checks": checks,
               "signing": "unsigned", "notarized": False, "hardware_qualified": False,
               "manual_disclosure_review_required": bool(manual), "publication_authorized": False}
    write_json(candidate / "provenance.json", receipt)
    digest = file_sha(candidate / "provenance.json")
    verify_artifact(candidate, receipt, digest)
    print(json.dumps({"prepared": True, "publication": False, "receipt_sha256": digest,
                      "manual_review_required": True, "artifact_sha256": artifact["sha256"]}))


def verify(args, root):
    candidate = Path(args.candidate).resolve()
    require(re.fullmatch(r"[0-9a-f]{64}", args.receipt_sha256), "Supply the independently retained receipt SHA-256")
    require(file_sha(candidate / "provenance.json") == args.receipt_sha256, "Reviewed receipt changed")
    receipt = json.loads((candidate / "provenance.json").read_text())
    destination(receipt["repository"], receipt["repository_id"])
    require(receipt["schema"] in {1, 2} and receipt["public_boundary"] == PUBLIC_BASE, "Unsupported provenance policy")
    refs = remote_state()
    tree = source_guard(root, receipt["source_commit"], refs["refs/heads/main"])
    require(tree == receipt["source_tree"], "Source tree mismatch")
    with tempfile.TemporaryDirectory(prefix="rewinddv-release-verify-") as tmp:
        require(versions(root, environment(Path(tmp))) == receipt["versions"], "Source/bundle version mismatch")
    release_identity(receipt["versions"], receipt["channel"], receipt["tag"], receipt.get("signing", "unsigned"), receipt.get("offline_only", False))
    tag_guard(receipt["tag"], receipt["source_commit"], refs, args.tag_state,
              api("repos/" + REPOSITORY + "/releases/tags/" + receipt["tag"], missing=True) is not None)
    require(receipt["prerelease"] == (receipt["channel"] != "stable"), "Release channel/prerelease mismatch")
    verify_artifact(candidate, receipt, args.receipt_sha256)
    print("PASS: source/tag/artifact identity; manual disclosure/distribution review still required. No publication performed.")


def ingest_signed(args, root):
    """Package a hash-bound, already verified stage; never signs or publishes.

    Native verification and independent disclosure approval remain separate
    gates. The private input receipt binds the complete final stage, including
    stapled bytes; it is not itself an independent approval.
    """
    raw = Path(args.distribution_receipt).read_bytes()
    require(sha(raw) == args.distribution_receipt_sha256, "Distribution receipt changed")
    value = json.loads(raw)
    receipt, expected = value["provenance"], value["stage_manifest"]
    destination(receipt["repository"], receipt["repository_id"])
    require(receipt["signing"] == "developer-id" and receipt["public_boundary"] == PUBLIC_BASE, "Wrong signed distribution policy")
    tree = source_guard(root, receipt["source_commit"])
    require(tree == receipt["source_tree"], "Distribution source tree changed")
    require(receipt["prerelease"] == (receipt["channel"] != "stable"), "Release lifecycle mismatch")
    with tempfile.TemporaryDirectory(prefix="rewinddv-signed-ingest-") as tmp:
        require(versions(root, environment(Path(tmp))) == receipt["versions"], "Source/version mismatch")
    stage = Path(args.stage).resolve(); candidate = Path(args.output).resolve()
    require(stage.is_dir() and not candidate.exists() and root not in candidate.parents and candidate != root
            and candidate != stage and stage not in candidate.parents,
            "Use a new candidate output outside source")
    actual = []
    for path in sorted(stage.rglob("*")):
        require(not path.is_symlink(), "Stage symlinks are not permitted")
        if path.is_dir(): continue
        require(path.is_file(), "Nonregular stage input")
        actual.append({"path": path.relative_to(stage).as_posix(), "mode": stat.S_IMODE(path.stat().st_mode),
                       "bytes": path.stat().st_size, "sha256": file_sha(path)})
    require(actual == expected, "Stage differs from distribution receipt")
    validate_distribution(receipt, {m["path"]:m for m in actual})
    name = release_identity(receipt["versions"], receipt["channel"], receipt["tag"], "developer-id", False)
    candidate.mkdir()
    receipt["artifact"] = package(stage, candidate, name, receipt["versions"], signing="developer-id")
    require(json.loads((candidate / "manifest.json").read_text()) == expected, "Packaged bytes differ from verified stage")
    write_json(candidate / "provenance.json", receipt)
    digest = file_sha(candidate / "provenance.json")
    verify_artifact(candidate, receipt, digest)
    print(json.dumps({"receipt_sha256": digest, "publication": False, "independent_review_required": True}))


def inspect_versions(args, root):
    with tempfile.TemporaryDirectory(prefix="rewinddv-release-inspect-") as tmp:
        print(json.dumps(versions(root, environment(Path(tmp))), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--source", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--channel", choices=["alpha", "beta", "rc", "stable"], required=True)
    p.add_argument("--repository", default=REPOSITORY)
    p.add_argument("--repository-id", type=int, default=REPOSITORY_ID)
    p.add_argument("--output", required=True)
    p.add_argument("--private-config")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("verify")
    p.add_argument("--candidate", required=True)
    p.add_argument("--receipt-sha256", required=True)
    p.add_argument("--tag-state", choices=["absent", "present"], required=True)
    p = sub.add_parser("ingest-signed")
    p.add_argument("--stage", required=True)
    p.add_argument("--distribution-receipt", required=True)
    p.add_argument("--distribution-receipt-sha256", required=True)
    p.add_argument("--output", required=True)
    sub.add_parser("versions")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        {"prepare": prepare, "verify": verify, "versions": inspect_versions, "ingest-signed": ingest_signed}[args.command](args, root)
    except (GateError, OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
        print("BLOCKED: " + str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
