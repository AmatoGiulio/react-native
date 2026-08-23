#!/usr/bin/env bash
set -euo pipefail

if [[ "${PG_BOTH_REEXEC:-0}" != "1" ]]; then
  root="$(git rev-parse --show-toplevel)"
  runner="${TMPDIR:-/tmp}/rn-pg-both-$$.sh"
  cp "$root/scripts/run-presentation-geometry-both.sh" "$runner"
  exec env PG_BOTH_REEXEC=1 PG_BOTH_ROOT="$root" bash "$runner"
fi

ROOT="${PG_BOTH_ROOT:?missing PG_BOTH_ROOT}"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit/stash changes before running validation." >&2
  exit 1
fi

ORIGINAL_SHA="$(git rev-parse HEAD)"
ORIGINAL_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
RESULT_DIR="${TMPDIR:-/tmp}/rn-presentation-geometry-both-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"
RESTORED=0

restore_checkout() {
  if [[ "$RESTORED" == "1" ]]; then
    return
  fi
  RESTORED=1
  if [[ -n "$ORIGINAL_BRANCH" ]]; then
    git switch -q "$ORIGINAL_BRANCH" >/dev/null 2>&1 || git checkout -q "$ORIGINAL_SHA"
  else
    git checkout -q "$ORIGINAL_SHA"
  fi
}
trap restore_checkout EXIT INT TERM

echo "Fetching validation branches..."
git fetch origin

run_gate() {
  local label="$1"
  local ref="$2"
  local log="$RESULT_DIR/${label}.log"

  echo
  echo "=== $label ==="
  echo "Checking out $ref"
  git switch --detach "$ref" >/dev/null

  set +e
  bash scripts/run-presentation-geometry-regression.sh 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "$label: FAIL (exit $status)" >&2
    return "$status"
  fi

  echo "$label: PASS"
}

proof_status=0
upstream_status=0
run_gate "proof-regression" "origin/research/presentation-geometry-regression" || proof_status=$?
run_gate "upstream-clean" "origin/research/presentation-geometry-upstream-clean" || upstream_status=$?

echo
echo "=== PRESENTATION GEOMETRY BOTH ==="
if [[ "$proof_status" -eq 0 ]]; then
  echo "proof-regression: PASS"
else
  echo "proof-regression: FAIL ($proof_status)"
fi
if [[ "$upstream_status" -eq 0 ]]; then
  echo "upstream-clean:    PASS"
else
  echo "upstream-clean:    FAIL ($upstream_status)"
fi

echo "Logs: $RESULT_DIR"

if [[ "$proof_status" -ne 0 || "$upstream_status" -ne 0 ]]; then
  exit 1
fi
