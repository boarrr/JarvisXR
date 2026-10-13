#!/bin/sh
# Double-click this in Finder to run the Spatial Agent dev app.
#
# Unlike the packaged /Applications/Spatial Agent.app (which uses localhost,
# no TLS, and does not bind this repo), this launcher sets the LAN host, TLS,
# pairing, discovery, workspace binding, whisper model, and opencode password —
# exactly what the headset needs to connect and show your agents.
cd "$(dirname "$0")" || exit 1
exec ./scripts/run_daemon_app.sh
