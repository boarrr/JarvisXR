#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
client_root="$project_root/client-godot"
godot_bin=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}
adb_bin=${ADB_BIN:-adb}
plugin_version=5.1.0-stable
plugin_sha256=6a838dbdf4115549e4511ebee0da9a5dcc8f9f6258d4cc2f2ee57a907a3e2911
plugin_url="https://github.com/GodotVR/godot_openxr_vendors/releases/download/$plugin_version/godotopenxrvendorsaddon.zip"
plugin_target="$client_root/addons/godotopenxrvendors"
apk_path="$project_root/build/quest/spatial-agent.apk"

usage() {
	printf '%s\n' "Usage: ./scripts/quest.sh setup|doctor|export|install|tunnel|deploy"
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf '%s\n' "Required command not found: $1" >&2
		exit 2
	fi
}

resolve_java17_home() {
	if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
		java_line=$("$JAVA_HOME/bin/java" -version 2>&1 | sed -n '1p')
		case "$java_line" in
			*\"17.*) printf '%s\n' "$JAVA_HOME"; return 0 ;;
		esac
	fi
	if [ -x /usr/libexec/java_home ]; then
		java_home_candidate=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
		if [ -n "$java_home_candidate" ] && [ -x "$java_home_candidate/bin/java" ]; then
			printf '%s\n' "$java_home_candidate"
			return 0
		fi
	fi
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
	JAVA_HOME="$java17_home" "$godot_bin" --headless --path "$client_root" --export-debug "Quest 3/3S" "$apk_path"
	printf '%s\n' "Exported: $apk_path"
}

tunnel_backend() {
	require_command "$adb_bin"
	"$adb_bin" reverse tcp:8787 tcp:8787
	printf '%s\n' "Quest localhost:8787 now reaches the Mac backend without LAN exposure."
}

install_apk() {
	require_command "$adb_bin"
	if [ ! -f "$apk_path" ]; then
		printf '%s\n' "APK not found; run ./scripts/quest.sh export first." >&2
		exit 2
	fi
	"$adb_bin" install -r "$apk_path"
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
	tunnel)
		tunnel_backend
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
