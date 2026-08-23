#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
RNTESTER="$ROOT/packages/rn-tester"
DERIVED_DATA="${TMPDIR:-/tmp}/rn-presentation-geometry-ios-build"
LOG="$DERIVED_DATA/xcodebuild.log"

for tool in bundle pod xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

cd "$RNTESTER"

if ! bundle check >/dev/null 2>&1; then
  bundle install
fi

bundle exec pod install

rm -rf "$DERIVED_DATA"
mkdir -p "$DERIVED_DATA"

set +e
xcodebuild \
  -scheme RNTester \
  -workspace RNTesterPods.xcworkspace \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]]; then
  echo
  echo "=== PRESENTATION GEOMETRY IOS BUILD ==="
  echo "RESULT: FAIL ($status)"
  echo "Log: $LOG"
  exit "$status"
fi

echo
echo "=== PRESENTATION GEOMETRY IOS BUILD ==="
echo "RESULT: PASS"
echo "Log: $LOG"
