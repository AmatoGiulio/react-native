#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
RNTESTER="$ROOT/packages/rn-tester"
LOCKFILE="$ROOT/Gemfile.lock"
DERIVED_DATA="${TMPDIR:-/tmp}/rn-presentation-geometry-ios-build"
LOG="$DERIVED_DATA/xcodebuild.log"

REQUIRED_RUBY="$(awk '/^RUBY VERSION$/{getline; sub(/^   ruby /, ""); sub(/p[0-9]+$/, ""); print; exit}' "$LOCKFILE")"
REQUIRED_BUNDLER="$(awk '/^BUNDLED WITH$/{getline; gsub(/^ +| +$/, ""); print; exit}' "$LOCKFILE")"
CURRENT_RUBY="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"

# Prefer an already-installed rbenv Ruby matching Gemfile.lock instead of the
# macOS system Ruby. This keeps the build gate reproducible without modifying
# the developer's global Ruby configuration.
if [[ "$CURRENT_RUBY" != "$REQUIRED_RUBY" ]] && command -v rbenv >/dev/null 2>&1; then
  if rbenv versions --bare 2>/dev/null | sed 's/[[:space:]]//g' | grep -Fxq "$REQUIRED_RUBY"; then
    export RBENV_VERSION="$REQUIRED_RUBY"
    export PATH="$(rbenv root)/shims:$PATH"
    exec bash "$0"
  fi
fi

if [[ "$CURRENT_RUBY" != "$REQUIRED_RUBY" ]]; then
  cat >&2 <<EOF
Ruby version mismatch for the RN iOS build gate.

Current:  ${CURRENT_RUBY:-not found}
Required: $REQUIRED_RUBY (Gemfile.lock)
Bundler:  $REQUIRED_BUNDLER (Gemfile.lock)

Install the locked toolchain once with rbenv:

  brew install rbenv ruby-build
  rbenv install -s $REQUIRED_RUBY
  export RBENV_VERSION=$REQUIRED_RUBY
  export PATH="\$(rbenv root)/shims:\$PATH"
  gem install bundler -v $REQUIRED_BUNDLER

Then rerun:

  bash scripts/check-presentation-geometry-ios-build.sh
EOF
  exit 2
fi

if ! gem list -i bundler -v "$REQUIRED_BUNDLER" >/dev/null 2>&1; then
  cat >&2 <<EOF
Bundler $REQUIRED_BUNDLER is not installed for Ruby $REQUIRED_RUBY.

Install it with:

  gem install bundler -v $REQUIRED_BUNDLER

Then rerun:

  bash scripts/check-presentation-geometry-ios-build.sh
EOF
  exit 2
fi

BUNDLE=(bundle "_${REQUIRED_BUNDLER}_")

for tool in xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

cd "$RNTESTER"

if ! "${BUNDLE[@]}" check >/dev/null 2>&1; then
  "${BUNDLE[@]}" install
fi

"${BUNDLE[@]}" exec pod install

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
