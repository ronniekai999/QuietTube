#!/usr/bin/env python3
import hashlib
import json
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

project = Path(__file__).resolve().parent.parent
upstream = Path(sys.argv[1]).resolve()
metadata = json.loads((project / 'engine-metadata.json').read_text())
# Chromium writes a local ruleset cache beside unpacked extension sources.
# Let Edge generate its own cache; ship the reviewed JSON rules and scripts.
shutil.rmtree(project / 'extension' / '_metadata', ignore_errors=True)
archive = project / 'upstream-source.tar.gz'
with tarfile.open(archive, 'w:gz', compresslevel=6) as tar:
    for file in sorted(upstream.rglob('*')):
        relative = file.relative_to(upstream)
        if any(part == '.git' for part in relative.parts):
            continue
        if relative.parts[0] == 'dist' and not str(relative).startswith('dist/build/mv3-data'):
            continue
        if file.is_file():
            tar.add(file, arcname='uBlock/' + relative.as_posix(), recursive=False)
    import io
    value = (metadata['commit'] + '\n').encode()
    info = tarfile.TarInfo('uBlock/UPSTREAM-COMMIT')
    info.size = len(value)
    tar.addfile(info, io.BytesIO(value))

entries = []
for file in sorted(project.rglob('*')):
    if not file.is_file() or file.name == 'checksums.json' or '.git' in file.relative_to(project).parts:
        continue
    entries.append({'path': file.relative_to(project).as_posix(), 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
(project / 'checksums.json').write_text(json.dumps(entries, indent=2) + '\n')
package = project.parent / 'QuietTube-Windows-x64-0.1.1.zip'
with zipfile.ZipFile(package, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zip_file:
    for file in sorted(project.rglob('*')):
        if file.is_file() and '.git' not in file.relative_to(project).parts:
            zip_file.write(file, 'QuietTube/' + file.relative_to(project).as_posix())
checksum = hashlib.sha256(package.read_bytes()).hexdigest()
(package.parent / (package.name + '.sha256')).write_text(checksum + '  ' + package.name + '\n')
print(json.dumps({'package': str(package), 'bytes': package.stat().st_size, 'sha256': checksum, 'files': len(entries)}, indent=2))
