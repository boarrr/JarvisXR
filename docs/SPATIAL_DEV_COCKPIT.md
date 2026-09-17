# Spatial Dev Cockpit (rev 2)

Rev 2 turns the prototype into a spatial development cockpit: the headset is a
hand-tracked terminal and a companion **Spatial Agent Daemon** on the developer
machine owns the workspace, the agent loop, and every side effect.

## Topology

```text
Quest 3S / Android XR headset (Godot client)      Development machine (daemon)
  interaction, orbs, cockpit panels                 WebSocket server (optional TLS)
  BackendClient ──── protocol v2 JSON ────►         WorkspaceManager (git worktrees)
  BackendBridge ──── normalized events ◄────        McpHost (stdio + streamable HTTP)
                                                    AgentCoordinator (tool-calling loop)
                                                    SQLite: threads, devices, runs, audit
```

The headset never stores the only copy of anything. Code lives in the user's
git repository on the daemon machine; each agent run works inside an isolated
`git worktree` on its own `spatial/agent-<run_id>` branch.

## Running the daemon

Loopback development (unchanged behaviour, no pairing):

```sh
cd backend
.venv/bin/spatial-agent-backend
```

LAN use with paired devices and TLS:

```sh
SPATIAL_AGENT_HOST=0.0.0.0 \
SPATIAL_AGENT_AUTH_REQUIRED=1 \
SPATIAL_AGENT_TLS_CERT=/path/cert.pem \
SPATIAL_AGENT_TLS_KEY=/path/key.pem \
.venv/bin/spatial-agent-backend
```

Narrow-network helper: `./scripts/quest.sh lan` prints the exact settings.
The daemon refuses to bind a non-loopback host without auth and TLS.

Pairing:

1. On the daemon machine run `.venv/bin/spatial-agent-pair` (or read the code
   printed at startup). Codes are single use and expire.
2. On the headset type `/pair CODE` in the composer. The returned device token
   is stored in `user://daemon_auth.cfg` and reused on reconnect.
3. Revoke devices by deleting their rows from the daemon database.

## Workspaces

Register repositories in `data/workspaces.json` (see `SPATIAL_AGENT_WORKSPACES_FILE`):

```json
{
  "workspaces": [
    {"id": "ws_demo", "name": "Demo", "path": "/Users/you/projects/demo", "base_branch": "main"}
  ]
}
```

Bind a focused thread with `/workspace NAME`. From then on:

- Every run creates a worktree under `.spatial/worktrees/<run_id>` and emits
  `run.workspace`; the user's checkout is untouched.
- `/diff` opens the review panel; `diff.proposed` streams bounded per-file hunks.
- `/apply` commits on the agent branch and removes the worktree; `/reject`
  discards the worktree and branch. Both are audit-logged.
- `/files` opens the read-only file viewer (active worktree, falling back to the
  workspace root). `/file PATH` reads one file, `/tools` refreshes the catalog.

## MCP servers

`data/mcp.json` (see `SPATIAL_AGENT_MCP_CONFIG`) declares stdio and streamable
HTTP servers:

```json
{
  "servers": [
    {
      "id": "filesystem",
      "transport": "stdio",
      "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/Users/you/projects/demo"],
      "timeout_seconds": 60,
      "policy": {"default": "write_reversible", "tools": {"read_text_file": "safe_read"}}
    },
    {
      "id": "browser",
      "transport": "http",
      "url": "http://127.0.0.1:8931/mcp"
    }
  ]
}
```

- Tool IDs become `mcp.<server>.<tool>`; permissions come from explicit policy
  first, then MCP annotations (`readOnlyHint`, `destructiveHint`,
  `openWorldHint`), defaulting to approval-required.
- Side-effecting tools suspend the run behind the existing spatial approval
  gate. The Ghost Future impact preview stays argument-free.
- Servers are ordinary local processes: treat them as code you trust, scope
  their environment, and keep their credentials in the daemon environment.

## Cockpit surfaces

- **Workspace panel** — registered repositories, focus binding, active branch.
- **Diff review** — per-file hunks with APPLY/REJECT pinch targets.
- **File viewer** — directory rows are pinch targets; files open read-only.
- **Daemon panel** — link, protocol version, authorization, MCP inventory.
- Palm target `WORKSPACE // FILES // DIFF` opens review or files for the focused
  thread. Composer commands: `/pair /workspaces /workspace /files /diff /apply
  /reject /daemon /tools`.
- A Bluetooth keyboard works in XR via the composer; without one, voice
  dictation (Android plugin) or the quick-intent panel remains available.

## Security posture

- Provider keys, MCP credentials, and device tokens never enter the APK.
- Pairing codes and device tokens are stored hashed; codes are one time.
- Non-loopback binds require auth and TLS by configuration validation.
- Agent changes are isolated in worktrees and only reach the user's branch
  through an explicit apply decision.
- Cognition telemetry remains content-blind; code and diffs appear only on the
  dedicated review surfaces.

## Verification

`./scripts/test_all.sh` runs the backend suite, the Godot smoke scenes (including
cockpit transport, cockpit panels, and the Android dictation adapter boundary),
the socket fixture, reconnect, and the full-stack path. Live provider calls,
Android plugin builds, and headset ergonomics remain user-gated.
