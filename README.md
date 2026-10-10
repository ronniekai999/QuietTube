# QuietTube 0.1.1

A private Windows 11 test build for watching YouTube in Edge or Chrome, with a Windows system-tray app and a companion Manifest V3 extension.

The extension is an independent modification of **uBlock Origin Lite**, by Raymond Hill and contributors. The Windows app manages shared protection settings; the existing filtering engine performs network filtering and packaged YouTube scriptlet injection. Source and license notices are included.

This GitHub repository contains the application source, extension overlay, build scripts, assets, review, and test receipts for version 0.1.1. The Windows installer ZIP is a separate build output. Build the package before running setup from a source checkout.

## Install on your brother's Windows PC

1. Copy `QuietTube-Windows-x64-0.1.1.zip` to the Windows PC and **extract the entire ZIP**. Open the extracted `QuietTube` folder.
2. Double-click **Setup.cmd**. Setup installs the app for the current Windows account in `%LOCALAPPDATA%\QuietTube`, registers its browser companion, adds a Start menu shortcut, and enables startup on first installation. Administrator access and a separate .NET installation are not required.
3. In Edge, open **edge://extensions**. Turn on **Developer mode**, choose **Load unpacked**, and select **%LOCALAPPDATA%\QuietTube\extension**. Select the installed folder, rather than the ZIP's temporary extraction folder.
4. Pin QuietTube to Edge's toolbar and open its popup. It should say **Windows app connected**. The tray app should show **Edge profile 1: filtering ready**.
5. Reload YouTube and play videos. Follow the short device checks in **TESTING.md**.

Chrome uses the same extension folder; open **chrome://extensions** and repeat the one-time extension installation there.

This is an **unsigned private test build**. Windows may ask you to confirm running it. The package includes SHA-256 checksums for file-integrity verification; those checksums are not a publisher signature.

Setup preserves other apps’ startup entries and requires a QuietTube installation marker before replacing an existing folder. If it finds an unrecognized folder, it stops and preserves that folder for repair. Version 0.1.1 fixes all six findings from the first review; the follow-up results and validation scope are in **REVIEW.md**.

## Controls

- **Turn protection off/on:** synchronizes through the Windows companion to connected browser profiles.
- **Pause 15 minutes:** automatically resumes. Reload an already open video after changing protection; previously injected player scripts remain until that page reloads.
- **Reload YouTube:** reloads the currently open YouTube tabs.
- **Export diagnostics:** saves the app version, engine source/version, protection settings, browser connection state, and filtering acknowledgments. No browsing history, account cookies, page contents, or video URLs are sent to the companion.
- **Start when I sign in:** can be changed in the Windows app. Updates preserve this choice.
- Closing the app window keeps it in the tray. Windows shutdown and logoff are allowed to close it. **Quit tray app** exits the tray process; the extension retains its filtering settings and the browser-launched native helper continues communicating.

If the native companion is unavailable, the extension can still filter YouTube and expose local browser controls. An offline control change is queued and reconciled when the companion reconnects. The popup distinguishes browser-only protection from a connected Windows app and checks actual filtering readiness. Removing YouTube site access shows **Needs attention**, with instructions to restore access.

## Updates

This first private build ships packaged rules and scripts. Apply a new QuietTube ZIP by closing Edge and Chrome, running its setup, and then reloading QuietTube on the browser's Extensions page. Protection settings and the extension ID are preserved.

**Check upstream updates** reads the latest published uBlock Origin Lite release from GitHub. It does not replace the modified extension with an upstream package. Reliable unattended distribution requires a future extension-store release or another reviewed update channel; there is no remote-code downloader or automatic binary installer in this build.

YouTube can change its ad delivery or blocking detection. An active filtering engine is not proof that every ad is removed. The actual Windows Edge pre-roll and mid-roll checks in TESTING.md are required before considering this build ready for everyday use.

## Remove

Remove QuietTube from each browser's Extensions page, then run **Uninstall.cmd** from the extracted ZIP or installed folder. Type **REMOVE** when prompted. This removes QuietTube's app files, saved settings, per-user native messaging registrations, owned shortcut, and owned startup entry.

## Source layout

- `src/QuietTube.Tray`: native C#/.NET WinForms tray app and controls.
- `src/QuietTube.Host`: browser-launched native messaging helper; no network listener.
- `src/QuietTube.Core`: atomic settings, connection acknowledgments, and bounded native-message framing.
- `extension-overlay`: custom popup and native integration overlay.
- `extension`: generated, loadable extension with current packaged filters and original copyright notices.
- `upstream-source.tar.gz`: matching upstream source, pinned submodule contents, and downloaded filter inputs used for this build.
- `scripts/prepare-extension.py`: deterministic integration patches that fail visibly if upstream changes their expected targets.
- `tests` and `src/QuietTube.Checks`: browser integration, framing, state, and installer checks.

The bundled engine source is pinned in `engine-metadata.json`. The extension public key is in `extension-key.txt`; keep it to preserve the same extension ID across future builds. It is a public key, not a signing credential.

## Develop on the Mac

The scripts expect an `outputs/QuietTube` project directory beside a workspace `work/` directory. Clone into that layout:

```sh
mkdir -p quiettube-workspace/outputs
git clone https://github.com/ronniekai999/QuietTube.git quiettube-workspace/outputs/QuietTube
cd quiettube-workspace/outputs/QuietTube
```

Run `scripts/build-mac.sh` from this project folder. It expects Python with Pillow, Node.js, jq, OpenSSL, Git, and the .NET 10 SDK. It defaults to this workspace's SDK in `work/tools/dotnet/dotnet`; set `QUIETTUBE_DOTNET` to the absolute path of another SDK's `dotnet` executable, and `QUIETTUBE_PYTHON` if Pillow is in a separate Python runtime.

For a system-installed SDK, invoke the build with its executable path:

```sh
QUIETTUBE_DOTNET="$(command -v dotnet)" bash scripts/build-mac.sh
```

The build script uses this workspace's `work/` directory for dependencies, compiler outputs, and upstream checkout. It publishes self-contained Windows x64 executables. Development on an Apple Silicon Mac does not change the Windows target architecture.

Git excludes generated `bin/`, `extension/`, `checksums.json`, the upstream source archive, and installer ZIPs. The build retrieves the pinned upstream source and generates those outputs; the Windows ZIP includes the complete generated extension, matching upstream source and notices. Keep `extension-key.txt` and `extension-id.txt` in Git to preserve the extension identity.

The Mac integration tests launch isolated Playwright Chromium profiles. They register the test native host only inside those isolated profiles; your normal Chrome profile is not used. See TESTING.md for the validation boundary and commands.

## License

GPL-3.0-or-later; see LICENSE.txt and THIRD-PARTY-NOTICES.md. QuietTube is independent of the upstream uBlock Origin project and Microsoft, Google, and YouTube.
