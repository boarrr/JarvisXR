# Spatial Agent protocol v2

Protocol v2 uses UTF-8 JSON text frames over WebSocket. It is additive over v1: a client may request version 1 in `session.hello` and receives the original command/event set, while version 2 adds device pairing, workspace, file, diff, and tool-catalog messages. Both versions share one provider-neutral envelope:

```json
{
  "v": 2,
  "type": "agent.message.delta",
  "event_id": "evt_103",
  "session_id": "sess_1",
  "thread_id": "thread_research",
  "timestamp": "2026-09-09T22:00:00Z",
  "payload": {
    "message_id": "msg_44",
    "delta": "I found three relevant approaches...",
    "sequence": 3,
    "run_id": "run_9"
  }
}
```

Command identifiers use the `event_id` field. `session_id` and `thread_id` are empty strings when not scoped. Timestamps are UTC RFC 3339 strings.

## Connection lifecycle

1. Client opens the configured WebSocket URL.
2. If the daemon requires pairing, the client sends `session.pair` with a short-lived code and receives `session.paired` plus a durable device token. The token is presented in `session.hello` on every later connection.
3. Client sends `session.hello` with `protocol_version: 1` or `2` and, when paired, `auth_token`.
4. Server sends `session.ready` with the negotiated `protocol_version` and its capabilities.
5. Client sends `thread.list`; server returns an authoritative `thread.snapshot`. Version-2 clients also send `workspace.list` and `tool.catalog`.
6. Commands and asynchronous events flow until disconnect.
7. After an unexpected disconnect, the Godot client retries with bounded exponential backoff, establishes a new session, and requests another snapshot.

Runs belong to a session. The current backend cancels live runs and discards pending approvals when that session disconnects. Pairing codes are single use, time limited, and stored only as hashes; device tokens are stored only as hashes and can be revoked.

## Client commands

Version 1:

- `session.hello`: `{ "client": string?, "protocol_version": 1 | 2, "auth_token": string? }`
- `thread.list`: `{}`
- `thread.create`: `{ "title": string? }`
- `thread.focus`: `{}`; an empty `thread_id` clears focus
- `thread.rename`: `{ "title": string }`
- `thread.archive`: `{}`
- `message.send`: `{ "content": string }`
- `run.cancel`: `{}`
- `approval.respond`: `{ "approval_id": string, "decision": "approve" | "deny" }`
- `voice.transcript.final`: `{ "transcript": string }`

Version 2 additions:

- `session.pair`: `{ "code": string, "device_name": string? }` (pre-session)
- `workspace.list`: `{}`
- `workspace.bind`: `{ "workspace_id": string }`; an empty string clears the binding
- `file.list`: `{ "path": string? }` (thread-scoped; browses the active worktree, then the workspace)
- `file.read`: `{ "path": string }`
- `diff.get`: `{}` (thread-scoped; returns the pending agent diff)
- `diff.decision`: `{ "run_id": string, "decision": "apply" | "reject" }`
- `tool.catalog`: `{}`

Undeclared client envelope or payload fields are rejected. `message.send` and transcript text are limited to 20,000 characters; thread titles are limited to 120. File paths are relative to the workspace root and are rejected if they escape it.

## Server events

- `session.ready`, `session.paired`
- `thread.snapshot`, `thread.created`, `thread.updated`, `thread.archived`
- `agent.status`
- `agent.message.started`, `agent.message.delta`, `agent.message.completed`
- `tool.running`, `tool.completed`, `tool.failed`
- `approval.required`
- `run.completed`, `run.failed`
- `error`
- v2: `workspace.snapshot`, `run.workspace`, `diff.proposed`, `diff.applied`, `diff.rejected`, `file.tree`, `file.content`, `tool.catalog`

## Workspaces and diffs

Each agent run bound to a workspace works inside an isolated `git worktree` on its own `spatial/agent-<run_id>` branch; the user's checkout is never modified. `run.workspace` announces the worktree when a run starts. `diff.proposed` streams bounded, per-file hunks; `diff.decision` applies (commits on the agent branch and removes the worktree) or rejects (removes the worktree and branch). Every apply and reject is recorded in the daemon audit log.

## Ordering and compatibility

Ordering is guaranteed only within one message stream. Every delta has a positive, monotonically increasing `sequence`; clients ignore already-applied sequences. Events for unrelated threads may interleave.

Unknown valid event types are logged and ignored. Malformed JSON, unsupported protocol versions, binary frames, and oversized packets do not mutate domain state.

Within v2, existing required fields and meanings do not change. Version-2 commands sent on a version-1 session are rejected with `unsupported_version`. Additive optional fields are compatible; breaking changes require a new version. Provider chunks, SDK objects, audio, credentials, and tool secrets never cross this protocol.

`approval.required` may include a bounded `impact_preview`: a content-blind route, scope, side-effect class, reversibility statement, and external-system flag. Tool arguments are deliberately excluded so the consent surface does not become a second copy of sensitive input.

The normative machine-readable contract is `events.schema.json`.
