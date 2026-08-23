#!/usr/bin/env bash
set -euo pipefail

if [[ "${PG_AB_REEXEC:-0}" != "1" ]]; then
  root="$(git rev-parse --show-toplevel)"
  runner="${TMPDIR:-/tmp}/rn-pg-ab-runner-$$.sh"
  cp "$root/scripts/run-presentation-geometry-ab.sh" "$runner"
  exec env PG_AB_REEXEC=1 PG_AB_ROOT="$root" bash "$runner"
fi

ROOT="${PG_AB_ROOT:?missing PG_AB_ROOT}"
cd "$ROOT"

APP_ID="com.facebook.react.uiapp"
ACTIVITY="$APP_ID/.RNTesterActivity"
DEEPLINK="rntester://example/AnimationBackend/presentation-geometry"
PROTOCOL="PG_CONTINUOUS_V3"
STOCK_REF="origin/research/presentation-geometry-stock"
PATCHED_REF="origin/research/presentation-geometry-proof"
RESULT_SETTLE_SECONDS=21
RESULT_TIMEOUT_SECONDS=45

for tool in git adb yarn curl python3 pkill; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit/stash changes before running the A/B matrix." >&2
  exit 1
fi

adb get-state >/dev/null 2>&1 || {
  echo "No Android device/emulator available via adb." >&2
  exit 1
}

ORIGINAL_SHA="$(git rev-parse HEAD)"
ORIGINAL_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
RESULT_DIR="${TMPDIR:-/tmp}/rn-presentation-geometry-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

METRO_PID=""
LOGCAT_PID=""
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

stop_metro() {
  if [[ -n "$METRO_PID" ]]; then
    pkill -TERM -P "$METRO_PID" >/dev/null 2>&1 || true
    kill "$METRO_PID" >/dev/null 2>&1 || true
    wait "$METRO_PID" >/dev/null 2>&1 || true
    METRO_PID=""
  fi
}

cleanup() {
  if [[ -n "$LOGCAT_PID" ]] && kill -0 "$LOGCAT_PID" >/dev/null 2>&1; then
    kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  fi
  stop_metro
  restore_checkout
}
trap cleanup EXIT INT TERM

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

start_metro() {
  local label="$1"
  local port="$2"
  local metro_log="$RESULT_DIR/${label}-metro.log"

  echo "Starting fresh Metro for $label on :$port (--reset-cache)..."
  (
    cd packages/rn-tester
    exec yarn start --port "$port" --reset-cache
  ) >"$metro_log" 2>&1 &
  METRO_PID=$!

  for _ in $(seq 1 90); do
    if ! kill -0 "$METRO_PID" >/dev/null 2>&1; then
      echo "Metro for $label exited before becoming ready. See $metro_log" >&2
      tail -n 80 "$metro_log" >&2 || true
      return 1
    fi
    if curl -fsS "http://127.0.0.1:$port/status" 2>/dev/null | grep -q "packager-status:running"; then
      return 0
    fi
    sleep 1
  done

  echo "Metro for $label did not become ready. See $metro_log" >&2
  return 1
}

find_and_tap_matrix_button() {
  local label="$1"
  local ui_xml="$RESULT_DIR/${label}-start-ui.xml"
  local coords=""

  for _ in $(seq 1 60); do
    adb shell uiautomator dump /sdcard/pg-ui.xml >/dev/null 2>&1 || true
    adb shell cat /sdcard/pg-ui.xml >"$ui_xml" 2>/dev/null || true

    coords="$(python3 - "$ui_xml" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    sys.exit(0)

for node in root.iter('node'):
    text = node.attrib.get('text', '')
    if 'START CONTINUOUS V3' not in text:
        continue
    bounds = node.attrib.get('bounds', '')
    match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
    if match:
        x1, y1, x2, y2 = map(int, match.groups())
        print(f'{(x1 + x2) // 2} {(y1 + y2) // 2}')
        break
PY
)"

    if [[ -n "$coords" ]]; then
      read -r x y <<<"$coords"
      adb shell input tap "$x" "$y"
      return 0
    fi
    sleep 1
  done

  echo "Could not find START CONTINUOUS V3 for $label." >&2
  return 1
}

wait_for_matrix_result() {
  local label="$1"
  local log_file="$2"
  local result_file="$RESULT_DIR/${label}.json"
  local ui_xml="$RESULT_DIR/${label}-result-ui.xml"
  local elapsed=0
  local parsed=""

  # The V3 matrix takes ~18.6 seconds. Do not run UIAutomator while sampling;
  # it can perturb the UI thread and measurement latency.
  sleep "$RESULT_SETTLE_SECONDS"

  while (( elapsed < RESULT_TIMEOUT_SECONDS )); do
    adb shell uiautomator dump /sdcard/pg-result.xml >/dev/null 2>&1 || true
    adb shell cat /sdcard/pg-result.xml >"$ui_xml" 2>/dev/null || true

    parsed="$(python3 - "$ui_xml" "$PROTOCOL" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

path, protocol = sys.argv[1:]
try:
    root = ET.parse(path).getroot()
except Exception:
    sys.exit(0)

texts = [node.attrib.get('text', '') for node in root.iter('node')]
text = '\n'.join(part for part in texts if part)
if f'protocol: {protocol}' not in text:
    sys.exit(0)

number = r'-?[0-9]+(?:\.[0-9]+)?'
runs = re.findall(
    rf'run\s+(\d+):\s+samples=(\d+)\s+observed=({number})\s+'
    rf'expected=({number})\s+ratio=({number})\s+mae=({number})\s+'
    rf'maxErr=({number})\s+duration=(\d+)ms',
    text,
)
if len(runs) != 3:
    sys.exit(0)

run_data = []
for run, samples, observed, expected, ratio, mae, max_err, duration in runs:
    run_data.append({
        'run': int(run),
        'samples': int(samples),
        'observedDelta': float(observed),
        'expectedDelta': float(expected),
        'trackingRatio': float(ratio),
        'meanAbsError': float(mae),
        'maxAbsError': float(max_err),
        'durationMs': int(duration),
    })

print(json.dumps({'protocol': protocol, 'runs': run_data}))
PY
)"

    if [[ -n "$parsed" ]]; then
      printf '%s\n' "$parsed" >"$result_file"
      echo "$result_file"
      return 0
    fi

    if ! adb shell pidof "$APP_ID" >/dev/null 2>&1; then
      echo "$label app process exited before producing a $PROTOCOL result." >&2
      tail -n 120 "$log_file" >&2 || true
      return 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Timed out waiting for $label $PROTOCOL result." >&2
  tail -n 120 "$log_file" >&2 || true
  return 1
}

