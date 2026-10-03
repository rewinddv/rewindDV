#!/usr/bin/env python3
"""Build a pinned app-only engineering candidate; retain the exact public B183 DEXT.
No installation, hardware access, personal signing identity or release publication.
"""
from pathlib import Path
import hashlib, json, os, plistlib, re, shutil, stat, subprocess, sys, urllib.request, zipfile
hub = Path(__file__).resolve().parents[1]
plan = json.loads((hub/'release/alpha081-source.json').read_text())
root = Path(sys.argv[1]).resolve(); root.mkdir(exist_ok=False)
source = root/'source'; output = root/'output'; output.mkdir()
env = os.environ.copy(); env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', TMPDIR=str(root/'tmp')+'/', CLANG_MODULE_CACHE_PATH=str(root/'modules'), SWIFT_MODULECACHE_PATH=str(root/'swift'))
(root/'tmp').mkdir()
def run(args, cwd=None): return subprocess.check_output(args, cwd=cwd, env=env, stderr=subprocess.STDOUT)
def sha(data): return hashlib.sha256(data).hexdigest()
def tree(path):
    values = {}
    for p in sorted(path.rglob('*')):
        assert not p.is_symlink()
        values[p.relative_to(path).as_posix()] = dict(mode=stat.S_IMODE(p.stat().st_mode), type='directory' if p.is_dir() else 'file')
        if p.is_file(): values[p.relative_to(path).as_posix()]['sha256'] = sha(p.read_bytes())
    return values
run(['git','clone','--quiet','--no-checkout','https://github.com/rewinddv/rewindDV.git',str(source)])
run(['git','checkout','--quiet','--detach',plan['source_commit']],source)
assert run(['git','rev-parse','HEAD'],source).decode().strip()==plan['source_commit']
assert (source/'Foundation/Config/AlphaVersion.txt').read_text().strip()=='0.0.81'
toolchain=run(['xcodebuild','-version']).decode().strip()
assert toolchain=='Xcode 27.0\nBuild version 27A266a', toolchain
project=source/'Foundation/RewindDV.xcodeproj/project.pbxproj';text=project.read_text()
old='"dependencies" = (\n        "000000000000000000000901",\n      );'
assert text.count(old)==1; text=text.replace(old,'"dependencies" = ();')
old='        "000000000000000000000903",\n';assert text.count(old)==1;project.write_text(text.replace(old,''))
command=['xcodebuild','-project','Foundation/RewindDV.xcodeproj','-target','RewindDV','-configuration','Release','SYMROOT='+str(root/'products'),'OBJROOT='+str(root/'objects'),'CLANG_MODULE_CACHE_PATH='+str(root/'modules'),'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','DEVELOPMENT_TEAM=','OTHER_CFLAGS=$(inherited) -ffile-prefix-map='+str(source)+'=/rewindDV -fdebug-prefix-map='+str(source)+'=/rewindDV','OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map '+str(source)+'=/rewindDV -debug-prefix-map '+str(source)+'=/rewindDV','build']
with (root/'build.log').open('wb') as log:
    result=subprocess.run(command,cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT)
if result.returncode:
    print((root/'build.log').read_text()[-16000:]);raise SystemExit(result.returncode)
baseline=urllib.request.urlopen(plan['retained_zip_url']).read();assert sha(baseline)==plan['retained_zip_sha256']
(root/'retained.zip').write_bytes(baseline);retained=root/'retained'
with zipfile.ZipFile(root/'retained.zip') as z:
    for info in z.infolist():
        assert not Path(info.filename).is_absolute() and '..' not in Path(info.filename).parts and stat.S_ISREG(info.external_attr>>16)
        p=retained/info.filename;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(z.read(info));p.chmod(stat.S_IMODE(info.external_attr>>16))
