# Spatial Agent desktop app

A macOS app that **hosts the daemon** and shows a live "office" of your agents:
create/select/delete agents, chat with them, pause runs, and see the
headset-facing link info (LAN URLs, CA fingerprint, pairing code, paired
devices).

## Run

```sh
cd desktop
python3 -m venv .venv && . .venv/bin/activate
pip install -e .            # installs the backend + pywebview/pystray
# Point at your agent harness (opencode by default):
SPATIAL_AGENT_PROVIDER=opencode \
SPATIAL_AGENT_OPENCODE_URL=http://127.0.0.1:4096 \
SPATIAL_AGENT_HARNESS=opencode \
spatial-agent-desktop
```

The app writes its database/config to
`~/Library/Application Support/SpatialAgent/`. The daemon binds loopback by
default; set `SPATIAL_AGENT_HOST=0.0.0.0 SPATIAL_AGENT_AUTH_REQUIRED=1` plus TLS
to let a headset connect (the **Pair headset** button shows the code).

## Layout

- `src/spatial_agent_desktop/runtime.py` — hosts `SpatialAgentServer` on a
  background asyncio loop; sync API for the UI.
- `src/spatial_agent_desktop/bridge.py` — pywebview JS↔Python facade.
- `src/spatial_agent_desktop/linkinfo.py` — LAN URLs / CA fingerprint / pairing.
- `src/spatial_agent_desktop/app.py` — pywebview window entry point.
- `src/spatial_agent_desktop/web/` — the agent-office UI (canvas + chat).

## Test

```sh
PYTHONPATH="../backend/src:src" ../backend/.venv/bin/python tests/test_runtime.py
```
