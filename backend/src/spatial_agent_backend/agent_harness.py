from __future__ import annotations

"""Normalized agent-harness seam.

The daemon drives any coding agent (opencode, Codex CLI, ...) through this one
interface so the UI never sees harness-specific events.
"""

from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Protocol, runtime_checkable


@dataclass(frozen=True, slots=True)
class HarnessCapabilities:
    streaming: bool = True
    tools: bool = True
    permission_requests: bool = True
    directory_scoping: bool = True
    resume: bool = False
    cost_reporting: bool = False


@dataclass(frozen=True, slots=True)
class AgentEvent:
    """A normalized event from an agent run."""

    kind: str  # delta | thinking_delta | tool | permission | status | file_edited | idle | error
    text: str = ""
    tool: str = ""
    status: str = ""
    approval_id: str = ""
    command: str = ""
    path: str = ""
    detail: dict[str, Any] = field(default_factory=dict)


@runtime_checkable
class AgentHarness(Protocol):
    name: str
    capabilities: HarnessCapabilities

    async def create_session(self, *, directory: str, title: str) -> str: ...

    async def prompt(self, session_id: str, text: str) -> None: ...

    def events(self, session_id: str) -> AsyncIterator[AgentEvent]: ...

    async def reply_permission(
        self, session_id: str, approval_id: str, decision: str
    ) -> bool: ...

    async def abort(self, session_id: str) -> bool: ...

    async def close(self, session_id: str) -> None: ...
