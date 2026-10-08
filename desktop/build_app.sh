#!/usr/bin/env bash
# Build a macOS .app bundle for the Spatial Agent daemon app.
#
#   ./desktop/build_app.sh
#
# Produces dist/Spatial Agent.app. Requires Xcode command line tools. The app
# carries its own Python + the backend + pywebview; config lives in
# ~/Library/Application Support/SpatialAgent/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$here"

python3 -m venv .venv 2>/dev/null || true
# shellcheck disable=SC1091
. .venv/bin/activate
pip install -q --upgrade pip
pip install -q -e "$root/backend" -e .
pip install -q pyinstaller

pyinstaller --noconfirm --clean --windowed \
  --name "Spatial Agent" \
  --add-data "src/spatial_agent_desktop/web:spatial_agent_desktop/web" \
  --collect-all webview \
  --osx-bundle-identifier "dev.spatialagent.desktop" \
  run_app.py

echo "Built: $here/dist/Spatial Agent.app"
echo "Run it, or move it to /Applications. Headset pairing lives in the app's"
echo "'Pair headset' dialog (LAN URL + code + QR)."
