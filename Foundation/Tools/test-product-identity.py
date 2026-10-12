#!/usr/bin/env python3
"""Independent expected fixtures; never infer expected values from the generator."""
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import sys
sys.dont_write_bytecode = True
import product_identity as p

EXPECTED = {'product_version': '0.1.23', 'channel': 'beta', 'app_build': 213, 'driver_build': 204}
HISTORY = [{'product_version':'0.1.4', 'app_build':194, 'driver_build':197}]
BASE = {'product_version':'0.1.9','channel':'beta','app_build':199,'driver_build':202}

class IdentityTests(unittest.TestCase):
    def reuse(self):
        return dict(BASE, product_version='0.1.10', app_build=200,
                    driver_reuse={'product_version':'0.1.9','channel':'beta',
                                  'source_revision':'a'*40,'bundle_manifest_sha256':'b'*64})
    def test_reuse_keeps_driver_identity(self):
        history=[BASE]
        i=self.reuse()
        self.assertEqual(p.validate(i,history),i)
        generated=p.generated(i)
        self.assertIn('driverVersion = "0.1.9"',generated[Path('Foundation/Sources/RewindDVMonitorCore/ProductIdentity.swift')])
        self.assertIn('REWINDDV_PRODUCT_VERSION_STRING "0.1.9"',generated[p.CONFIG/'ProductIdentity.hpp'])
        for key,value in [('driver_build',201),('driver_build',203),('app_build',199),('product_version','0.1.9')]:
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):p.validate(dict(i,**{key:value}),history)
        for key,value in [('product_version','0.1.8'),('channel','alpha'),('source_revision','bad'),('bundle_manifest_sha256','bad')]:
            bad=copy.deepcopy(i);bad['driver_reuse'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):p.validate(bad,history)
    def test_successive_reuse_preserves_binding(self):
        prior=self.reuse();i=dict(prior,product_version='0.1.11',app_build=201)
        p.validate(i,[BASE,prior])
        for key,value in [('source_revision','c'*40),('bundle_manifest_sha256','d'*64)]:
            bad=copy.deepcopy(i);bad['driver_reuse'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):p.validate(bad,[BASE,prior])
    def test_older_reuse_requires_existing_immutable_pin(self):
        pinned=self.reuse()
        newer=dict(BASE,product_version='0.1.11',app_build=201,driver_build=203)
        candidate=dict(pinned,product_version='0.1.13',app_build=203)
        self.assertEqual(p.validate(candidate,[BASE,pinned,newer]),candidate)
        with self.assertRaises(ValueError):p.validate(candidate,[BASE,newer])
        for key,value in [('source_revision','c'*40),('bundle_manifest_sha256','d'*64),('product_version','0.1.8'),('channel','alpha')]:
            bad=copy.deepcopy(candidate);bad['driver_reuse'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):p.validate(bad,[BASE,pinned,newer])
        unbound=dict(candidate);unbound.pop('driver_reuse')
        with self.assertRaises(ValueError):p.validate(unbound,[BASE,pinned,newer])
    def test_forward_numeric(self):
        self.assertLess(p.version('0.0.96'), p.version('0.1.1'))
        self.assertLess(p.version('0.1.0'), p.version('0.1.1'))
        self.assertLess(p.version('0.0.100'), p.version('0.1.0'))
    def test_invalid_version(self):
        for value in ['01.1.0', '0.1', '0.1.1-alpha', '0.1.-1', '0.1.1\n', 0.1, '0.1.10000', '０.1.1']:
            with self.subTest(value=value), self.assertRaises(ValueError): p.version(value)
    def test_invalid_build(self):
        for value in [0, -1, '191', True, 1.5, 10000]:
            with self.subTest(value=value), self.assertRaises(ValueError): p.build(value)
    def test_reserved_or_downgrade(self):
        for key, value in [('app_build',194),('driver_build',197),('product_version','0.0.100'),('channel','stable')]:
            i = dict(EXPECTED, **{key:value})
            with self.subTest(key=key), self.assertRaises(ValueError): p.validate(i, HISTORY)
    def test_components_not_interchanged(self):
        self.assertEqual(p.validate(BASE,HISTORY),BASE)
        with self.assertRaises(ValueError): p.validate(dict(EXPECTED,app_build=198,driver_build=195),HISTORY)
    def test_current_source(self): self.assertEqual(p.check(),EXPECTED)
    def test_same_identity_changed_bytes(self):
        a = {'identity':EXPECTED, 'executables_sha256':{'app':'a','driver':'b'}}
        b = copy.deepcopy(a); b['executables_sha256']['driver']='c'
        with self.assertRaisesRegex(ValueError,'ambiguity'): p.compare_artifacts(a,b)
        p.compare_artifacts(a,a)
    def test_legacy_records_not_reinterpreted(self):
        row = json.loads('{"alpha":"0.0.96","version":"0.1.0","build":"190"}')
        self.assertNotEqual(row['alpha'],row['version'])
        self.assertEqual(row['build'],'190')
    def bundle(self, root):
        app = root/'RewindDV.app'; driver=app/'Contents/Library/SystemExtensions/net.rewinddigital.RewindDV.Driver.dext'
        driver.mkdir(parents=True); (app/'Contents/MacOS').mkdir()
        a={'CFBundleIdentifier':'net.rewinddigital.RewindDV','CFBundleShortVersionString':'0.1.23','CFBundleVersion':'213','RewindDVAlphaVersion':'0.1.23','RewindDVProductVersion':'0.1.23','RewindDVReleaseChannel':'beta','RewindDVRequiredDriverBuild':'204','RewindDVRequiredDriverVersion':'0.1.23'}
        d={'CFBundleIdentifier':'net.rewinddigital.RewindDV.Driver','CFBundleShortVersionString':'0.1.23','CFBundleVersion':'204','IOKitPersonalities':{'RewindDVFoundationController':{'FoundationBuildNumber':'204'}}}
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(a));(driver/'Info.plist').write_bytes(plistlib.dumps(d))
        (app/'Contents/MacOS/RewindDV').write_bytes(b'app fixture');(driver/'net.rewinddigital.RewindDV.Driver').write_bytes(b'driver fixture')
        return app,a
    def test_actual_bundle_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            app,a=self.bundle(Path(tmp));identity=copy.deepcopy(EXPECTED)
            driver=app/'Contents/Library/SystemExtensions/net.rewinddigital.RewindDV.Driver.dext'
            result=p.bundle_identity(app,identity)
            self.assertEqual(result['package_name'],'rewindDV-beta-0.1.23-App213-Driver204.zip')
            for key,bad in [('RewindDVRequiredDriverBuild','194'),('CFBundleShortVersionString','0.1.0'),('CFBundleVersion','195'),('RewindDVReleaseChannel','alpha')]:
                with self.subTest(key=key):
                    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(a,**{key:bad})))
                    with self.assertRaises(ValueError): p.bundle_identity(app,identity)
    def test_generated_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/p.CONFIG).mkdir(parents=True)
            for name in ['ProductIdentity.json','IdentityHistory.json']:
                (root/p.CONFIG/name).write_bytes((p.ROOT/p.CONFIG/name).read_bytes())
            for path,content in p.generated(EXPECTED).items():
                (root/path).parent.mkdir(parents=True,exist_ok=True);(root/path).write_text(content)
            (root/'Foundation/RewindDV.xcodeproj').mkdir();(root/'Foundation/RewindDV.xcodeproj/project.pbxproj').write_text((p.ROOT/'Foundation/RewindDV.xcodeproj/project.pbxproj').read_text())
            p.check(root)
            project=root/'Foundation/RewindDV.xcodeproj/project.pbxproj'
            original=project.read_text()
            for text in ['', original.replace('"baseConfigurationReference" = "F01100000000000000000001";', ''), original.replace('"SDKROOT" = "macosx";', '"REWINDDV_APP_BUILD" = "190";')]:
                project.write_text(text)
                with self.assertRaises(ValueError): p.check(root)
            project.write_text(original)
            (root/p.CONFIG/'AlphaVersion.txt').write_text('0.0.96\n')
            with self.assertRaisesRegex(ValueError,'drift'):p.check(root)

if __name__=='__main__': unittest.main()
