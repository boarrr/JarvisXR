from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence
import os
from typing import Any

from ..domain import Message
from .base import (
    AgentProvider,
    ProviderConfigurationError,
    ProviderStreamEvent,
    ToolCall,
    ToolSpec,
)


class ClaudeProvider(AgentProvider):
    supports_tools = True

    def __init__(self, *, model: str, max_output_tokens: int, client: Any | None = None) -> None:
        if client is None:
            api_key = os.getenv("ANTHROPIC_API_KEY", "").strip()
            if not api_key:
                raise ProviderConfigurationError(
                    "ANTHROPIC_API_KEY is required for Claude and Council provider modes"
                )
            try:
                from anthropic import AsyncAnthropic
            except ImportError as error:
                raise ProviderConfigurationError(
                    "Install the Claude extra with: python -m pip install -e '.[claude]'"
                ) from error
            client = AsyncAnthropic(api_key=api_key)
        self.model = model
        self.max_output_tokens = max_output_tokens
        self._client = client

    @property
    def name(self) -> str:
        return "claude"

    def _provider_messages(self, messages: Sequence[Message]) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for message in messages:
            if message.role == "assistant":
                blocks: list[dict[str, Any]] = []
                if message.content:
                    blocks.append({"type": "text", "text": message.content})
                for call in message.metadata.get("tool_calls", []) or []:
                    if not isinstance(call, dict):
                        continue
                    blocks.append(
                        {
                            "type": "tool_use",
                            "id": str(call.get("call_id", "")),
                            "name": str(call.get("name", "")),
                            "input": call.get("arguments", {}),
                        }
                    )
                if blocks:
                    result.append({"role": "assistant", "content": blocks})
            elif message.role == "tool":
                call_id = str(message.metadata.get("tool_call_id", ""))
                if call_id:
                    block = {
                        "type": "tool_result",
                        "tool_use_id": call_id,
                        "content": message.content,
                    }
                    if (
                        result
                        and result[-1]["role"] == "user"
                        and isinstance(result[-1]["content"], list)
                    ):
                        result[-1]["content"].append(block)
                    else:
                        result.append({"role": "user", "content": [block]})
            elif message.role == "user" and message.content:
                result.append({"role": "user", "content": message.content})
        return result

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
            "max_tokens": self.max_output_tokens,
            "messages": self._provider_messages(messages),
        }
        if tools:
            kwargs["tools"] = [
                {
                    "name": spec.name,
                    "description": spec.description,
                    "input_schema": spec.input_schema
                    or {"type": "object", "properties": {}},
                }
                for spec in tools
            ]
        async with self._client.messages.stream(**kwargs) as stream:
            async for text in stream.text_stream:
                if cancel_event.is_set():
                    return
                yield ProviderStreamEvent(kind="delta", text=text)
            if cancel_event.is_set():
                return
            try:
                final = await stream.get_final_message()
            except Exception:
                final = None
            if final is not None:
                for block in getattr(final, "content", []) or []:
                    if getattr(block, "type", "") == "tool_use":
                        yield ProviderStreamEvent(
                            kind="tool_call",
                            tool_call=ToolCall(
                                call_id=str(getattr(block, "id", "")),
                                tool_name=str(getattr(block, "name", "")),
                                arguments=dict(getattr(block, "input", {}) or {}),
                            ),
                        )
        yield ProviderStreamEvent(kind="done")
