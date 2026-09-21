#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root/backend"
export PYTHONPATH="$project_root/backend/src${PYTHONPATH:+:$PYTHONPATH}"

mode="loopback"
if [ "${1:-}" = "--lan" ]; then
	mode="lan"
fi

if [ "$mode" = "lan" ]; then
	"$project_root/scripts/tls.sh"
	cert_dir="$project_root/backend/certs"
	lan_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
	if [ -z "$lan_ip" ]; then
		printf '%s\n' "No LAN address found on en0/en1; connect to Wi-Fi first." >&2
		exit 2
	fi
	export SPATIAL_AGENT_HOST=0.0.0.0
	export SPATIAL_AGENT_AUTH_REQUIRED=1
	export SPATIAL_AGENT_TLS_CERT="$cert_dir/server.crt"
	export SPATIAL_AGENT_TLS_KEY="$cert_dir/server.key"
	printf '%s\n' "LAN daemon: wss://$lan_ip:8787/ws"
	printf '%s\n' "Pairing: read the code below, or run ./scripts/run_backend.sh --pair in another shell."
	printf '%s\n' "Keep this Mac awake: this launcher uses caffeinate."
	exec caffeinate -is .venv/bin/python -m spatial_agent_backend
fi

if [ "${1:-}" = "--pair" ]; then
	exec .venv/bin/python -c "from spatial_agent_backend.pairing_cli import main; main()"
fi

exec .venv/bin/python -m spatial_agent_backend
