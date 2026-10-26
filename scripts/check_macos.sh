#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Xcode / iOS SDK validation requires macOS.' >&2
    exit 2
fi
mkdir -p artifacts
python3 scripts/bootstrap.py
python3 scripts/check_project.py
swift test --enable-code-coverage 2>&1 | tee artifacts/swift-tests-macos.log
xcodebuild -project NPV.xcodeproj -scheme NPV -showdestinations > artifacts/xcode-destinations.txt
# Compilation only. This does not establish a tunnel or verify signing on a device.
xcodebuild -project NPV.xcodeproj -scheme NPV \
    -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee artifacts/ios-build.log
