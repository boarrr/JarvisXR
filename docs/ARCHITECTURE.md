# Spatial Agent Interface Architecture

The system is an XR-only Godot presentation client—OpenXR hand tracking on device, with a headless test runtime—and a separate local Python agent service. The daemon runs headless (`spatial-agent-backend`) or inside the optional `desktop/` pywebview app, which hosts the same server. One Godot unit is approximately one meter.

```text
Quest optical hand trackers (simulated joints in headless tests)
             │ semantic InteractionEvent
             ▼
      InteractionManager ───────► AppState ───────► orbs / panels
                                      │                    │
                                      ├────────────► cognition / mission layers
                                      └────────────► privacy veil / spatial audio
                                      ▲
                                      │ normalized BackendEvent
                                      │
                         BackendBridge / BackendTransport
                                      │ protocol JSON
                                      ▼
       WebSocket server ─► coordinator ─► AgentHarness ─► opencode / Codex CLI
              │                 │
              │                 ├── provider path ─► fake / OpenAI / Claude / Council
              │                 ├── permission policy ─► allowlisted tools
              │                 └── WorkspaceManager ─► per-run git worktrees
              │
              ├── MissionService ─► N agents + budget watchdog
              └── SQLite: threads, messages, devices, runs, audit, missions

 desktop/ pywebview app ── hosts the same daemon on a background asyncio loop
```

## Godot client

`Main` composes `UserRig`, `XRRuntime`, `OrbManager`, `CognitionLayer`, `MissionTopology`, `PrivacyVeil`, `InteractionManager`, `ThreadPanel`, `CodeViewer`, `QuickIntentPanel`, `PalmConsole`, `SpatialKeyboard`, `HandRayVisualizer`, `ApprovalPanel`, `BackendBridge`, both transports, `CommandRouter`, `LocalWhisperSpeechService`, `SpatialAudioCueService`, `RoomAnchorRegistry`, and diagnostics.

- `AppState` is authoritative for presentation state: connection/session, provider/model identity, threads/messages, focus/hover, transcript/listening state, and pending approvals.
- `XRRuntime` owns the `XROrigin3D`/`XRCamera3D`, enables the XR viewport only when OpenXR initialized at startup, applies passthrough-friendly alpha output and VRS, and mirrors head pose into the device-neutral layout anchor. There is no desktop fallback; the headless test runtime drives the same scenes without a device.
- `InteractionSource` converts device input to semantic events. `OpenXRInteractionSource` reads tracked joints at Godot's standard left/right paths, requires optical rather than controller-derived hand data, stabilizes the distal-to-tip ray, applies thumb/index pinch hysteresis, quantizes code scroll, and emits bimanual transforms. Presentation objects never read XR APIs.
- `OrbManager` creates views from thread data, maintains stable identity-to-slot mapping, and lays out overflow on additional rings.
- `CognitionLayer` listens only to normalized event classifications and content-free command notifications. It maintains a bounded 32-record temporal black box, aggregates token deltas into pulses, draws ten reusable causal nodes, follows the focused orb, and exposes hand targets for rewind/live/forward inspection. Its privacy route switches between sealed local, single hosted egress, and explicit dual hosted Council egress.
- `MissionTopology` derives at most 12 content-free links from explicit parent IDs and focused-to-active correlations. Animated pulses follow real orb transforms; the legend labels inferred correlations as non-authoritative. When threads share `mission_id` metadata it also renders a star per mission (a hub-to-agent constellation), and `/fleet` toggles the layer.
- `PrivacyVeil` is a presentation privacy state in `AppState`. Views fail closed while it is active, the palm toggle remains reachable, and active speech capture is stopped. It does not pretend to cancel backend work or erase persisted data.
- `DiffSculptor` classifies bounded diff lines into addition, removal, and context geometry attached to `CodeViewer`; no extra code copy is retained.
- `SpatialAudioCueService` maps semantic states to short WAVs synthesized in memory and places playback at the relevant orb. `RoomAnchorRegistry` accepts only bounded semantic transforms for the session and advertises that raw scene mesh storage and vendor scene APIs are disabled.
- `ThreadPanel`, `CodeViewer`, `QuickIntentPanel`, `PalmConsole`, `SpatialKeyboard`, and `ApprovalPanel` are views over domain state. World-space controls expose semantic target IDs; they never call a provider. `PalmConsole` is text-first: selecting `palm:input_focus` enters typing, hardware keys route into the field (Enter sends, Esc cancels), and `SpatialKeyboard` auto-opens a qwerty pane only when no hardware key has been seen. The quick-intent surface preserves a completely hand-only path when mobile speech is unavailable.
- `BackendTransport` has fake and WebSocket implementations. `BackendBridge` alone reduces normalized events into `AppState`; its command notification deliberately omits payloads so telemetry consumers cannot observe prompt content.
- `BackendClient` performs protocol handshakes, bounded exponential reconnect, fresh snapshot requests, packet checks, and UTF-8 JSON decoding without blocking the frame loop.
- `LocalWhisperSpeechService` records from a muted capture bus, runs configurable `whisper-cli` asynchronously, emits transcript signals, and deletes service-owned audio by default. It does not decide routing.

