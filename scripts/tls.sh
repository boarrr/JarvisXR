#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cert_dir="$project_root/backend/certs"
force=0
if [ "${1:-}" = "--force" ]; then
	force=1
fi

lan_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
local_name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
desired="ip=${lan_ip:-none} name=$local_name"

mkdir -p "$cert_dir"
current="$(cat "$cert_dir/issued.txt" 2>/dev/null || true)"
if [ "$force" -eq 0 ] && [ -f "$cert_dir/server.crt" ] && [ "$current" = "$desired" ]; then
	printf '%s\n' "Certificates already current for $desired"
	exit 0
fi

printf '%s\n' "Generating dev CA and server certificate for $desired"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 730 \
	-subj "/CN=Spatial Agent Dev CA" \
	-keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" >/dev/null 2>&1

san="DNS:localhost,IP:127.0.0.1"
if [ -n "$lan_ip" ]; then
	san="$san,IP:$lan_ip"
fi
if [ -n "$local_name" ]; then
	san="$san,DNS:$local_name.local,DNS:$local_name"
fi
cat > "$cert_dir/server.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
EOF

openssl req -newkey rsa:2048 -nodes -sha256 \
	-subj "/CN=$local_name.local" \
	-keyout "$cert_dir/server.key" -out "$cert_dir/server.csr" >/dev/null 2>&1
openssl x509 -req -in "$cert_dir/server.csr" \
	-CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
	-days 730 -sha256 -extfile "$cert_dir/server.ext" \
	-out "$cert_dir/server.crt" >/dev/null 2>&1
rm -f "$cert_dir/server.csr" "$cert_dir/ca.srl"
printf '%s\n' "$desired" > "$cert_dir/issued.txt"
chmod 600 "$cert_dir/ca.key" "$cert_dir/server.key"
printf '%s\n' "SANs: $san"
printf '%s\n' "Wrote ca.crt, ca.key, server.crt, server.key to $cert_dir"
