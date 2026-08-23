#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

APP_ID="com.facebook.react.uiapp"
ACTIVITY="$APP_ID/.RNTesterActivity"
DEEPLINK="rntester://example/AnimationBackend/presentation-geometry"
PROTOCOL="PG_CONTINUOUS_V3"
RESULT_DIR="${TMPDIR:-/tmp}/rn-presentation-geometry-regression-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

for tool in adb yarn curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

adb get-state >/dev/null 2>&1 || {
  echo "No Android device/emulator available via adb." >&2
  exit 1
}

METRO_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
METRO_PID=""
LOGCAT_PID=""

cleanup() {
  if [[ -n "$LOGCAT_PID" ]] && kill -0 "$LOGCAT_PID" >/dev/null 2>&1; then
    kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$METRO_PID" ]] && kill -0 "$METRO_PID" >/dev/null 2>&1; then
    kill "$METRO_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting fresh Metro on :$METRO_PORT (--reset-cache)..."
(
  cd packages/rn-tester
  yarn start --port "$METRO_PORT" --reset-cache
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
  echo "Metro did not become ready. See $RESULT_DIR/metro.log" >&2
  exit 1
fi

adb reverse "tcp:$METRO_PORT" "tcp:$METRO_PORT" >/dev/null
adb uninstall "$APP_ID" >/dev/null 2>&1 || true
adb shell pm trim-caches 1G >/dev/null 2>&1 || true

echo "Building/installing current branch..."
./gradlew \
  :packages:rn-tester:android:app:installDebug \
  -PreactNativeArchitectures=arm64-v8a \
  -PreactNativeDevServerPort="$METRO_PORT" \
  -Preact.internal.useHermesStable=false \
  -Preact.internal.useHermesNightly=false

adb reverse "tcp:$METRO_PORT" "tcp:$METRO_PORT" >/dev/null
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
adb logcat -c
adb logcat -v raw >"$RESULT_DIR/logcat.txt" 2>&1 &
LOGCAT_PID=$!

echo "Launching presentation geometry regression..."
adb shell am start -W \
  -a android.intent.action.VIEW \
  -d "$DEEPLINK" \
  -n "$ACTIVITY" >/dev/null

START_UI="$RESULT_DIR/start-ui.xml"
coords=""
for _ in $(seq 1 60); do
  adb shell uiautomator dump /sdcard/pg-regression-start.xml >/dev/null 2>&1 || true
  adb shell cat /sdcard/pg-regression-start.xml >"$START_UI" 2>/dev/null || true
  coords="$(python3 - "$START_UI" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)

for node in root.iter('node'):
    if 'START CONTINUOUS V3' not in node.attrib.get('text', ''):
        continue
    match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.attrib.get('bounds', ''))
    if match:
        x1, y1, x2, y2 = map(int, match.groups())
        print(f'{(x1 + x2) // 2} {(y1 + y2) // 2}')
        break
PY
)"
  if [[ -n "$coords" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$coords" ]]; then
  echo "Could not find START CONTINUOUS V3." >&2
  exit 1
fi

read -r tap_x tap_y <<<"$coords"
adb shell input tap "$tap_x" "$tap_y"

echo "Running $PROTOCOL (3 x 6s)..."
# Do not run UIAutomator while the sweep is being measured.
sleep 20

RESULT_UI="$RESULT_DIR/result-ui.xml"
RESULT_JSON="$RESULT_DIR/result.json"
parsed=""
for _ in $(seq 1 30); do
  adb shell uiautomator dump /sdcard/pg-regression-result.xml >/dev/null 2>&1 || true
  adb shell cat /sdcard/pg-regression-result.xml >"$RESULT_UI" 2>/dev/null || true
  parsed="$(python3 - "$RESULT_UI" "$PROTOCOL" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

path, protocol = sys.argv[1:]
try:
    root = ET.parse(path).getroot()
except Exception:
    sys.exit(0)

text = '\n'.join(node.attrib.get('text', '') for node in root.iter('node'))
if f'protocol: {protocol}' not in text:
    sys.exit(0)

pattern = re.compile(
    r'run\s+(\d+):\s+samples=(\d+)\s+observed=([-0-9.]+)\s+'
    r'expected=([-0-9.]+)\s+ratio=([-0-9.]+)\s+mae=([-0-9.]+)\s+'
    r'maxErr=([-0-9.]+)\s+duration=(\d+)ms'
)
runs = []
for match in pattern.finditer(text):
    run, samples, observed, expected, ratio, mae, max_err, duration = match.groups()
    runs.append({
        'run': int(run),
        'samples': int(samples),
        'observedDelta': float(observed),
        'expectedDelta': float(expected),
        'trackingRatio': float(ratio),
        'meanAbsError': float(mae),
        'maxAbsError': float(max_err),
        'durationMs': int(duration),
    })

if len(runs) != 3:
    sys.exit(0)

print(json.dumps({'protocol': protocol, 'runs': runs}))
PY
)"
  if [[ -n "$parsed" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$parsed" ]]; then
  echo "No valid $PROTOCOL result was produced." >&2
  tail -n 120 "$RESULT_DIR/logcat.txt" >&2 || true
  exit 1
fi
printf '%s\n' "$parsed" >"$RESULT_JSON"

python3 - "$RESULT_JSON" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    result = json.load(f)

failures = []
for run in result['runs']:
    label = f"run {run['run']}"
    if run['samples'] < 40:
        failures.append(f"{label}: too few samples ({run['samples']})")
    if run['expectedDelta'] < 80:
        failures.append(f"{label}: expected movement too small ({run['expectedDelta']:.1f}px)")
    if not 0.95 <= run['trackingRatio'] <= 1.05:
        failures.append(f"{label}: tracking ratio {run['trackingRatio']:.3f} outside [0.95, 1.05]")
    if run['meanAbsError'] > 3.0:
        failures.append(f"{label}: MAE {run['meanAbsError']:.1f}px > 3.0px")
    if run['maxAbsError'] > 8.0:
        failures.append(f"{label}: max error {run['maxAbsError']:.1f}px > 8.0px")

print('\n=== PRESENTATION GEOMETRY REGRESSION ===')
for run in result['runs']:
    print(
        f"run {run['run']}: samples={run['samples']} "
        f"observed={run['observedDelta']:.1f}px expected={run['expectedDelta']:.1f}px "
        f"ratio={run['trackingRatio']:.3f} mae={run['meanAbsError']:.1f}px "
        f"maxErr={run['maxAbsError']:.1f}px"
    )

if failures:
    print('RESULT: FAIL')
    for failure in failures:
        print(f'  - {failure}')
    sys.exit(1)

print('RESULT: PASS')
PY

echo "Artifacts: $RESULT_DIR"