## Backend

The Python backend uses `asyncio`, `websockets`, and SQLite:

- `SpatialAgentServer` owns sessions, handshake enforcement, rate limiting, command dispatch, and event emission.
- `ThreadService` provides concurrent async access over the synchronous SQLite store and seeds one default thread.
- `AgentCoordinator` keeps independent per-thread runs, normalizes provider streams, supports cancellation, and suspends approval-gated work. It emits `agent.usage` (cost/tokens) whenever a harness reports usage.
- `AgentHarness` (`agent_harness.py`) normalizes any coding agent into `AgentEvent`s. `opencode` remains the native path; `CodexCliHarness` drives `codex exec` as a subprocess and parses JSONL or plain text into the same events. `SPATIAL_AGENT_HARNESS=codex` selects it and `SPATIAL_AGENT_CODEX_COMMAND` overrides the binary and leading arguments.
- `MissionService` fans a goal out to 1–8 agents, each in its own thread and git worktree. It tracks mission status, compares per-agent diffs, and merges pick-one: the chosen branch is merged to the base branch through a temporary worktree and the losing worktrees are discarded. Optional `budget_seconds`/`budget_cost` watchdogs cancel the fleet and emit `mission.budget_exceeded`.
- `AgentProvider` isolates provider details. `FakeProvider` is deterministic; `OpenAIProvider` owns Responses streaming and `ClaudeProvider` owns Messages streaming. `CouncilProvider` runs the two hosted adapters concurrently and emits labelled independent sections without a synthetic verdict. No SDK or key crosses the protocol.
- `PermissionService` is authoritative for approval policy. `ToolRegistry` exposes only typed, allowlisted tools: two side-effect-free local telemetry reads and a simulated note that still requires approval. Each definition can provide a content-blind impact descriptor for the Ghost Future consent view.
- `Observability` writes structured event metadata without prompt content or secrets.

The server cancels a disconnected session's live runs and removes its pending approvals. On recovery, the client receives a new session and reconciles against a fresh durable snapshot. Missions persist in their own SQLite table and reload on startup.

## Desktop app

`desktop/` is an optional macOS pywebview control surface. `DaemonRuntime` starts the same `SpatialAgentServer` on a background asyncio loop and exposes a synchronous, thread-safe API; `Bridge` is the JS↔Python facade, and `app.py` owns the window. The UI shows a live agent office (canvas avatars), chat, link info (LAN URLs, CA fingerprint), pairing code and device revocation, pause/resume, and fleet controls (New mission, Missions list, per-agent compare, pick-one merge). Config, database, workspaces, and MCP config default to `~/Library/Application Support/SpatialAgent/`.

## Protocol

Every command and event uses the same protocol-v1 envelope. IDs and monotonically increasing message-delta sequence numbers make reducers idempotent where practical. Provider SDK objects never cross the boundary. The normative JSON Schema is in `protocol/events.schema.json`; server-side validation is stricter for client commands and rejects undeclared envelope and payload fields.

## Portability boundary

There is no desktop Godot runtime; the headless test runtime runs the same scenes without OpenXR. (The `desktop/` app is a separate pywebview daemon host, not a Godot desktop client.) Android feature overrides activate OpenXR, XR shaders, hand extensions, alpha passthrough, and the WebSocket backend only in the Quest export. The Meta vendor plugin is intentionally a verified setup-time dependency instead of an 85 MB checked-in binary tree. ADB reverse keeps the provider service loopback-only during development. See [Quest 3/3S setup](QUEST_3S_SETUP.md) and [Hand-only XR interaction target](HAND_INTERACTION_TARGET.md).
