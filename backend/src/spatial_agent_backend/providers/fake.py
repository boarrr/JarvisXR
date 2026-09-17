from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence

from ..domain import Message
from .base import AgentProvider


class FakeProvider(AgentProvider):
    def __init__(self, *, chunk_delay_seconds: float = 0.015, chunk_size: int = 12) -> None:
        self.chunk_delay_seconds = max(0.0, chunk_delay_seconds)
        self.chunk_size = max(1, chunk_size)

    @property
    def name(self) -> str:
        return "fake"

    async def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        latest_user_message = next((item.content for item in reversed(messages) if item.role == "user"), "")
        if latest_user_message == "[simulate:error]":
            raise RuntimeError("Simulated provider failure")
        response = (
            "The local fake provider received your message: "
            f"{latest_user_message} This response confirms end-to-end streaming through the backend."
        )
        for offset in range(0, len(response), self.chunk_size):
            if cancel_event.is_set():
                return
            if self.chunk_delay_seconds:
                await asyncio.sleep(self.chunk_delay_seconds)
            yield response[offset : offset + self.chunk_size]
