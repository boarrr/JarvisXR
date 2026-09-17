from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence
import os
from typing import Any

from ..domain import Message
from .base import AgentProvider, ProviderConfigurationError


class OpenAIProvider(AgentProvider):
    """OpenAI Responses API adapter with provider details kept server-side."""

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

    async def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        provider_messages = [
            {"role": message.role, "content": message.content}
            for message in messages
            if message.role in {"system", "user", "assistant"} and message.content
        ]
        async with await self._client.responses.create(
            model=self.model,
            input=provider_messages,
            max_output_tokens=self.max_output_tokens,
            stream=True,
        ) as stream:
            async for event in stream:
                if cancel_event.is_set():
                    return
                if getattr(event, "type", "") != "response.output_text.delta":
                    continue
                delta = getattr(event, "delta", "")
                if delta:
                    yield str(delta)
