#!/usr/bin/env python3
"""Build/sign only the host app and copy its pinned, unchanged signed DriverKit bundle.

No driver compilation/signing, installation, activation or publication. Build the
clean reviewed source; retain exact signed-driver bytes and source correspondence.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
from product_identity import check, bundle_identity
from driver_reuse import DEXT, bundle_manifest, verify_retained, app_only_project

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parents[1]


def mapped_compiler_flags(source, output):
    """Map compiler-emitted source/build paths without changing source provenance."""
    maps = []
    for root, destination in [(source, '/rewindDV/source'),
                              (output, '/rewindDV/build')]:
        for prefix in (str(root.absolute()), str(root.resolve())):
            if (prefix, destination) not in maps:
                maps.append((prefix, destination))
    clang = ' '.join(shlex.quote('-f' + kind + '-prefix-map=' + old + '=' + new)
                     for old, new in maps for kind in ('file', 'debug'))
    swift = ' '.join('-' + kind + '-prefix-map ' + shlex.quote(old + '=' + new)
                     for old, new in maps for kind in ('file', 'debug'))
    swift += ' -prefix-serialized-debugging-options'
    return ['OTHER_CFLAGS=$(inherited) ' + clang,
            'OTHER_CPLUSPLUSFLAGS=$(inherited) ' + clang,
            'OTHER_SWIFT_FLAGS=$(inherited) ' + swift]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--retained-driver', type=Path, required=True)
    parser.add_argument('--driver-receipt', type=Path, required=True)
    parser.add_argument('--app-profile', type=Path, required=True)
    parser.add_argument('--certificate-sha1', required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'LANG':'en_US.UTF-8',
           'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer', 'PYTHONDONTWRITEBYTECODE':'1'}
    if 'HOME' in os.environ:env['HOME']=os.environ['HOME']
    git = lambda *a: subprocess.check_output(['git', '-C', str(REPO), *a], text=True).strip()
    if git('status', '--porcelain', '--untracked-files=all'):
        parser.error('Commit source before distribution build')
    source = git('rev-parse', 'HEAD')
    identity = check(REPO)
    receipt = json.loads(args.driver_receipt.read_text())
    original = verify_retained(args.retained_driver.resolve(), identity, REPO, receipt)
    out = args.output.resolve()
    if out.is_relative_to(REPO) or out.is_relative_to(args.retained_driver.resolve()) or args.retained_driver.resolve().is_relative_to(out):
        parser.error('Use a new output directory outside source and retained bundle')
    spec = importlib.util.spec_from_file_location('distribution_verifier', TOOLS/'verify-developer-id-candidate.py')
    verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
    profile_bytes = args.app_profile.read_bytes()
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(args.app_profile)]))
    checks = verifier.profile_checks(profile, verifier.APP_ID, args.certificate_sha1, datetime.datetime.now(datetime.timezone.utc), args.team_id)
    if not all(checks.values()):
        parser.error('App distribution profile rejected: ' + json.dumps(checks))
    ent = plistlib.loads((REPO/'Foundation/Config/App.entitlements').read_bytes())
    ent.update({'com.apple.application-identifier': args.team_id + '.' + verifier.APP_ID,
                'com.apple.developer.team-identifier': args.team_id})
    for k,v in ent.items():
        if k in profile['Entitlements']:
            if not verifier.authorized(v, profile['Entitlements'][k]):parser.error('Unauthorized entitlement: ' + k)
        elif k not in {'com.apple.security.app-sandbox','com.apple.security.files.user-selected.read-write'}:
            parser.error('Missing profile grant: ' + k)
    out.mkdir(parents=True, exist_ok=False)
    for name in ['tmp','clang','swift','logs','products','objects']:(out/name).mkdir()
    env.update(TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'clang'), SWIFT_MODULECACHE_PATH=str(out/'swift'))
    commands = []
    def run(label, command):
        log = out/'logs'/(label+'.log')
        with log.open('wb') as f:r=subprocess.run(command,cwd=REPO,env=env,stdout=f,stderr=subprocess.STDOUT)
        commands.append({'command':command,'exit':r.returncode,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
        (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
        if r.returncode:raise SystemExit(label+' failed: '+str(log))
    original_project=REPO/'Foundation/RewindDV.xcodeproj/project.pbxproj'
    project=out/'AppOnly.xcodeproj'; project.mkdir()
    projected=project/'project.pbxproj'
    projected.write_bytes(plistlib.dumps(app_only_project(original_project)))
    (out/'project-projection.json').write_text(json.dumps({'original_sha256':hashlib.sha256(original_project.read_bytes()).hexdigest(),
        'projected_sha256':hashlib.sha256(projected.read_bytes()).hexdigest(),
        'changes':['Remove host dependency on driver','Remove host Embed Driver Extension phase',
                   'Root project group at original source directory for relative resources',
                   'Resolve base configurations, synchronized groups and source-root references absolutely'],
        'source_root':str(REPO/'Foundation')},indent=2)+'\n')
    run('app-build',['xcodebuild','-project',str(project),'-target','RewindDV','-configuration','Release',
        'SRCROOT='+str(REPO/'Foundation'),'PROJECT_DIR='+str(REPO/'Foundation'),
        'SYMROOT='+str(out/'products'),'OBJROOT='+str(out/'objects'),
        'CLANG_MODULE_CACHE_PATH='+str(out/'clang'),'SWIFT_MODULECACHE_PATH='+str(out/'swift'),
        *mapped_compiler_flags(REPO, out), 'CODE_SIGNING_ALLOWED=NO','build'])
    app=out/'products/Release/RewindDV.app'
    if not app.is_dir() or (app/DEXT).exists():raise SystemExit('App-only graph unexpectedly produced a driver')
    (app/DEXT).parent.mkdir(parents=True,exist_ok=True)
    run('copy-driver',['ditto',str(args.retained_driver.resolve()),str(app/DEXT)])
    if bundle_manifest(app/DEXT)!=original:raise SystemExit('Retained driver changed during copy')
    (app/'Contents/embedded.provisionprofile').write_bytes(profile_bytes)
    ent_file=out/'app-entitlements.plist';ent_file.write_bytes(plistlib.dumps(ent))
    # Sign only the outer host. Never use --deep for signing the retained driver.
    run('app-sign',['codesign','--force','--sign',args.certificate_sha1,'--options','runtime','--timestamp',
                   '--entitlements',str(ent_file),str(app)])
    if bundle_manifest(app/DEXT)!=original or bundle_manifest(args.retained_driver.resolve())!=original:
        raise SystemExit('Retained driver changed during outer signing')
    run('verify',['python3','-B',str(TOOLS/'verify-developer-id-candidate.py'),str(app),str(out/'verification'),
                  '--certificate-sha1',args.certificate_sha1,'--team-id',args.team_id])
    if git('rev-parse','HEAD')!=source or git('status','--porcelain','--untracked-files=all'):
        raise SystemExit('Source changed during build')
    result={'source_commit':source,'source_tree':git('rev-parse','HEAD^{tree}'),'clean_source':True,
            'app':str(app),'identity':identity,'retained_driver_receipt':receipt,
            'driver_rebuilt':False,'driver_resigned':False,'driver_reused_byte_for_byte':True,
            'bundle_identity':bundle_identity(app,identity),
            'verification':json.loads((out/'verification/verification.json').read_text())}
    (out/'provenance.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Verified app-only candidate:',app)


if __name__=='__main__':main()
