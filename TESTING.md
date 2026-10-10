# QuietTube testing

## Verified on the Mac

The Windows tray app and native helper cross-compile as self-contained Windows x64 executables. They have not been executed on Windows yet.

`core-test-results.json` records ten checks of state persistence, pause expiry, concurrent controls, corrupt settings, native message framing and limits, exact extension origin validation, and truthful connection acknowledgments.

`browser-test-results.json` records real browser/native-host integration in isolated Chromium profiles on macOS, including shared controls, timed pause/resume, automatic expiration with a short isolated test deadline, permission loss/restoration in the Extensions UI, actual blocking of a known ad-network request on a controlled YouTube test page, allowing the same request elsewhere and when off, browser restart persistence, native command rejection before handshake, and diagnostics privacy.

The controlled network test proves that the filtering integration works. It does **not** prove that all YouTube video ads are removed. An empty ad count on an unmonetized video is not a valid acceptance result.

`youtube-smoke-results.json` records a live, signed-out YouTube playback check in Chromium on the Mac. Playback advanced beyond five seconds at 854 × 480 with the filtering engine active and no engine error. This checks that the extension can coexist with real video playback; it does not establish that an ad would have appeared without protection or validate every ad format.

`bridge-test-results.json` records twelve lifecycle regressions: permission readiness, script scope, stale pause events, pause expiry, queued disconnects, interrupted persistence, offline intent acknowledgment, old-port events and native revision ordering.

`installer-test-results.json` records nine parser/integrity/helper checks, including the legacy JSON array behavior that broke setup on Windows PowerShell 5.1. `installer-regression-results.json` records twenty full setup/uninstall scenarios using small real filesystem fixtures with Windows registry, shell and process boundaries substituted. These cover other apps’ startup values, preserved on/off preference and data, ownership rejection, linked directories, destination collision, rollback, exact shortcut restoration, blocked file rollback, launch failure, uninstall scope and concurrent installation locking.

`REVIEW.md` records the six resolved findings and the follow-up review.

## Verified on Windows PowerShell 5.1

The [Windows installer workflow](https://github.com/ronniekai999/QuietTube/actions/workflows/windows-installer.yml) runs on a disposable Windows Server 2022 runner using `powershell.exe`, matching the shell selected by `Setup.cmd`. It verifies the version rather than substituting PowerShell 7.

- `windows-installer-test-results.json`: 9 helper checks, including valid multi-entry checksum manifests and rejection of damaged payloads.
- `windows-installer-regression-results.json`: 20 setup/uninstall scenarios with Windows boundaries substituted and real Windows filesystem/mutex behavior.
- `windows-integration-results.json`: 8 checks that reproduce the original `System.Object[]`/`ChildPath` error and exercise the fixed production setup/update/uninstall with real HKCU browser registrations, native-host JSON, COM Start menu shortcuts, process launch, startup preservation, saved data, and damaged-package rejection.

Integration uses small fixture executables and a fixture extension. Only the instructions-page launch and unattended uninstall answer are substituted; registry writes, shortcut creation, and executable launch use Windows APIs. This verifies installation behavior, while the real tray app, Edge connection, filtering, login startup and reboot still require the Windows 11 PC. The workflow retains detailed logs and receipts as an artifact.

## Windows 11 acceptance — Edge first

1. Run Setup.cmd from a fully extracted ZIP. Confirm that QuietTube opens, appears in the tray, and can reopen from the Start menu.
2. Load `%LOCALAPPDATA%\QuietTube\extension` through `edge://extensions` with Developer mode enabled. Confirm the popup says **Windows app connected**, and the tray window says **Edge profile 1: filtering ready**.
3. Open YouTube with the brother's usual account. Choose videos on monetized channels where ads normally appear. Test several starts, then watch enough of a longer video to reach normal mid-roll opportunities. Record any ad, blank player, playback warning, or unexpected delay. Do not infer success from a single video that happens to have no ad.
4. Turn protection off in the tray app, confirm the popup updates, and **reload** the video. Turn it on, confirm the popup updates again, and reload. Check that comments, seeking, audio, fullscreen, captions, and quality selection still work.
5. Pause for 15 minutes. Confirm the tray app and popup show the pause. Check automatic resume at the displayed time and reload the video.
6. Turn off QuietTube’s YouTube site access in Edge’s Extensions page. Confirm the popup shows **Needs attention** and the tray stops reporting filtering ready; restore access and confirm both recover.
7. Close and reopen Edge; restart Windows. Confirm QuietTube allows logoff/restart without cancelling it. Confirm startup works and protection retains the chosen setting. Test saved off as well as saved on.
8. If Chrome is also used, load the same installed extension folder there and confirm a tray change reaches both browsers. Repeat playback checks there.
9. Test signed-out playback in a separate normal browser profile, without taking the brother's main profile out of its account. Private/InPrivate operation is not part of this first acceptance gate.
10. If anything fails, select **Export diagnostics** in the tray app and keep the text of the error, browser version, and reproduction steps. Video URLs are intentionally absent from diagnostics; record a problematic public video separately if needed.

After playback acceptance, test an update by running setup again with Edge and Chrome closed. Confirm settings and the startup preference survive, and another app’s existing startup entry is still present. Test startup enabled and disabled. If setup reports rollback needs repair, preserve the backup folder it names. Finally, verify uninstall removes the owned app/registrations/startup entry after removing the extension.

## Run development checks

From the project directory, with the .NET SDK available:

```sh
dotnet run --project src/QuietTube.Checks/QuietTube.Checks.csproj -- ../../work/tests/core
```

The Mac browser test requires a Mac native-host publish in `work/publish/host-mac`, Playwright in `work/browser-tests`, and its browser binaries. The local workspace commands used for this build are captured by `scripts/build-mac.sh`; integration tests are in `tests/browser-integration.mjs`.

```sh
PLAYWRIGHT_BROWSERS_PATH="$PWD/../../work/browser-browsers" node tests/browser-integration.mjs
node tests/bridge-lifecycle.mjs
```

These tests use a separate data directory and separate browser profiles. Runtime settings for an installed Windows app are never used by the Mac checks.

Run the PowerShell checks from this project directory using PowerShell 7 on the Mac:

```powershell
pwsh -NoProfile -File tests/installer-checks.ps1 -ProjectDirectory $PWD -WorkDirectory ../../work/tests
pwsh -NoProfile -File tests/installer-regressions.ps1 -ProjectDirectory $PWD -WorkDirectory ../../work/tests
```

The regression runner substitutes Windows boundaries only within its child test processes and uses separate temporary installation folders. It does not run setup against the installed Windows app.
