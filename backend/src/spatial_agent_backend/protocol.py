from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from typing import Any
from uuid import uuid4


PROTOCOL_VERSION = 1
MAX_TEXT_LENGTH = 20_000

CLIENT_COMMAND_TYPES = frozenset(
    {
        "session.hello",
        "thread.list",
        "thread.create",
        "thread.focus",
        "thread.rename",
        "thread.archive",
        "message.send",
        "run.cancel",
        "approval.respond",
        "voice.transcript.final",
    }
)


class ProtocolError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class Envelope:
    v: int
    type: str
    event_id: str
    session_id: str
    thread_id: str
    timestamp: str
    payload: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "type": self.type,
            "event_id": self.event_id,
            "session_id": self.session_id,
            "thread_id": self.thread_id,
            "timestamp": self.timestamp,
            "payload": self.payload,
        }

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), separators=(",", ":"), ensure_ascii=False)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex[:16]}"


def make_event(
    event_type: str,
    *,
    session_id: str,
    thread_id: str = "",
    payload: dict[str, Any] | None = None,
) -> Envelope:
    return Envelope(
        v=PROTOCOL_VERSION,
        type=event_type,
        event_id=new_id("evt"),
        session_id=session_id,
        thread_id=thread_id,
        timestamp=utc_now(),
        payload=payload or {},
    )


def parse_client_message(raw: str, *, max_bytes: int) -> Envelope:
    if len(raw.encode("utf-8")) > max_bytes:
        raise ProtocolError("packet_too_large", "Command exceeds the configured packet limit")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ProtocolError("invalid_json", "Command is not valid JSON") from error
    if not isinstance(value, dict):
        raise ProtocolError("invalid_envelope", "Command must be a JSON object")

    required = {"v", "type", "event_id", "session_id", "thread_id", "timestamp", "payload"}
    if set(value) != required:
        raise ProtocolError("invalid_envelope", "Command envelope fields do not match protocol v1")
    if value["v"] != PROTOCOL_VERSION:
        raise ProtocolError("unsupported_version", "Only protocol version 1 is supported")
    if not isinstance(value["type"], str) or value["type"] not in CLIENT_COMMAND_TYPES:
        raise ProtocolError("unknown_command", "Unknown client command")
    for key in ("event_id", "session_id", "thread_id", "timestamp"):
        if not isinstance(value[key], str):
            raise ProtocolError("invalid_envelope", f"{key} must be a string")
    if not value["event_id"] or not value["timestamp"]:
        raise ProtocolError("invalid_envelope", "event_id and timestamp are required")
    if not isinstance(value["payload"], dict):
        raise ProtocolError("invalid_envelope", "payload must be an object")

    envelope = Envelope(**value)
    validate_command_payload(envelope)
    return envelope


def validate_command_payload(command: Envelope) -> None:
    payload = command.payload
    allowed_fields = {
        "session.hello": {"client", "protocol_version"},
        "thread.list": set(),
        "thread.create": {"title"},
        "thread.focus": set(),
        "thread.rename": {"title"},
        "thread.archive": set(),
        "message.send": {"content"},
        "run.cancel": set(),
        "approval.respond": {"approval_id", "decision"},
        "voice.transcript.final": {"transcript"},
    }
    unexpected_fields = set(payload) - allowed_fields[command.type]
    if unexpected_fields:
        raise ProtocolError(
            "invalid_payload",
            f"Unexpected payload fields for {command.type}: {', '.join(sorted(unexpected_fields))}",
        )
    if command.type == "session.hello":
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise ProtocolError("unsupported_version", "session.hello must request protocol version 1")
        _optional_text(payload, "client", 120)
    elif command.type in {"thread.archive", "run.cancel"}:
        _require_thread_id(command)
    elif command.type == "thread.create":
        _optional_text(payload, "title", 120)
    elif command.type == "thread.rename":
        _require_thread_id(command)
        _required_text(payload, "title", 120)
    elif command.type == "message.send":
        _require_thread_id(command)
        _required_text(payload, "content", MAX_TEXT_LENGTH)
    elif command.type == "approval.respond":
        _required_text(payload, "approval_id", 160)
        if payload.get("decision") not in {"approve", "deny"}:
            raise ProtocolError("invalid_payload", "decision must be 'approve' or 'deny'")
    elif command.type == "voice.transcript.final":
        _required_text(payload, "transcript", MAX_TEXT_LENGTH)


def _require_thread_id(command: Envelope) -> None:
    if not command.thread_id:
        raise ProtocolError("invalid_payload", f"{command.type} requires thread_id")


def _required_text(payload: dict[str, Any], key: str, limit: int) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError("invalid_payload", f"{key} must be a non-empty string")
    if len(value) > limit:
        raise ProtocolError("invalid_payload", f"{key} exceeds {limit} characters")
    return value.strip()


def _optional_text(payload: dict[str, Any], key: str, limit: int) -> str | None:
    if key not in payload:
        return None
    return _required_text(payload, key, limit)
