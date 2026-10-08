#!/usr/bin/env python3
"""Validate independent lifecycle status against source and reviewed public inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.request
import release_candidate as release

ROOT = Path(__file__).resolve().parents[1]
DOCS = ('README.md', 'COMPATIBILITY.md', 'RELEASE-NOTES.md')
START, END = '<!-- project-status:start -->', '<!-- project-status:end -->'
INPUT_ROOTS = ('Foundation/', 'ASFWDriver/', 'tests/', 'licenses/')
NOTICES = {'LICENSE', 'NOTICE', 'ThirdPartyNotices.txt', 'ACKNOWLEDGMENTS.md',
           'ASFireWire-LICENSE.txt', 'ASFireWire-NOTICE.txt'}


def check(ok, message):
    if not ok:
        raise ValueError(message)


def validate_identities(status, alpha, driver, app_build=None):
    check(status['schema_version'] == 1, 'Unsupported status schema')
    for name in ('development', 'public_release'):
        identity = status[name]
        check(re.fullmatch(r'\d+\.\d+\.\d+', identity['application_version']), 'Invalid alpha version')
        check(type(identity['driver_build']) is int and identity['driver_build'] > 0, 'Invalid driver build')
        check(re.fullmatch(r'[0-9a-f]{40}', identity['source_revision']), 'Full public source revision required')
    check(status['development']['application_version'] == alpha, 'Development alpha disagrees with source')
    check(status['development']['driver_build'] == driver, 'Development driver disagrees with source')
    if app_build is not None:
        check(status['development'].get('application_build') == app_build, 'App build disagrees with source')
    check(type(status['development'].get('application_build')) is int, 'Independent app build required')
    check(isinstance(status['qualification'].get('capture'), str) and isinstance(status['qualification'].get('hot_unload'), str), 'Separate capture and hot-unload states required')
    r = status['public_release']
    if r.get('offline_only', False):
        check(r.get('driver_included') is False and r.get('requires_sip_disabled') is False, 'Offline package must exclude driver and SIP requirement')
    check(r['tag'] == 'alpha-' + r['application_version'], 'Release tag disagrees with application version')
    check(re.fullmatch(r'[0-9a-f]{64}', r['package_sha256']), 'Exact released package hash required')
    check(status['links']['source'] == 'https://github.com/' + release.REPOSITORY, 'Wrong canonical project')
    check(status['links']['release'] == status['links']['source'] + '/releases/tag/' + r['tag'], 'Wrong release link')
    # Deliberately no arithmetic/coupling across app, driver or lifecycle versions.


def source_versions(root):
    alpha = (root / 'Foundation/Config/AlphaVersion.txt').read_text().strip()
    config = (root / 'Foundation/Config/DriverBuild.xcconfig').read_text()
    builds = re.findall(r'^REWINDDV_DRIVER_BUILD = ([1-9][0-9]*)$', config, re.M)
    check(len(builds) == 1 and int(builds[0]) <= 4294967295, 'Ambiguous canonical driver build')
    check('CURRENT_PROJECT_VERSION = $(REWINDDV_DRIVER_BUILD)' in config,
          'Driver bundle version is not bound to canonical driver build')
    project = (root / 'Foundation/RewindDV.xcodeproj/project.pbxproj').read_text()
    # CI uses the same checked-in OpenStep structure without Apple plutil.
    blocks = re.findall(r'"buildSettings" = \{(.*?)\n      \};', project, re.S)
    driver_blocks = [b for b in blocks if '"PRODUCT_BUNDLE_IDENTIFIER" = "net.rewinddigital.RewindDV.Driver";' in b]
    check(len(driver_blocks) == 2 and not any('"CURRENT_PROJECT_VERSION"' in b for b in driver_blocks),
          'Driver build must resolve through its canonical xcconfig')
    config_ids = re.findall(r'"([A-Za-z0-9]+)" = \{\n      "isa" = "PBXFileReference";\n      "lastKnownFileType" = "text.xcconfig";\n      "path" = "Config/DriverBuild.xcconfig";', project)
    check(len(config_ids) == 1 and project.count('"baseConfigurationReference" = "' + config_ids[0] + '";') == 2,
          'Both driver configurations must use the canonical xcconfig')
    header = (root / 'Foundation/Config/DriverVersion.hpp').read_text()
    check('REWINDDV_STRINGIFY(REWINDDV_DRIVER_BUILD)' in header, 'Compiled driver metadata is not canonical')
    return alpha, int(builds[0])


def source_app_build(root):
    project = (root / 'Foundation/RewindDV.xcodeproj/project.pbxproj').read_text()
    defaults = re.findall(r'"CURRENT_PROJECT_VERSION" = "([0-9]+)";', project)
    check(len(set(defaults)) == 1, 'Ambiguous independent app build')
    return int(defaults[0])


def status_block(status):
    d, r = status['development'], status['public_release']
    if r.get('offline_only', False):
        download = (f"**Latest public download:** [Alpha {r['application_version']} offline-only / app build {r['application_build']}]"
                    f"({status['links']['release']}) — engineering prerelease, ad-hoc signed and not notarized. "
                    "No DriverKit extension is included; driver activation, deck control and physical acquisition are disabled. "
                    "Offline operations require no SIP change.\n\n")
    else:
        download = (f"**Latest public download:** [Alpha {r['application_version']} / Driver B{r['driver_build']}]"
                    f"({status['links']['release']}) — engineering prerelease, ad-hoc signed and not notarized. "
                    "Driver installation requires disabling SIP, which reduces macOS security. Offline playback, Surgery and inspection require no driver activation.\n\n")
    return (START + "\n"
            f"**Current development:** Alpha {d['application_version']} / Driver B{d['driver_build']}. "
            f"App build {d['application_build']}. [Reviewed public source]({status['links']['source']}/tree/{d['source_revision']}).\n\n"
            + download + "Development source and downloads have separate identities and qualification. "
            "Application versions and driver builds advance independently. "
            "[Machine-readable status](PROJECT-STATUS.json).\n" + END)



def validate_manifest(root, status):
    manifest = json.loads((root / 'SOURCE-MANIFEST.json').read_text())
    source = status['development']['source_revision']
    check(manifest['source_revision'] == source, 'Status and source manifest disagree')
    subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', source, 'HEAD'], check=True)
    entries = {}
    for line in subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', source], text=True).splitlines():
        meta, path = line.split('\t'); mode, kind, blob = meta.split()
        if path.startswith(INPUT_ROOTS) or path in NOTICES:
            entries[path] = (mode, blob)
    paths = [r['path'] for r in manifest['files']]
    check(len(paths) == len(set(paths)) and set(paths) == set(entries), 'Source manifest coverage mismatch')
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).splitlines()
    check({p for p in tracked if p.startswith(INPUT_ROOTS) or p in NOTICES} == set(paths), 'Build input added/removed without new manifest')
    for row in manifest['files']:
        path = row['path']; file = root / path
        check((row['mode'], row['git_blob']) == entries[path], 'Source revision blob mismatch: ' + path)
        check(file.is_file() and not file.is_symlink(), 'Missing/nonregular input: ' + path)
        check(hashlib.sha256(file.read_bytes()).hexdigest() == row['sha256'], 'Source input drift: ' + path)
        blob = subprocess.check_output(['git', 'hash-object', str(file)], text=True).strip()
        check(blob == row['git_blob'], 'Source blob drift: ' + path)
    return len(paths)


def validate_release(status, remote, provenance=None):
    r = status['public_release']
    check(remote['tag_name'] == r['tag'] and not remote['draft'] and remote['prerelease'], 'Release lifecycle mismatch')
    packages = [a for a in remote['assets'] if a['name'] == r['package_name']]
    check(len(packages) == 1 and packages[0]['digest'] == 'sha256:' + r['package_sha256'], 'Released package hash mismatch')
    check(any(a['name'] == r['package_name'] + '.sha256' for a in remote['assets']), 'Release checksum absent')
    if r['tag'] not in release.HISTORICAL:
        check(provenance is not None, 'New release requires provenance.json')
        check(provenance.get('offline_only', False) == r.get('offline_only', False), 'Released distribution mode mismatch')
        if r.get('offline_only', False):
            check(provenance.get('driver_included') is False, 'Offline provenance includes driver')
        versions = provenance['versions']
        check(versions['application_version'] == r['application_version'], 'Released application mismatch')
        check(str(versions['driver_build']) == str(r['driver_build']), 'Released driver mismatch')
        check(str(versions.get('app_bundle_build')) == str(r['application_build']), 'Released app build mismatch')
        check(provenance['source_commit'] == r['source_revision'] and provenance['tag'] == r['tag'], 'Released source/tag mismatch')
        check(provenance['artifact']['sha256'] == r['package_sha256'] and provenance['artifact']['name'] == r['package_name'], 'Released provenance hash mismatch')
        check(provenance['repository_id'] == release.REPOSITORY_ID and provenance['repository'] == release.REPOSITORY, 'Released repository mismatch')
        manifests = [a for a in remote['assets'] if a['name'] == 'manifest.json']
        check(len(manifests) == 1 and manifests[0]['digest'] == 'sha256:' + provenance['artifact']['manifest_sha256'], 'Released manifest digest mismatch')


def live_check(status):
    repo = release.api('repos/' + release.REPOSITORY)
    release.destination(repo['full_name'], repo['id'])
    check(not repo['private'] and not repo['archived'], 'Canonical project unavailable')
    # GitHub /latest excludes prereleases; enumerate them explicitly.
    releases = []; page = 1
    while True:
        chunk = release.api('repos/' + release.REPOSITORY + f'/releases?per_page=100&page={page}')
        releases.extend(chunk)
        if len(chunk) < 100: break
        page += 1
    available = [r for r in releases if not r['draft'] and any(a['name'].endswith('.zip') for a in r['assets'])]
    newest = max(available, key=lambda r: r['published_at'])
    provenance = None
    if newest['tag_name'] not in release.HISTORICAL:
        asset = next(a for a in newest['assets'] if a['name'] == 'provenance.json')
        with urllib.request.urlopen(asset['browser_download_url'], timeout=30) as response:
            raw = response.read(1024 * 1024 + 1)
        check(len(raw) <= 1024 * 1024, 'Provenance too large')
        check(asset['digest'] == 'sha256:' + hashlib.sha256(raw).hexdigest(), 'Provenance asset digest mismatch')
        provenance = json.loads(raw)
        refs = dict(line.split()[::-1] for line in subprocess.check_output(['git', 'ls-remote', status['links']['source'] + '.git', 'refs/tags/' + newest['tag_name'], 'refs/tags/' + newest['tag_name'] + '^{}'], text=True).splitlines())
        tag_ref = 'refs/tags/' + newest['tag_name']
        check(refs.get(tag_ref + '^{}', refs.get(tag_ref)) == status['public_release']['source_revision'], 'Release tag does not bind exact source')
        commit = release.api('repos/' + release.REPOSITORY + '/git/commits/' + status['public_release']['source_revision'])
        check(commit['tree']['sha'] == provenance['source_tree'], 'Released tree mismatch')
    validate_release(status, newest, provenance)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-docs', action='store_true')
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    status = json.loads((ROOT / 'PROJECT-STATUS.json').read_text())
    validate_identities(status, *source_versions(ROOT), app_build=source_app_build(ROOT))
    count = validate_manifest(ROOT, status)
    block = status_block(status)
    for name in DOCS:
        path = ROOT / name; text = path.read_text()
        check(text.count(START) == 1 and text.count(END) == 1, 'Missing/duplicate status block: ' + name)
        updated = re.sub(re.escape(START) + '.*?' + re.escape(END), lambda _: block, text, flags=re.S)
        if args.write_docs: path.write_text(updated)
        else: check(text == updated, 'Stale current status: ' + name)
    if args.live: live_check(status)
    print(f'PASS: independent development/release identities; {count} source inputs; current documentation' + ('; live release' if args.live else ''))


if __name__ == '__main__':
    main()
