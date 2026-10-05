#!/bin/sh
# Run the daemon in opencode "builder" mode against this repository.
#
# Starts a headless opencode server, then the Spatial Agent daemon configured
# to route agent runs through opencode, with this repository registered and all
# threads bound to it. Edits happen in a per-thread git worktree; shell commands
# surface as spatial approvals. Apply is gated by SPATIAL_AGENT_TEST_COMMAND.
#
# Usage: ./scripts/run_builder.sh
#   SPATIAL_AGENT_OPENCODE_PASSWORD  server password (default: generated)
#   OPENCODE_PORT                    default 4096
#   SPATIAL_AGENT_TEST_COMMAND       command run in the worktree before APPLY
#                                    (default: empty = no gate)

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
opencode_bin=${OPENCODE_BIN:-opencode}
port=${OPENCODE_PORT:-4096}
password=${SPATIAL_AGENT_OPENCODE_PASSWORD:-$(openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(16))')}
test_command=${SPATIAL_AGENT_TEST_COMMAND:-}

if ! command -v "$opencode_bin" >/dev/null 2>&1; then
	printf '%s\n' "opencode CLI not found on PATH (set OPENCODE_BIN)." >&2
	exit 2
fi

export SPATIAL_AGENT_PROVIDER=opencode
export SPATIAL_AGENT_OPENCODE_URL="http://127.0.0.1:$port"
export SPATIAL_AGENT_OPENCODE_PASSWORD="$password"
export SPATIAL_AGENT_OPENCODE_DIR="$project_root"
export SPATIAL_AGENT_WORKSPACE_PATH="$project_root"
export SPATIAL_AGENT_WORKSPACE_NAME="${SPATIAL_AGENT_WORKSPACE_NAME:-SpatialAgent}"
export SPATIAL_AGENT_WORKSPACE_BRANCH="${SPATIAL_AGENT_WORKSPACE_BRANCH:-main}"
export SPATIAL_AGENT_TEST_COMMAND="$test_command"

mkdir -p "$project_root/build/quest"
OPENCODE_SERVER_PASSWORD="$password" "$opencode_bin" serve \
	--hostname 127.0.0.1 --port "$port" \
	> "$project_root/build/quest/opencode.log" 2>&1 &
serve_pid=$!

whisper_pid=""
whisper_model=${SPATIAL_AGENT_WHISPER_MODEL:-$project_root/build/quest/whisper-model.bin}
whisper_port=${SPATIAL_AGENT_WHISPER_PORT:-8081}
if [ -f "$whisper_model" ] && command -v whisper-server >/dev/null 2>&1; then
	if ! nc -z 127.0.0.1 "$whisper_port" 2>/dev/null; then
		whisper-server -m "$whisper_model" --host 127.0.0.1 --port "$whisper_port" \
			> "$project_root/build/quest/whisper.log" 2>&1 &
		whisper_pid=$!
	fi
	export SPATIAL_AGENT_WHISPER_URL="http://127.0.0.1:$whisper_port"
	printf '%s\n' "whisper-server: 127.0.0.1:$whisper_port (model $(basename "$whisper_model"))"
fi

cleanup() { kill "$serve_pid" $whisper_pid 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 2

printf '%s\n' "opencode serve: 127.0.0.1:$port (pid $serve_pid, log build/quest/opencode.log)"
printf '%s\n' "provider=opencode workspace=$project_root threads auto-bound"
printf '%s\n' "Press Ctrl-C to stop both."
"$project_root/scripts/run_backend.sh" --lan
