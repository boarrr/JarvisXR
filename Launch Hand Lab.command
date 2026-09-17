#!/bin/sh
set -eu
lab_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lab_godot=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}
if [ ! -x "$lab_godot" ]; then
  printf '%s\n' "Godot not found at $lab_godot. Install Godot or set GODOT_BIN."
  exit 1
fi
exec "$lab_godot" --xr-mode off --path "$lab_root/client-godot" -- --hand-lab