relative=Path('Contents/Library/SystemExtensions/net.rewinddigital.RewindDV.Driver.dext')
oldapp=retained/'RewindDV.app';run(['codesign','--verify','--deep','--strict',str(oldapp)])
oldtree=tree(oldapp/relative)
assert sha((oldapp/relative/'net.rewinddigital.RewindDV.Driver').read_bytes())==plan['retained_dext_sha256']
stage=root/'stage';stage.mkdir();app=stage/'RewindDV.app';built=root/'products/Release/RewindDV.app'
shutil.copytree(built,app,copy_function=shutil.copyfile)
assert not (app/relative).exists();(app/relative).parent.mkdir(parents=True)
shutil.copytree(oldapp/relative,app/relative,copy_function=shutil.copy2)
for name in ['AppIcon.icns','Assets.car']:
    p=app/'Contents/Resources'/name
    if p.exists():p.unlink()
host=app/'Contents/MacOS/RewindDV'
for p in app.rglob('*'):
    assert not p.is_symlink()
    if p.is_file() and relative not in p.relative_to(app).parents:p.chmod(0o755 if p==host else 0o644)
info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes())
assert data['RewindDVAlphaVersion']=='0.0.81' and data['CFBundleVersion']=='183'
data.update(CFBundleShortVersionString='0.0.81',RewindDVCandidateRevision='Alpha 0.0.81 / Build183 engineering alpha; ad-hoc signed, not notarized')
for key in ['BuildMachineOSBuild','CFBundleIconFile','CFBundleIconName']:data.pop(key,None)
info.write_bytes(plistlib.dumps(data,fmt=plistlib.FMT_BINARY))
assert not list(app.rglob('*.provisionprofile'))
run(['codesign','--force','--sign','-','--options','0','--timestamp=none','--entitlements',str(source/'Foundation/Config/App.entitlements'),str(app)])
assert tree(app/relative)==oldtree
for bundle,arch,binary in [(app,'arm64',host),(app/relative,'arm64e',app/relative/'net.rewinddigital.RewindDV.Driver')]:
    run(['codesign','--verify','--deep','--strict',str(bundle)])
    sig=run(['codesign','-d','--verbose=4',str(bundle)]).decode()
    assert 'Signature=adhoc' in sig and 'TeamIdentifier=not set' in sig and 'Authority=' not in sig
    assert run(['lipo','-archs',str(binary)]).decode().strip()==arch
# Human-reviewed package documentation is versioned beside this workflow.
for name in ['INSTALL.md','UNINSTALL.md']:shutil.copyfile(hub/'release'/('alpha081-'+name),stage/name)
manifest=[]
for p in sorted(stage.rglob('*')):
    if p.is_file():
        payload=p.read_bytes()
        for encoding in ['utf-8','utf-16-le','utf-16-be','utf-32-le','utf-32-be']:
            text=payload.decode(encoding,errors='replace')
            assert not re.search(r'/(?:Users|home|Volumes|private/tmp|var/folders)/|Apple Development:|Developer ID Application:|ProvisionedDevices|github_pat_|gh[pousr]_[A-Za-z0-9]{30,}',text,re.I),p.name
        manifest.append(dict(path=p.relative_to(stage).as_posix(),bytes=len(payload),mode=oct(stat.S_IMODE(p.stat().st_mode)),sha256=sha(payload)))
archive=output/'rewindDV-Alpha-0.0.81-Build183-AdHoc.zip'
with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_STORED) as z:
    for f in manifest:
        entry=zipfile.ZipInfo(f['path'],(2026,10,3,0,0,0));entry.create_system=3;entry.external_attr=(stat.S_IFREG|int(f['mode'],8))<<16
        z.writestr(entry,(stage/f['path']).read_bytes())
digest=sha(archive.read_bytes());(output/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
(output/'bundle-tree-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(output/'candidate-seal.json').write_text(json.dumps(dict(source_commit=plan['source_commit'],toolchain=toolchain,zip=archive.name,sha256=digest,app_sha256=sha(host.read_bytes()),dext_sha256=plan['retained_dext_sha256'],driver_tree_unchanged=True,driver_tree=oldtree,signature='adhoc',notarized=False,installed=False),indent=2)+'\n')
print('Candidate built and sealed; release publication requires a separate verified digest gate.')
print(digest)
