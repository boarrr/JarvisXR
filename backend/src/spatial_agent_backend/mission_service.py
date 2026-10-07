from __future__ import annotations

"""Mission service: fan out a goal to N agents and merge the winner (pick-one)."""

from uuid import uuid4

from .mission import Mission
from .thread_service import ThreadService
from .workspace import WorkspaceError, WorkspaceManager

_TERMINAL = {"complete", "error", "idle"}


class MissionService:
    def __init__(self, threads: ThreadService, workspaces: WorkspaceManager | None, coordinator) -> None:
        self.threads = threads
        self.workspaces = workspaces
        self.coordinator = coordinator
        self._missions: dict[str, Mission] = {}

    def get(self, mission_id: str) -> Mission | None:
        return self._missions.get(mission_id)

    async def create(
        self,
        *,
        session_id: str,
        workspace_id: str,
        goal: str,
        agent_count: int = 3,
        harness: str = "opencode",
        budget_seconds: int = 0,
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
        )
        self._missions[mission.id] = mission
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
        return True

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
            "agents": list(mission.agent_thread_ids),
        }
