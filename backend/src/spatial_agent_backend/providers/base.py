from __future__ import annotations

from abc import ABC, abstractmethod
import asyncio
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass, field
import json
from typing import Any

from ..domain import Message


class ProviderConfigurationError(RuntimeError):
    pass


def parse_tool_arguments(raw: str) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


@dataclass(frozen=True, slots=True)
class ToolSpec:
    name: str
    description: str
    input_schema: dict[str, Any]

    def to_wire(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": self.input_schema,
        }


@dataclass(frozen=True, slots=True)
class ToolCall:
    call_id: str
    tool_name: str
    arguments: dict[str, Any] = field(default_factory=dict)

    def to_wire(self) -> dict[str, Any]:
        return {
            "call_id": self.call_id,
            "name": self.tool_name,
            "arguments": self.arguments,
        }


@dataclass(frozen=True, slots=True)
class ProviderStreamEvent:
    kind: str  # "delta" | "tool_call" | "done"
    text: str = ""
    tool_call: ToolCall | None = None


class AgentProvider(ABC):
    supports_tools: bool = False

    @property
    @abstractmethod
    def name(self) -> str:
        raise NotImplementedError

    @abstractmethod
    def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        raise NotImplementedError

    async def stream_turn(
        self,
        messages: Sequence[Message],
        tools: Sequence[ToolSpec],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[ProviderStreamEvent]:
        """Stream one provider turn as text deltas and optional tool calls.

        Providers without tool support fall back to text-only streaming.
        """
        async for delta in self.stream_reply(messages, cancel_event):
            yield ProviderStreamEvent(kind="delta", text=delta)
        yield ProviderStreamEvent(kind="done")
