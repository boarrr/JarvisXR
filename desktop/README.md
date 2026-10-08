# Spatial Agent desktop app

A macOS app that **hosts the daemon** and shows a live "office" of your agents:
create/select/delete agents, chat with them, pause runs, and see the
headset-facing link info (LAN URLs, CA fingerprint, pairing code, paired
devices).

The app is self-contained: it starts and stops **opencode** (and **whisper**
when a model is present) itself, so there is no third program to run.

## Quick start

Build and install the app (writes `/Applications/Spatial Agent.app`):

```sh
./desktop/build_app.sh
cp -R "desktop/dist/Spatial Agent.app" /Applications/
```

Then **launch "Spatial Agent"** from Applications/Spotlight. On first run:

- It starts **opencode** itself (and `whisper` when a model is present) — no
  third program to run.
- Click **Workspace → Choose folder…** to pick the repository agents should edit
  (any git repo). The choice is remembered; new agents and missions target it.
- Click **Pair headset** for the LAN URL + code + QR.

No config files to edit — everything is in the window.

Dev convenience (runs from source with LAN + pairing preconfigured):

```sh
./scripts/run_daemon_app.sh
```

## Manual run

```sh
cd desktop
python3 -m venv .venv && . .venv/bin/activate
pip install -e .            # installs the backend + pywebview/pystray
SPATIAL_AGENT_WORKSPACE_PATH=/path/to/your/repo spatial-agent-desktop
```

The app writes its database/config to
`~/Library/Application Support/SpatialAgent/` and its dependency logs to
`~/Library/Application Support/SpatialAgent/logs/`. The daemon binds loopback by
default; set `SPATIAL_AGENT_HOST=0.0.0.0 SPATIAL_AGENT_AUTH_REQUIRED=1` plus TLS
(or use `run_daemon_app.sh`) to let a headset connect — the **Pair headset**
button shows the code + QR.

## Layout

- `src/spatial_agent_desktop/runtime.py` — hosts `SpatialAgentServer` on a
  background asyncio loop; sync API for the UI.
- `src/spatial_agent_desktop/dependencies.py` — starts/stops opencode + whisper.
- `src/spatial_agent_desktop/bridge.py` — pywebview JS↔Python facade.
- `src/spatial_agent_desktop/linkinfo.py` — LAN URLs / CA fingerprint / pairing.
- `src/spatial_agent_desktop/app.py` — pywebview window entry point.
- `src/spatial_agent_desktop/web/` — the agent-office UI (canvas + chat).

## Test

```sh
PYTHONPATH="../backend/src:src" ../backend/.venv/bin/python tests/test_runtime.py
```

