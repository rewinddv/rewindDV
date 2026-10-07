#!/usr/bin/env python3
"""Build and seal a public ad-hoc engineering candidate. Never installs or publishes."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import release_candidate as gate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--private-config', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = Path(args.output).resolve()
    config = Path(args.private_config).resolve()
    gate.require(root != output and root not in output.parents and not output.exists(), 'Use new external output')
    gate.require(config.is_file() and root not in config.parents and output not in config.parents, 'External disclosure configuration required')
    tree = gate.source_guard(root, args.source)
    output.mkdir()
    work = output / 'private-work'; work.mkdir()
    env = gate.environment(work)
    versions = gate.versions(root, env)
    name = gate.release_identity(versions, 'alpha', args.tag, signing='ad-hoc')
    toolchain = gate.run(['xcodebuild', '-version'], env=env)
    gate.require(toolchain.startswith('Xcode 27.'), 'Reviewed Xcode 27 toolchain required')
    checks = []
    for label, command in [
        ('release-tests', [sys.executable, '-B', 'tools/test_release_candidate.py']),
        ('disclosure-tests', [sys.executable, '-B', 'tools/test-publication-content.py']),
        ('status-tests', [sys.executable, '-B', 'tools/test_project_status.py']),
        ('source-status', [sys.executable, '-B', 'tools/project_status.py']),
        ('swift-tests', ['xcrun', 'swift', 'test', '--package-path', 'Foundation', '--disable-sandbox', '--scratch-path', str(work/'package'), '--cache-path', str(work/'cache'), '--config-path', str(work/'config'), '--security-path', str(work/'security')]),
        ('public-cli-release-build', ['xcrun', 'swift', 'build', '--package-path', 'Foundation', '--product', 'rewinddv', '-c', 'release', '--disable-sandbox', '--scratch-path', str(work/'cli'), '--cache-path', str(work/'cli-cache'), '--config-path', str(work/'cli-config'), '--security-path', str(work/'cli-security'), '-Xswiftc', '-file-prefix-map', '-Xswiftc', str(root)+'=/rewindDV', '-Xswiftc', '-debug-prefix-map', '-Xswiftc', str(root)+'=/rewindDV']),
        ('public-release-build', ['xcodebuild', '-project', gate.PROJECT, '-target', 'RewindDV', '-configuration', 'Release', 'SYMROOT='+str(work/'products'), 'OBJROOT='+str(work/'objects'), 'CLANG_MODULE_CACHE_PATH='+str(work/'modules'), 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'DEVELOPMENT_TEAM=', 'OTHER_CFLAGS=$(inherited) -ffile-prefix-map='+str(root)+'=/rewindDV -fdebug-prefix-map='+str(root)+'=/rewindDV', 'OTHER_CPLUSPLUSFLAGS=$(inherited) -ffile-prefix-map='+str(root)+'=/rewindDV -fdebug-prefix-map='+str(root)+'=/rewindDV', 'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map '+str(root)+'=/rewindDV -debug-prefix-map '+str(root)+'=/rewindDV', 'build'])]:
        checks.append(gate.checked_command(command, root, env, work, label))
    gate.source_guard(root, args.source)
    stage = work/'stage'; stage.mkdir()
    app = stage/'RewindDV.app'
    shutil.copytree(work/'products/Release/RewindDV.app', app, copy_function=shutil.copyfile)
    driver = app/gate.DEXT
    gate.require(not list(app.rglob('*.provisionprofile')) and not list(app.rglob('*.p12')), 'Unsigned public build unexpectedly contains signing resources')
    for info in [app/'Contents/Info.plist', driver/'Info.plist']:
        data = plistlib.loads(info.read_bytes()); data.pop('BuildMachineOSBuild', None)
        if info.parent.name == 'Contents':
            data['RewindDVCandidateRevision'] = 'Public ad-hoc engineering alpha; source '+args.source+'; hardware installation unqualified'
        info.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
    for bundle, entitlements, arch, binary in [
        (driver, root/'Foundation/Config/Driver.entitlements', 'arm64e', driver/gate.DRIVER_ID),
        (app, root/'Foundation/Config/App.entitlements', 'arm64', app/'Contents/MacOS/RewindDV')]:
        gate.run(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', '--entitlements', str(entitlements), str(bundle)], env=env)
        gate.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], env=env)
        signature = subprocess.run(['codesign', '-d', '--verbose=4', str(bundle)], capture_output=True, text=True, env=env)
        gate.require(signature.returncode == 0 and 'Signature=adhoc' in signature.stderr and 'TeamIdentifier=not set' in signature.stderr and 'Authority=' not in signature.stderr and 'runtime' in signature.stderr, 'Ad-hoc signature identity/runtime mismatch')
        gate.require(gate.run(['lipo', '-archs', str(binary)], env=env) == arch, 'Target architecture changed')
        (work/(arch+'-signature.txt')).write_text(signature.stderr)
        # Confirm no signed account identity was synthesized into entitlements.
        signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], capture_output=True, env=env)
        gate.require(signed.returncode == 0, 'Entitlement readback failed')
        values = plistlib.loads(signed.stdout)
        gate.require(values == plistlib.loads(entitlements.read_bytes()), 'Signed entitlements differ from public source')
    for file in app.rglob('*'):
        gate.require(not file.is_symlink(), 'Bundle symlink requires independent review')
        if file.is_file(): file.chmod(0o755 if file.name in ['RewindDV', gate.DRIVER_ID] else 0o644)
    # SwiftPM's native Xcode build backend emits into out/Products/Release.
    # Resolve through --show-bin-path rather than assuming a backend layout.
    cli_bin = Path(gate.run(['xcrun', 'swift', 'build', '--package-path', 'Foundation',
        '--product', 'rewinddv', '-c', 'release', '--scratch-path', str(work/'cli'),
        '--show-bin-path'], env=env)) / 'rewinddv'
    cli = stage/'rewinddv'
    shutil.copyfile(cli_bin, cli); cli.chmod(0o755)
    gate.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
              '--timestamp=none', str(cli)], env=env)
    gate.run(['codesign', '--verify', '--strict', str(cli)], env=env)
    signature = subprocess.run(['codesign', '-d', '--verbose=4', str(cli)],
                               capture_output=True, text=True, env=env)
    gate.require(signature.returncode == 0 and 'Signature=adhoc' in signature.stderr
                 and 'TeamIdentifier=not set' in signature.stderr
                 and 'Authority=' not in signature.stderr and 'runtime' in signature.stderr,
                 'CLI ad-hoc signature identity/runtime mismatch')
    gate.require(gate.run(['lipo', '-archs', str(cli)], env=env) == 'arm64',
                 'CLI architecture changed')
    (work/'cli-signature.txt').write_text(signature.stderr)
    shutil.copyfile(root/'Foundation/CLIAndMCP.md', stage/'CLIAndMCP.md')
    for doc in ['INSTALL.md', 'UNINSTALL.md', 'LICENSE', 'NOTICE', 'ThirdPartyNotices.txt', 'SOURCE-PROVENANCE.txt']:
        shutil.copyfile(root/doc, stage/doc)
    shutil.copytree(root/'licenses', stage/'licenses')
    (stage/'READ-ME.txt').write_text('rewindDV Alpha '+versions['application_version']+' / app'+versions['app_bundle_build']+' / Driver B'+versions['driver_build']+'\nAd-hoc signed engineering prerelease; not notarized. Read INSTALL.md and UNINSTALL.md before use.\nExact packaged artifact has not been installed or physically qualified. Development-source bounded NTSC capture evidence is separate.\nLive extension unload and hot replacement are unqualified; use the documented shutdown/restart maintenance procedure.\nIncludes the ad-hoc signed arm64 rewinddv CLI / MCP client. Read CLIAndMCP.md; start the app and accept its notice before ./rewinddv status or ./rewinddv mcp. External path grants are session-scoped.\nSource: https://github.com/'+gate.REPOSITORY+'/commit/'+args.source+'\n')
    candidate = output/'candidate'; candidate.mkdir()
    artifact = gate.package(stage, candidate, name, versions)
    spec = importlib.util.spec_from_file_location('disclosure', root/'tools/check-publication-content.py')
    disclosure = importlib.util.module_from_spec(spec); spec.loader.exec_module(disclosure)
    privacy = disclosure.inspect(candidate/name, json.loads(config.read_text()))
    (work/'disclosure.json').write_text(json.dumps(privacy, indent=2)+'\n')
    receipt = {'schema':1, 'repository':gate.REPOSITORY, 'repository_id':gate.REPOSITORY_ID, 'source_commit':args.source, 'source_tree':tree, 'public_boundary':gate.PUBLIC_BASE, 'channel':'alpha', 'tag':args.tag, 'prerelease':True, 'versions':versions, 'artifact':artifact, 'toolchain':toolchain, 'checks':[{'check':c['check'],'exit':c['exit'],'log_sha256':c['log_sha256']} for c in checks], 'signing':'ad-hoc', 'hardened_runtime':True, 'notarized':False, 'hardware_qualified':False, 'qualification':'Bounded B190 development-signed NTSC capture/STOP/re-entry evidence; this exact public package is not installed or physically qualified. Live unload unqualified; full-tape completion not claimed.', 'manual_disclosure_review_required':True, 'publication_authorized':False}
    gate.write_json(candidate/'provenance.json', receipt)
    digest = gate.file_sha(candidate/'provenance.json'); gate.verify_artifact(candidate, receipt, digest)
    gate.require(all(f['category']=='manual_format_metadata_or_visual_review_required' for f in privacy['findings']), 'Artifact disclosure finding; inspect retained private report')
    print(json.dumps({'candidate':str(candidate),'artifact_sha256':artifact['sha256'],'provenance_sha256':digest,'manual_review_required':True,'published':False}))


if __name__ == '__main__': main()
