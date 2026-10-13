#!/bin/sh
# Run the Spatial Agent desktop app from source (dev convenience).
#
# The app now starts its own dependencies (opencode + whisper), so this script
# only: provisions the venv, frees the daemon port, points the daemon at this
# repo, and enables LAN pairing — then launches the app.
#
# Usage: ./scripts/run_daemon_app.sh
#   SPATIAL_AGENT_PORT        daemon port, default 8787
#   SPATIAL_AGENT_WORKSPACE_PATH  repo agents should edit (default: this repo)
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
desktop_dir="$project_root/desktop"
venv="$desktop_dir/.venv"
daemon_port=${SPATIAL_AGENT_PORT:-8787}
export PYTHONPATH="$project_root/backend/src:$desktop_dir/src${PYTHONPATH:+:$PYTHONPATH}"

# 1. Provision the app venv (first run only).
if [ ! -x "$venv/bin/python" ]; then
	printf '%s\n' "Creating desktop venv and installing dependencies..."
	python3 -m venv "$venv"
	"$venv/bin/python" -m pip install -q --upgrade pip
fi
if ! "$venv/bin/python" -c "import webview" >/dev/null 2>&1; then
	"$venv/bin/python" -m pip install -q -e "$project_root/backend" -e "$desktop_dir"
fi

# 2. Free the daemon port (the app hosts its own daemon).
if nc -z 127.0.0.1 "$daemon_port" 2>/dev/null; then
	printf '%s\n' "Stopping an existing daemon on :$daemon_port..."
	pkill -f "spatial_agent_backend" 2>/dev/null || true
	sleep 1
fi

# 3. Configure the daemon the app will host (it starts opencode + whisper).
mkdir -p "$project_root/build/quest"
export SPATIAL_AGENT_PORT="$daemon_port"
export SPATIAL_AGENT_OPENCODE_DIR="$project_root"
export SPATIAL_AGENT_WORKSPACE_PATH="${SPATIAL_AGENT_WORKSPACE_PATH:-$project_root}"
export SPATIAL_AGENT_WORKSPACE_NAME="${SPATIAL_AGENT_WORKSPACE_NAME:-SpatialAgent}"
export SPATIAL_AGENT_WORKSPACE_BRANCH="${SPATIAL_AGENT_WORKSPACE_BRANCH:-main}"
# Fixed opencode server password so the daemon's client and the spawned
# `opencode serve` always agree (a random password from a stale server caused
# every agent run to fail with HTTP 401 -> OpencodeError).
export SPATIAL_AGENT_OPENCODE_PASSWORD="${SPATIAL_AGENT_OPENCODE_PASSWORD:-spatialagent}"
# Mirror headset logs relayed over the websocket to a file on the daemon host.
export SPATIAL_AGENT_CLIENT_LOG="$project_root/build/quest/client.log"

# Auto-detect a whisper.cpp model so on-headset voice works out of the box. The
# app starts whisper-server itself once this points at a ggml model.
if [ -z "${SPATIAL_AGENT_WHISPER_MODEL:-}" ]; then
	for candidate in \
		"$project_root/../../work/whisper-model/ggml-small.en.bin" \
		"$project_root/../../work/whisper-model/ggml-base.en.bin" \
		"$project_root/../../work/whisper-model/ggml-tiny.en.bin" \
		"$project_root/../whisper-model/ggml-base.en.bin" \
		"$HOME/.cache/whisper/ggml-small.en.bin" \
		"$HOME/.cache/whisper/ggml-base.en.bin" \
		"$HOME/whisper.cpp/models/ggml-base.en.bin"; do
		if [ -f "$candidate" ]; then
			export SPATIAL_AGENT_WHISPER_MODEL="$candidate"
			break
		fi
	done
fi

# Bind the LAN so the headset can reach it (TLS + pairing).
"$project_root/scripts/tls.sh" >/dev/null 2>&1 || true
if [ -f "$project_root/backend/certs/server.crt" ]; then
	export SPATIAL_AGENT_HOST=0.0.0.0
	export SPATIAL_AGENT_AUTH_REQUIRED=1
	export SPATIAL_AGENT_TLS_CERT="$project_root/backend/certs/server.crt"
	export SPATIAL_AGENT_TLS_KEY="$project_root/backend/certs/server.key"
fi

printf '%s\n' "Opening the Spatial Agent app (close the window to stop everything)..."
exec "$venv/bin/python" -m spatial_agent_desktop.app
