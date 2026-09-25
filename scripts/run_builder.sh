#!/bin/sh
# Run the daemon in opencode "builder" mode against this repository.
#
# Starts a headless opencode server, then the Spatial Agent daemon configured
# to route agent runs through opencode, with this repository registered and all
# threads bound to it. Edits happen in per-run git worktrees; shell commands
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
password=${SPATIAL_AGENT_OPENCODE_PASSWORD:-builder-$(id -u)}
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
cleanup() { kill "$serve_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 2

printf '%s\n' "opencode serve: 127.0.0.1:$port (pid $serve_pid, log build/quest/opencode.log)"
printf '%s\n' "provider=opencode workspace=$project_root threads auto-bound"
printf '%s\n' "Press Ctrl-C to stop both."
"$project_root/scripts/run_backend.sh" --lan
