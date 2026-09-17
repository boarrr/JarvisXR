from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence

from ..domain import Message
from .base import AgentProvider


class CouncilProvider(AgentProvider):
    """Run two independent providers and expose both answers without arbitration.

    Council mode is intentionally explicit: it sends the same eligible context to
    both configured hosted providers and therefore has roughly twice the data and
    token exposure of a single-provider run.
    """

    def __init__(self, openai_provider: AgentProvider, claude_provider: AgentProvider) -> None:
        self._openai = openai_provider
        self._claude = claude_provider
        self.model = (
            f"{getattr(openai_provider, 'model', openai_provider.name)} + "
            f"{getattr(claude_provider, 'model', claude_provider.name)}"
        )

    @property
    def name(self) -> str:
        return "council"

    async def stream_reply(
        self,
        messages: Sequence[Message],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[str]:
        if cancel_event.is_set():
            return

        async def collect(provider: AgentProvider) -> str:
            parts: list[str] = []
            async for chunk in provider.stream_reply(messages, cancel_event):
                if cancel_event.is_set():
                    return ""
                parts.append(chunk)
            return "".join(parts).strip()

        tasks = [
            asyncio.create_task(collect(self._openai)),
            asyncio.create_task(collect(self._claude)),
        ]
        try:
            openai_reply, claude_reply = await asyncio.gather(*tasks)
        except BaseException:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise

        if cancel_event.is_set():
            return

        yield "## OpenAI perspective\n\n"
        yield openai_reply or "No response returned."
        yield "\n\n## Claude perspective\n\n"
        yield claude_reply or "No response returned."
        yield (
            "\n\n## Council note\n\n"
            "These are independent perspectives. No automatic verdict or hidden "
            "tie-break was applied; you remain the decision-maker."
        )
