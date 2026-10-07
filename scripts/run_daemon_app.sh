#!/bin/sh
# Run the Spatial Agent desktop app.
#
# Sets up its own virtualenv, starts the agent dependencies (opencode serve +
# whisper), then opens the pywebview window which HOSTS the daemon. The daemon
# binds the LAN so the headset can pair (see the app's "Pair headset" button).
#
# Usage: ./scripts/run_daemon_app.sh
#   SPATIAL_AGENT_PROVIDER     default opencode (use "fake" for a UI-only demo)
#   SPATIAL_AGENT_HARNESS      opencode | codex  (codex needs the codex CLI)
#   OPENCODE_PORT              default 4096
#   SPATIAL_AGENT_PORT         daemon port, default 8787
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
desktop_dir="$project_root/desktop"
venv="$desktop_dir/.venv"
opencode_bin=${OPENCODE_BIN:-opencode}
opencode_port=${OPENCODE_PORT:-4096}
daemon_port=${SPATIAL_AGENT_PORT:-8787}
provider=${SPATIAL_AGENT_PROVIDER:-opencode}
harness=${SPATIAL_AGENT_HARNESS:-opencode}
password=${SPATIAL_AGENT_OPENCODE_PASSWORD:-$(openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(16))')}

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

# 3. Start opencode (and whisper when available) for real agents.
opencode_pid=""
whisper_pid=""
cleanup() {
	[ -n "$opencode_pid" ] && kill "$opencode_pid" 2>/dev/null || true
	[ -n "$whisper_pid" ] && kill "$whisper_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ "$provider" = "opencode" ]; then
	if ! command -v "$opencode_bin" >/dev/null 2>&1; then
		printf '%s\n' "opencode CLI not found (set OPENCODE_BIN or SPATIAL_AGENT_PROVIDER=fake)." >&2
		exit 2
	fi
	OPENCODE_SERVER_PASSWORD="$password" "$opencode_bin" serve \
		--hostname 127.0.0.1 --port "$opencode_port" \
		> "$project_root/build/quest/opencode.log" 2>&1 &
	opencode_pid=$!
	printf '%s\n' "opencode serve: 127.0.0.1:$opencode_port (log build/quest/opencode.log)"
fi

whisper_model=${SPATIAL_AGENT_WHISPER_MODEL:-$project_root/build/quest/whisper-model.bin}
whisper_port=${SPATIAL_AGENT_WHISPER_PORT:-8081}
if [ -f "$whisper_model" ] && command -v whisper-server >/dev/null 2>&1; then
	if ! nc -z 127.0.0.1 "$whisper_port" 2>/dev/null; then
		whisper-server -m "$whisper_model" --host 127.0.0.1 --port "$whisper_port" \
			> "$project_root/build/quest/whisper.log" 2>&1 &
		whisper_pid=$!
	fi
	export SPATIAL_AGENT_WHISPER_URL="http://127.0.0.1:$whisper_port"
	printf '%s\n' "whisper-server: 127.0.0.1:$whisper_port"
fi

# 4. Configure the daemon the app will host.
mkdir -p "$project_root/build/quest"
export SPATIAL_AGENT_PORT="$daemon_port"
export SPATIAL_AGENT_PROVIDER="$provider"
export SPATIAL_AGENT_HARNESS="$harness"
export SPATIAL_AGENT_OPENCODE_URL="http://127.0.0.1:$opencode_port"
export SPATIAL_AGENT_OPENCODE_PASSWORD="$password"
export SPATIAL_AGENT_OPENCODE_DIR="$project_root"
export SPATIAL_AGENT_WORKSPACE_PATH="$project_root"
export SPATIAL_AGENT_WORKSPACE_NAME="${SPATIAL_AGENT_WORKSPACE_NAME:-SpatialAgent}"
export SPATIAL_AGENT_WORKSPACE_BRANCH="${SPATIAL_AGENT_WORKSPACE_BRANCH:-main}"

# Bind the LAN so the headset can reach it (TLS + pairing), like run_builder.
"$project_root/scripts/tls.sh" >/dev/null 2>&1 || true
if [ -f "$project_root/backend/certs/server.crt" ]; then
	export SPATIAL_AGENT_HOST=0.0.0.0
	export SPATIAL_AGENT_AUTH_REQUIRED=1
	export SPATIAL_AGENT_TLS_CERT="$project_root/backend/certs/server.crt"
	export SPATIAL_AGENT_TLS_KEY="$project_root/backend/certs/server.key"
fi

printf '%s\n' "Opening the Spatial Agent app (close the window to stop everything)..."
exec "$venv/bin/python" -m spatial_agent_desktop.app
