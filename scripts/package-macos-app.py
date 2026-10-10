#!/usr/bin/env python3
"""Package the signed native Mac app with matching source and local install steps."""
import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path

project = Path(__file__).resolve().parent.parent
workspace = project.parent.parent
work = workspace / 'work/mac'
app = Path((work / 'build/app-path.txt').read_text().strip()).resolve()
upstream = workspace / 'work/vendor/uBlock'
version = (project / 'mac/VERSION').read_text().strip()
architecture = subprocess.check_output(['uname', '-m'], text=True).strip()
label = 'AppleSilicon' if architecture == 'arm64' else 'Intel'
output = project.parent / f'QuietTube-macOS-{label}-{version}'
output.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.quiettube.mac' or info['CFBundleShortVersionString'] != version:
    raise SystemExit('The built Mac app does not match this source version.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

source = work / 'build/QuietTube-source.zip'
upstream_archive = work / 'build/uBlock-matching-source.tar.gz'
with tarfile.open(upstream_archive, 'w:gz', compresslevel=6) as tar:
    for file in sorted(upstream.rglob('*')):
        relative = file.relative_to(upstream)
        if '.git' in relative.parts or (relative.parts[0] == 'dist' and not str(relative).startswith('dist/build/mv3-data')):
            continue
        if file.is_file():
            tar.add(file, arcname='uBlock/' + relative.as_posix(), recursive=False)
    commit = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'])
    entry = tarfile.TarInfo('uBlock/UPSTREAM-COMMIT'); entry.size = len(commit); tar.addfile(entry, io.BytesIO(commit))

files = subprocess.check_output(['git', '-C', str(project), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name in sorted(set(filter(None, files))):
        file = project / name
        if not file.is_file() or file.is_symlink():
            raise SystemExit(f'Unexpected source member: {name}')
        archive.write(file, 'QuietTube/' + name)
    archive.write(upstream_archive, 'QuietTube/uBlock-matching-source.tar.gz')
source_folder = app / 'Contents/Resources/Source'
source_folder.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, source_folder / source.name)
identity = os.environ.get('QUIETTUBE_SIGNING_IDENTITY')
if not identity:
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    import re
    matches = re.findall(r'"((?:Developer ID Application|Apple Development):[^\"]+)"', identities)
    if not matches:
        raise SystemExit('No Mac signing identity is available.')
    identity = matches[0]
subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none',
    '--entitlements', str(work / 'project/QuietTube/QuietTube/QuietTube.entitlements'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

# Build the archive in a local temporary directory, avoiding File Provider's
# bundle metadata. Preserve executable modes and omit extended attributes.
import tempfile
with tempfile.TemporaryDirectory(prefix='quiettube-mac-package-') as temporary:
    stage = Path(temporary) / output.name
    stage.mkdir()
    subprocess.run(['ditto', '--norsrc', '--noextattr', str(app), str(stage / 'QuietTube.app')], check=True)
    installer = stage / 'Install QuietTube.command'
    shutil.copyfile(project / 'mac/Install QuietTube.command', installer); installer.chmod(0o755)
    shutil.copyfile(project / 'mac/README.md', stage / 'README.md')
    shutil.copyfile(project / 'LICENSE.txt', stage / 'LICENSE.txt')
    shutil.copyfile(source, stage / 'QuietTube-source.zip')
    for name in ['native-check-results.json', 'installer-check-results.json', 'safari-transport-results.json', 'browser-check-results.json']:
        if (project / 'mac' / name).exists():
            shutil.copyfile(project / 'mac' / name, stage / name)
    entries = [{'path': file.relative_to(stage).as_posix(), 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()}
               for file in sorted(stage.rglob('*')) if file.is_file()]
    (stage / 'checksums.json').write_text(json.dumps(entries, indent=2) + '\n')
    package = output.parent / (output.name + '.zip')
    subprocess.run(['ditto', '--norsrc', '--noextattr', '-c', '-k', '--keepParent', str(stage), str(package)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage / 'QuietTube.app')], check=True)
    shutil.copyfile(stage / 'checksums.json', output / 'checksums.json')
digest = hashlib.sha256(package.read_bytes()).hexdigest()
package.with_name(package.name + '.sha256').write_text(digest + '  ' + package.name + '\n')
receipt = {'package': package.name, 'bytes': package.stat().st_size, 'sha256': digest, 'appVersion': version,
           'architecture': architecture, 'payloadFiles': len(entries), 'signed': True, 'notarized': False,
           'signingScope': 'Local Mac preview. Developer ID signing and notarization are required for public distribution.',
           'sourceCommit': subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], text=True).strip(),
           'sourceSnapshotIncludesWorkingTree': bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'])),
           'upstreamCommit': commit.decode().strip()}
(project.parent / f'QuietTube-macOS-{label}-{version}-verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