run_variant() {
  local label="$1"
  local ref="$2"
  local port
  local log_file="$RESULT_DIR/${label}-logcat.txt"

  echo
  echo "=== $label ==="
  echo "Checking out $ref"
  git switch --detach "$ref" >/dev/null

  port="$(free_port)"

  adb uninstall "$APP_ID" >/dev/null 2>&1 || true
  adb shell pm trim-caches 1G >/dev/null 2>&1 || true

  echo "Building/installing $label..."
  ./gradlew \
    :packages:rn-tester:android:app:installDebug \
    -PreactNativeArchitectures=arm64-v8a \
    -PreactNativeDevServerPort="$port"

  start_metro "$label" "$port"
  adb reverse "tcp:$port" "tcp:$port" >/dev/null

  adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  adb logcat -c
  adb logcat -v raw >"$log_file" 2>&1 &
  LOGCAT_PID=$!

  echo "Launching presentation-geometry deep link..."
  adb shell am start -W \
    -a android.intent.action.VIEW \
    -d "$DEEPLINK" \
    -n "$ACTIVITY" >/dev/null

  find_and_tap_matrix_button "$label"
  echo "Running $PROTOCOL: 3 x 6s time-bounded sweeps..."
  wait_for_matrix_result "$label" "$log_file" >/dev/null

  if [[ -n "$LOGCAT_PID" ]] && kill -0 "$LOGCAT_PID" >/dev/null 2>&1; then
    kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  fi
  LOGCAT_PID=""
  stop_metro

  echo "$label $PROTOCOL result captured."
}

echo "Fetching A/B refs..."
git fetch origin

run_variant "stock" "$STOCK_REF"
run_variant "patched" "$PATCHED_REF"

COMBINED_JSON="$RESULT_DIR/ab-result.json"
python3 - "$RESULT_DIR/stock.json" "$RESULT_DIR/patched.json" "$COMBINED_JSON" <<'PY'
import json
import statistics
import sys

stock_path, patched_path, out_path = sys.argv[1:]
with open(stock_path) as f:
    stock = json.load(f)
with open(patched_path) as f:
    patched = json.load(f)


def mean(values):
    return statistics.mean(values) if values else 0.0


def summarize(name, data):
    ratios = [r['trackingRatio'] for r in data['runs']]
    maes = [r['meanAbsError'] for r in data['runs']]
    observed = [r['observedDelta'] for r in data['runs']]
    expected = [r['expectedDelta'] for r in data['runs']]
    samples = [r['samples'] for r in data['runs']]
    durations = [r['durationMs'] for r in data['runs']]
    print(
        f"{name:7} ratio={[round(v, 3) for v in ratios]} "
        f"MAE={[round(v, 1) for v in maes]} "
        f"observed={[round(v, 1) for v in observed]} "
        f"expected={[round(v, 1) for v in expected]} "
        f"samples={samples} duration={durations}"
    )
    return mean(ratios), mean(maes)

print('\n=== PRESENTATION GEOMETRY A/B V3 ===')
stock_ratio, stock_mae = summarize('STOCK', stock)
patched_ratio, patched_mae = summarize('PATCHED', patched)

patched_tracks = 0.85 <= patched_ratio <= 1.15
stock_does_not = stock_ratio < 0.6 or stock_ratio > 1.4
if patched_tracks and stock_does_not and patched_mae + 10 < stock_mae:
    verdict = 'PASS: patched tracks the native presentation sweep; stock does not'
elif patched_mae < stock_mae * 0.5:
    verdict = 'IMPROVED: patched materially reduces presentation tracking error'
else:
    verdict = 'INCONCLUSIVE: V3 did not show a material tracking improvement'

print(f'VERDICT: {verdict}')

with open(out_path, 'w') as f:
    json.dump({
        'protocol': 'PG_CONTINUOUS_V3',
        'stock': stock,
        'patched': patched,
        'stockMeanRatio': stock_ratio,
        'patchedMeanRatio': patched_ratio,
        'stockMeanAbsError': stock_mae,
        'patchedMeanAbsError': patched_mae,
        'verdict': verdict,
    }, f, indent=2)
PY

echo
echo "Artifacts: $RESULT_DIR"
echo "Combined JSON: $COMBINED_JSON"