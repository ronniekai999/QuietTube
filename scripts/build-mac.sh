#!/usr/bin/env bash
set -euo pipefail

QUIETTUBE_PROJECT=$(cd "$(dirname "$0")/.." && pwd)
QUIETTUBE_WORK=$(cd "$QUIETTUBE_PROJECT/../.." && pwd)/work
QUIETTUBE_DOTNET=${QUIETTUBE_DOTNET:-$QUIETTUBE_WORK/tools/dotnet/dotnet}
QUIETTUBE_PYTHON=${QUIETTUBE_PYTHON:-python3}
QUIETTUBE_UPSTREAM=$QUIETTUBE_WORK/vendor/uBlock
QUIETTUBE_COMMIT=e5e96f6765aa2a1d89044e2ce0f31f077f1dc1b6
export DOTNET_CLI_HOME="$QUIETTUBE_WORK/tools/dotnet-home"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
export DOTNET_NOLOGO=1

mkdir -p "$QUIETTUBE_WORK/vendor" "$QUIETTUBE_WORK/build" "$QUIETTUBE_PROJECT/bin"
if [ ! -d "$QUIETTUBE_UPSTREAM/.git" ]; then
    git clone --no-checkout --depth 1 https://github.com/gorhill/uBlock.git "$QUIETTUBE_UPSTREAM"
    git -C "$QUIETTUBE_UPSTREAM" fetch --depth 1 origin "$QUIETTUBE_COMMIT"
    git -C "$QUIETTUBE_UPSTREAM" checkout --detach "$QUIETTUBE_COMMIT"
fi
if [ "$(git -C "$QUIETTUBE_UPSTREAM" rev-parse HEAD)" != "$QUIETTUBE_COMMIT" ]; then
    printf '%s\n' 'The upstream checkout differs from the pinned revision. Review it before rebuilding.' >&2
    exit 1
fi
git -C "$QUIETTUBE_UPSTREAM" submodule update --init --recursive
if [ ! -f "$QUIETTUBE_UPSTREAM/dist/build/uBOLite.edge/manifest.json" ]; then
    (cd "$QUIETTUBE_UPSTREAM" && bash tools/make-mv3.sh edge > "$QUIETTUBE_WORK/build/ubol-build.log" 2>&1)
fi
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/prepare-extension.py" "$QUIETTUBE_UPSTREAM"
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/make-icons.py"
"$QUIETTUBE_DOTNET" run --project "$QUIETTUBE_PROJECT/src/QuietTube.Checks/QuietTube.Checks.csproj" -- "$QUIETTUBE_WORK/tests/core" > "$QUIETTUBE_PROJECT/core-test-results.json"
"$QUIETTUBE_DOTNET" publish "$QUIETTUBE_PROJECT/src/QuietTube.Tray/QuietTube.Tray.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o "$QUIETTUBE_WORK/publish/tray"
"$QUIETTUBE_DOTNET" publish "$QUIETTUBE_PROJECT/src/QuietTube.Host/QuietTube.Host.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "$QUIETTUBE_WORK/publish/host-windows"
cp "$QUIETTUBE_WORK/publish/tray/QuietTube.exe" "$QUIETTUBE_PROJECT/bin/"
cp "$QUIETTUBE_WORK/publish/host-windows/QuietTube.Host.exe" "$QUIETTUBE_PROJECT/bin/"
cp "$QUIETTUBE_PROJECT/extension-id.txt" "$QUIETTUBE_PROJECT/engine-metadata.json" "$QUIETTUBE_PROJECT/bin/"
QUIETTUBE_SDK_DIR=$(cd "$(dirname "$QUIETTUBE_DOTNET")" && pwd)
cp "$QUIETTUBE_SDK_DIR/LICENSE.txt" "$QUIETTUBE_PROJECT/bin/LICENSE-DOTNET.txt"
cp "$QUIETTUBE_SDK_DIR/ThirdPartyNotices.txt" "$QUIETTUBE_PROJECT/bin/THIRD-PARTY-NOTICES-DOTNET.txt"
"$QUIETTUBE_PYTHON" "$QUIETTUBE_PROJECT/scripts/package.py" "$QUIETTUBE_UPSTREAM"
