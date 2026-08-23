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
METRO_PORT=8099
STOCK_REF="origin/research/presentation-geometry-stock"
PATCHED_REF="origin/research/presentation-geometry-proof"
RESULT_TIMEOUT_SECONDS=210

for tool in git adb yarn curl python3; do
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

cleanup() {
  if [[ -n "$LOGCAT_PID" ]] && kill -0 "$LOGCAT_PID" >/dev/null 2>&1; then
    kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$METRO_PID" ]] && kill -0 "$METRO_PID" >/dev/null 2>&1; then
    kill "$METRO_PID" >/dev/null 2>&1 || true
  fi
  restore_checkout
}
trap cleanup EXIT INT TERM

echo "Fetching A/B refs..."
git fetch origin

echo "Starting isolated Metro on :$METRO_PORT..."
(
  cd packages/rn-tester
  yarn start --port "$METRO_PORT"
) >"$RESULT_DIR/metro.log" 2>&1 &
METRO_PID=$!

metro_ready=0
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$METRO_PORT/status" 2>/dev/null | grep -q "packager-status:running"; then
    metro_ready=1
    break
  fi
  if ! kill -0 "$METRO_PID" >/dev/null 2>&1; then
    echo "Metro exited before becoming ready. See $RESULT_DIR/metro.log" >&2
    exit 1
  fi
  sleep 1
done

if [[ "$metro_ready" != "1" ]]; then
  echo "Metro did not become ready on port $METRO_PORT. See $RESULT_DIR/metro.log" >&2
  exit 1
fi

adb reverse "tcp:$METRO_PORT" "tcp:$METRO_PORT" >/dev/null

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
    if 'START CONTINUOUS MATRIX' not in text:
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

  echo "Could not find START CONTINUOUS MATRIX for $label." >&2
  return 1
}

wait_for_matrix_result() {
  local label="$1"
  local log_file="$2"
  local result_file="$RESULT_DIR/${label}.json"
  local ui_xml="$RESULT_DIR/${label}-result-ui.xml"
  local elapsed=0
  local parsed=""

  while (( elapsed < RESULT_TIMEOUT_SECONDS )); do
    adb shell uiautomator dump /sdcard/pg-result.xml >/dev/null 2>&1 || true
    adb shell cat /sdcard/pg-result.xml >"$ui_xml" 2>/dev/null || true

    parsed="$(python3 - "$ui_xml" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    sys.exit(0)

texts = [node.attrib.get('text', '') for node in root.iter('node')]
text = '\n'.join(part for part in texts if part)
if 'Presentation geometry matrix' not in text:
    sys.exit(0)

runs = re.findall(
    r'run\s+(\d+):\s+span=([0-9.]+)\s+freeze=(\d+)\s+max=(\d+)ms\s+duration=(\d+)ms',
    text,
)
if len(runs) != 3:
    sys.exit(0)

samples_match = re.search(r'samples/run:\s*(\d+)', text)
total_match = re.search(r'total freeze episodes:\s*(\d+)', text)
max_match = re.search(r'matrix max freeze:\s*(\d+)ms', text)
press_in_match = re.search(r'onPressIn:\s*(\d+)', text)
press_match = re.search(r'onPress:\s*(\d+)', text)
press_gap_match = re.search(r'press gap:\s*(-?\d+)', text)
if not all((samples_match, total_match, max_match, press_in_match, press_match, press_gap_match)):
    sys.exit(0)

samples = int(samples_match.group(1))
run_data = [
    {
        'run': int(run),
        'span': float(span),
        'samples': samples,
        'freezeEpisodes': int(freeze),
        'maxFreezeMs': int(max_freeze),
        'durationMs': int(duration),
    }
    for run, span, freeze, max_freeze, duration in runs
]

print(json.dumps({
    'sampleIntervalMs': 50,
    'samplesPerRun': samples,
    'runs': run_data,
    'totalFreezeEpisodes': int(total_match.group(1)),
    'maxFreezeMs': int(max_match.group(1)),
    'onPressIn': int(press_in_match.group(1)),
    'onPress': int(press_match.group(1)),
    'pressGap': int(press_gap_match.group(1)),
}))
PY
)"

    if [[ -n "$parsed" ]]; then
      printf '%s\n' "$parsed" >"$result_file"
      echo "$result_file"
      return 0
    fi

    if ! adb shell pidof "$APP_ID" >/dev/null 2>&1; then
      echo "$label app process exited before producing a result." >&2
      tail -n 120 "$log_file" >&2 || true
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "Timed out waiting for $label matrix result after ${RESULT_TIMEOUT_SECONDS}s." >&2
  tail -n 120 "$log_file" >&2 || true
  return 1
}

run_variant() {
  local label="$1"
  local ref="$2"
  local log_file="$RESULT_DIR/${label}-logcat.txt"

  echo
  echo "=== $label ==="
  echo "Checking out $ref"
  git switch --detach "$ref" >/dev/null

  adb uninstall "$APP_ID" >/dev/null 2>&1 || true
  adb shell pm trim-caches 1G >/dev/null 2>&1 || true

  echo "Building/installing $label..."
  ./gradlew \
    :packages:rn-tester:android:app:installDebug \
    -PreactNativeArchitectures=arm64-v8a \
    -PreactNativeDevServerPort="$METRO_PORT"

  adb reverse "tcp:$METRO_PORT" "tcp:$METRO_PORT" >/dev/null
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
  echo "Matrix running; waiting for continuous sweep result..."
  wait_for_matrix_result "$label" "$log_file" >/dev/null

  if [[ -n "$LOGCAT_PID" ]] && kill -0 "$LOGCAT_PID" >/dev/null 2>&1; then
    kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  fi
  LOGCAT_PID=""

  echo "$label result captured."
}

run_variant "stock" "$STOCK_REF"
run_variant "patched" "$PATCHED_REF"

COMBINED_JSON="$RESULT_DIR/ab-result.json"
python3 - "$RESULT_DIR/stock.json" "$RESULT_DIR/patched.json" "$COMBINED_JSON" <<'PY'
import json
import sys

stock_path, patched_path, out_path = sys.argv[1:]
with open(stock_path) as f:
    stock = json.load(f)
with open(patched_path) as f:
    patched = json.load(f)


def print_variant(name, data):
    freezes = [run['freezeEpisodes'] for run in data['runs']]
    spans = [round(run['span'], 1) for run in data['runs']]
    print(
        f"{name:7} freezes/run={freezes} total={data['totalFreezeEpisodes']} "
        f"max={data['maxFreezeMs']}ms spans={spans}"
    )

print('\n=== PRESENTATION GEOMETRY A/B ===')
print_variant('STOCK', stock)
print_variant('PATCHED', patched)

if stock['totalFreezeEpisodes'] > 0 and patched['totalFreezeEpisodes'] == 0:
    verdict = 'PASS: stock freezes, patched has zero freeze episodes'
elif patched['totalFreezeEpisodes'] < stock['totalFreezeEpisodes']:
    verdict = 'IMPROVED: patched has fewer freeze episodes than stock'
else:
    verdict = 'INCONCLUSIVE: patched did not reduce freeze episodes'

print(f'VERDICT: {verdict}')

with open(out_path, 'w') as f:
    json.dump({'stock': stock, 'patched': patched, 'verdict': verdict}, f, indent=2)
PY

echo
echo "Artifacts: $RESULT_DIR"
echo "Combined JSON: $COMBINED_JSON"
