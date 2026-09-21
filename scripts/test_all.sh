#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
godot_bin=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}
backend_python=${BACKEND_PYTHON:-"$project_root/backend/.venv/bin/python"}

if [ ! -x "$godot_bin" ]; then
	printf '%s\n' "Godot executable not found: $godot_bin" >&2
	exit 2
fi
if [ ! -x "$backend_python" ]; then
	printf '%s\n' "Backend virtual environment not found. Follow backend/README.md first." >&2
	exit 2
fi

# The pinned Godot OpenXR Vendors GDExtension (required for the Quest export)
# segfaults headless Godot 4.7.2 runs. Stash it for the duration of the test
# run; the trap below restores it, so export helpers are unaffected.
vendor_addon="$project_root/client-godot/addons/godotopenxrvendors"
vendor_stash="$project_root/client-godot/addons/.godotopenxrvendors.test-stash"
vendor_stashed=0
if [ -d "$vendor_addon" ]; then
	mv "$vendor_addon" "$vendor_stash"
	vendor_stashed=1
fi
restore_vendor_addon() {
	if [ "$vendor_stashed" -eq 1 ] && [ -d "$vendor_stash" ]; then
		mv "$vendor_stash" "$vendor_addon"
		vendor_stashed=0
	fi
}
trap restore_vendor_addon EXIT INT TERM

cd "$project_root/backend"
# Always test this checkout, including in environments that ignore editable
# installation .pth files. The venv still supplies the pinned dependencies.
export PYTHONPATH="$project_root/backend/src${PYTHONPATH:+:$PYTHONPATH}"
"$backend_python" -W error::ResourceWarning -m unittest discover -s tests -v

# Refresh Godot's global class cache so newly added class_name scripts are
# visible to the headless smoke scenes on a fresh checkout.
"$godot_bin" --headless --path "$project_root/client-godot" --import >/dev/null 2>&1 || true

# Run one headless Godot scene with a watchdog. A scene that fails to quit
# (for example after a script error) is killed and reported instead of hanging
# the whole suite.
run_scene() {
	scene=$1
	"$godot_bin" --headless --path "$project_root/client-godot" "res://tests/$scene.tscn" &
	scene_pid=$!
	( sleep "${SCENE_TIMEOUT_SECONDS:-60}"; kill "$scene_pid" 2>/dev/null ) &
	watchdog_pid=$!
	if wait "$scene_pid"; then
		kill "$watchdog_pid" 2>/dev/null || true
		wait "$watchdog_pid" 2>/dev/null || true
		return 0
	fi
	kill "$watchdog_pid" 2>/dev/null || true
	wait "$watchdog_pid" 2>/dev/null || true
	printf '%s\n' "Scene failed or timed out: $scene" >&2
	return 1
}

for scene in \
	milestone_0_smoke \
	openxr_hand_source_smoke \
	hand_lab_smoke \
	quick_intent_smoke \
	cognition_layer_smoke \
	mission_topology_smoke \
	privacy_veil_smoke \
	spatial_services_smoke \
	milestone_1_smoke \
	milestone_2_smoke \
	milestone_3_smoke \
	code_viewer_smoke \
	transport_boundary_smoke \
	cockpit_transport_smoke \
	cockpit_panels_smoke \
	standing_orbit_smoke \
	daemon_config_smoke \
	perf_probe_smoke \
	backend_client_smoke \
	command_and_approval_smoke \
	speech_service_smoke \
	android_speech_service_smoke
do
	run_scene "$scene" || exit 1
done

fixture_pid=""
backend_pid=""
fixture_ready=""
test_data_dir=""
cleanup() {
	if [ -n "$fixture_pid" ]; then
		kill "$fixture_pid" 2>/dev/null || true
	fi
	if [ -n "$backend_pid" ]; then
		kill "$backend_pid" 2>/dev/null || true
	fi
	if [ -n "$fixture_ready" ]; then
		rm -f "$fixture_ready"
	fi
	if [ -n "$test_data_dir" ]; then
		rm -rf "$test_data_dir"
	fi
}
trap 'cleanup; restore_vendor_addon' EXIT INT TERM

wait_for_fixture() {
	attempt=0
	until [ -s "$fixture_ready" ]; do
		attempt=$((attempt + 1))
		if ! kill -0 "$fixture_pid" 2>/dev/null; then
			printf '%s\n' "WebSocket fixture exited before becoming ready." >&2
			exit 1
		fi
		if [ "$attempt" -ge 100 ]; then
			printf '%s\n' "WebSocket fixture did not become ready." >&2
			exit 1
		fi
		sleep 0.02
	done
}


fixture_ready=$(mktemp "${TMPDIR:-/tmp}/spatial-agent-fixture.XXXXXX")
python3 "$project_root/client-godot/tests/support/websocket_fixture_server.py" --port 18787 --ready-file "$fixture_ready" &
fixture_pid=$!
wait_for_fixture
run_scene websocket_loopback_smoke
wait "$fixture_pid"
fixture_pid=""
rm -f "$fixture_ready"
fixture_ready=""

fixture_ready=$(mktemp "${TMPDIR:-/tmp}/spatial-agent-fixture.XXXXXX")
python3 "$project_root/client-godot/tests/support/websocket_fixture_server.py" --port 18789 --connections 2 --ready-file "$fixture_ready" &
fixture_pid=$!
wait_for_fixture
run_scene websocket_reconnect_smoke
wait "$fixture_pid"
fixture_pid=""
rm -f "$fixture_ready"
fixture_ready=""

test_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/spatial-agent-tests.XXXXXX")
SPATIAL_AGENT_PORT=18788 \
SPATIAL_AGENT_DB="$test_data_dir/full-stack.db" \
SPATIAL_AGENT_PROVIDER=fake \
"$backend_python" -m spatial_agent_backend &
backend_pid=$!

attempt=0
until nc -z 127.0.0.1 18788 2>/dev/null; do
	attempt=$((attempt + 1))
	if [ "$attempt" -ge 50 ]; then
		printf '%s\n' "Backend did not become ready on port 18788" >&2
		exit 1
	fi
	sleep 0.1
done

run_scene full_stack_smoke
kill "$backend_pid" 2>/dev/null || true
wait "$backend_pid" 2>/dev/null || true
backend_pid=""
rm -rf "$test_data_dir"
test_data_dir=""

printf '%s\n' "All backend, Godot, socket, reconnect, speech-boundary, and full-stack tests passed."
