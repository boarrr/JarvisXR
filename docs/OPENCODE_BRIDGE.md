# opencode bridge (builder-in-the-cockpit)

Goal: drive an **opencode** coding session from the headset so the cockpit can
iterate this project from inside it — prompt → edit in an isolated worktree →
review diff → APPLY → DEPLOY → self-install → relaunch.

## Decisions (agreed)

- **Agent:** opencode via its local HTTP server (`opencode serve`); the daemon is
  a translator, not the brain.
- **Permissions:** edits auto-proceed; **shell + deploy** route to the spatial
  approval gate.
- **Edits:** isolated `git worktree` per request; APPLY/REJECT preserved; `main`
  stays clean.
- **Deploy:** explicit **DEPLOY** after review; the agent only reports readiness.
- **Self-update:** the app downloads the new APK from the daemon and installs it,
  removing adb from the normal loop. adb remains the bootstrap/escape hatch.

## Spike findings (verified against opencode 1.18.32)

`opencode serve --hostname 127.0.0.1 --port <p>` (Basic auth via
`OPENCODE_SERVER_PASSWORD`) exposes everything needed. Verified round-trips:

- Session: `POST /session` → `{"id": "ses_..."}`.
- Prompt (non-blocking): `POST /session/:id/prompt_async` → `204`.
- Streaming: `GET /event` (SSE). Relevant events and payloads:
  - `message.part.delta` `{messageID, partID, field:"text", delta}` — token stream.
  - `message.part.updated` `{part:{type:"tool", tool, callID, state:{status}}}`.
  - `session.status` `{status:{type:"busy"|"idle"}}`.
  - `session.idle` `{sessionID}`.
  - `file.edited` `{file}`.
  - `permission.asked` `{id, sessionID, permission, patterns[], always[], metadata, tool:{messageID, callID}}`.
  - `permission.replied` `{sessionID, requestID, reply}`.
- Approval: `POST /session/:id/permissions/:pid {"response":"once"}` → `true`.
- **Multi-directory:** every session endpoint takes a `?directory=<path>`
  query param, and `POST /session` accepts a per-session `permission` ruleset.
  One `opencode serve` can therefore drive an isolated worktree per run, with
  `{"*":"allow","edit":"allow","bash":"ask"}` set per session — no per-worktree
  servers.
  Outcomes are `once` / `always` (uses the event's `always` patterns) / `reject`.
- Abort: `POST /session/:id/abort`. Status: `GET /session/status`.
- Agent questions: `POST /question/{requestID}/reply` (the cockpit can answer
  the model's questions too, later).
- `GET /session/:id/diff` returned `[]` in our environment, so **diffs are
  computed by the daemon with `git diff` in the run's worktree**, reusing
  `workspace.py`, rather than trusting opencode's diff endpoint.

Permission policy is configured with a project/global `opencode.json` (or
`OPENCODE_CONFIG` outside the repo so it does not show up in diffs):

```json
{ "permission": { "*": "allow", "edit": "allow", "bash": "ask" } }
```

Edits ran with no prompt; `bash` raised `permission.asked` and resumed after the
reply. This is exactly the agreed policy.

## Implementation status

- **Done:** `backend/src/spatial_agent_backend/opencode_bridge.py` — dependency-free
  client (sessions, directory scoping, per-session permission ruleset,
  `prompt_async`, SSE `events()`, permission reply, abort, status, messages) plus
  `translate_event()` / `permission_from_event()` mapping opencode events to
  daemon-facing events. Tests: `backend/tests/test_opencode_bridge.py` (fake
  opencode server, approval round-trip, auth, directory + permission scoping).
- **Done:** deploy substrate — `scripts/quest.sh manifest` writes
  `build/quest/manifest.json` (`version`, `sha256`, `size_bytes`, `built_at`) and
  publishes `build/quest/updates/spatial-agent-<sha8>.apk`; `SPATIAL_CLIENT_ROOT`
  lets the export target a worktree.

## Phase 1 implemented

- `SPATIAL_AGENT_PROVIDER=opencode` makes the daemon drive an opencode session
  instead of the built-in provider. `AgentCoordinator._drive_opencode` maps a
  Spatial Agent thread to an opencode session, streams `message.part.delta` as
  `agent.message.delta`, surfaces `file.edited`, and turns `permission.asked`
  into the existing **spatial approval gate** (`approval.required` →
  `approval.respond` → `POST /session/:id/permissions/:id`). Policy:
  `{"*":"allow","edit":"allow","bash":"ask"}`.
- Each run uses the daemon-created worktree directory when a workspace is bound
  (via the bridge's per-request `?directory=` scoping); otherwise
  `SPATIAL_AGENT_OPENCODE_DIR`.
- Config: `SPATIAL_AGENT_OPENCODE_URL` (default `http://127.0.0.1:4096`),
  `SPATIAL_AGENT_OPENCODE_PASSWORD`, `SPATIAL_AGENT_OPENCODE_USERNAME`,
  `SPATIAL_AGENT_OPENCODE_DIR`, `SPATIAL_AGENT_OPENCODE_MODEL`.
- Tests: `backend/tests/test_opencode_flow.py` runs a full opencode turn
  through the coordinator against the fake opencode server (streaming, shell
  approval round-trip, completion).

### Running it

```sh
# Terminal 1: a headless opencode server scoped to this repo
OPENCODE_SERVER_PASSWORD=your-password opencode serve --port 4096

# Terminal 2: the daemon in opencode mode
SPATIAL_AGENT_PROVIDER=opencode \
SPATIAL_AGENT_OPENCODE_URL=http://127.0.0.1:4096 \
SPATIAL_AGENT_OPENCODE_PASSWORD=your-password \
SPATIAL_AGENT_OPENCODE_DIR="$PWD" \
./scripts/run_backend.sh --lan
```

Then focus an agent in the cockpit and send a prompt. Shell commands surface as
approval requests; edits proceed automatically.

## Next

1. Wire `opencode` as a provider mode in the coordinator/server: thread ↔ session,
   SSE → `message.delta` / `tool.activity` / `agent.status` / `run.completed`,
   `permission.asked` → existing spatial approval gate (`approval:*`), diff via
   `git diff` in the worktree.
2. Deploy service: HTTPS endpoints `GET /update/manifest` and `GET /update/apk`
   (device-token authed), `update.available` event, in-headset BUILD/DEPLOY.
3. Self-updater plugin (Kotlin, `ACTION_INSTALL_PACKAGE` /
   `PackageInstaller` + `REQUEST_INSTALL_PACKAGES`); download → verify sha256 →
   install → relaunch. First build that contains it must be installed over adb.
4. Close the loop on this repo (register it as a workspace).

## Risks

- **Bootstrap:** the first self-updating build needs adb once; keep last-known-good
  APK + rollback.
- **Self-hosting:** never ship an APK that failed tests.
- **Worktree builds:** the vendor addon and Android build template are not in git;
  building from a worktree needs provisioning (or apply-then-build from `main`).
- **Latency:** export + install is ~1–2 min per loop; conversational, not live.
