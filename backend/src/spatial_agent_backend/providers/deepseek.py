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

DEEPSEEK_BASE_URL = "https://api.deepseek.com"


class DeepSeekProvider(AgentProvider):
    """DeepSeek adapter over the OpenAI-compatible chat completions API.

    DeepSeek exposes /chat/completions (not the OpenAI Responses API), so this
    adapter speaks the chat format directly while preserving the same
    provider-neutral text and tool-call events as the other adapters.
    """

    supports_tools = True

    def __init__(
        self,
        *,
        model: str,
        max_output_tokens: int,
        client: Any | None = None,
    ) -> None:
        if client is None:
            api_key = os.getenv("DEEPSEEK_API_KEY", "").strip()
            if not api_key:
                raise ProviderConfigurationError(
                    "DEEPSEEK_API_KEY is required for the DeepSeek provider mode"
                )
            try:
                from openai import AsyncOpenAI
            except ImportError as error:
                raise ProviderConfigurationError(
                    "Install the DeepSeek extra with: python -m pip install -e '.[deepseek]'"
                ) from error
            client = AsyncOpenAI(api_key=api_key, base_url=DEEPSEEK_BASE_URL)
        self.model = model
        self.max_output_tokens = max_output_tokens
        self._client = client

    @property
    def name(self) -> str:
        return "deepseek"

    def _chat_messages(self, messages: Sequence[Message]) -> list[dict[str, Any]]:
        chat_messages: list[dict[str, Any]] = []
        for message in messages:
            if message.role == "assistant":
                tool_calls: list[dict[str, Any]] = []
                for call in message.metadata.get("tool_calls", []) or []:
                    if not isinstance(call, dict):
                        continue
                    tool_calls.append(
                        {
                            "id": str(call.get("call_id", "")),
                            "type": "function",
                            "function": {
                                "name": str(call.get("name", "")),
                                "arguments": json.dumps(call.get("arguments", {})),
                            },
                        }
                    )
                if not message.content and not tool_calls:
                    continue
                entry: dict[str, Any] = {
                    "role": "assistant",
                    "content": message.content or None,
                }
                if tool_calls:
                    entry["tool_calls"] = tool_calls
                chat_messages.append(entry)
            elif message.role == "tool":
                call_id = str(message.metadata.get("tool_call_id", ""))
                if call_id:
                    chat_messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call_id,
                            "content": message.content,
                        }
                    )
            elif message.role in {"system", "user"} and message.content:
                chat_messages.append({"role": message.role, "content": message.content})
        return chat_messages

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
        request: dict[str, Any] = {
            "model": self.model,
            "messages": self._chat_messages(messages),
            "max_tokens": self.max_output_tokens,
            "stream": True,
        }
        if tools:
            request["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": spec.input_schema
                        or {"type": "object", "properties": {}},
                    },
                }
                for spec in tools
            ]
        accumulated: dict[int, dict[str, str]] = {}
        stream = await self._client.chat.completions.create(**request)
        async for chunk in stream:
            if cancel_event.is_set():
                return
            choices = getattr(chunk, "choices", None) or []
            if not choices:
                continue
            delta = getattr(choices[0], "delta", None)
            if delta is None:
                continue
            content = getattr(delta, "content", None)
            if content:
                yield ProviderStreamEvent(kind="delta", text=str(content))
            for tool_delta in getattr(delta, "tool_calls", None) or []:
                index = int(getattr(tool_delta, "index", 0) or 0)
                entry = accumulated.setdefault(
                    index, {"call_id": "", "name": "", "arguments": ""}
                )
                call_id = getattr(tool_delta, "id", None)
                if call_id:
                    entry["call_id"] = str(call_id)
                function = getattr(tool_delta, "function", None)
                if function is not None:
                    name = getattr(function, "name", None)
                    if name:
                        entry["name"] = str(name)
                    arguments = getattr(function, "arguments", None)
                    if arguments:
                        entry["arguments"] += str(arguments)
        for index in sorted(accumulated):
            entry = accumulated[index]
            if not entry["name"]:
                continue
            yield ProviderStreamEvent(
                kind="tool_call",
                tool_call=ToolCall(
                    call_id=entry["call_id"] or f"call_{index}",
                    tool_name=entry["name"],
                    arguments=parse_tool_arguments(entry["arguments"]),
                ),
            )
        yield ProviderStreamEvent(kind="done")
