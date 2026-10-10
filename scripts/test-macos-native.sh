#!/usr/bin/env bash
# Compile and test native boundaries without a distribution certificate.
set -euo pipefail
QUIETTUBE_PROJECT=$(cd "$(dirname "$0")/.." && pwd)
QUIETTUBE_TEST_WORK=$(mktemp -d "${TMPDIR:-/tmp}/QuietTube-native-checks.XXXXXX")
trap 'rm -rf "$QUIETTUBE_TEST_WORK"' EXIT
QUIETTUBE_VERSION=$(cat "$QUIETTUBE_PROJECT/mac/VERSION")
QUIETTUBE_EXTENSION_ID=$(cat "$QUIETTUBE_PROJECT/extension-id.txt")
cat > "$QUIETTUBE_TEST_WORK/BuildConfiguration.swift" <<EOF
enum BuildConfiguration {
    static let appGroup = "QUIETTUBECI.com.quiettube.shared"
    static let version = "$QUIETTUBE_VERSION"
    static let chromeExtensionId = "$QUIETTUBE_EXTENSION_ID"
    static let safariExtensionId = "com.quiettube.mac.SafariExtension"
}
EOF
xcrun swiftc -swift-version 5 "$QUIETTUBE_TEST_WORK/BuildConfiguration.swift" \
    "$QUIETTUBE_PROJECT/mac/Shared/QuietTubeState.swift" "$QUIETTUBE_PROJECT/mac/Shared/NativeProtocol.swift" \
    "$QUIETTUBE_PROJECT/mac/Host/QuietTubeNative.swift" -o "$QUIETTUBE_TEST_WORK/QuietTubeNative"
xcrun swiftc -swift-version 5 "$QUIETTUBE_TEST_WORK/BuildConfiguration.swift" \
    "$QUIETTUBE_PROJECT/mac/Shared/QuietTubeState.swift" "$QUIETTUBE_PROJECT/mac/Shared/NativeProtocol.swift" \
    "$QUIETTUBE_PROJECT/mac/App/ChromeRegistration.swift" "$QUIETTUBE_PROJECT/mac/Tests/NativeChecks.swift" \
    -o "$QUIETTUBE_TEST_WORK/NativeChecks"
"$QUIETTUBE_TEST_WORK/NativeChecks" "$QUIETTUBE_TEST_WORK/fixtures" "$QUIETTUBE_TEST_WORK/QuietTubeNative" \
    > "$QUIETTUBE_PROJECT/mac/native-check-results.json"
cat "$QUIETTUBE_PROJECT/mac/native-check-results.json"
