#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
client_root="${SPATIAL_CLIENT_ROOT:-$project_root/client-godot}"
godot_bin=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}
adb_bin=${ADB_BIN:-adb}
plugin_version=5.1.0-stable
plugin_sha256=6a838dbdf4115549e4511ebee0da9a5dcc8f9f6258d4cc2f2ee57a907a3e2911
plugin_url="https://github.com/GodotVR/godot_openxr_vendors/releases/download/$plugin_version/godotopenxrvendorsaddon.zip"
plugin_target="$client_root/addons/godotopenxrvendors"
apk_path="$project_root/build/quest/spatial-agent.apk"
wifi_ip_file="$project_root/build/quest/wifi-ip"
manifest_path="$project_root/build/quest/manifest.json"
updates_dir="$project_root/build/quest/updates"

usage() {
	printf '%s\n' "Usage: ./scripts/quest.sh setup|doctor|export|install|tunnel|lan|dictation-plugin|updater-plugin|deploy|wifi|wifi-install|deploy-wifi|manifest|export-release|deploy-release|deploy-release-wifi|adb|tune|discover"
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf '%s\n' "Required command not found: $1" >&2
		exit 2
	fi
}

resolve_java17_home() {
	# Prefer a JDK that actually runs on this machine (arm64). A stale x86_64
	# JDK otherwise breaks Godot's Gradle export with "Bad CPU type".
	for candidate in \
		"${JAVA_HOME:-}" \
		"/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
		"$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
		"$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
	do
		if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ]; then
			if "$candidate/bin/java" -version >/dev/null 2>&1; then
				printf '%s\n' "$candidate"
				return 0
			fi
		fi
	done
	return 1
}

install_vendor_plugin() {
	if [ -d "$plugin_target" ]; then
		printf '%s\n' "OpenXR vendors plugin already installed: $plugin_target"
		return
	fi
	require_command curl
	require_command unzip
	require_command shasum
	temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/spatial-agent-openxr.XXXXXX")
	trap 'rm -rf "$temporary_dir"' EXIT INT TERM
	archive="$temporary_dir/vendor.zip"
	printf '%s\n' "Downloading verified Godot OpenXR Vendors $plugin_version..."
	curl -L --fail --silent --show-error -o "$archive" "$plugin_url"
	actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
	if [ "$actual_sha" != "$plugin_sha256" ]; then
		printf '%s\n' "Vendor plugin checksum mismatch; refusing to install." >&2
		exit 1
	fi
	unzip -q "$archive" 'asset/addons/*' -d "$temporary_dir/unpacked"
	mkdir -p "$client_root/addons"
	cp -R "$temporary_dir/unpacked/asset/addons/godotopenxrvendors" "$plugin_target"
	printf '%s\n' "Installed OpenXR vendors plugin at $plugin_target"
}

install_android_template() {
	if [ ! -x "$godot_bin" ]; then
		printf '%s\n' "Godot executable not found: $godot_bin" >&2
		exit 2
	fi
	java17_home=$(resolve_java17_home || true)
	if [ -z "$java17_home" ]; then
		printf '%s\n' "JDK 17 was not found. Install it or set JAVA_HOME to its Home directory." >&2
		exit 2
	fi
	JAVA_HOME="$java17_home" "$godot_bin" --headless --editor --path "$client_root" --install-android-build-template
}

doctor() {
	status=0
	if [ -x "$godot_bin" ]; then
		printf '%s\n' "OK  Godot: $godot_bin"
	else
		printf '%s\n' "MISS Godot: set GODOT_BIN" >&2
		status=1
	fi
	if command -v "$adb_bin" >/dev/null 2>&1; then
		printf '%s\n' "OK  adb: $(command -v "$adb_bin")"
	else
		printf '%s\n' "MISS adb: install Android platform-tools or set ADB_BIN" >&2
		status=1
	fi
	if [ -d "$plugin_target" ]; then
		printf '%s\n' "OK  OpenXR vendors: $plugin_version"
	else
		printf '%s\n' "MISS OpenXR vendors: run ./scripts/quest.sh setup" >&2
		status=1
	fi
	if [ -f "$client_root/android/build/build.gradle" ]; then
		printf '%s\n' "OK  Android Gradle build template"
	else
		printf '%s\n' "MISS Android build template: run ./scripts/quest.sh setup" >&2
		status=1
	fi
	java17_home=$(resolve_java17_home || true)
	if [ -n "$java17_home" ]; then
		java_line=$("$java17_home/bin/java" -version 2>&1 | sed -n '1p')
		printf '%s\n' "OK  JDK 17: $java_line ($java17_home)"
	else
		printf '%s\n' "MISS JDK 17: install it or set JAVA_HOME" >&2
		status=1
	fi
	return "$status"
}

