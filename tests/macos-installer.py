#!/usr/bin/env python3
"""Exercise the production Mac installer with signed apps in disposable folders."""
import datetime
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

project = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1]).resolve()
report = pathlib.Path(sys.argv[2])
results, errors = [], []

with tempfile.TemporaryDirectory(prefix='QuietTube-installer-check-') as temporary:
    root = pathlib.Path(temporary)
    package = root / 'package'
    package.mkdir()
    subprocess.run(['ditto', '--norsrc', '--noextattr', str(app), str(package / 'QuietTube.app')], check=True)
    installer = package / 'Install QuietTube.command'
    shutil.copyfile(project / 'mac/Install QuietTube.command', installer)
    tools = root / 'tools'
    tools.mkdir()
    # Only the launch boundary is stubbed. Real ditto, codesign, shell logic and
    # the bundled exclusive-rename helper execute in every installation.
    (tools / 'open').write_text('#!/bin/zsh\nexit ${QUIETTUBE_TEST_OPEN_EXIT:-0}\n')
    (tools / 'open').chmod(0o755)

    def run(destination, **extra):
        environment = dict(os.environ, QUIETTUBE_TEST_APPLICATIONS_DIR=str(destination),
                           PATH=str(tools) + ':' + os.environ['PATH'], **extra)
        return subprocess.run(['/bin/zsh', str(installer)], env=environment, text=True,
                              capture_output=True, timeout=45)

    def check(name, action):
        try:
            action()
            results.append(name)
        except Exception as error:
            errors.append(name + ': ' + str(error))

    def require(condition, message):
        if not condition:
            raise AssertionError(message)

    applications = root / 'Applications'
    destination = applications / 'QuietTube.app'

    def first_install():
        result = run(applications)
        require(result.returncode == 0, result.stdout + result.stderr)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
        info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        require(info['CFBundleIdentifier'] == 'com.quiettube.mac', 'Wrong installed app')
        require(not list(applications.glob('.QuietTube-install.*')), 'Staging folder was not cleaned')
    check('First install copies and verifies the signed app without administrator access', first_install)

    def update():
        sentinel = applications / 'unrelated.txt'
        sentinel.write_text('preserved')
        result = run(applications)
        require(result.returncode == 0, result.stdout + result.stderr)
        require(sentinel.read_text() == 'preserved', 'Unrelated file changed')
        require(not list(applications.glob('.QuietTube-install.*')), 'Update backup was not cleaned')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    check('Signed update preserves unrelated files and removes only its own staging directory', update)

    def unknown_destination():
        directory = root / 'foreign'
        target = directory / 'QuietTube.app'
        target.mkdir(parents=True)
        sentinel = target / 'foreign.txt'
        sentinel.write_text('preserved')
        require(run(directory).returncode != 0, 'Unknown app was accepted')
        require(sentinel.read_text() == 'preserved', 'Unknown app was changed')
    check('An unrecognized existing app is refused and preserved', unknown_destination)

    def linked_destination():
        directory = root / 'linked-app'
        directory.mkdir()
        target = root / 'outside'
        target.mkdir()
        sentinel = target / 'foreign.txt'
        sentinel.write_text('preserved')
        (directory / 'QuietTube.app').symlink_to(target, target_is_directory=True)
        require(run(directory).returncode != 0, 'Linked app was accepted')
        require(sentinel.read_text() == 'preserved', 'Link target changed')
    check('A symbolic-link app destination preserves its outside target', linked_destination)

    def linked_applications():
        directory = root / 'linked-applications'
        directory.symlink_to(root / 'outside', target_is_directory=True)
        require(run(directory).returncode != 0, 'Linked Applications folder was accepted')
        require(not (root / 'outside/QuietTube.app').exists(), 'App escaped through destination link')
    check('A symbolic-link Applications folder is rejected before copying', linked_applications)

    def tampered_source():
        manifest = package / 'QuietTube.app/Contents/Resources/ChromeExtension/manifest.json'
        saved = manifest.read_bytes()
        try:
            manifest.write_bytes(saved + b' ')
            directory = root / 'tampered'
            require(run(directory).returncode != 0, 'Modified signature was accepted')
            require(not directory.exists(), 'Destination was touched before signature validation')
        finally:
            manifest.write_bytes(saved)
    check('A changed source payload fails signature validation before installation', tampered_source)

    def launch_failure():
        directory = root / 'launch-failure'
        result = run(directory, QUIETTUBE_TEST_OPEN_EXIT='9')
        require(result.returncode == 9, result.stdout + result.stderr)
        require('was installed, but could not open' in result.stdout, 'Committed install was reported incorrectly')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(directory / 'QuietTube.app')], check=True)
        require(not list(directory.glob('.QuietTube-install.*')), 'Committed stage was retained')
    check('A launch failure retains the completed installation and explains how to open it', launch_failure)

    def destination_race():
        # After the real old-app move, create an unrelated destination before
        # promotion. The production helper must refuse it and retain the backup.
        mover = tools / 'mv'
        mover.write_text('''#!/usr/bin/env python3
import os,pathlib,subprocess,sys
subprocess.run(['/bin/mv', *sys.argv[1:]], check=True)
if sys.argv[-1].endswith('/Previous QuietTube.app'):
    target=pathlib.Path(os.environ['QUIETTUBE_TEST_APPLICATIONS_DIR'])/'QuietTube.app'
    target.mkdir()
    (target/'foreign.txt').write_text('preserved')
''')
        mover.chmod(0o755)
        try:
            result = run(applications)
            require(result.returncode != 0, 'New destination was overwritten')
            require((destination / 'foreign.txt').read_text() == 'preserved', 'New destination changed')
            backups = list(applications.glob('.QuietTube-install.*/Previous QuietTube.app'))
            require(len(backups) == 1, 'Old signed app backup was lost')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(backups[0])], check=True)
            require(str(backups[0]) in result.stdout, 'Recovery path was not reported')
        finally:
            mover.unlink()
    check('An update destination appearing during promotion is preserved with the old app recovery path', destination_race)

receipt = {'testedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'results': results, 'errors': errors,
           'scope': 'Production installer, real signed app copies, codesign verification and exclusive moves in disposable Mac folders. App launch is stubbed; normal UI and browser activation are separate.'}
report.write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
sys.exit(bool(errors))
