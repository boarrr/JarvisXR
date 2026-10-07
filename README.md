# Spatial Agent XR

A Quest-ready Godot 4.7 spatial agent workbench for OpenXR hand tracking. Eight data-driven agent orbs run out of the box in offline mode; the same client can connect to the included local WebSocket backend for persistent threads, streaming responses, cancellation, safe telemetry, approval-gated tools, OpenAI, Claude, DeepSeek, or an explicit dual-provider Council mode.

> **Rev 2 (spatial dev cockpit):** the headset is now a terminal for a companion daemon that owns the workspace. Agents work in isolated `git worktree` branches, MCP servers (filesystem, git, shell, browser, GitHub) expose real tools behind the approval gate, LAN devices pair with a short code over TLS, and new cockpit panels cover workspace state, diff review, file browsing, and daemon settings. See [Spatial Dev Cockpit](docs/SPATIAL_DEV_COCKPIT.md) and the new ADRs in [Decisions](docs/DECISIONS.md).

> **Rev 3 (fleet + desktop app):** the daemon gains **fleet missions**—one goal fanned out to N isolated agents with pick-one merge and time/cost budgets—and the XR composer is now **text-first** with a spatial-keyboard fallback. A macOS **daemon desktop app** hosts the daemon and shows a live agent office, and a normalized `AgentHarness` seam keeps `opencode` native while adding a Codex CLI adapter. See [Fleet (missions)](#fleet-missions) and [Daemon desktop app](#daemon-desktop-app) below.

![Spatial Agent XR prototype](preview.png)

## What is complete

- Hand-ray hover/select, pinch selection, semantic focus/dismiss, and a stable 8–12-orb layout.
- Original holographic instrument treatment with concentric orb telemetry, calibrated ticks, dark-glass panels, and an animated hand-ray reticle.
- Readable world-space transcript panel with incremental assistant output.
- Vim-inspired floating code trace with streamed fenced-code extraction, line numbers, syntax highlighting, minimap, semantic scrolling, and a bounded animated 3D sculpture for fenced diffs.
- Protocol commands for create, focus, rename, archive, cancel, list, and the safe tool demonstration.
- Versioned provider-neutral WebSocket protocol, reconnection with snapshot restoration, packet limits, strict command validation, and per-session rate limiting.
- SQLite persistence and a provider abstraction with deterministic fake, OpenAI Responses, Claude, DeepSeek chat completions, and explicit OpenAI+Claude Council adapters.
- A normalized `AgentHarness` seam: `opencode` stays the native path, and `SPATIAL_AGENT_HARNESS=codex` drives runs through `CodexCliHarness` (subprocess; JSONL or plain text; `SPATIAL_AGENT_CODEX_COMMAND` overrides the binary).
- Explicit backend-authoritative approval UI with modal world-space Approve/Deny pinch targets and a content-blind **Ghost Future** showing route, scope, side effects, and reversibility before consent. The included `demo.write_note` tool is simulated and makes no external change.
- Privacy-oriented local push-to-talk boundary using `whisper.cpp`; microphone audio is not sent over WebSocket and temporary recordings are deleted by default.
- A real `XROrigin3D`/`XRCamera3D` runtime with optical-hand-only joint polling, a stabilized hand ray, thumb-index pinch hysteresis, pinch-drag code scrolling, and two-hand Code Trace transforms. Controller-inferred skeletons are rejected.
- A left-palm command console with live provider/model/link telemetry and a text-first composer: an input row pairs a text field with **SPEAK**. Selecting the field starts hardware typing (Enter sends, Esc cancels); a spatial qwerty keyboard auto-appears when no hardware keyboard has been detected, and SPEAK uses host-streamed voice. When speech is unavailable, SPEAK falls back to a four-choice hand-only quick-intent panel.
- A summonable Spatial Cognition Layer: live backend activity becomes an animated causal constellation around the focused agent, a hand-scrubbable temporal black box, and a privacy field that makes local versus hosted provider routing visible without rendering prompt contents.
- A room-scale Mission Map with animated, content-blind status pulses over explicit parent links and clearly labelled focused-agent correlations. It is capped at 12 links for standalone hardware, and the fleet constellation stars each mission over its agents.
- Fleet missions with `/mission GOAL`: one goal fans out to N isolated agents, `/fleet` toggles the constellation view, and review merges one winning branch via a pick-one decision under optional time and cost budgets.
- A fail-closed Privacy Veil that hides agent identities, transcripts, code, and telemetry and stops active microphone capture while honestly indicating that background runs continue.
- Procedurally synthesized 3D audio cues and a session-only semantic room-anchor registry. No audio assets, prompt text, raw room mesh, or scene image enters either telemetry boundary.
- A pinned Meta Quest 3/3S Android export profile, verified vendor-plugin installer, secure ADB backend tunnel, and one-command debug deploy helper.

See [completion status](docs/STATUS.md) for the few checks that require the user's own provider credential, microphone/model, or Quest hardware.

The client is **XR-only**: it targets OpenXR hand tracking on Quest and Android XR, and the earlier desktop Hand Lab simulator has been removed. Development runs either headless or on device.

## Development and testing

Run the backend and headless Godot suites without a headset:

```sh
./scripts/test_all.sh
```

On-device work uses the Quest 3/3S export and deploy path in [Quest 3/3S setup](docs/QUEST_3S_SETUP.md). See [verified status](docs/STATUS.md) for current test counts.

## Hand-only XR workflow

The headset workflow is hand-only: point with an index ray, pinch to select, pinch-drag to scroll, use the left-palm console for workspace actions, and pinch with both hands to reposition/scale Code Trace. The palm console is text-first: select the input field to type with a hardware keyboard (Enter sends, Esc cancels), or use the spatial qwerty keyboard that auto-appears when no hardware keyboard has been detected; **SPEAK** does host-streamed voice. **Cognition** summons causal telemetry, **Mission Map** reveals swarm activity, and **Privacy Veil** immediately conceals the workspace. No controller action map is required. If headset speech is unavailable, SPEAK opens fixed, clearly labeled intents for Continue, Summarize, Explain Code, and Privacy Review. See the [hand-only XR target](docs/HAND_INTERACTION_TARGET.md).

Sensitive actions replace the workspace with a blocking spatial gate. Approve and Deny are separate, generous pinch targets; gaze or dwell alone can never confirm an action.

![Hand-only explicit approval gate](approval-preview.png)

Commands:

```text
/help
/list
/new TITLE
/focus NAME
/rename NEW TITLE
/archive [NAME]
/cancel [NAME]
/tool status
/tool clock
/tool note NOTE
/mission GOAL
/fleet
```

## Meta Quest 3/3S

The project includes an Android OpenXR export preset and `scripts/quest.sh`. After Godot's export templates, JDK 17, Android SDK, and Quest developer mode are ready:

```sh
./scripts/quest.sh setup
./scripts/quest.sh doctor
./scripts/quest.sh deploy
```

`deploy` exports an ARM64 debug APK, installs it over ADB, and maps the headset's `localhost:8787` back to the Mac backend. This keeps the backend on loopback instead of opening an unauthenticated LAN port. Open the app from Quest's Unknown Sources library. Full prerequisites and troubleshooting are in [Quest 3/3S setup](docs/QUEST_3S_SETUP.md).

![Hand-only palm console and quick-intent workspace](xr-workspace-preview.png)

## Run the persistent local backend

From `backend/`:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e .
.venv/bin/spatial-agent-backend
```

Then change the project settings in `client-godot/project.godot`:

```ini
[spatial_agent]
backend_mode="websocket"
backend_websocket_url="ws://127.0.0.1:8787/ws"
```

The backend binds to loopback and writes `backend/data/spatial_agent.db` by default. Copy `backend/.env.example` to `backend/.env` and select `fake`, `openai`, `claude`, `deepseek`, or `council`. Council requires both keys, sends eligible context to both providers, and can roughly double provider cost. Provider keys never enter Godot or the APK. See [backend setup](backend/README.md).

Agent harness: `opencode` is the native path. Set `SPATIAL_AGENT_HARNESS=codex` to route runs through `CodexCliHarness`, which drives `codex exec` as a subprocess and parses JSONL or plain text into normalized events; `SPATIAL_AGENT_CODEX_COMMAND` overrides the binary and leading arguments. The normalized `AgentHarness` interface is the "front end for any agent" pillar; see [Architecture](docs/ARCHITECTURE.md).

## Fleet (missions)

A mission fans one goal out to N agents (default 3, max 8), each in its own `git worktree` and session. Launch one from the composer with `/mission GOAL`; `/fleet` toggles the fleet constellation view, which renders a star per mission. Compare agents side by side and **merge pick-one**: the chosen agent's branch is merged to the base branch through a temporary worktree and the losing worktrees are discarded.

Missions persist in SQLite and reload on startup. Wall-clock (`budget_seconds`) and cost (`budget_cost`) budgets arm a watchdog that cancels the fleet and emits `mission.budget_exceeded`; the coordinator emits `agent.usage` (cost/tokens). Backend commands: `mission.create`, `mission.status`, `mission.cancel`, `mission.merge`, `agent.spawn`, `agent.status`, `agent.compare`.

## Daemon desktop app

`desktop/` is a pywebview app that **hosts the daemon** (the server runs on a background asyncio loop) and shows a live "agent office": canvas avatars, chat, link info (LAN URLs, CA fingerprint), a pairing code + QR, the paired-device list with revoke, and pause/resume. It also drives the fleet: New mission (goal, worker count, time and cost budget), a Missions list, per-agent compare, and pick-one merge.

```sh
cd desktop
pip install -e .
SPATIAL_AGENT_PROVIDER=opencode spatial-agent-desktop
```

Config and the database live in `~/Library/Application Support/SpatialAgent/`. See [desktop README](desktop/README.md).

## Optional local voice

Voice is off by default so the application does not request microphone access unexpectedly. Install `whisper.cpp`, download a compatible local GGML model, and set an absolute model path:

```ini
[spatial_agent]
speech_enabled=true
whisper_cli_path="whisper-cli"
whisper_model_path="/absolute/path/to/ggml-base.en.bin"
speech_retain_recordings=false
speech_max_recording_seconds=20.0
```

Recognition runs as a child process without blocking the Godot frame loop. The resulting text—not the audio—is routed through `voice.transcript.final` to the focused thread. This adapter is exercised by the headless suite and is not part of the XR product surface. In XR, **SPEAK** prefers host-streamed voice (capture on the headset, transcribe on the daemon), falls back to the Android dictation adapter when the plugin is present, and otherwise opens the hand-only quick-intent panel.

## Sensitive-data notes

- Fake mode is fully offline.
- Local-backend mode stores conversation text in an unencrypted local SQLite file.
- OpenAI, Claude, and DeepSeek modes send prompt text and conversation context to the selected provider; all are opt-in and require backend-only environment keys.
- Council mode sends the same eligible context to both OpenAI and Anthropic, displays the two perspectives separately, applies no hidden tie-break, and may roughly double token/API cost.
- A fleet mission sends its goal to N agents and can multiply provider usage; `budget_cost` is a best-effort cap that depends on a harness reporting `agent.usage`.
- Local voice temporarily writes a WAV under Godot's per-user data directory, then deletes it after transcription unless retention is explicitly enabled.
- Backend logs contain identifiers, event types, timing, and error classes—not prompt bodies or credentials.
- The included tool is allowlisted, approval-gated, and simulated. There is no arbitrary shell tool.
- Privacy Veil conceals local holograms and stops active capture; it does not cancel model runs, erase SQLite history, or prevent someone else from seeing the physical display.

Read [Security and privacy](docs/SECURITY_AND_PRIVACY.md) before using real sensitive content.

## Test

After creating `backend/.venv`, run:

```sh
./scripts/test_all.sh
```

The suite covers backend unit/integration behavior (including fleet missions, budgets, and the Codex harness adapter), all Godot milestones, offline event reduction, commands and approvals, the text-first palm composer and spatial keyboard, local speech process isolation, a real WebSocket handshake, reconnect/snapshot recovery, the desktop daemon runtime, and the full Godot-to-backend workflow. Set `GODOT_BIN` or `BACKEND_PYTHON` to override executable locations.

Architecture details live in [Architecture](docs/ARCHITECTURE.md), [Quest setup](docs/QUEST_3S_SETUP.md), [hand-only XR target](docs/HAND_INTERACTION_TARGET.md), [Protocol v1](protocol/README.md), [decisions](docs/DECISIONS.md), and [UX notes](docs/UX_NOTES.md).
