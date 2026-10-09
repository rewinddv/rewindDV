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

EXPECTED = {'product_version': '0.1.1', 'channel': 'alpha', 'app_build': 191, 'driver_build': 194}
HISTORY = [{'product_version':'0.1.0', 'app_build':190, 'driver_build':193}]

class IdentityTests(unittest.TestCase):
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
        for key, value in [('app_build',190),('driver_build',193),('product_version','0.0.100'),('channel','stable')]:
            i = dict(EXPECTED, **{key:value})
            with self.subTest(key=key), self.assertRaises(ValueError): p.validate(i, HISTORY)
    def test_components_not_interchanged(self):
        self.assertEqual(p.validate(EXPECTED,HISTORY),EXPECTED)
        with self.assertRaises(ValueError): p.validate(dict(EXPECTED,app_build=194,driver_build=191),HISTORY)
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
        a={'CFBundleIdentifier':'net.rewinddigital.RewindDV','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'191','RewindDVAlphaVersion':'0.1.1','RewindDVProductVersion':'0.1.1','RewindDVReleaseChannel':'alpha','RewindDVRequiredDriverBuild':'194'}
        d={'CFBundleIdentifier':'net.rewinddigital.RewindDV.Driver','CFBundleShortVersionString':'0.1.1','CFBundleVersion':'194','IOKitPersonalities':{'RewindDVFoundationController':{'FoundationBuildNumber':'194'}}}
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(a));(driver/'Info.plist').write_bytes(plistlib.dumps(d))
        (app/'Contents/MacOS/RewindDV').write_bytes(b'app fixture');(driver/'net.rewinddigital.RewindDV.Driver').write_bytes(b'driver fixture')
        return app,a
    def test_actual_bundle_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            app,a=self.bundle(Path(tmp));result=p.bundle_identity(app,EXPECTED)
            self.assertEqual(result['package_name'],'rewindDV-alpha-0.1.1-App191-Driver194.zip')
            for key,bad in [('RewindDVRequiredDriverBuild','193'),('CFBundleShortVersionString','0.1.0'),('CFBundleVersion','194'),('RewindDVReleaseChannel','beta')]:
                with self.subTest(key=key):
                    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(a,**{key:bad})))
                    with self.assertRaises(ValueError): p.bundle_identity(app,EXPECTED)
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
