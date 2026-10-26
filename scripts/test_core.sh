#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
swift --version | tee artifacts/swift-version.txt
swift test --enable-code-coverage 2>&1 | tee artifacts/core-tests.log
# Parsing Apple source catches syntax errors only. Linux has no iOS SDK, so this
# MUST NOT be reported as a successful iOS build/type check.
while IFS= read -r file; do
    swiftc -frontend -parse "$file"
done < <(find Sources/App Sources/AppleShared Sources/Tunnel Tests/AppleTests -name '*.swift' -type f | sort)
echo 'Apple source syntax parsing passed; iOS SDK compilation remains unverified.' | tee artifacts/apple-syntax.log
