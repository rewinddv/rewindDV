#!/usr/bin/env python3
"""Negative regressions for distribution profile authorization boundaries."""
import copy
import datetime
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("verifier", Path(__file__).with_name("verify-developer-id-candidate.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class DistributionProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 8, tzinfo=datetime.timezone.utc)
        self.cert = b"synthetic public certificate fixture"
        self.fingerprint = hashlib.sha1(self.cert).hexdigest().upper()
        self.profile = {
            "TeamIdentifier": ["TESTTEAM01"], "Platform": ["OSX"], "ProvisionsAllDevices": True,
            "CreationDate": datetime.datetime(2026, 1, 1), "ExpirationDate": datetime.datetime(2027, 1, 1),
            "DeveloperCertificates": [self.cert], "Entitlements": {
                "com.apple.developer.team-identifier": "TESTTEAM01",
                "com.apple.application-identifier": "TESTTEAM01" + "." + v.DRIVER_ID,
                "com.apple.developer.driverkit.transport.pci": copy.deepcopy(v.PCI),
            }}

    def checks(self):
        return v.profile_checks(self.profile, v.DRIVER_ID, self.fingerprint, self.now, "TESTTEAM01")

    def test_distribution_profile_passes(self):
        self.assertTrue(all(self.checks().values()))

    def test_development_wildcard_rejected(self):
        self.profile["Entitlements"]["com.apple.developer.driverkit.transport.pci"] = [
            {"IOPCIPrimaryMatch": "0xFFFFFFFF&0x00000000"}]
        self.assertFalse(self.checks()["approved_pci"])

    def test_other_device_rejected(self):
        self.profile["Entitlements"]["com.apple.developer.driverkit.transport.pci"] = [
            {"IOPCIPrimaryMatch": "0x590211C1"}]
        self.assertFalse(self.checks()["approved_pci"])

    def test_wrong_match_type_rejected(self):
        self.profile["Entitlements"]["com.apple.developer.driverkit.transport.pci"] = [
            {"IOPCIPrimaryMatch": 0x590111C1}]
        self.assertFalse(self.checks()["approved_pci"])

    def test_wrong_explicit_identifier_rejected(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "TESTTEAM01" + ".*"
        self.assertFalse(self.checks()["explicit_app_id"])

    def test_wrong_team_rejected(self):
        self.profile["TeamIdentifier"] = ["OTHERTEAM"]
        self.assertFalse(self.checks()["team"])

    def test_supplied_team_must_match_even_when_profile_fields_agree(self):
        checks = v.profile_checks(self.profile, v.DRIVER_ID, self.fingerprint, self.now, "OTHERTEAM1")
        self.assertFalse(checks["team"])
        self.assertFalse(checks["explicit_app_id"])

    def test_wrong_certificate_rejected(self):
        self.profile["DeveloperCertificates"] = [b"different certificate"]
        self.assertFalse(self.checks()["certificate"])

    def test_device_limited_profile_rejected(self):
        self.profile["ProvisionedDevices"] = ["synthetic-device"]
        self.assertFalse(self.checks()["all_devices"])

    def test_expired_profile_rejected(self):
        self.profile["ExpirationDate"] = datetime.datetime(2026, 10, 7)
        self.assertFalse(self.checks()["dates"])

    def test_future_profile_rejected(self):
        self.profile["CreationDate"] = datetime.datetime(2026, 10, 9)
        self.assertFalse(self.checks()["dates"])

    def test_debug_grants_rejected(self):
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            with self.subTest(key=key):
                self.profile["Entitlements"][key] = True
                self.assertFalse(self.checks()["no_debug_grants"])
                del self.profile["Entitlements"][key]

    def test_ios_profile_rejected(self):
        self.profile["Platform"] = ["iOS", "OSX"]
        self.assertFalse(self.checks()["macos_distribution"])

    def test_entitlement_types_and_array_scope(self):
        self.assertFalse(v.authorized(True, 1))
        self.assertFalse(v.authorized([v.DRIVER_ID, "other.driver"], [v.DRIVER_ID]))
        self.assertTrue(v.authorized([v.DRIVER_ID], [v.DRIVER_ID]))
        self.assertFalse(v.authorized(v.PCI, [{"IOPCIPrimaryMatch": "0x590211C1"}]))


if __name__ == "__main__":
    unittest.main()
