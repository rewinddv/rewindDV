#!/usr/bin/env python3
"""Synthetic release gates: no network, signing, release writes or hardware."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import release_candidate as r


VERSIONS = {"application_version": "9.8.7", "app_bundle_build": "190", "app_bundle_version": "0.1.0",
            "driver_build": "183", "driver_bundle_version": "0.1.0"}
SOURCE = "a" * 40


def fake_app(stage):
    app = stage / "RewindDV.app"
    driver = app / r.DEXT
    driver.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": r.APP_ID, "RewindDVAlphaVersion": "9.8.7",
        "CFBundleVersion": "190", "CFBundleShortVersionString": "0.1.0"}))
    (driver / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": r.DRIVER_ID, "CFBundleVersion": "183", "CFBundleShortVersionString": "0.1.0"}))
    (app / "Contents/MacOS").mkdir()
    (app / "Contents/MacOS/RewindDV").write_bytes(b"synthetic host executable")
    (driver / r.DRIVER_ID).write_bytes(b"synthetic driver executable")
    return app


class IdentityTests(unittest.TestCase):
    def test_adhoc_keeps_independent_app_driver_identity(self):
        values = {"application_version":"0.0.89", "driver_build":"190", "app_bundle_build":"188"}
        self.assertEqual(r.release_identity(values, "alpha", "alpha-0.0.89", signing="ad-hoc"),
                         "rewindDV-Alpha-0.0.89-Driver190-AppBuild188-AdHoc.zip")

    def test_canonical_destination(self):
        r.destination(r.REPOSITORY, r.REPOSITORY_ID)

    def test_wrong_destinations(self):
        for dest in ["rewinddv/rewindDV-LAB", "rewinddv/rewindDV-source-history", "rewinddv/rewindDV-private", "someone/rewindDV"]:
            with self.subTest(destination=dest), self.assertRaises(r.GateError):
                r.destination(dest, r.REPOSITORY_ID)

    def test_wrong_repository_id(self):
        with self.assertRaises(r.GateError):
            r.destination(r.REPOSITORY, 1402605229)

    def test_historical_and_existing_tags(self):
        for tag in r.HISTORICAL:
            with self.subTest(tag=tag), self.assertRaises(r.GateError):
                r.tag_guard(tag, SOURCE, {}, "absent")
        with self.assertRaises(r.GateError):
            r.tag_guard("alpha-9.8.7", SOURCE, {"refs/tags/alpha-9.8.7": SOURCE}, "absent")

    def test_tag_peels_exactly(self):
        ref = "refs/tags/alpha-9.8.7"
        r.tag_guard("alpha-9.8.7", SOURCE, {ref: SOURCE}, "present")
        r.tag_guard("alpha-9.8.7", SOURCE, {ref: "b" * 40, ref + "^{}": SOURCE}, "present")
        with self.assertRaises(r.GateError):
            r.tag_guard("alpha-9.8.7", SOURCE, {ref: "b" * 40, ref + "^{}": "c" * 40}, "present")
        with self.assertRaises(r.GateError):
            r.tag_guard("alpha-9.8.7", SOURCE, {}, "present")

    def test_existing_release_even_without_tag(self):
        with self.assertRaises(r.GateError):
            r.tag_guard("alpha-9.8.7", SOURCE, {}, "absent", release_exists=True)

    def test_app_version_and_tag_mismatch(self):
        with self.assertRaises(r.GateError):
            r.release_identity(VERSIONS, "alpha", "alpha-9.8.8")

    def test_versions_are_separate(self):
        name = r.release_identity(VERSIONS, "alpha", "alpha-9.8.7")
        self.assertIn("Driver183-AppBuild190", name)
        self.assertIn("Unsigned", name)

    def test_private_paths(self):
        for path in ["research/reference.pdf", "Foundation/evidence/local.json", "Foundation/key.p12", "tests/tape.dv"]:
            with self.subTest(path=path), self.assertRaises(r.GateError):
                r.safe_source_path(path)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stage = self.root / "stage"
        fake_app(self.stage)
        self.candidate = self.root / "candidate"
        self.candidate.mkdir()
        self.name = r.release_identity(VERSIONS, "alpha", "alpha-9.8.7")
        artifact = r.package(self.stage, self.candidate, self.name, VERSIONS)
        self.receipt = {"versions": VERSIONS.copy(), "channel": "alpha", "tag": "alpha-9.8.7", "artifact": artifact}
        r.write_json(self.candidate / "provenance.json", self.receipt)
        self.seal = r.file_sha(self.candidate / "provenance.json")

    def verify(self):
        r.verify_artifact(self.candidate, self.receipt, self.seal)

    def test_valid_candidate(self):
        self.verify()

    def test_bad_sidecar(self):
        (self.candidate / (self.name + ".sha256")).write_text("0" * 64 + "  " + self.name + "\n")
        with self.assertRaises(r.GateError):
            self.verify()

    def test_mutated_archive(self):
        with (self.candidate / self.name).open("ab") as f:
            f.write(b"changed after approval")
        with self.assertRaises(r.GateError):
            self.verify()

    def test_modified_manifest(self):
        (self.candidate / "manifest.json").write_text("[]")
        with self.assertRaises(r.GateError):
            self.verify()

    def test_modified_receipt(self):
        (self.candidate / "provenance.json").write_text("{}")
        with self.assertRaises(r.GateError):
            self.verify()

    def test_wrong_driver_build_naming(self):
        self.receipt["versions"]["driver_build"] = "184"
        with self.assertRaises(r.GateError):
            self.verify()

    def test_wrong_built_app_version(self):
        v = VERSIONS.copy()
        v["application_version"] = "9.8.8"
        with self.assertRaises(r.GateError):
            r.bundle_versions(lambda p: (self.stage / p).read_bytes(), v)

    def test_wrong_built_driver_build(self):
        v = VERSIONS.copy()
        v["driver_build"] = "184"
        with self.assertRaises(r.GateError):
            r.bundle_versions(lambda p: (self.stage / p).read_bytes(), v)

    def test_no_overwrite(self):
        with self.assertRaises(r.GateError):
            r.package(self.stage, self.candidate, self.name, VERSIONS)

    def test_extra_candidate_file(self):
        (self.candidate / "local-log.txt").write_text("private work")
        with self.assertRaises(r.GateError):
            self.verify()

    def test_symlink_rejected(self):
        (self.stage / "link").symlink_to(self.stage / "RewindDV.app/Contents/Info.plist")
        with self.assertRaises(r.GateError):
            r.package(self.stage, self.candidate, "different.zip", VERSIONS)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.g("init", "-q", "-b", "main")
        self.g("config", "user.name", "Synthetic test")
        self.g("config", "user.email", "test@example.invalid")
        self.g("remote", "add", "origin", "https://github.com/" + r.REPOSITORY + ".git")
        for p in [r.PROJECT + "/project.pbxproj", "Foundation/Config/AlphaVersion.txt", "Foundation/Config/DriverInfo.plist", "Foundation/Package.swift", "LICENSE", "NOTICE"]:
            f = self.root / p
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text("synthetic input\n")
        self.commit()
        self.base = self.g("rev-parse", "HEAD")
        self.scope = patch.object(r, "PUBLIC_BASE", self.base)
        self.scope.start()
        self.addCleanup(self.scope.stop)

    def g(self, *args):
        return r.git(self.root, *args)

    def commit(self):
        self.g("add", "-A")
        self.g("commit", "-qm", "Synthetic source")

    def test_clean_public_descendant(self):
        (self.root / "README.md").write_text("Public source description")
        self.commit()
        r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_dirty_and_ignored_inputs(self):
        (self.root / "LICENSE").write_text("changed")
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.base)
        self.g("restore", "LICENSE")
        (self.root / ".gitignore").write_text("local-input\n")
        self.commit()
        (self.root / "local-input").write_text("ignored input")
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_unreachable_source(self):
        (self.root / "README.md").write_text("not public yet")
        self.commit()
        source = self.g("rev-parse", "HEAD")
        real_git = r.git
        def no_network(root, *args):
            if args[0] == "fetch":
                return ""
            if args == ("rev-parse", "FETCH_HEAD"):
                return self.base
            return real_git(root, *args)
        with patch.object(r, "git", side_effect=no_network), self.assertRaises(r.GateError):
            r.source_guard(self.root, source, self.base)

    def test_private_ancestry_merge(self):
        self.g("switch", "--orphan", "unrelated")
        (self.root / "README.md").write_text("private root")
        self.commit()
        self.g("switch", "main")
        self.g("merge", "--allow-unrelated-histories", "--no-edit", "unrelated")
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_deleted_private_path_in_history(self):
        p = self.root / "private/receipt.txt"
        p.parent.mkdir()
        p.write_text("private")
        self.commit()
        p.unlink()
        self.commit()
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_private_content_in_deleted_blob(self):
        p = self.root / "README.md"
        p.write_text("/" + "Users/fixture-user/private-material")
        self.commit()
        p.write_text("Public summary")
        self.commit()
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_private_origin(self):
        self.g("remote", "set-url", "origin", "https://github.com/rewinddv/rewindDV-private.git")
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.base)

    def test_source_symlink_outside_tree(self):
        (self.root / "Foundation/external.hpp").symlink_to("/tmp/untracked-build-input.hpp")
        self.commit()
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))

    def test_deleted_source_symlink(self):
        p = self.root / "Foundation/external.hpp"
        p.symlink_to("/tmp/untracked-build-input.hpp")
        self.commit()
        p.unlink()
        self.commit()
        with self.assertRaises(r.GateError):
            r.source_guard(self.root, self.g("rev-parse", "HEAD"))


class PreparationTests(unittest.TestCase):
    def test_build_environment_drops_external_overrides(self):
        with tempfile.TemporaryDirectory() as t, patch.dict(os.environ, {
            "XCODE_XCCONFIG_FILE": "/tmp/override.xcconfig", "SDKROOT": "unreviewed-sdk",
            "OTHER_CFLAGS": "-include /tmp/private.h", "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            "GH_TOKEN": "synthetic-secret", "PATH": "/tmp/untrusted-bin"}):
            env = r.environment(Path(t))
            for key in ["XCODE_XCCONFIG_FILE", "SDKROOT", "OTHER_CFLAGS", "DYLD_INSERT_LIBRARIES", "GH_TOKEN"]:
                self.assertNotIn(key, env)
            self.assertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")

    def test_complete_synthetic_preparation_and_seal(self):
        with tempfile.TemporaryDirectory() as t:
            base = Path(t).resolve()
            root = base / "source"
            root.mkdir()
            (root / "licenses").mkdir()
            for doc in ["LICENSE", "NOTICE", "ThirdPartyNotices.txt", "licenses/example.txt"]:
                (root / doc).write_text("Synthetic license notice")
            config = base / "private-config.json"
            config.write_text('{"terms": [], "private_values": []}')
            output = base / "outputs"
            args = argparse.Namespace(repository=r.REPOSITORY, repository_id=r.REPOSITORY_ID, source=SOURCE,
                                      tag="alpha-9.8.7", channel="alpha", output=str(output), dry_run=False,
                                      private_config=str(config))
            invocations = []
            def build(command, checkout, env, work, label):
                invocations.append((label, command))
                if label == "unsigned-release-build":
                    fake_app(work / "products/Release")
                return {"check": label, "exit": 0, "log_sha256": "d" * 64}
            scanner = types.SimpleNamespace(inspect=lambda *a: {"findings": []})
            loader = types.SimpleNamespace(exec_module=lambda module: None)
            with patch.object(r, "remote_state", return_value={"refs/heads/main": SOURCE}), \
                 patch.object(r, "source_guard", return_value="b" * 40), \
                 patch.object(r, "versions", return_value=VERSIONS), \
                 patch.object(r, "api", return_value=None), \
                 patch.object(r, "run", return_value="Xcode 27.0\nBuild version synthetic"), \
                 patch.object(r, "checked_command", side_effect=build), \
                 patch.object(r.importlib.util, "spec_from_file_location", return_value=types.SimpleNamespace(loader=loader)), \
                 patch.object(r.importlib.util, "module_from_spec", return_value=scanner), \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                r.prepare(args, root)
            result = json.loads(out.getvalue())
            receipt = json.loads((output / "candidate/provenance.json").read_text())
            self.assertFalse(receipt["publication_authorized"])
            self.assertTrue(receipt["prerelease"])
            self.assertEqual(len(invocations), 4)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", invocations[-1][1])
            r.verify_artifact(output / "candidate", receipt, result["receipt_sha256"])

    def test_valid_dry_run_has_no_candidate_or_build(self):
        with tempfile.TemporaryDirectory() as t:
            output = Path(t) / "not-created"
            args = argparse.Namespace(repository=r.REPOSITORY, repository_id=r.REPOSITORY_ID, source=SOURCE,
                                      tag="alpha-9.8.7", channel="alpha", output=str(output), dry_run=True)
            with patch.object(r, "remote_state", return_value={"refs/heads/main": SOURCE}), \
                 patch.object(r, "source_guard", return_value="b" * 40), \
                 patch.object(r, "versions", return_value=VERSIONS), \
                 patch.object(r, "api", return_value=None), \
                 patch.object(r, "checked_command") as build, contextlib.redirect_stdout(io.StringIO()) as out:
                r.prepare(args, Path(t) / "source")
            self.assertTrue(json.loads(out.getvalue())["dry_run"])
            build.assert_not_called()
            self.assertFalse(output.exists())

    def test_build_settings_derive_versions_and_check_duplicate_consistency(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / "Foundation/Config").mkdir(parents=True)
            (root / "Foundation/Config/AlphaVersion.txt").write_text("9.8.7\n")
            app = {"PRODUCT_BUNDLE_IDENTIFIER": r.APP_ID, "CURRENT_PROJECT_VERSION": "190", "MARKETING_VERSION": "0.1.0"}
            driver = {"PRODUCT_BUNDLE_IDENTIFIER": r.DRIVER_ID, "CURRENT_PROJECT_VERSION": "183", "MARKETING_VERSION": "0.1.0"}
            settings = [{"buildSettings": b} for b in [app, driver, driver.copy()]]
            self.assertEqual(r.versions_from_settings(root, settings), VERSIONS)
            settings[-1]["buildSettings"]["CURRENT_PROJECT_VERSION"] = "184"
            with self.assertRaises(r.GateError):
                r.versions_from_settings(root, settings)


if __name__ == "__main__":
    unittest.main(verbosity=2)
