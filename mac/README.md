# QuietTube for Mac

QuietTube **0.2.0** is a native menu bar app for **Safari and Chrome**. The app, Chrome native host, and Safari app extension use the same Swift settings and protocol code. Browser filtering uses the pinned uBlock Origin Lite engine, with YouTube-only permissions and packaged scripts.

The initial build targets **Apple Silicon, macOS 14 or later, and Safari 18.6 or later**. Validation on this project’s Mac uses macOS 27.2 and Safari 27.2. Older supported versions and Intel Macs have not been exercised. The local preview uses an Apple development certificate. A public Mac download requires Developer ID signing and notarization.

## Install and connect

1. Extract the complete Mac ZIP and run **Install QuietTube.command**. It installs to `~/Applications/QuietTube.app` without administrator access. Alternatively, move the app there yourself.
2. Open QuietTube and choose **Safari settings**. Enable QuietTube and allow access on **youtube.com**. Open its toolbar popup and check for **Mac app connected**.
3. For Chrome, choose **Connect Chrome**, open `chrome://extensions`, enable **Developer mode**, and choose **Load unpacked**. The app’s **Show extension folder & copy path** button reveals the exact folder.
4. Reload YouTube after changing protection. The app only reports confirmed protection after the browser acknowledges its setting, rules, scripts, and site access.

Protection controls live in the menu bar. **Pause 15 minutes** resumes automatically, and explicit off persists across app and browser restarts. **Launch at login** is opt-in. Closing the setup window keeps the menu bar app running; quitting the app leaves each extension using its saved setting.

## Build

Xcode, a Mac signing identity, Node.js, Python 3, and the pinned upstream checkout are required. On a new checkout, initialize `work/vendor/uBlock` at commit `e5e96f6765aa2a1d89044e2ce0f31f077f1dc1b6` with its submodules; the existing Windows cross-build script also prepares that checkout.

```bash
bash scripts/build-macos-app.sh
```

The script builds separate Chrome and Safari extensions, runs Apple’s Safari packager, configures the generated project with the native Swift code, compiles the Chrome host, and signs and verifies the resulting app. It reads the signing team from the certificate’s **OU**, not the personal identifier in the certificate’s display name. Set `QUIETTUBE_SIGNING_IDENTITY` to select a specific development or Developer ID identity.

Generated projects, extension resources, and logs stay under `work/mac`. Signed Xcode products use a local temporary build cache because File Provider adds Finder metadata to app bundles under Documents. `work/mac/build/app-path.txt` records the final app path. Source and deliverable archives stay in the workspace.

## Architecture and boundaries

- **Native UI:** AppKit status item and windows with SwiftUI views; no Electron or bundled .NET runtime.
- **Shared settings:** A team-prefixed Mac app group, atomic private files, cross-process `flock`, bounded decoding, monotonically increasing revisions, and explicit corruption errors. Changing the signing team creates a separate group rather than silently importing another publisher’s data.
- **Chrome:** A signed stdio host restricted to the existing exact QuietTube extension origin. Registration goes into the current user’s Chrome `NativeMessagingHosts` folder. Foreign registrations and symlinks are rejected, and removal requires the current installation’s exact manifest.
- **Safari:** A sandboxed native app extension handles request/reply messages using the same protocol. Native app notifications and a polling fallback synchronize settings; periodic acknowledgments prevent unchanged protection from appearing disconnected.
- **Privacy:** No proxy, DNS changes, root certificate, network listener, or browser policy changes. The extension requests YouTube access. Diagnostic exports omit browsing history, cookies, and video URLs and redact URLs from error text.
- **Updates:** The installer stages and validates a signed app before replacing an installation from the same publisher. Shared data and login preferences are retained. Reload the Chrome extension after replacing the app.
- **Removal:** Remove the Chrome extension, use **Disconnect Chrome**, disable **Launch at login**, disable the Safari extension, and move the app to Trash. Shared settings remain for a later reinstall.

## Verification

`mac/Tests/NativeChecks.swift` tests real files, settings locking across independent processes, framing, corrupt data preservation, symlink boundaries, Chrome registration ownership, Safari protocol compatibility, and acknowledgment freshness. `tests/safari-transport.mjs` exercises the production Safari transport’s request metadata, notifications, polling, periodic acknowledgments, disconnection, and late replies. `tests/browser-integration.mjs` supports `QUIETTUBE_TEST_HOST`, `QUIETTUBE_TEST_EXTENSION`, and `QUIETTUBE_TEST_REPORT` to test the native Swift host in isolated Chromium.

The local preview passes **18 native checks**, **8 Safari transport checks**, **13 real Chromium/Swift-host checks**, and **8 Mac installer checks**. The installer tests execute the production shell, signed app copies, signature verification, and exclusive promotion in disposable folders; only launching the app is stubbed. The shared bridge's 12 lifecycle checks and Windows installer's 20 isolated regressions also pass.

See the JSON receipts in this folder. Actual Safari playback and browser permissions, the menu bar UI, login behavior, and a full Mac reboot require their own acceptance evidence. Active filtering is not a guarantee that every YouTube ad is blocked.

GPL-3.0-or-later. The package includes QuietTube source, matching upstream source and filter inputs, and license notices. Windows remains version 0.1.2; the Mac preview has its own version in `mac/VERSION`.
