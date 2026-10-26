#!/bin/bash
# Run from an SSH session on the development Mac. No signing or server required.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Simulator validation requires macOS and Xcode.' >&2
    exit 2
fi
export PATH="/usr/local/go/bin:$PATH"
mkdir -p artifacts
output=$(mktemp -d "$PWD/artifacts/simulator-$(date +%Y%m%d-%H%M%S).XXXXXX")
python3 scripts/bootstrap.py --verify-only
python3 scripts/check_project.py
xcrun simctl list devices available -j > "$output/devices-before.json"
selection=$(python3 - "$output/devices-before.json" "${NPV_SIMULATOR_UDID:-}" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    devices = [d for group in json.load(handle)["devices"].values() for d in group]
selected = [d for d in devices if d["udid"] == sys.argv[2]] if sys.argv[2] else [d for d in devices if d["name"] == "NPV Validation"]
if len(selected) != 1:
    sys.exit("Set NPV_SIMULATOR_UDID to one available iPhone simulator's UDID (xcrun simctl list devices available).")
print(selected[0]["udid"], selected[0]["state"])
PY
)
read -r simulator previous_state <<< "$selection"
started_here=0
cleanup() {
    if [[ "$started_here" == 1 ]]; then
        xcrun simctl shutdown "$simulator" || true
    fi
}
trap cleanup EXIT
if [[ "$previous_state" == Shutdown ]]; then
    xcrun simctl boot "$simulator"
    started_here=1
fi
xcrun simctl bootstatus "$simulator" -b
swift test --enable-code-coverage 2>&1 | tee "$output/core-tests.log"
python3 -m unittest discover -s scripts -p 'test_*.py' -v 2>&1 | tee "$output/build-tool-tests.log"
python3 -m unittest discover -s lab -p 'test_*.py' -v 2>&1 | tee "$output/fixture-tests.log"
set +e
xcodebuild -project NPV.xcodeproj -scheme NPV -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath DerivedData \
    -parallel-testing-enabled NO -resultBundlePath "$output/Simulator.xcresult" \
    -only-testing:NPVAppleTests/IdentityTests -only-testing:NPVAppleTests/ControllerTests \
    -only-testing:NPVUITests CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$output/simulator-tests.log"
test_result=${PIPESTATUS[0]}
set -e
if [[ -d "$output/Simulator.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$output/Simulator.xcresult" --output-path "$output/screenshots"
fi
if [[ "$test_result" != 0 ]]; then
    printf 'Simulator tests failed (%s). Evidence: %s\n' "$test_result" "$output" >&2
    exit "$test_result"
fi
for configuration in Debug Release; do
    xcodebuild -project NPV.xcodeproj -scheme NPV -configuration "$configuration" \
        -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
        CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$output/ios-$configuration-build.log"
done
binary=DerivedData/Build/Products/Release-iphoneos/NPV.app/NPV
xcrun nm -j "$binary" > "$output/release-symbols.txt"
if grep -Eq 'SimulatedTunnelBackend|SimulationSession|SimulationScenario' "$output/release-symbols.txt"; then
    echo 'Unexpected simulation implementation in device Release binary.' >&2
    exit 1
fi
file "$binary" DerivedData/Build/Products/Release-iphoneos/NPV.app/PlugIns/NPVTunnel.appex/NPVTunnel > "$output/ios-binaries.txt"
printf 'PASS: simulator tests, screenshots, unsigned iOS Debug/Release builds. Evidence: %s\n' "$output"
