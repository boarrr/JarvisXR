from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence
import json
import os
from typing import Any

from ..domain import Message
from .base import (
    AgentProvider,
    ProviderConfigurationError,
    ProviderStreamEvent,
    ToolCall,
    ToolSpec,
    parse_tool_arguments,
)


class OpenAIProvider(AgentProvider):
    """OpenAI Responses API adapter with provider details kept server-side."""

    supports_tools = True

    def __init__(
        self,
        *,
        model: str,
        max_output_tokens: int,
        client: Any | None = None,
    ) -> None:
        if client is None:
            api_key = os.getenv("OPENAI_API_KEY", "").strip()
            if not api_key:
                raise ProviderConfigurationError(
                    "OPENAI_API_KEY is required for OpenAI and Council provider modes"
                )
            try:
                from openai import AsyncOpenAI
            except ImportError as error:
                raise ProviderConfigurationError(
                    "Install the OpenAI extra with: python -m pip install -e '.[openai]'"
                ) from error
            client = AsyncOpenAI(api_key=api_key)
        self.model = model
        self.max_output_tokens = max_output_tokens
        self._client = client

    @property
    def name(self) -> str:
        return "openai"

    def _provider_items(self, messages: Sequence[Message]) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for message in messages:
            if message.role == "assistant":
                if message.content:
                    items.append({"role": "assistant", "content": message.content})
                for call in message.metadata.get("tool_calls", []) or []:
                    if not isinstance(call, dict):
                        continue
                    items.append(
                        {
                            "type": "function_call",
                            "call_id": str(call.get("call_id", "")),
                            "name": str(call.get("name", "")),
                            "arguments": json.dumps(call.get("arguments", {})),
                        }
                    )
            elif message.role == "tool":
                call_id = str(message.metadata.get("tool_call_id", ""))
                if call_id:
                    items.append(
                        {
                            "type": "function_call_output",
                            "call_id": call_id,
                            "output": message.content,
                        }
                    )
            elif message.role in {"system", "user"} and message.content:
                items.append({"role": message.role, "content": message.content})
        return items

    async def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        async for event in self.stream_turn(messages, [], cancel_event):
            if event.kind == "delta":
                yield event.text

    async def stream_turn(
        self,
        messages: Sequence[Message],
        tools: Sequence[ToolSpec],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[ProviderStreamEvent]:
        kwargs: dict[str, Any] = {
            "model": self.model,
            "input": self._provider_items(messages),
            "max_output_tokens": self.max_output_tokens,
            "stream": True,
        }
        if tools:
            kwargs["tools"] = [
                {
                    "type": "function",
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": spec.input_schema
                    or {"type": "object", "properties": {}},
                }
                for spec in tools
            ]
        accumulated: dict[str, dict[str, str]] = {}
        async with await self._client.responses.create(**kwargs) as stream:
            async for event in stream:
                if cancel_event.is_set():
                    return
                event_type = getattr(event, "type", "")
                if event_type == "response.output_text.delta":
                    delta = getattr(event, "delta", "")
                    if delta:
                        yield ProviderStreamEvent(kind="delta", text=str(delta))
                elif event_type == "response.output_item.added":
                    item = getattr(event, "item", None)
                    if item is not None and getattr(item, "type", "") == "function_call":
                        item_id = str(getattr(item, "id", getattr(event, "item_id", "")))
                        accumulated[item_id] = {
                            "call_id": str(getattr(item, "call_id", "")),
                            "name": str(getattr(item, "name", "")),
                            "arguments": str(getattr(item, "arguments", "") or ""),
                        }
                elif event_type == "response.function_call_arguments.delta":
                    item_id = str(getattr(event, "item_id", ""))
                    entry = accumulated.setdefault(
                        item_id, {"call_id": "", "name": "", "arguments": ""}
                    )
                    entry["arguments"] += str(getattr(event, "delta", "") or "")
                elif event_type == "response.function_call_arguments.done":
                    item_id = str(getattr(event, "item_id", ""))
                    entry = accumulated.setdefault(
                        item_id, {"call_id": "", "name": "", "arguments": ""}
                    )
                    entry["arguments"] = str(
                        getattr(event, "arguments", entry["arguments"]) or ""
                    )
                elif event_type == "response.output_item.done":
                    item = getattr(event, "item", None)
                    if item is not None and getattr(item, "type", "") == "function_call":
                        item_id = str(getattr(item, "id", getattr(event, "item_id", "")))
                        entry = accumulated.pop(item_id, {})
                        call_id = str(getattr(item, "call_id", "") or entry.get("call_id", ""))
                        name = str(getattr(item, "name", "") or entry.get("name", ""))
                        raw_arguments = str(
                            getattr(item, "arguments", "") or entry.get("arguments", "")
                        )
                        if name:
                            yield ProviderStreamEvent(
                                kind="tool_call",
                                tool_call=ToolCall(
                                    call_id=call_id or item_id,
                                    tool_name=name,
                                    arguments=parse_tool_arguments(raw_arguments),
                                ),
                            )
        yield ProviderStreamEvent(kind="done")
