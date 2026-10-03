#!/usr/bin/env python3
"""Local disclosure preflight, not anonymity certification.
Private JSON config: {"terms": [...], "private_values": [...]} outside publication tree.
Writes categories and redacted locations only. No secret validation or network access.
Nonzero exit means a finding or an inspection gap; every release must also inspect
signing/profiles, Git metadata, images and formats this checker cannot fully interpret.
"""
import argparse, hashlib, io, json, os, plistlib, re, stat, unicodedata, urllib.parse, zipfile, subprocess, shutil
from pathlib import Path

TEXT = {'.swift','.cpp','.hpp','.h','.c','.iig','.m','.mm','.def','.inc','.md','.txt','.json','.ndjson','.xml','.xsd','.plist','.entitlements','.pbxproj','.py','.rb','.sh','.zsh','.yml','.yaml','.gitignore','.xcconfig','.svg','.html'}
MAX_BYTES = 256 * 1024 * 1024

def normalized(value):
    for _ in range(3):
        next_value = urllib.parse.unquote(value)
        if next_value == value: break
        value = next_value
    return ''.join(c for c in unicodedata.normalize('NFKC', value).casefold() if c.isalnum())

def inspect(target, config):
    target = Path(target)
    terms = [normalized(x) for x in config.get('terms', []) if normalized(x)]
    values = [normalized(x) for x in config.get('private_values', []) if normalized(x)]
    findings, files = [], []
    def safe(value):
        for term in config.get('terms', []) + config.get('private_values', []):
            value = re.sub(re.escape(term), '[redacted]', value, flags=re.I)
        # Encoded or punctuation-separated identity in a filename gets an opaque label.
        if any(t in normalized(value) for t in terms + values):
            return '[redacted-location]'
        return value
    def issue(path, category):
        item = {'location': safe(path), 'category': category}
        if item not in findings: findings.append(item)
    def scan_text(value, path):
        norm = normalized(value)
        if any(t in norm for t in terms): issue(path, 'configured_personal_name_match')
        if any(t in norm for t in values): issue(path, 'configured_private_identifier_match')
        if re.search(r'/(?:Users|home|Volumes)/[^\s/"<>]+|[A-Za-z]:[/\\](?:Users|Projects)[/\\]', value):
            issue(path, 'personal_or_machine_path_candidate')
        if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bAKIA[0-9A-Z]{16}\b', value):
            issue(path, 'credential_marker_candidate')
    def scan(data, path, depth=0):
        files.append({'location': safe(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        scan_text(path, path)
        if len(data) > MAX_BYTES:
            issue(path, 'uninspected_size_limit'); return
        member_path = path.rsplit('!', 1)[-1]
        ext = Path(member_path).suffix.lower()
        for encoding in ['utf-8', 'utf-16-le', 'utf-16-be', 'utf-32-le', 'utf-32-be']:
            scan_text(data.decode(encoding, errors='ignore'), path)
        if data.startswith(b'bplist') or ext in {'.plist', '.entitlements'}:
            try:
                parsed = plistlib.loads(data)
                scan_text(json.dumps(parsed, default=str), path)
                if isinstance(parsed, dict) and parsed.get('ProvisionedDevices'):
                    issue(path, 'registered_device_list')
            except Exception: issue(path, 'unparsed_structured_metadata')
        if zipfile.is_zipfile(io.BytesIO(data)):
            if depth >= 3: issue(path, 'uninspected_archive_depth'); return
            try:
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    scan_text(archive.comment.decode('utf-8', errors='ignore'), path + ':comment')
                    if sum(x.file_size for x in archive.infolist()) > MAX_BYTES:
                        issue(path, 'uninspected_archive_expansion_limit'); return
                    for entry in archive.infolist():
                        name = entry.filename
                        if Path(name).is_absolute() or '..' in Path(name).parts:
                            issue(path, 'unsafe_archive_path'); continue
                        if entry.is_dir(): continue
                        child = path + '!' + name
                        scan_text((entry.comment + entry.extra).decode('utf-8', errors='ignore'), child + ':metadata')
                        if stat.S_ISLNK(entry.external_attr >> 16):
                            scan_text(archive.read(entry).decode('utf-8', errors='ignore'), child)
                            issue(child, 'symlink_requires_manual_review'); continue
                        scan(archive.read(entry), child, depth + 1)
            except Exception: issue(path, 'unparsed_archive')
        elif ext in {'.png','.jpg','.jpeg','.icns','.car','.pdf','.gif','.webp','.tiff','.dmg','.pkg','.p12','.provisionprofile'} or data.startswith((b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\x00\x05\x16\x07')):
            issue(path, 'manual_format_metadata_or_visual_review_required')
        elif Path(member_path).name == '.DS_Store' or '/__MACOSX/' in path or Path(member_path).name.startswith('._'):
            issue(path, 'macos_metadata_requires_review_or_exclusion')
        elif ext not in TEXT and Path(member_path).name not in {'LICENSE','NOTICE','CMakeLists.txt','.gitignore'}:
            issue(path, 'unclassified_format_requires_review')
    if target.is_dir():
        for root, dirs, names in os.walk(target, followlinks=False):
            for name in list(dirs):
                p=Path(root)/name
                if p.is_symlink():
                    issue(str(p.relative_to(target)), 'symlink_requires_manual_review'); dirs.remove(name)
            for name in sorted(names):
                p=Path(root)/name; rel=str(p.relative_to(target))
                if p.is_symlink():
                    scan_text(os.readlink(p), rel); issue(rel, 'symlink_requires_manual_review'); continue
                try:
                    if hasattr(os, 'listxattr'):
                        attrs = os.listxattr(p)
                        for attr in attrs:
                            scan_text(attr, rel + ':xattr')
                            scan_text(os.getxattr(p, attr).decode('utf-8', errors='ignore'), rel + ':xattr')
                        if attrs: issue(rel, 'extended_attribute_requires_review')
                    elif shutil.which('xattr'):
                        result = subprocess.run(['xattr', '-l', str(p)], capture_output=True)
                        if result.returncode: issue(rel, 'extended_attributes_uninspected')
                        elif result.stdout:
                            scan_text(result.stdout.decode('utf-8', errors='ignore'), rel + ':xattr')
                            issue(rel, 'extended_attribute_requires_review')
                    else: issue(rel, 'extended_attributes_uninspected')
                    scan(p.read_bytes(), rel)
                except Exception: issue(rel, 'unreadable_input')
    else:
        scan(target.read_bytes(), target.name)
    return {'status': 'BLOCKED' if findings else 'PASS', 'scope': 'configured names/identifiers, text encodings, plist, ZIP entries and metadata; manual gaps explicit', 'files': files, 'findings': findings, 'approval_invalidated_by_any_input_change': True}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('target');p.add_argument('--private-config', required=True);p.add_argument('--output', required=True)
    a=p.parse_args();target=Path(a.target).resolve();conf=Path(a.private_config).resolve();output=Path(a.output).resolve()
    if target.is_dir() and (conf==target or target in conf.parents or target==output or target in output.parents):
        p.error('Keep private configuration and findings outside the publication tree')
    report=inspect(target,json.loads(conf.read_text()));output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'status':report['status'],'file_count':len(report['files']),'finding_count':len(report['findings'])}))
    raise SystemExit(0 if report['status']=='PASS' else 1)
if __name__=='__main__': main()
