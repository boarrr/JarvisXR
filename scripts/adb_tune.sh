#!/bin/sh
# Reduce wireless-adb drops on the Quest.
#
# The headset powers down Wi-Fi when idle and applies battery saving, which
# tears down the tcp:5555 transport mid-transfer. These settings keep Wi-Fi and
# the device awake enough for adb to be reliable. Applied best-effort.
#
# Usage: scripts/adb_tune.sh [--serial SERIAL]

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adb_bin=${ADB_BIN:-adb}
serial=""

while [ $# -gt 0 ]; do
	case "$1" in
		--serial) serial="$2"; shift 2 ;;
		*) printf '%s\n' "Unknown option: $1" >&2; exit 2 ;;
	esac
done

if [ -z "$serial" ]; then
	serial=$("$project_root/scripts/adb_ensure.sh" --wait 15 2>/dev/null || true)
fi
if [ -z "$serial" ]; then
	printf '%s\n' "adb_tune: no device available" >&2
	exit 1
fi

apply() {
	"$adb_bin" -s "$serial" "$@" >/dev/null 2>&1 || true
}

apply shell settings put global wifi_sleep_policy 2
apply shell settings put global wifi_scan_always_enabled 0
apply shell settings put global low_power 0
apply shell settings put global adaptive_battery_management_enabled 0
apply shell svc power stayon true

sleep_policy=$("$adb_bin" -s "$serial" shell settings get global wifi_sleep_policy 2>/dev/null | tr -d '\r' || true)
printf '%s\n' "adb_tune: applied to $serial (wifi_sleep_policy=$sleep_policy)"
printf '%s\n' "  keep the headset charging to make stay-awake effective"