export_debug() {
	if [ ! -x "$godot_bin" ]; then
		printf '%s\n' "Godot executable not found: $godot_bin" >&2
		exit 2
	fi
	mkdir -p "$(dirname -- "$apk_path")"
	java17_home=$(resolve_java17_home || true)
	if [ -z "$java17_home" ]; then
		printf '%s\n' "JDK 17 was not found. Install it or set JAVA_HOME to its Home directory." >&2
		exit 2
	fi
	# The Android build template must stay invisible to Godot's importer:
	# generated .import sidecars break the Gradle resource merger.
	mkdir -p "$client_root/android/build"
	# Hide only the generated Gradle template from Godot's importer; the rest of
	# res://android (including res://android/plugins) must stay discoverable.
	rm -f "$client_root/android/.gdignore"
	: > "$client_root/android/build/.gdignore"
	find "$client_root/android" -name "*.import" -delete 2>/dev/null || true
	version_name=$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$client_root/export_presets.cfg" | head -1)
	if [ -n "$version_name" ]; then
		if grep -q '^config/version=' "$client_root/project.godot"; then
			sed -i '' "s|^config/version=.*|config/version=\"$version_name\"|" "$client_root/project.godot"
		else
			sed -i '' "s|^config/name=.*|&\nconfig/version=\"$version_name\"|" "$client_root/project.godot"
		fi
	fi
	inject_fallback_host
	inject_dev_ca
	apk_timestamp_before=$(stat -f %m "$apk_path" 2>/dev/null || printf '0')
	set +e
	JAVA_HOME="$java17_home" "$godot_bin" --headless --path "$client_root" --export-debug "Quest 3/3S" "$apk_path"
	export_status=$?
	set -e
	apk_timestamp_after=$(stat -f %m "$apk_path" 2>/dev/null || printf '0')
	if [ "$apk_timestamp_after" = "$apk_timestamp_before" ]; then
		printf '%s\n' "Export did not produce a fresh APK (Godot exit code $export_status)." >&2
		exit 1
	fi
	if [ "$export_status" -ne 0 ]; then
		printf '%s\n' "Note: Godot exited with code $export_status after writing the APK (known OpenXR vendor plugin shutdown crash); the APK is fresh."
	fi
	printf '%s\n' "Exported: $apk_path"
	write_manifest
}

export_release() {
	# Release build with compressed native libraries: ~30 MB instead of ~95 MB,
	# which makes Wi-Fi updates far faster and more reliable.
	if [ ! -x "$godot_bin" ]; then
		printf '%s\n' "Godot executable not found: $godot_bin" >&2
		exit 2
	fi
	mkdir -p "$(dirname -- "$apk_path")"
	java17_home=$(resolve_java17_home || true)
	if [ -z "$java17_home" ]; then
		printf '%s\n' "A JDK was not found. Set JAVA_HOME." >&2
		exit 2
	fi
	mkdir -p "$client_root/android/build"
	rm -f "$client_root/android/.gdignore"
	: > "$client_root/android/build/.gdignore"
	find "$client_root/android" -name "*.import" -delete 2>/dev/null || true
	version_name=$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$client_root/export_presets.cfg" | head -1)
	if [ -n "$version_name" ]; then
		if grep -q '^config/version=' "$client_root/project.godot"; then
			sed -i '' "s|^config/version=.*|config/version=\"$version_name\"|" "$client_root/project.godot"
		else
			sed -i '' "s|^config/name=.*|&\nconfig/version=\"$version_name\"|" "$client_root/project.godot"
		fi
	fi
	inject_fallback_host
	inject_dev_ca
	apk_timestamp_before=$(stat -f %m "$apk_path" 2>/dev/null || printf '0')
	set +e
	JAVA_HOME="$java17_home" "$godot_bin" --headless --path "$client_root" --export-release "Quest 3/3S" "$apk_path"
	export_status=$?
	set -e
	apk_timestamp_after=$(stat -f %m "$apk_path" 2>/dev/null || printf '0')
	if [ "$apk_timestamp_after" = "$apk_timestamp_before" ]; then
		printf '%s\n' "Release export did not produce a fresh APK (exit $export_status)." >&2
		exit 1
	fi
	printf '%s\n' "Exported: $apk_path ($(du -h "$apk_path" | cut -f1))"
	printf '%s\n' "Update payload size: $(du -h "$apk_path" | cut -f1)"
	write_manifest
}

