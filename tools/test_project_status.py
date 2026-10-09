import copy
import json
from pathlib import Path
import unittest
import project_status as status

BASE = json.loads((Path(__file__).resolve().parents[1] / 'PROJECT-STATUS.json').read_text())
ALPHA = BASE['development']['application_version']
DRIVER = BASE['development']['driver_build']

class StatusTests(unittest.TestCase):
    def test_older_download_is_valid(self):
        data = copy.deepcopy(BASE)
        data['public_release'].update(application_version='0.0.81', application_build=183, driver_build=183, tag='alpha-0.0.81')
        data['links']['release'] = data['links']['source'] + '/releases/tag/alpha-0.0.81'
        status.validate_identities(data, ALPHA, DRIVER)

    def test_app_only_update_keeps_driver(self):
        data = copy.deepcopy(BASE); data['development']['application_version'] = '0.0.90'
        status.validate_identities(data, '0.0.90', DRIVER)

    def test_driver_only_update_keeps_app(self):
        data = copy.deepcopy(BASE); data['development']['driver_build'] = 191
        status.validate_identities(data, ALPHA, 191)

    def test_source_disagreement_is_rejected(self):
        for alpha, driver in [('0.0.0', DRIVER), (ALPHA, DRIVER - 1)]:
            with self.assertRaises(ValueError): status.validate_identities(BASE, alpha, driver)

    def test_app_build_is_independent_and_checked(self):
        data = copy.deepcopy(BASE); data['development']['application_build'] = 189
        status.validate_identities(data, ALPHA, DRIVER, app_build=189)
        with self.assertRaises(ValueError):
            status.validate_identities(data, ALPHA, DRIVER, app_build=188)

    def test_capture_and_hot_unload_are_separate_states(self):
        data = copy.deepcopy(BASE)
        data['qualification']['capture'] = 'bounded capture passed'
        data['qualification']['hot_unload'] = 'unqualified'
        status.validate_identities(data, ALPHA, DRIVER)
        del data['qualification']['hot_unload']
        with self.assertRaises(ValueError): status.validate_identities(data, ALPHA, DRIVER)

    def test_current_block_labels_both_lifecycles(self):
        block = status.status_block(BASE)
        self.assertIn(f'Current development:** rewindDV {ALPHA} (Alpha)', block)
        if BASE['public_release'].get('offline_only', False):
            self.assertIn('offline-only', block); self.assertIn('No DriverKit extension is included', block)
        else:
            self.assertIn(f"Latest public download:** [Alpha {BASE['public_release']['application_version']} / Driver B{BASE['public_release']['driver_build']}]", block)

    def test_offline_distribution_cannot_claim_driver_or_sip_requirement(self):
        data = copy.deepcopy(BASE)
        data['public_release'].update(signing='ad-hoc', notarized=False, offline_only=True, driver_included=False, requires_sip_disabled=False)
        status.validate_identities(data, ALPHA, DRIVER)
        for key in ['driver_included', 'requires_sip_disabled']:
            bad = copy.deepcopy(data); bad['public_release'][key] = True
            with self.assertRaises(ValueError): status.validate_identities(bad, ALPHA, DRIVER)

    def test_full_signed_status_and_false_claims(self):
        data = copy.deepcopy(BASE)
        data['public_release'].update(signing='developer-id', notarized=True, offline_only=False,
                                      driver_included=True, requires_sip_disabled=False)
        status.validate_identities(data, ALPHA, DRIVER)
        block = status.status_block(data)
        self.assertIn('Developer ID-signed and notarized', block)
        self.assertNotIn('disabling SIP', block)
        self.assertNotIn('ad-hoc', block)
        for field in ('notarized', 'offline_only', 'driver_included', 'requires_sip_disabled'):
            bad = copy.deepcopy(data); bad['public_release'][field] = not bad['public_release'][field]
            with self.subTest(field=field), self.assertRaises(ValueError): status.validate_identities(bad, ALPHA, DRIVER)

    def test_signed_provenance_scope_must_match(self):
        data, remote, receipt = self.candidate()
        flags = dict(signing='developer-id', notarized=True, offline_only=False, driver_included=True, requires_sip_disabled=False)
        data['public_release'].update(flags); receipt.update(flags, schema=2)
        status.validate_release(data, remote, receipt)
        for field in flags:
            bad = copy.deepcopy(receipt); bad[field] = 'wrong' if field == 'signing' else not bad[field]
            with self.subTest(field=field), self.assertRaises(ValueError): status.validate_release(data, remote, bad)

    def candidate(self):
        data = copy.deepcopy(BASE); r = data['public_release']; r.pop('offline_only', None); r.pop('driver_included', None)
        r.update(signing='ad-hoc', notarized=False, application_version='0.0.90', application_build=188, driver_build=190, tag='alpha-0.0.90', package_name='future.zip')
        remote = {'tag_name':r['tag'], 'draft':False, 'prerelease':True, 'assets':[
            {'name':r['package_name'], 'digest':'sha256:' + r['package_sha256']},
            {'name':r['package_name'] + '.sha256'}, {'name':'manifest.json','digest':'sha256:' + 'a' * 64}]}
        receipt = {'repository':status.release.REPOSITORY,'repository_id':status.release.REPOSITORY_ID,'versions':{'application_version':'0.0.90','driver_build':'190','app_bundle_build':'188'},
                   'source_commit':r['source_revision'], 'tag':r['tag'],
                   'artifact':{'sha256':r['package_sha256'],'name':r['package_name'],'manifest_sha256':'a' * 64}}
        return data, remote, receipt

    def test_future_release_binds_independent_identities(self):
        status.validate_release(*self.candidate())

    def test_future_release_requires_provenance(self):
        data, remote, _ = self.candidate()
        with self.assertRaises(ValueError): status.validate_release(data, remote)

    def test_release_artifact_or_source_mismatch_is_rejected(self):
        for field in ['source_commit', 'tag', 'driver_build', 'app_bundle_build', 'sha256']:
            data, remote, receipt = self.candidate()
            if field in ['driver_build', 'app_bundle_build']: receipt['versions'][field] = '191'
            elif field == 'sha256': receipt['artifact'][field] = '0' * 64
            else: receipt[field] = 'wrong'
            with self.assertRaises(ValueError): status.validate_release(data, remote, receipt)

if __name__ == '__main__': unittest.main()
