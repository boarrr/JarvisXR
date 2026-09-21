#!/bin/sh
set -eu

package_name=com.spatialagent.xr
out_dir=${1:-/tmp/spatial-agent-metrics}
mkdir -p "$out_dir"

adb shell "run-as $package_name cat files/perf_session.jsonl" > "$out_dir/perf_session.jsonl" 2>/dev/null || true
adb shell "run-as $package_name cat files/gesture_session.jsonl" > "$out_dir/gesture_session.jsonl" 2>/dev/null || true

python3 - "$out_dir" <<'PY'
import json
import statistics
import sys
from pathlib import Path

out = Path(sys.argv[1])


def load(name):
    path = out / name
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


perf = load("perf_session.jsonl")
if perf:
    fps = [row["fps_avg"] for row in perf]
    p95 = [row["frame_ms_p95"] for row in perf]
    draws = [row["draw_calls"] for row in perf]
    mem = [row["static_mem_mb"] for row in perf]
    print(
        "PERF windows: %d | fps min/median/max: %s/%s/%s | p95 max: %s ms | draws max: %d | mem max: %s MB"
        % (len(perf), min(fps), statistics.median(fps), max(fps), max(p95), max(draws), max(mem))
    )
    low = [row for row in perf if row["fps_avg"] < 70]
    print("windows below 70 fps: %d" % len(low))
else:
    print("no perf samples")

gest = load("gesture_session.jsonl")
if gest:
    losses = gest[-1].get("tracking_losses", 0)
    minutes = len(gest) / 60.0
    print(
        "GEST samples: %d (~%.1f min) | tracking losses: %d (%.1f/min)"
        % (len(gest), minutes, losses, losses / max(minutes, 0.1))
    )
    pinches = []
    fist_max = []
    for row in gest:
        hand = row.get("right") or {}
        if hand.get("pinch_mm") is not None:
            pinches.append(hand["pinch_mm"])
        fist = hand.get("fist_mm") or []
        if fist:
            fist_max.append(max(fist))
    if pinches:
        print(
            "right pinch gap mm min/median/max: %s/%s/%s"
            % (min(pinches), statistics.median(pinches), max(pinches))
        )
    if fist_max:
        print(
            "open-hand fingertip-to-palm mm min/median/max: %s/%s/%s"
            % (min(fist_max), statistics.median(fist_max), max(fist_max))
        )
else:
    print("no gesture samples")

print("raw files in %s" % out)
PY
