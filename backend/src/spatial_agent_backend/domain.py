from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .protocol import new_id, utc_now


VALID_STATUSES = {"idle", "listening", "working", "waiting_user", "complete", "error"}
VALID_ROLES = {"user", "assistant", "system", "tool"}


@dataclass(slots=True)
class Message:
    id: str
    thread_id: str
    role: str
    content: str
    created_at: str = field(default_factory=utc_now)
    is_streaming: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def create(cls, thread_id: str, role: str, content: str = "", *, streaming: bool = False) -> "Message":
        if role not in VALID_ROLES:
            raise ValueError(f"Unsupported message role: {role}")
        return cls(new_id("msg"), thread_id, role, content, is_streaming=streaming)

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "thread_id": self.thread_id,
            "role": self.role,
            "content": self.content,
            "created_at": self.created_at,
            "is_streaming": self.is_streaming,
            "metadata": dict(self.metadata),
        }


@dataclass(frozen=True, slots=True)
class Device:
    id: str
    name: str
    created_at: str
    last_seen_at: str

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "created_at": self.created_at,
            "last_seen_at": self.last_seen_at,
        }


@dataclass(slots=True)
class Thread:
    id: str
    title: str
    status: str = "idle"
    messages: list[Message] = field(default_factory=list)
    unread_count: int = 0
    created_at: str = field(default_factory=utc_now)
    updated_at: str = field(default_factory=utc_now)
    parent_thread_id: str = ""
    tags: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    is_pinned: bool = False

    @classmethod
    def create(cls, title: str) -> "Thread":
        return cls(new_id("thread"), title.strip() or "Untitled thread")

    def touch(self) -> None:
        self.updated_at = utc_now()

    def set_status(self, status: str) -> None:
        if status not in VALID_STATUSES:
            raise ValueError(f"Unsupported thread status: {status}")
        self.status = status
        self.touch()

    def add_message(self, message: Message) -> None:
        if message.thread_id != self.id:
            raise ValueError("Message thread_id does not match its thread")
        self.messages.append(message)
        self.touch()

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "status": self.status,
            "messages": [message.to_wire() for message in self.messages],
            "unread_count": self.unread_count,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "parent_thread_id": self.parent_thread_id,
            "tags": list(self.tags),
            "metadata": dict(self.metadata),
            "is_pinned": self.is_pinned,
        }
