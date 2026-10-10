#!/usr/bin/env bash
# QuietTube native Mac app and Safari extension — GPL-3.0-or-later.
set -euo pipefail
QUIETTUBE_PROJECT=$(cd "$(dirname "$0")/.." && pwd)
QUIETTUBE_WORK=$(cd "$QUIETTUBE_PROJECT/../.." && pwd)/work
QUIETTUBE_MAC_WORK="$QUIETTUBE_WORK/mac"
# File Provider adds FinderInfo to app bundles in Documents. Keep signed build
# products in a local cache; source, logs, and final archives stay in the workspace.
QUIETTUBE_BUILD_KEY=$(printf '%s' "$QUIETTUBE_PROJECT" | shasum -a 256 | cut -c 1-16)
QUIETTUBE_DERIVED_DATA=${QUIETTUBE_DERIVED_DATA:-${TMPDIR:-/tmp}/QuietTube-macos-$QUIETTUBE_BUILD_KEY}
QUIETTUBE_UPSTREAM="$QUIETTUBE_WORK/vendor/uBlock"
QUIETTUBE_PIN=e5e96f6765aa2a1d89044e2ce0f31f077f1dc1b6
QUIETTUBE_VERSION=$(cat "$QUIETTUBE_PROJECT/mac/VERSION")
QUIETTUBE_PYTHON=${QUIETTUBE_PYTHON:-python3}

if [ ! -d "$QUIETTUBE_UPSTREAM/.git" ] || [ "$(git -C "$QUIETTUBE_UPSTREAM" rev-parse HEAD)" != "$QUIETTUBE_PIN" ]; then
    printf '%s\n' 'Prepare the pinned upstream checkout with scripts/build-mac.sh first.' >&2
    exit 1
fi
if [ -z "${QUIETTUBE_SIGNING_IDENTITY:-}" ]; then
    QUIETTUBE_SIGNING_IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"((Developer ID Application|Apple Development):[^"]+)".*/\1/p' | head -1)
fi
if [ -z "$QUIETTUBE_SIGNING_IDENTITY" ]; then
    printf '%s\n' 'A Mac development or Developer ID signing identity is required for the shared Safari app group.' >&2
    exit 1
fi
QUIETTUBE_SIGNING_TEAM=$(security find-certificate -c "$QUIETTUBE_SIGNING_IDENTITY" -p | openssl x509 -noout -subject -nameopt RFC2253 | sed -nE 's/.*OU=([A-Z0-9]{10})(,|$).*/\1/p')
if [ -z "$QUIETTUBE_SIGNING_TEAM" ]; then
    printf '%s\n' 'Could not read the development team from the signing certificate.' >&2
    exit 1
fi
mkdir -p "$QUIETTUBE_MAC_WORK/build" "$QUIETTUBE_MAC_WORK/logs"
for QUIETTUBE_BROWSER in edge safari; do
    if [ ! -f "$QUIETTUBE_UPSTREAM/dist/build/uBOLite.$QUIETTUBE_BROWSER/manifest.json" ]; then
        (cd "$QUIETTUBE_UPSTREAM" && bash tools/make-mv3.sh "$QUIETTUBE_BROWSER" > "$QUIETTUBE_MAC_WORK/logs/engine-$QUIETTUBE_BROWSER.log" 2>&1)
    fi
done
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/prepare-extension.py" "$QUIETTUBE_UPSTREAM" --browser safari --destination "$QUIETTUBE_MAC_WORK/build/SafariExtension" --app-platform Mac --app-version "$QUIETTUBE_VERSION"
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/prepare-extension.py" "$QUIETTUBE_UPSTREAM" --browser edge --destination "$QUIETTUBE_MAC_WORK/build/ChromeExtension" --app-platform Mac --app-version "$QUIETTUBE_VERSION"
if [ ! -d "$QUIETTUBE_MAC_WORK/project/QuietTube/QuietTube.xcodeproj" ]; then
    xcrun safari-web-extension-packager "$QUIETTUBE_MAC_WORK/build/SafariExtension" --project-location "$QUIETTUBE_MAC_WORK/project" --app-name QuietTube --bundle-identifier com.quiettube.mac --swift --macos-only --copy-resources --no-prompt --no-open
else
    # Refresh only the known generated extension resource folder.
    rm -rf "$QUIETTUBE_MAC_WORK/project/QuietTube/QuietTube Extension/Resources"
    cp -R "$QUIETTUBE_MAC_WORK/build/SafariExtension" "$QUIETTUBE_MAC_WORK/project/QuietTube/QuietTube Extension/Resources"
fi
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/configure-macos-project.py" "$QUIETTUBE_MAC_WORK/project/QuietTube" --team "$QUIETTUBE_SIGNING_TEAM"
QUIETTUBE_ARCH=$(uname -m)
xcrun swiftc -swift-version 5 -O -target "$QUIETTUBE_ARCH-apple-macos14.0" \
    "$QUIETTUBE_MAC_WORK/project/QuietTube/BuildConfiguration.swift" \
    "$QUIETTUBE_PROJECT/mac/Shared/QuietTubeState.swift" "$QUIETTUBE_PROJECT/mac/Shared/NativeProtocol.swift" \
    "$QUIETTUBE_PROJECT/mac/Host/QuietTubeNative.swift" -o "$QUIETTUBE_MAC_WORK/build/QuietTubeNative"
codesign --force --sign "$QUIETTUBE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    --identifier com.quiettube.mac.native --entitlements "$QUIETTUBE_MAC_WORK/project/QuietTube/Host.entitlements" "$QUIETTUBE_MAC_WORK/build/QuietTubeNative"
xcodebuild -project "$QUIETTUBE_MAC_WORK/project/QuietTube/QuietTube.xcodeproj" -scheme QuietTube -configuration Release \
    -derivedDataPath "$QUIETTUBE_DERIVED_DATA" -destination 'platform=macOS' \
    "CODE_SIGN_IDENTITY=$QUIETTUBE_SIGNING_IDENTITY" "ARCHS=$QUIETTUBE_ARCH" ONLY_ACTIVE_ARCH=YES build > "$QUIETTUBE_MAC_WORK/logs/xcodebuild.log" 2>&1
QUIETTUBE_APP="$QUIETTUBE_DERIVED_DATA/Build/Products/Release/QuietTube.app"
mkdir -p "$QUIETTUBE_APP/Contents/Helpers" "$QUIETTUBE_APP/Contents/Resources/Licenses"
cp "$QUIETTUBE_MAC_WORK/build/QuietTubeNative" "$QUIETTUBE_APP/Contents/Helpers/QuietTubeNative"
cp "$QUIETTUBE_PROJECT/LICENSE.txt" "$QUIETTUBE_APP/Contents/Resources/Licenses/QuietTube-GPL-3.0.txt"
codesign --force --sign "$QUIETTUBE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$QUIETTUBE_MAC_WORK/project/QuietTube/QuietTube/QuietTube.entitlements" "$QUIETTUBE_APP"
codesign --verify --deep --strict --verbose=2 "$QUIETTUBE_APP"
printf '%s\n' "$QUIETTUBE_APP"
printf '%s\n' "$QUIETTUBE_APP" > "$QUIETTUBE_MAC_WORK/build/app-path.txt"
