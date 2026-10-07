from __future__ import annotations

from dataclasses import dataclass, field

MISSION_STATUSES = frozenset({"running", "awaiting_merge", "merged", "cancelled", "error"})


@dataclass
class Mission:
    """A goal fanning out to several sub-agents, each on its own worktree."""

    id: str
    session_id: str
    workspace_id: str
    goal: str
    harness: str
    agent_count: int
    budget_seconds: int = 0
    status: str = "running"
    agent_thread_ids: list[str] = field(default_factory=list)
