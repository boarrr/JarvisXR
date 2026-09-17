from __future__ import annotations

from abc import ABC, abstractmethod
import asyncio
from collections.abc import AsyncIterator, Sequence

from ..domain import Message


class ProviderConfigurationError(RuntimeError):
    pass


class AgentProvider(ABC):
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
