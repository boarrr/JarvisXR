from __future__ import annotations

"""Mission service: fan out a goal to N agents and merge the winner (pick-one)."""

import asyncio
from typing import Any, Awaitable, Callable
from uuid import uuid4

from .mission import Mission
from .thread_service import ThreadService
from .workspace import WorkspaceError, WorkspaceManager

_TERMINAL = {"complete", "error", "idle"}
_FINISHED = {"merged", "cancelled", "error"}


class MissionService:
    def __init__(self, threads: ThreadService, workspaces: WorkspaceManager | None, coordinator) -> None:
        self.threads = threads
        self.workspaces = workspaces
        self.coordinator = coordinator
        self._missions: dict[str, Mission] = {}
        self._watchdogs: dict[str, asyncio.Task] = {}
        self._emits: dict[str, Callable[..., Awaitable[Any]]] = {}
        self.store = getattr(threads, "store", None)

    def load(self) -> None:
        """Load persisted missions after the store has been initialized."""
        store = self.store
        if store is None or not hasattr(store, "list_missions"):
            return
        try:
            rows = store.list_missions()
        except Exception:  # noqa: BLE001 - table may not exist yet
            return
        for row in rows:
            self._missions[row["id"]] = Mission(
                id=row["id"],
                session_id=row["session_id"],
                workspace_id=row["workspace_id"],
                goal=row["goal"],
                harness=row["harness"],
                agent_count=int(row["agent_count"]),
                budget_seconds=int(row["budget_seconds"]),
                budget_cost=float(row.get("budget_cost", 0.0)),
                status=row["status"],
                agent_thread_ids=list(row["agents"]),
            )

    def _persist(self, mission: Mission) -> None:
        store = self.store
        if store is None or not hasattr(store, "save_mission"):
            return
        store.save_mission(
            mission.id,
            session_id=mission.session_id,
            workspace_id=mission.workspace_id,
            goal=mission.goal,
            harness=mission.harness,
            agent_count=mission.agent_count,
            budget_seconds=mission.budget_seconds,
            budget_cost=mission.budget_cost,
            status=mission.status,
            agents=list(mission.agent_thread_ids),
        )

    def get(self, mission_id: str) -> Mission | None:
        return self._missions.get(mission_id)

    def list_missions(self) -> list[dict]:
        return [self._wire(mission) for mission in self._missions.values()]

    async def create(
        self,
        *,
        session_id: str,
        workspace_id: str,
        goal: str,
        agent_count: int = 3,
        harness: str = "opencode",
        budget_seconds: int = 0,
        budget_cost: float = 0.0,
    ) -> dict:
        count = max(1, min(int(agent_count), 8))
        mission = Mission(
            id=f"mission_{uuid4().hex[:12]}",
            session_id=session_id,
            workspace_id=workspace_id,
            goal=goal.strip(),
            harness=harness,
            agent_count=count,
            budget_seconds=max(0, int(budget_seconds)),
            budget_cost=max(0.0, float(budget_cost)),
        )
        self._missions[mission.id] = mission
        self._persist(mission)
        return self._wire(mission)

    async def spawn(self, mission_id: str, emit) -> bool:
        mission = self._missions.get(mission_id)
        if mission is None:
            return False
        if mission.agent_thread_ids:
            return True  # already fanned out
        for index in range(mission.agent_count):
            thread = await self.threads.create_thread(f"{mission.goal} · #{index + 1}")
            metadata = dict(thread.metadata)
            if mission.workspace_id:
                metadata["workspace_id"] = mission.workspace_id
            metadata["mission_id"] = mission.id
            thread.metadata = metadata
            await self.threads.persist_thread(thread.id)
            mission.agent_thread_ids.append(thread.id)
            await emit(
                "agent.spawned",
                thread.id,
                {"mission_id": mission.id, "thread_id": thread.id, "index": index},
            )
            await self.coordinator.submit_message(
                session_id=mission.session_id,
                thread_id=thread.id,
                content=f"{mission.goal}\n\nYou are worker #{index + 1} of {mission.agent_count}.",
                emit=emit,
            )
        await emit("mission.status", "", self._wire(mission))
        self._persist(mission)
        self._emits[mission.id] = emit
        if mission.budget_seconds > 0 or mission.budget_cost > 0:
            self._watchdogs[mission.id] = asyncio.create_task(self._budget_guard(mission))
        return True

    async def _budget_guard(self, mission: Mission) -> None:
        loop = asyncio.get_event_loop()
        deadline = loop.time() + mission.budget_seconds if mission.budget_seconds > 0 else None
        while True:
            if mission.status in _FINISHED:
                return
            now = loop.time()
            reason = ""
            if deadline is not None and now >= deadline:
                reason = "time"
            elif mission.budget_cost > 0 and self.coordinator is not None:
                if self.coordinator.total_cost(mission.agent_thread_ids) >= mission.budget_cost:
                    reason = "cost"
            if reason:
                for thread_id in list(mission.agent_thread_ids):
                    await self.coordinator.cancel(session_id=mission.session_id, thread_id=thread_id)
                mission.status = "error"
                self._persist(mission)
                emit = self._emits.get(mission.id)
                if emit is not None:
                    await emit(
                        "mission.budget_exceeded",
                        "",
                        {
                            "mission_id": mission.id,
                            "reason": reason,
                            "budget_seconds": mission.budget_seconds,
                            "budget_cost": mission.budget_cost,
                        },
                    )
                return
            delay = 0.5
            if deadline is not None:
                delay = max(0.05, min(0.5, deadline - now))
            try:
                await asyncio.sleep(delay)
            except asyncio.CancelledError:
                return

    def _stop_watchdog(self, mission_id: str) -> None:
        task = self._watchdogs.pop(mission_id, None)
        if task is not None and not task.done():
            task.cancel()

    async def status(self, mission_id: str) -> dict:
        mission = self._missions.get(mission_id)
        if mission is None:
            return {}
        statuses: list[str] = []
        for thread_id in mission.agent_thread_ids:
            thread = await self.threads.get_thread(thread_id)
            if thread is not None:
                statuses.append(thread.status)
        if mission.status == "running" and statuses and all(s in _TERMINAL for s in statuses):
            mission.status = "awaiting_merge"
            self._stop_watchdog(mission.id)
            self._persist(mission)
        return self._wire(mission)

    async def cancel(self, mission_id: str, agent_id: str = "") -> bool:
        mission = self._missions.get(mission_id)
        if mission is None:
            return False
        targets = [agent_id] if agent_id else list(mission.agent_thread_ids)
        for thread_id in targets:
            await self.coordinator.cancel(session_id=mission.session_id, thread_id=thread_id)
        if not agent_id:
            mission.status = "cancelled"
            self._stop_watchdog(mission.id)
            self._persist(mission)
        return True

    async def compare(self, mission_id: str) -> list[dict]:
        mission = self._missions.get(mission_id)
        if mission is None:
            return []
        results: list[dict] = []
        for thread_id in mission.agent_thread_ids:
            try:
                files, truncated, run_id = await self.coordinator.diff_for_thread(thread_id)
            except WorkspaceError as error:
                results.append(
                    {"thread_id": thread_id, "run_id": "", "files": [], "error": str(error)}
                )
                continue
            results.append(
                {
                    "thread_id": thread_id,
                    "run_id": run_id,
                    "truncated": truncated,
                    "files": [file.to_wire() for file in files],
                }
            )
        return results

    async def merge(self, mission_id: str, run_id: str) -> dict:
        mission = self._missions.get(mission_id)
        if mission is None or self.workspaces is None:
            return {"merged": False, "error": "Unknown mission"}
        worktree = self.coordinator.worktree_for_run(run_id)
        if worktree is None:
            return {"merged": False, "error": "No worktree for that run"}
        try:
            commit = await self.workspaces.merge_worktree_to_base(worktree)
        except WorkspaceError as error:
            mission.status = "error"
            self._stop_watchdog(mission.id)
            self._persist(mission)
            return {"merged": False, "error": str(error)}
        # Discard the losing agents.
        for thread_id in mission.agent_thread_ids:
            other = self.coordinator.latest_worktree(thread_id)
            if other is not None and other.run_id != run_id:
                try:
                    await self.workspaces.discard_worktree_changes(other)
                    await self.workspaces.remove_worktree(other)
                except WorkspaceError:
                    pass
        mission.status = "merged"
        self._stop_watchdog(mission.id)
        self._persist(mission)
        return {"merged": True, "commit": commit, "run_id": run_id}

    @staticmethod
    def _wire(mission: Mission) -> dict:
        return {
            "id": mission.id,
            "goal": mission.goal,
            "workspace_id": mission.workspace_id,
            "harness": mission.harness,
            "agent_count": mission.agent_count,
            "status": mission.status,
            "budget_seconds": mission.budget_seconds,
            "budget_cost": mission.budget_cost,
            "agents": list(mission.agent_thread_ids),
        }
