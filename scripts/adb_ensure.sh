#!/bin/sh
# Robust adb helper for the Quest.
#
# Wireless adb is fragile: the host adb server gets restarted (losing the
# tcp:5555 transport), the headset drops to "offline" when it idles or the Wi-Fi
# power-saves, and tcpip mode resets on reboot. This script centralises the
# recovery logic so every caller behaves the same:
#
#   - start the host server if it is not running
#   - prefer a USB device (fast, reliable); otherwise connect wireless
#   - heal "offline"/stale wireless entries (disconnect + reconnect)
#   - wait with a bounded budget for the device to become usable
#
# Usage:
#   scripts/adb_ensure.sh [--prefer usb|wifi|any] [--wait SECONDS] [--quiet]
#   scripts/adb_ensure.sh --arm            # enable wireless via USB, cache IP
#   scripts/adb_ensure.sh --ip             # print the headset Wi-Fi IP
#   scripts/adb_ensure.sh --list           # list devices and states
#
# On success prints the chosen serial (e.g. 340YC10G770FBN or 192.168.0.48:5555)
# and exits 0. Prints nothing and exits 1 when no usable device is found.

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
adb_bin=${ADB_BIN:-adb}
wifi_ip_file="$project_root/build/quest/wifi-ip"

prefer="any"
wait_budget=30
quiet=0
action="ensure"

while [ $# -gt 0 ]; do
	case "$1" in
		--prefer) prefer="$2"; shift 2 ;;
		--wait) wait_budget="$2"; shift 2 ;;
		--quiet) quiet=1; shift ;;
		--arm) action="arm"; shift ;;
		--ip) action="ip"; shift ;;
		--list) action="list"; shift ;;
		*) printf '%s\n' "Unknown option: $1" >&2; exit 2 ;;
	esac
done

log() {
	[ "$quiet" -eq 1 ] || printf '%s\n' "$*" >&2
}

start_server() {
	"$adb_bin" start-server >/dev/null 2>&1 || true
}

devices() {
	"$adb_bin" devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $1, $2}'
}

state_of() {
	"$adb_bin" devices 2>/dev/null | awk -v d="$1" '$1==d {print $2}'
}

usb_serial() {
	devices | awk '$1 !~ /:/ && $2=="device" {print $1; exit}'
}

wifi_serial() {
	devices | awk '$1 ~ /:/ && $2=="device" {print $1; exit}'
}

any_serial() {
	devices | awk '$2=="device" {print $1; exit}'
}

cached_ip() {
	[ -f "$wifi_ip_file" ] && cat "$wifi_ip_file" 2>/dev/null || true
}

arm_wireless() {
	serial=$(usb_serial)
	if [ -z "$serial" ]; then
		log "adb: need USB once to enable wireless (tcpip)"
		return 1
	fi
	"$adb_bin" -s "$serial" tcpip 5555 >/dev/null 2>&1 || true
	sleep 4
	ip=$("$adb_bin" -s "$serial" shell ip -4 addr show wlan0 2>/dev/null \
		| sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
	if [ -z "$ip" ]; then
		# Fall back to the USB-observed address in "adb devices".
		ip=$(devices | awk '$1 !~ /:/ {print $1; exit}')
	fi
	if [ -z "$ip" ]; then
		log "adb: could not determine headset Wi-Fi address"
		return 1
	fi
	mkdir -p "$(dirname -- "$wifi_ip_file")"
	printf '%s' "$ip" > "$wifi_ip_file"
	connect_wireless "$ip" || true
	log "adb: wireless armed at $ip:5555 (cached)"
	printf '%s\n' "$ip"
}

connect_wireless() {
	ip="$1"
	host="$ip:5555"
	attempt=0
	while [ "$attempt" -lt 5 ]; do
		attempt=$((attempt + 1))
		current=$(state_of "$host")
		if [ "$current" = "device" ]; then
			printf '%s\n' "$host"
			return 0
		fi
		if [ "$current" = "offline" ]; then
			"$adb_bin" disconnect "$host" >/dev/null 2>&1 || true
		fi
		"$adb_bin" connect "$host" >/dev/null 2>&1 || true
		sleep 2
		[ "$(state_of "$host")" = "device" ] && { printf '%s\n' "$host"; return 0; }
	done
	return 1
}

ensure() {
	start_server

	case "$prefer" in
		usb)
			usb_serial && return 0
			;;
		wifi)
			ip=$(cached_ip)
			if [ -n "$ip" ] && connect_wireless "$ip" >/dev/null 2>&1; then
				printf '%s\n' "$ip:5555"
				return 0
			fi
			;;
		any)
			serial=$(usb_serial)
			if [ -n "$serial" ]; then
				printf '%s\n' "$serial"
				return 0
			fi
			ip=$(cached_ip)
			if [ -n "$ip" ] && connect_wireless "$ip" >/dev/null 2>&1; then
				printf '%s\n' "$ip:5555"
				return 0
			fi
			;;
	esac

	# Bounded wait: keep trying every couple of seconds.
	elapsed=0
	while [ "$elapsed" -lt "$wait_budget" ]; do
		sleep 2
		elapsed=$((elapsed + 2))
		if [ -n "$(any_serial)" ]; then
			printf '%s\n' "$(any_serial)"
			return 0
		fi
		ip=$(cached_ip)
		[ -n "$ip" ] && connect_wireless "$ip" >/dev/null 2>&1 || true
	done
	return 1
}

case "$action" in
	arm)
		arm_wireless
		;;
	ip)
		ip=$(cached_ip)
		if [ -n "$ip" ]; then printf '%s\n' "$ip"; exit 0; fi
		serial=$(usb_serial)
		if [ -n "$serial" ]; then
			"$adb_bin" -s "$serial" shell ip -4 addr show wlan0 2>/dev/null \
				| sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
			exit 0
		fi
		exit 1
		;;
	list)
		devices
		exit 0
		;;
	ensure)
		if serial=$(ensure); then
			printf '%s\n' "$serial"
			exit 0
		fi
		log "adb: no usable device after ${wait_budget}s"
		exit 1
		;;
esac