inject_fallback_host() {
	# Bake the host's current LAN IP as a link fallback so a headset whose mDNS
	# cannot resolve <host>.local still reaches the daemon directly.
	local ip=""
	for candidate in en0 en1 en2 en3 en4; do
		ip=$(ipconfig getifaddr "$candidate" 2>/dev/null || true)
		[ -n "$ip" ] && break
	done
	if [ -z "$ip" ]; then
		printf '%s\n' "No LAN IP found; leaving backend_websocket_fallback untouched." >&2
		return 0
	fi
	local fallback="wss://$ip:8787/ws"
	if grep -q '^backend_websocket_fallback=' "$client_root/project.godot"; then
		sed -i '' "s|^backend_websocket_fallback=.*|backend_websocket_fallback=\"$fallback\"|" "$client_root/project.godot"
	elif grep -q '^backend_websocket_url=' "$client_root/project.godot"; then
		sed -i '' "s|^backend_websocket_url=.*|&\nbackend_websocket_fallback=\"$fallback\"|" "$client_root/project.godot"
	fi
	printf '%s\n' "Fallback daemon URL: $fallback"
}


inject_dev_ca() {
	# Ship the dev CA inside the APK so a fresh headset trusts the daemon
	# without a separate cert push.
	if [ ! -f "$project_root/backend/certs/ca.crt" ]; then
		"$project_root/scripts/tls.sh" >/dev/null 2>&1 || true
	fi
	if [ ! -f "$project_root/backend/certs/ca.crt" ]; then
		printf '%s\n' "No dev CA available; skipping baked CA." >&2
		return 0
	fi
	mkdir -p "$client_root/certs"
	cp "$project_root/backend/certs/ca.crt" "$client_root/certs/dev_ca.crt"
	if grep -q '^baked_ca_path=' "$client_root/project.godot"; then
		sed -i '' "s|^baked_ca_path=.*|baked_ca_path=\"res://certs/dev_ca.crt\"|" "$client_root/project.godot"
	elif grep -q '^backend_websocket_url=' "$client_root/project.godot"; then
		sed -i '' "s|^backend_websocket_url=.*|&\nbaked_ca_path=\"res://certs/dev_ca.crt\"|" "$client_root/project.godot"
	fi
	printf '%s\n' "Baked dev CA into res://certs/dev_ca.crt"
}


