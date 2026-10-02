#!/bin/bash
# Builds the demo, runs it on a headless iOS simulator against the fake
# terminal server, and saves screenshots and the logs to OUT. Nothing is
# shown on screen: the simulator is booted with simctl only (Simulator.app is
# never opened).
#
#   OUT=/tmp/out ./run-simulator.sh            # needs macos/GhosttyKit.xcframework
#                                              # built with -Dxcframework-target=native-ios
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
PORT=${PORT:-8765}
DEVICE_NAME=${DEVICE_NAME:-ghostty-hosted-demo}
DEVICE_TYPE=${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}
BUNDLE=dev.ghostty.example.GhosttyHosted
mkdir -p "$OUT"

udid=$(xcrun simctl list devices -j | python3 -c "
import json,sys
for rt,ds in json.load(sys.stdin)['devices'].items():
    for d in ds:
        if d['name']=='$DEVICE_NAME' and d['isAvailable']: print(d['udid']); sys.exit()")
if [[ -z $udid ]]; then
    runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin)['runtimes'] if r['platform']=='iOS' and r['isAvailable']]
print(rs[-1]['identifier'])")
    udid=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$runtime")
fi
xcrun simctl bootstatus "$udid" -b >/dev/null
echo "simulator $udid"

(cd "$HERE" && xcodegen generate --quiet)
xcodebuild -project "$HERE/GhosttyHosted.xcodeproj" -scheme GhosttyHosted -configuration Debug \
    -sdk iphonesimulator -destination "id=$udid" -derivedDataPath "$OUT/dd" build -quiet \
    > "$OUT/xcodebuild.log" 2>&1 || { tail -40 "$OUT/xcodebuild.log"; exit 1; }
app=$(find "$OUT/dd/Build/Products" -name GhosttyHosted.app -maxdepth 2 | head -1)

python3 "$HERE/fake_terminal_server.py" --port "$PORT" --log "$OUT/frames.jsonl" > "$OUT/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; kill $logger 2>/dev/null' EXIT
sleep 0.5

xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl spawn "$udid" log stream --style compact --predicate "process == \"GhosttyHosted\"" > "$OUT/app.log" 2>&1 &
logger=$!
sleep 1
xcrun simctl launch "$udid" "$BUNDLE" -ws "ws://127.0.0.1:$PORT/terminal" -scenario 1 >/dev/null

wait_for() {
    for _ in $(seq 1 60); do grep -q "$1" "$OUT/app.log" && return 0; sleep 0.25; done
    echo "timed out waiting for $1" >&2; return 1
}
wait_for "scenario: READY-1"; sleep 0.3
xcrun simctl io "$udid" screenshot "$OUT/1-output-and-input.png" >/dev/null
wait_for "scenario: READY-2"; sleep 0.3
xcrun simctl io "$udid" screenshot "$OUT/2-after-resize.png" >/dev/null
xcrun simctl terminate "$udid" "$BUNDLE" || true
sleep 0.3
grep "\[demo\]" "$OUT/app.log" | grep -v "\] action " | sed 's/^.*\[demo\] //' > "$OUT/demo.log" || true
echo "screenshots and logs in $OUT"
python3 "$HERE/check_frames.py" "$OUT/frames.jsonl"
