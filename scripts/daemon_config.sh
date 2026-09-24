#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_name=com.spatialagent.xr
cert_dir="$project_root/backend/certs"

"$project_root/scripts/tls.sh" >/dev/null
lan_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [ -z "$lan_ip" ]; then
	printf '%s\n' "No LAN address found on en0/en1." >&2
	exit 2
fi
if ! command -v adb >/dev/null 2>&1; then
	printf '%s\n' "adb was not found on PATH." >&2
	exit 2
fi
if [ ! -f "$cert_dir/ca.crt" ]; then
	printf '%s\n' "Missing $cert_dir/ca.crt" >&2
	exit 2
fi

if [ "${1:-}" = "--show" ]; then
	adb shell "run-as $package_name cat files/daemon.cfg" 2>/dev/null || {
		printf '%s\n' "No daemon.cfg on the device yet." >&2
		exit 1
	}
	exit 0
fi

local_name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
daemon_host=${SPATIAL_DAEMON_HOST:-$local_name.local}
config_file=$(mktemp "${TMPDIR:-/tmp}/spatial-agent-daemon.XXXXXX")
token=$("$project_root/scripts/run_backend.sh" --pair-token 2>/dev/null | tail -1 || true)
cat > "$config_file" <<EOF
[daemon]

websocket_url="wss://$daemon_host:8787/ws"
ca_certificate_path="dev_ca.crt"
auth_token="$token"
EOF

adb start-server >/dev/null 2>&1
adb shell "run-as $package_name mkdir -p files"
adb shell "run-as $package_name sh -c 'cat > files/dev_ca.crt'" < "$cert_dir/ca.crt"
adb shell "run-as $package_name sh -c 'cat > files/daemon.cfg'" < "$config_file"
rm -f "$config_file"

printf '%s\n' "Seeded device daemon config: wss://$daemon_host:8787/ws with the dev CA."
printf '%s\n' "A fresh bootstrap device token was written for this headset."
"$project_root/scripts/adb_tune.sh" >/dev/null 2>&1 || true
printf '%s\n' "Next: ./scripts/run_backend.sh --lan  then relaunch Spatial Agent XR."
