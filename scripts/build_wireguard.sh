#!/bin/bash
set -euo pipefail
export PATH="$PATH:/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin"
: "${SRCROOT:?Run this script from the Xcode extension target}"
: "${CONFIGURATION_BUILD_DIR:?Missing Xcode build directory}"
vendor="$SRCROOT/Vendor/wireguard-apple"
expected="2fec12a6e1f6e3460b6ee483aa00ad29cddadab1"
if [[ "$(git -C "$vendor" rev-parse HEAD)" != "$expected" ]]; then
    echo 'WireGuard dependency revision mismatch. Run python3 scripts/bootstrap.py.' >&2
    exit 1
fi
python3 "$SRCROOT/scripts/bootstrap.py" --verify-only
command -v go >/dev/null || { echo 'Install a supported Go toolchain on this Mac, then rerun.' >&2; exit 1; }
go_version="$(go env GOVERSION)"
if [[ ! "$go_version" =~ ^go1\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Use a release Go toolchain; development toolchains need a separate compatibility review.' >&2
    exit 1
fi
bridge_build="$TARGET_TEMP_DIR/wireguard-go-bridge-$go_version"
python3 "$SRCROOT/scripts/prepare_go_runtime.py" \
    --source "$(go env GOROOT)" --destination "$bridge_build/goroot"
# Simulator and device use different Go targets. The upstream Makefile does not
# define iphonesimulator, so supply that mapping explicitly.
make -C "$vendor/Sources/WireGuardKitGo" \
    GOOS_iphonesimulator=ios \
    ARCHS="$ARCHS" PLATFORM_NAME="$PLATFORM_NAME" SDKROOT="$SDKROOT" \
    CONFIGURATION_BUILD_DIR="$CONFIGURATION_BUILD_DIR" \
    CONFIGURATION_TEMP_DIR="$TARGET_TEMP_DIR" \
    BUILDDIR="$bridge_build" \
    build
