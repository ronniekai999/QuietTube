# QuietTube 0.1.2 review

All six findings from the first review are fixed. The follow-up review found no remaining actionable issues in the reviewed code after the additional fixes below. This is a source and package review with Mac validation; Windows runtime acceptance is still pending.

| Original finding | Resolution | Validation |
| --- | --- | --- |
| P1: setup could clear other apps’ startup entries | Opens the shared Run key through `RegistryKey.CreateSubKey` and changes only QuietTube’s value. Updates preserve the startup choice. | First installation and updates with startup on/off retain another app’s startup value. |
| P1: setup/uninstall could erase an unrelated folder | Requires the installation marker, matching product and extension ID, and an ordinary directory tree before replacing or removing it. | Unknown folders, wrong markers and linked directories are rejected before files or registrations change. |
| P2: popup could show protection on after YouTube access was revoked | Readiness checks site access, actual filtering mode, enabled rules and YouTube script registrations. Popup, badge and native acknowledgment show the error. | Real Chromium site-access toggle removes readiness; restoring access restores it. |
| P2: close-to-tray could cancel Windows shutdown | Hides the window only for a normal user close; system close reasons pass through. | Close-reason regression covers Windows shutdown, application exit and explicit Quit. Physical Windows logoff/restart is pending. |
| P2: a disconnected companion could become connected again through queued messages | Every native callback and queued apply checks the port identity. In-flight persistence is restored if that connection disappears. Popup command intent falls back to an offline change. | Deterministic disconnects before pending reads, during persistence and during a command. Old-port callbacks cannot affect a new connection. |
| P2: a delayed old alarm could end a newer pause | Checks the currently saved deadline and consults current native settings while connected. | Delayed alarm keeps a future pause; offline and real native expiration resume protection. |

The follow-up review also resolved these related failure cases:

- Losing the companion at pause expiry now resumes local browser protection.
- Offline changes carry tokens, so an acknowledgment for an old change cannot remove a newer queued choice.
- Native state snapshot creation and frame output are serialized together to preserve revision order.
- Setup refuses a destination that appears after preflight, preserves exact shortcut bytes on rollback, and serializes setup/uninstall with an installation lock.
- A blocked file rollback retains the old backup and still attempts to restore registrations, startup and shortcut; the failure names the remaining repair steps.
- Setup and uninstall recognize the exact startup command instead of matching a substring of another command.

The reviewed scope includes `scripts/Setup.ps1`, `scripts/Uninstall.ps1`, `scripts/Install-Helpers.ps1`, the custom browser overlay and its generated copy, native host framing/state delivery, tray close behavior, settings acknowledgments, regression fixtures, version consistency and packaged source. The upstream filtering engine remains pinned to the source revision in `engine-metadata.json`.

Validation receipts are included beside this report:

- `core-test-results.json`: 10 passing core checks.
- `bridge-test-results.json`: 12 passing lifecycle and readiness regressions using the production bridge with controlled Chrome/native boundaries.
- `installer-test-results.json`: 7 passing parser, integrity and installer-helper checks.
- `installer-regression-results.json`: 20 passing setup/uninstall scenarios. These execute the production filesystem, ownership, checksum, mutex and rollback paths with Windows registry, shell and process boundaries substituted on the Mac. A simulated locked-file failure checks recovery behavior; it does not establish real Windows file-lock behavior.
- `browser-test-results.json`: 13 passing real Chromium/native-host integration checks in isolated Mac profiles, including actual DNR blocking on a controlled YouTube page, permission loss/restoration and automatic native pause expiration with a short fixture deadline.
- `youtube-smoke-results.json`: a signed-out live YouTube video played beyond five seconds at 854 × 480 with the engine ready and no engine error.

The Windows x64 tray app and helper publish successfully as self-contained executables. Windows 11 Edge, PowerShell 5.1, real registry/shortcut/startup writes, system shutdown and playback with the brother’s usual account still require the nearby PC. A successful playback smoke test and a controlled network block do not establish removal of all pre-roll or mid-roll video ads. Use `TESTING.md` for that acceptance pass.

API behavior was checked against primary documentation: [opening an existing registry key](https://learn.microsoft.com/en-us/dotnet/api/microsoft.win32.registrykey.createsubkey?view=net-10.0), [WinForms close reasons](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.closereason?view=windowsdesktop-10.0), and [Chrome permission queries and events](https://developer.chrome.com/docs/extensions/reference/api/permissions).
