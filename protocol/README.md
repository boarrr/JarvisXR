# Spatial Agent protocol v1

Protocol v1 uses UTF-8 JSON text frames over WebSocket. Every command and event uses one provider-neutral envelope:

```json
{
  "v": 1,
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
2. Client sends `session.hello` with `protocol_version: 1`.
3. Server sends `session.ready` and assigns a session ID.
4. Client sends `thread.list`; server returns an authoritative `thread.snapshot`.
5. Commands and asynchronous events flow until disconnect.
6. After an unexpected disconnect, the Godot client retries with bounded exponential backoff, establishes a new session, and requests another snapshot.

Runs belong to a session. The current backend cancels live runs and discards pending approvals when that session disconnects.

## Client commands

- `session.hello`: `{ "client": string?, "protocol_version": 1 }`
- `thread.list`: `{}`
- `thread.create`: `{ "title": string? }`
- `thread.focus`: `{}`; an empty `thread_id` clears focus
- `thread.rename`: `{ "title": string }`
- `thread.archive`: `{}`
- `message.send`: `{ "content": string }`
- `run.cancel`: `{}`
- `approval.respond`: `{ "approval_id": string, "decision": "approve" | "deny" }`
- `voice.transcript.final`: `{ "transcript": string }`

Undeclared client envelope or payload fields are rejected. `message.send` and transcript text are limited to 20,000 characters; thread titles are limited to 120.

## Server events

- `session.ready`
- `thread.snapshot`, `thread.created`, `thread.updated`, `thread.archived`
- `agent.status`
- `agent.message.started`, `agent.message.delta`, `agent.message.completed`
- `tool.running`, `tool.completed`, `tool.failed`
- `approval.required`
- `run.completed`, `run.failed`
- `error`

## Ordering and compatibility

Ordering is guaranteed only within one message stream. Every delta has a positive, monotonically increasing `sequence`; clients ignore already-applied sequences. Events for unrelated threads may interleave.

Unknown valid event types are logged and ignored. Malformed JSON, unsupported protocol versions, binary frames, and oversized packets do not mutate domain state.

Existing required fields and meanings do not change within v1. Additive optional fields are compatible; breaking changes require a new version. Provider chunks, SDK objects, audio, credentials, and tool secrets never cross this protocol.

`approval.required` may include a bounded `impact_preview`: a content-blind route, scope, side-effect class, reversibility statement, and external-system flag. Tool arguments are deliberately excluded so the consent surface does not become a second copy of sensitive input.

The normative machine-readable contract is `events.schema.json`.
