#!/usr/bin/env python3
"""Offline negative tests for signed-package evidence and profile boundaries."""
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import release_candidate as r
from test_release_candidate import fake_app, VERSIONS


class SignedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.stage = self.root / 'stage'
        fake_app(self.stage)
        for path in r.EMBEDDED_PROFILES:
            (self.stage / path).write_bytes(b'synthetic profile; not a real certificate')
        (self.stage / 'rewinddv-cli').write_bytes(b'synthetic CLI')
        self.entries = {p.relative_to(self.stage).as_posix(): {'sha256':r.file_sha(p)} for p in self.stage.rglob('*') if p.is_file()}
        self.receipt = {'schema':2,'signing':'developer-id','notarized':True,'offline_only':False,'driver_included':True,
                        'requires_sip_disabled':False,'hardware_qualified':False,'publication_authorized':False,
                        'versions':VERSIONS,'channel':'alpha','tag':'alpha-9.8.7',
                        'distribution':{'certificate_type':'Developer ID Application','verification':'PASS',
                          'verification_report_sha256':'1'*64,'pci_primary_match':'0x590111C1',
                          'executables': {role:{'path':path,'sha256':self.entries[path]['sha256'],
                             'architecture':'arm64e' if role=='driver' else 'arm64',
                             'strict_signature':True,'secure_timestamp':True,'hardened_runtime':True} for role,path in r.EXECUTABLES.items()},
                          'profiles':[{'path':path,'sha256':self.entries[path]['sha256']} for path in sorted(r.EMBEDDED_PROFILES)],
                          'notarization':{'submission_id':'12345678-1234-1234-1234-123456789abc','status':'Accepted','submitted_zip_sha256':'2'*64,'log_sha256':'3'*64},
                          'staple':'PASS','gatekeeper':'PASS','distribution_policy':'PASS'}}

    def test_signed_roundtrip_and_independent_filename(self):
        output=self.root/'candidate';output.mkdir()
        name=r.release_identity(VERSIONS,'alpha','alpha-9.8.7','developer-id')
        self.assertEqual(name,'rewindDV-Alpha-9.8.7-Driver183-AppBuild190-DeveloperID-Notarized.zip')
        self.receipt['artifact']=r.package(self.stage,output,name,VERSIONS,signing='developer-id')
        r.write_json(output/'provenance.json',self.receipt)
        r.verify_artifact(output,self.receipt,r.file_sha(output/'provenance.json'))

    def test_signed_flags_reject_every_contradiction(self):
        for field in ('notarized','offline_only','driver_included','requires_sip_disabled','hardware_qualified','publication_authorized'):
            for value in (not self.receipt[field],None,1 if self.receipt[field] else 0):
                bad=copy.deepcopy(self.receipt);bad[field]=value
                with self.subTest(field=field,value=value),self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_wrong_or_missing_native_verification_rejected(self):
        for field in ('verification','certificate_type','pci_primary_match','verification_report_sha256','staple','gatekeeper','distribution_policy'):
            bad=copy.deepcopy(self.receipt);bad['distribution'][field]='wrong'
            with self.subTest(field=field),self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_executable_identity_and_signing_rejected(self):
        for role in r.EXECUTABLES:
            for field,value in [('sha256','0'*64),('path','other'),('architecture','x86_64'),('strict_signature',False),('secure_timestamp',False),('hardened_runtime',False)]:
                bad=copy.deepcopy(self.receipt);bad['distribution']['executables'][role][field]=value
                with self.subTest(role=role,field=field),self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_cli_omission_rejected(self):
        bad=copy.deepcopy(self.receipt);del bad['distribution']['executables']['cli']
        with self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_profile_digest_or_missing_profile_rejected(self):
        bad=copy.deepcopy(self.receipt);bad['distribution']['profiles'][0]['sha256']='0'*64
        with self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)
        bad['distribution']['profiles'].pop()
        with self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_notarization_failures_rejected(self):
        for field in ('status','submission_id','submitted_zip_sha256','log_sha256'):
            bad=copy.deepcopy(self.receipt);bad['distribution']['notarization'][field]='invalid'
            with self.subTest(field=field),self.assertRaises(r.GateError):r.validate_distribution(bad,self.entries)

    def test_profiles_only_in_exact_signed_full_locations(self):
        r.profile_paths(r.EMBEDDED_PROFILES,'developer-id',False)
        for paths,signing,offline in [(r.EMBEDDED_PROFILES|{'other.provisionprofile'},'developer-id',False),
            (set(),'developer-id',False),(set(list(r.EMBEDDED_PROFILES)[:1]),'developer-id',False),
            (r.EMBEDDED_PROFILES,'ad-hoc',False),(r.EMBEDDED_PROFILES,'developer-id',True)]:
            with self.subTest(paths=paths,signing=signing,offline=offline),self.assertRaises(r.GateError):r.profile_paths(paths,signing,offline)
        for path in r.EMBEDDED_PROFILES:
            with self.assertRaises(r.GateError):r.safe_source_path(path)

    def test_wrong_driver_handshake_rejected(self):
        p=self.stage/'RewindDV.app/Contents/Info.plist';info=plistlib.loads(p.read_bytes())
        info['RewindDVRequiredDriverBuild']='999';p.write_bytes(plistlib.dumps(info))
        with self.assertRaises(r.GateError):r.bundle_versions(lambda x:(self.stage/x).read_bytes(),VERSIONS)

    def test_no_offline_developer_id_alias(self):
        with self.assertRaises(r.GateError):r.release_identity(VERSIONS,'alpha','alpha-9.8.7','developer-id',True)

    def ingestion_fixture(self, output):
        import types
        import stat
        receipt=copy.deepcopy(self.receipt)
        receipt.update(repository=r.REPOSITORY, repository_id=r.REPOSITORY_ID, public_boundary=r.PUBLIC_BASE,
                       source_commit='a'*40, source_tree='b'*40, prerelease=True)
        (self.stage/'READ-ME.txt').write_text('reviewed instructions')
        manifest=[{'path':p.relative_to(self.stage).as_posix(),'mode':stat.S_IMODE(p.stat().st_mode),
                   'bytes':p.stat().st_size,'sha256':r.file_sha(p)} for p in sorted(self.stage.rglob('*')) if p.is_file()]
        receipt_file=self.root/'distribution.json'
        r.write_json(receipt_file, {'provenance':receipt,'stage_manifest':manifest})
        return types.SimpleNamespace(distribution_receipt=str(receipt_file),distribution_receipt_sha256=r.file_sha(receipt_file),stage=str(self.stage),output=str(output))

    def test_ingestion_rejects_output_inside_stage(self):
        args=self.ingestion_fixture(self.stage/'candidate')
        with patch.object(r,'source_guard',return_value='b'*40),patch.object(r,'versions',return_value=VERSIONS),self.assertRaises(r.GateError):
            r.ingest_signed(args,self.root/'source')
        self.assertFalse((self.stage/'candidate').exists())

    def test_ingestion_detects_mutation_during_packaging(self):
        args=self.ingestion_fixture(self.root/'candidate')
        package=r.package
        def mutate(*args,**kwargs):
            (self.stage/'READ-ME.txt').write_text('changed after verification')
            return package(*args,**kwargs)
        with patch.object(r,'source_guard',return_value='b'*40),patch.object(r,'versions',return_value=VERSIONS),patch.object(r,'package',side_effect=mutate),self.assertRaises(r.GateError):
            r.ingest_signed(args,self.root/'source')
        self.assertFalse((self.root/'candidate/provenance.json').exists())

    def test_ingestion_rejects_changed_receipt_before_any_command(self):
        import types
        path=self.root/'receipt.json';path.write_text('{}')
        args=types.SimpleNamespace(distribution_receipt=str(path),distribution_receipt_sha256='0'*64)
        with patch.object(r,'source_guard') as guard,self.assertRaises(r.GateError):r.ingest_signed(args,self.root)
        guard.assert_not_called()

if __name__=='__main__':unittest.main()
