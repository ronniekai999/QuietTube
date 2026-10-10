#!/usr/bin/env python3
"""Build QuietTube's small, audited overlay on a pinned upstream uBO Lite build."""
import base64
import argparse
from datetime import datetime, timezone
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('upstream', type=Path)
parser.add_argument('--browser', choices=['edge', 'safari'], default='edge')
parser.add_argument('--destination', type=Path)
parser.add_argument('--app-platform', choices=['Windows', 'Mac'], default='Windows')
parser.add_argument('--app-version', default='0.1.2')
options = parser.parse_args()
project = Path(__file__).resolve().parent.parent
upstream = options.upstream.resolve()
engine = upstream / f'dist/build/uBOLite.{options.browser}'
if not (engine / 'manifest.json').is_file():
    raise SystemExit(f'Build the pinned upstream {options.browser} extension first.')
destination = options.destination.resolve() if options.destination else project / 'extension'
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(engine, destination)
key_file = project / 'extension-key.txt'
if not key_file.exists():
    with tempfile.TemporaryDirectory(prefix='quiettube-key-') as directory:
        key = Path(directory) / 'private.pem'
        subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
        public = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-pubout', '-outform', 'DER'], stderr=subprocess.DEVNULL)
        key_file.write_text(base64.b64encode(public).decode() + '\n')
public_key = key_file.read_text().strip()
digest = hashlib.sha256(base64.b64decode(public_key)).hexdigest()[:32]
extension_id = ''.join(chr(ord('a') + int(n, 16)) for n in digest)
(project / 'extension-id.txt').write_text(extension_id + '\n')
manifest_file = destination / 'manifest.json'
manifest = json.loads(manifest_file.read_text())
metadata = {
    'name': 'uBlock Origin Lite', 'version': manifest['version'],
    'source': 'https://github.com/gorhill/uBlock',
    'commit': subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip(),
    'builtAtUtc': datetime.now(timezone.utc).isoformat(), 'quiettubeVersion': options.app_version
}
(destination / 'engine-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
if options.destination is None:
    (project / 'engine-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
manifest.update(name='QuietTube', short_name='QuietTube', version=options.app_version,
    version_name=options.app_version + ' · uBO Lite ' + metadata['version'],
    description=f'YouTube filtering with a {options.app_platform} companion. Independent modification of uBlock Origin Lite.',
    author='QuietTube contributors; filtering engine by Raymond Hill and contributors', key=public_key,
    options_page='quiettube/help.html', homepage_url='https://github.com/uBlockOrigin/uBOL-home',
    host_permissions=['https://*.youtube.com/*'])
manifest['permissions'] = [p for p in manifest['permissions'] if p not in ['userScripts', 'activeTab']]
manifest['permissions'].append('nativeMessaging')
if options.browser == 'safari':
    manifest.pop('key', None)
    manifest.pop('version_name', None)
    # Safari displays its containing app's version and uses its bundle identity.
    # Chrome's public extension key remains unchanged in the Chrome build.
manifest['action']['default_popup'] = 'quiettube/popup.html'
manifest['action']['default_title'] = 'QuietTube'
manifest['commands'] = {}
manifest_file.write_text(json.dumps(manifest, indent=2) + '\n')
overlay = project / 'extension-overlay'
ui = destination / 'quiettube'
ui.mkdir()
for name in ['popup.html', 'popup.css', 'popup.js', 'help.html']:
    shutil.copy2(overlay / name, ui / name)
bridge_dir = destination / 'js/quiettube'
bridge_dir.mkdir()
shutil.copy2(overlay / 'bridge.js', bridge_dir / 'bridge.js')
shutil.copy2(overlay / 'platform.js', bridge_dir / 'platform.js')
(bridge_dir / 'engine.js').write_text('export const ENGINE = ' + json.dumps(metadata) + ';\n')

def replace_once(file, before, after):
    content = file.read_text()
    if content.count(before) != 1:
        raise SystemExit(f'Upstream changed: expected one patch target in {file.name}. Review integration before building.')
    file.write_text(content.replace(before, after))

replace_once(destination / 'js/mode-manager.js',
    "    none: [],\n    basic: [],\n    optimal: [ 'all-urls' ],\n    complete: [],",
    "    none: [ 'all-urls' ],\n    basic: [],\n    optimal: [ 'youtube.com' ],\n    complete: [],")
config = destination / 'js/config.js'
replace_once(config, "    hasBroadHostPermissions: true,", "    hasBroadHostPermissions: false,")
replace_once(config, "    strictBlockMode: webextFlavor !== 'safari',", "    strictBlockMode: false,")
replace_once(config, "    popupBlockMode: true,", "    popupBlockMode: false,")
background = destination / 'js/background.js'
replace_once(background, '    MODE_BASIC,', '    MODE_NONE,\n    MODE_BASIC,')
replace_once(background, 'const afterLevel = await setDefaultFilteringMode(MODE_BASIC);',
    'const afterLevel = await setDefaultFilteringMode(MODE_NONE); // QuietTube: default scope stays YouTube-only.')
replace_once(background, 'if ( afterLevel === MODE_BASIC ) {', 'if ( afterLevel === MODE_NONE ) {')
replace_once(destination / 'js/ext.js',
    'export function supportsUserScripts() {\n    try { browser.userScripts.getScripts(); }\n    catch { return false; }\n    return true;\n}',
    'export function supportsUserScripts() {\n    return false; // QuietTube uses packaged scriptlets, not downloaded user scripts.\n}')
background.write_text(background.read_text() + "\n// QuietTube integration, GPL-3.0-or-later.\nimport { initializeCompanion } from './quiettube/bridge.js';\ninitializeCompanion(isFullyInitialized);\n")
# Preserve engine source copyright; clearly identify this as a modified distribution.
(destination / 'QUIETTUBE-NOTICE.txt').write_text(
    f'QuietTube {options.app_version} is an independent modification of uBlock Origin Lite.\n'
    'Upstream authors: Raymond Hill and contributors. License: GPL-3.0-or-later.\n'
    f"Pinned source: {metadata['source']}/tree/{metadata['commit']}\n"
    'Changes: YouTube-only defaults, custom popup, native companion messaging, and branding.\n'
    'Matching source, overlay, filter inputs, and license are provided with this package.\n')
if options.app_platform == 'Mac':
    shutil.copy2(project / 'mac/extension-overlay/help.html', ui / 'help.html')
    popup = ui / 'popup.html'
    popup.write_text(popup.read_text().replace('Checking Windows app', 'Checking Mac app'))
if options.destination is None:
    shutil.copy2(upstream / 'LICENSE.txt', project / 'LICENSE.txt')
    shutil.copy2(ui / 'help.html', project / 'START-HERE.html')
    shutil.copy2(ui / 'popup.css', project / 'popup.css')
print(json.dumps({'extensionId': extension_id, 'engine': metadata, 'path': str(destination)}, indent=2))
