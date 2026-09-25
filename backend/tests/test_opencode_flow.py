from __future__ import annotations

import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.coordinator import AgentCoordinator
from spatial_agent_backend.opencode_bridge import OpencodeClient
from spatial_agent_backend.permissions import PermissionService
from spatial_agent_backend.providers import FakeProvider
from spatial_agent_backend.storage import SQLiteStore
from spatial_agent_backend.thread_service import ThreadService
from spatial_agent_backend.tools import ToolRegistry
from tests.test_opencode_bridge import start_fake_server


class OpencodeFlowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.server, self.base_url = start_fake_server()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.store = SQLiteStore(Path(self.temporary_directory.name) / "opencode.db")
        self.threads = ThreadService(self.store)
        await self.threads.initialize()
        self.thread_id = (await self.threads.list_threads())[0].id
        self.session_id = "sess_opencode"

        self.events: list[tuple[str, dict]] = []
        self.finished = asyncio.Event()
        self.client = OpencodeClient(self.base_url, password="secret")
        self.coordinator = AgentCoordinator(
            self.threads,
            FakeProvider(),
            ToolRegistry(),
            PermissionService(),
            None,
            opencode=self.client,
            opencode_directory="/tmp/spatial-worktree",
        )

    async def _emit(self, event_type: str, thread_id: str, payload: dict) -> None:
        self.events.append((event_type, payload))
        if event_type == "approval.required":
            await self.coordinator.respond_to_approval(
                session_id=self.session_id,
                approval_id=str(payload["approval_id"]),
                decision="approve",
            )
        if event_type in {"run.completed", "run.failed"}:
            self.finished.set()

    async def test_opencode_run_streams_and_gates_shell(self) -> None:
        accepted = await self.coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="read the file then run echo",
            emit=self._emit,
        )
        self.assertTrue(accepted)
        await asyncio.wait_for(self.finished.wait(), timeout=10)

        deltas = "".join(
            str(payload.get("delta", ""))
            for event_type, payload in self.events
            if event_type == "agent.message.delta"
        )
        self.assertEqual(deltas, "Hello")

        approvals = [p for e, p in self.events if e == "approval.required"]
        self.assertEqual(len(approvals), 1)
        self.assertEqual(approvals[0]["tool_id"], "opencode.bash")
        self.assertEqual(approvals[0]["source"], "opencode")

        event_types = [e for e, _p in self.events]
        self.assertIn("agent.message.started", event_types)
        self.assertIn("agent.message.completed", event_types)
        self.assertIn("file.edited", event_types)
        self.assertIn("run.completed", event_types)
        self.assertNotIn("run.failed", event_types)

        # The reply reached opencode and the run finished cleanly.
        self.assertEqual(self.server.state.permission_reply, "once")  # type: ignore[attr-defined]
        # The session was created with an array permission ruleset (the HTTP API
        # shape), not the config-file object.
        permission = self.server.state.session_permission  # type: ignore[attr-defined]
        self.assertIsInstance(permission, list)
        self.assertIn(
            {"permission": "bash", "pattern": "*", "action": "ask"},
            permission,
        )


if __name__ == "__main__":
    unittest.main()
