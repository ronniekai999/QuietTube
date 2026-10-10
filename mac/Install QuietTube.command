#!/bin/zsh
# QuietTube per-user Mac installation — GPL-3.0-or-later.
set -euo pipefail
QT_PACKAGE_DIR=${0:A:h}
QT_SOURCE="$QT_PACKAGE_DIR/QuietTube.app"
QT_APPLICATIONS=${QUIETTUBE_TEST_APPLICATIONS_DIR:-$HOME/Applications}
QT_APPLICATIONS=${QT_APPLICATIONS:a}
QT_DESTINATION="$QT_APPLICATIONS/QuietTube.app"
QT_STAGE=""
QT_BACKUP=""
QT_PROMOTED=0
QT_RETAIN_STAGE=0
function finish {
    local result=$?
    if [[ $result -ne 0 && -n "$QT_BACKUP" && -d "$QT_BACKUP" && $QT_PROMOTED -eq 0 ]]; then
        if [[ ! -e "$QT_DESTINATION" && ! -L "$QT_DESTINATION" ]]; then
            if ! "$QT_SOURCE/Contents/Helpers/QuietTubeNative" --promote-app "$QT_BACKUP" "$QT_DESTINATION"; then QT_RETAIN_STAGE=1; fi
        else
            QT_RETAIN_STAGE=1
        fi
        if [[ $QT_RETAIN_STAGE -eq 1 ]]; then print -r -- "The previous app is preserved at $QT_BACKUP"; fi
    fi
    if [[ -n "$QT_STAGE" && -d "$QT_STAGE" && $QT_RETAIN_STAGE -eq 0 ]]; then rm -rf "$QT_STAGE"; fi
    if [[ $result -ne 0 ]]; then
        if [[ $QT_PROMOTED -eq 1 ]]; then print -r -- 'QuietTube was installed, but could not open. Open it from your Applications folder.'
        else print -r -- 'Installation did not finish. Existing app files and settings were preserved.'; fi
    fi
}
trap finish EXIT
if [[ ! -d "$QT_SOURCE" || -L "$QT_SOURCE" ]]; then print -u2 -r -- 'Extract the complete QuietTube Mac ZIP first.'; exit 1; fi
codesign --verify --deep --strict "$QT_SOURCE"
QT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$QT_SOURCE/Contents/Info.plist")
QT_TEAM=$(codesign -dv --verbose=2 "$QT_SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "$QT_ID" != 'com.quiettube.mac' || -z "$QT_TEAM" || "$QT_TEAM" == 'not set' ]]; then print -u2 -r -- 'The app signature does not identify a signed QuietTube Mac build.'; exit 1; fi
if [[ -L "$QT_APPLICATIONS" || ( -e "$QT_APPLICATIONS" && ( ! -d "$QT_APPLICATIONS" || ! -O "$QT_APPLICATIONS" ) ) ]]; then print -u2 -r -- 'Your Applications destination is not an ordinary folder owned by this user.'; exit 1; fi
mkdir -p "$QT_APPLICATIONS"
if [[ -L "$QT_DESTINATION" ]]; then print -u2 -r -- 'The existing QuietTube app is a symbolic link. It was left unchanged.'; exit 1; fi
if [[ -e "$QT_DESTINATION" ]]; then
    if [[ ! -d "$QT_DESTINATION" || ! -O "$QT_DESTINATION" ]]; then print -u2 -r -- 'The existing destination is not an app owned by this user.'; exit 1; fi
    codesign --verify --deep --strict "$QT_DESTINATION"
    QT_OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$QT_DESTINATION/Contents/Info.plist")
    QT_OLD_TEAM=$(codesign -dv --verbose=2 "$QT_DESTINATION" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [[ "$QT_OLD_ID" != "$QT_ID" || "$QT_OLD_TEAM" != "$QT_TEAM" ]]; then print -u2 -r -- 'An app from another publisher occupies the destination. It was left unchanged.'; exit 1; fi
fi
# A running executable must not be replaced. This checks only this exact app's
# path; it never stops browsers or other applications.
if pgrep -f "$QT_DESTINATION/Contents/MacOS/QuietTube" >/dev/null; then print -u2 -r -- 'Quit QuietTube from its menu bar icon, then run installation again.'; exit 1; fi
QT_STAGE=$(mktemp -d "$QT_APPLICATIONS/.QuietTube-install.XXXXXX")
ditto --norsrc --noextattr "$QT_SOURCE" "$QT_STAGE/QuietTube.app"
codesign --verify --deep --strict "$QT_STAGE/QuietTube.app"
if [[ -d "$QT_DESTINATION" ]]; then
    QT_BACKUP="$QT_STAGE/Previous QuietTube.app"
    mv "$QT_DESTINATION" "$QT_BACKUP"
fi
"$QT_SOURCE/Contents/Helpers/QuietTubeNative" --promote-app "$QT_STAGE/QuietTube.app" "$QT_DESTINATION"
QT_PROMOTED=1
print -r -- "QuietTube installed in $QT_DESTINATION"
open "$QT_DESTINATION"
print -r -- 'Enable QuietTube in Safari settings. Use Connect Chrome in the app for Chrome setup.'