discover_info() {
	"$project_root/scripts/tls.sh" >/dev/null 2>&1 || true
	local ip name fp
	ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
	name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
	fp=$(openssl x509 -in "$project_root/backend/certs/ca.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')
	printf '%s\n' "Spatial Agent daemon discovery"
	printf '%s\n' "  websocket: wss://${ip:-<no-lan-ip>}:8787/ws"
	printf '%s\n' "  hostname:  ${name}.local"
	printf '%s\n' "  discovery: udp/8789 (broadcast + probe)"
	printf '%s\n' "  ca sha256: ${fp:-<none>}"
}


write_manifest() {
	if [ ! -f "$apk_path" ]; then
		printf '%s\n' "APK not found; run ./scripts/quest.sh export first." >&2
		exit 2
	fi
	require_command shasum
	mkdir -p "$updates_dir"
	sha=$(shasum -a 256 "$apk_path" | awk '{print $1}')
	short_sha=$(printf '%s' "$sha" | cut -c1-12)
	size=$(wc -c < "$apk_path" | tr -d ' ')
	git_rev=$(git -C "$client_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
	version_name=$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$client_root/export_presets.cfg" | head -1)
	[ -n "$version_name" ] || version_name="$git_rev"
	built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	published="$updates_dir/spatial-agent-$short_sha.apk"
	cp "$apk_path" "$published"
	cat > "$manifest_path" <<EOF
{
  "app": "spatial-agent",
  "package": "com.spatialagent.xr",
  "version": "$version_name",
  "git_rev": "$git_rev",
  "sha256": "$sha",
  "size_bytes": $size,
  "built_at": "$built_at",
  "apk": "$(basename -- "$published")"
}
EOF
	printf '%s\n' "Published update: $published"
	printf '%s\n' "Manifest: $manifest_path"
}

tunnel_backend() {
	require_command "$adb_bin"
	"$adb_bin" reverse tcp:8787 tcp:8787
	printf '%s\n' "Quest localhost:8787 now reaches the Mac backend without LAN exposure."
}

lan_backend() {
	lan_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
	if [ -z "$lan_ip" ]; then
		lan_ip="<your-host>"
	fi
	printf '%s\n' "Start the daemon so paired devices on the same network can reach it:"
	printf '%s\n' "  SPATIAL_AGENT_HOST=0.0.0.0 \\"
	printf '%s\n' "  SPATIAL_AGENT_AUTH_REQUIRED=1 \\"
	printf '%s\n' "  SPATIAL_AGENT_TLS_CERT=/path/to/cert.pem \\"
	printf '%s\n' "  SPATIAL_AGENT_TLS_KEY=/path/to/key.pem \\"
	printf '%s\n' "  .venv/bin/spatial-agent-backend"
	printf '%s\n' "Then set spatial_agent/backend_websocket_url to wss://$lan_ip:8787/ws,"
	printf '%s\n' "issue a code with .venv/bin/spatial-agent-pair, and pair with /pair CODE."
}

dictation_plugin() {
	plugin_source="$project_root/client-godot/android_plugins/dictation"
	if [ ! -d "$plugin_source" ]; then
		printf '%s\n' "Dictation plugin source not found: $plugin_source" >&2
		exit 2
	fi
	if ! command -v gradle >/dev/null 2>&1; then
		printf '%s\n' "Gradle was not found. Install Gradle 8.x, then rerun this command." >&2
		exit 2
	fi
	(cd "$plugin_source" && gradle assembleRelease --quiet)
	# Godot discovers *.gdap non-recursively in res://android/plugins.
	plugin_target="$client_root/android/plugins"
	mkdir -p "$plugin_target"
	cp "$plugin_source/build/outputs/aar/dictation-release.aar" \
		"$plugin_target/DictationPlugin.aar"
	cp "$plugin_source/DictationPlugin.gdap" "$plugin_target/DictationPlugin.gdap"
	printf '%s\n' "Installed dictation plugin at $plugin_target"
	printf '%s\n' "Export with Gradle build enabled so the plugin is packaged into the APK."
}

wireless_device_host() {
	"$adb_bin" devices | awk 'NR>1 && $2 == "device" && $1 ~ /:/ { print $1; exit }'
}

usb_device_serial() {
	"$adb_bin" devices | awk 'NR>1 && $2 == "device" && $1 !~ /:/ { print $1; exit }'
}

headset_wifi_ip() {
	host=$(wireless_device_host)
	if [ -z "$host" ] && [ -f "$wifi_ip_file" ]; then
		cached_ip=$(cat "$wifi_ip_file")
		if [ -n "$cached_ip" ]; then
			"$adb_bin" connect "$cached_ip:5555" >/dev/null 2>&1
			host=$(wireless_device_host)
		fi
	fi
	if [ -n "$host" ]; then
		printf '%s\n' "${host%%:*}"
		return 0
	fi
	serial=$(usb_device_serial)
	if [ -z "$serial" ]; then
		return 1
	fi
	"$adb_bin" -s "$serial" shell ip -4 addr show wlan0 2>/dev/null \
		| sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}

wifi_enable() {
	require_command "$adb_bin"
	serial=$(usb_device_serial)
	if [ -z "$serial" ]; then
		printf '%s\n' "Attach the headset over USB once to enable wireless debugging." >&2
		exit 2
	fi
	"$adb_bin" -s "$serial" tcpip 5555 >/dev/null
	sleep 3
	ip=$(headset_wifi_ip || true)
	if [ -z "$ip" ]; then
		printf '%s\n' "Could not read the headset Wi-Fi address from wlan0." >&2
		exit 1
	fi
	"$adb_bin" connect "$ip:5555"
	mkdir -p "$(dirname -- "$wifi_ip_file")"
	printf '%s' "$ip" > "$wifi_ip_file"
	printf '%s\n' "Wireless ADB ready: $ip:5555 (persists until the headset reboots)."
}

wireless_install() {
	require_command "$adb_bin"
	if [ ! -f "$apk_path" ]; then
		printf '%s\n' "APK not found; run ./scripts/quest.sh export first." >&2
		exit 2
	fi
	serial=$("$project_root/scripts/adb_ensure.sh" --prefer wifi --wait 20 2>/dev/null || true)
	if [ -z "$serial" ]; then
		printf '%s\n' "No wireless adb device; arm it with ./scripts/quest.sh wifi (USB)." >&2
		exit 2
	fi
	# Streaming install is more resilient than push+pm over flaky Wi-Fi, and
	# adb_ensure already healed the transport.
	"$adb_bin" -s "$serial" install -r "$apk_path"
	printf '%s\n' "Installed over Wi-Fi to $serial"
}

resolve_android_java_home() {
	resolve_java17_home
}

updater_plugin() {
	plugin_source="$client_root/android_plugins/updater"
	if [ ! -d "$plugin_source" ]; then
		printf '%s\n' "Updater plugin source not found: $plugin_source" >&2
		exit 2
	fi
	gradlew="$client_root/android/build/gradlew"
	if [ ! -x "$gradlew" ]; then
		printf '%s\n' "Android build template missing; run ./scripts/quest.sh setup first." >&2
		exit 2
	fi
	android_java_home=$(resolve_android_java_home || true)
	if [ -z "$android_java_home" ]; then
		printf '%s\n' "No arm64 JDK 17/21 found. Install Android Studio or a JDK 21." >&2
		exit 2
	fi
	android_sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
	if [ ! -d "$android_sdk" ]; then
		printf '%s\n' "Android SDK not found. Set ANDROID_HOME (tried: $android_sdk)." >&2
		exit 2
	fi
	(
		cd "$plugin_source" &&
			JAVA_HOME="$android_java_home" ANDROID_HOME="$android_sdk" \
				"$gradlew" assembleRelease --no-daemon --console=plain
	)
	aar=$(find "$plugin_source/build/outputs/aar" -name "*.aar" 2>/dev/null | head -1)
	if [ -z "$aar" ]; then
		printf '%s\n' "Updater AAR was not produced." >&2
		exit 1
	fi
	# Godot discovers *.gdap non-recursively in res://android/plugins.
	plugin_target="$client_root/android/plugins"
	mkdir -p "$plugin_target"
	cp "$aar" "$plugin_target/UpdaterPlugin.aar"
	cp "$plugin_source/AndroidUpdater.gdap" "$plugin_target/AndroidUpdater.gdap"
	printf '%s\n' "Installed updater plugin at $plugin_target"
	printf '%s\n' "Export with Gradle build enabled so the plugin is packaged into the APK."
}

install_apk() {
	require_command "$adb_bin"
	if [ ! -f "$apk_path" ]; then
		printf '%s\n' "APK not found; run ./scripts/quest.sh export first." >&2
		exit 2
	fi
	serial=$("$project_root/scripts/adb_ensure.sh" --wait 20 2>/dev/null || true)
	if [ -z "$serial" ]; then
		printf '%s\n' "No usable adb device (USB or wireless)." >&2
		exit 2
	fi
	printf '%s\n' "Installing to $serial ..."
	"$adb_bin" -s "$serial" install -r "$apk_path"
}

action=${1:-doctor}
case "$action" in
	setup)
		install_vendor_plugin
		install_android_template
		printf '%s\n' "Quest project dependencies are ready. Run ./scripts/quest.sh doctor."
		;;
	doctor)
		doctor
		;;
	export)
		export_debug
		;;
	install)
		install_apk
		;;
	adb)
		"$project_root/scripts/adb_ensure.sh" --wait 20
		;;
	tune)
		"$project_root/scripts/adb_tune.sh"
		;;
	discover)
		discover_info
		;;
	wifi)
		wifi_enable
		;;
	wifi-install)
		wireless_install
		;;
	deploy-wifi)
		export_debug
		wireless_install
		printf '%s\n' "Open Spatial Agent XR from Quest's Unknown Sources library."
		;;
	tunnel)
		tunnel_backend
		;;
	lan)
		lan_backend
		;;
	dictation-plugin)
		dictation_plugin
		;;
	updater-plugin)
		updater_plugin
		;;
	manifest)
		write_manifest
		;;
	export-release)
		export_release
		;;
	deploy-release)
		export_release
		install_apk
		;;
	deploy-release-wifi)
		export_release
		wireless_install
		;;
	deploy)
		export_debug
		install_apk
		tunnel_backend
		printf '%s\n' "Open Spatial Agent XR from Quest's Unknown Sources library."
		;;
	*)
		usage
		exit 2
		;;
esac
