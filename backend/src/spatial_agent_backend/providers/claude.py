from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence
import os

from ..domain import Message
from .base import AgentProvider, ProviderConfigurationError


class ClaudeProvider(AgentProvider):
    def __init__(self, *, model: str, max_output_tokens: int) -> None:
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
        self.model = model
        self.max_output_tokens = max_output_tokens
        self._client = AsyncAnthropic(api_key=api_key)

    @property
    def name(self) -> str:
        return "claude"

    async def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        provider_messages = [
            {"role": message.role, "content": message.content}
            for message in messages
            if message.role in {"user", "assistant"} and message.content
        ]
        async with self._client.messages.stream(
            model=self.model,
            max_tokens=self.max_output_tokens,
            messages=provider_messages,
        ) as stream:
            async for text in stream.text_stream:
                if cancel_event.is_set():
                    return
                yield text
