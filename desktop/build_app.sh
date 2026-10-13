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

# Bundle a config so a double-clicked app binds the LAN (TLS + pairing +
# discovery) and binds this repo, instead of localhost-only with no workspace.
python3 - "$root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
home = Path.home()
model = ""
for candidate in (
    root.parent.parent / "work/whisper-model/ggml-small.en.bin",
    root.parent.parent / "work/whisper-model/ggml-base.en.bin",
    home / ".cache/whisper/ggml-small.en.bin",
    home / "whisper.cpp/models/ggml-base.en.bin",
):
    if candidate.is_file():
        model = str(candidate)
        break
config = {
    "SPATIAL_AGENT_PROVIDER": "opencode",
    "SPATIAL_AGENT_HOST": "0.0.0.0",
    "SPATIAL_AGENT_PORT": "8787",
    "SPATIAL_AGENT_AUTH_REQUIRED": "1",
    "SPATIAL_AGENT_DISCOVERY": "1",
    "SPATIAL_AGENT_DISCOVERY_PORT": "8789",
    "SPATIAL_AGENT_TLS_CERT": str(root / "backend/certs/server.crt"),
    "SPATIAL_AGENT_TLS_KEY": str(root / "backend/certs/server.key"),
    "SPATIAL_AGENT_WORKSPACE_PATH": str(root),
    "SPATIAL_AGENT_WORKSPACE_NAME": "SpatialAgent",
    "SPATIAL_AGENT_WORKSPACE_BRANCH": "main",
    "SPATIAL_AGENT_OPENCODE_DIR": str(root),
    "SPATIAL_AGENT_OPENCODE_PASSWORD": "spatialagent",
    "SPATIAL_AGENT_FS_ROOT": str(home),
    "SPATIAL_AGENT_CLIENT_LOG": str(root / "build/quest/client.log"),
    "SPATIAL_AGENT_UPDATE_MANIFEST": str(root / "build/quest/manifest.json"),
}
if model:
    config["SPATIAL_AGENT_WHISPER_MODEL"] = model
out = root / "desktop/src/spatial_agent_desktop/bundle_config.json"
out.write_text(json.dumps(config, indent=2), encoding="utf-8")
print("Wrote", out)
PY

pyinstaller --noconfirm --clean --windowed \
  --name "Spatial Agent" \
  --add-data "src/spatial_agent_desktop/web:spatial_agent_desktop/web" \
  --add-data "src/spatial_agent_desktop/bundle_config.json:spatial_agent_desktop" \
  --collect-all webview \
  --osx-bundle-identifier "dev.spatialagent.desktop" \
  run_app.py

echo "Built: $here/dist/Spatial Agent.app"
echo "Run it, or move it to /Applications. Headset pairing lives in the app's"
echo "'Pair headset' dialog (LAN URL + code + QR)."
