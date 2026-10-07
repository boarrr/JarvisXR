from __future__ import annotations

import asyncio
import json
from pathlib import Path
import os
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from uuid import uuid4

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer

SLOW_FIXTURE = Path(__file__).parent / "fixtures" / "fake_codex_slow_cli.py"


def command(command_type: str, *, session_id: str = "", payload: dict | None = None) -> str:
    return json.dumps(
        {
            "v": 2,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": session_id,
            "thread_id": "",
            "timestamp": "2026-09-16T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(websocket, timeout: float = 6.0) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=timeout))


async def receive_until(websocket, event_type: str) -> dict:
    for _ in range(400):
        event = await receive_event(websocket)
        if event["type"] == event_type:
            return event
    raise AssertionError(f"Did not receive {event_type}")


def run_git(*arguments: str, cwd: Path) -> None:
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True)


class MissionBudgetTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        os.environ["SPATIAL_AGENT_CODEX_COMMAND"] = f"{sys.executable} {SLOW_FIXTURE}"
        self.addCleanup(os.environ.pop, "SPATIAL_AGENT_CODEX_COMMAND", None)
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        repo = Path(self.temporary_directory.name) / "repo"
        repo.mkdir()
        run_git("init", "-b", "main", cwd=repo)
        run_git("config", "user.name", "Test", cwd=repo)
        run_git("config", "user.email", "test@example.com", cwd=repo)
        (repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
        run_git("add", "-A", cwd=repo)
        run_git("commit", "-m", "initial", cwd=repo)

        settings = Settings(
            provider="fake",
            harness="codex",
            database_path=Path(self.temporary_directory.name) / "budget.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.workspace = self.application.workspaces.register("Demo", repo)
        self.websocket_server = await serve(self.application.handle_connection, "127.0.0.1", 0)
        self.port = self.websocket_server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.websocket_server.close()
        await self.websocket_server.wait_closed()

    async def test_time_budget_cancels_the_fleet(self) -> None:
        websocket = await connect(f"ws://127.0.0.1:{self.port}/ws")
        async with websocket:
            await websocket.send(
                command("session.hello", payload={"client": "budget-test", "protocol_version": 2})
            )
            ready = await receive_event(websocket)
            session_id = ready["session_id"]
            await websocket.send(
                command(
                    "mission.create",
                    session_id=session_id,
                    payload={"goal": "long task", "agent_count": 2, "budget_seconds": 1},
                )
            )
            exceeded = await receive_until(websocket, "mission.budget_exceeded")
            self.assertEqual(exceeded["payload"]["budget_seconds"], 1)
            self.assertTrue(exceeded["payload"]["mission_id"].startswith("mission_"))

            mission_id = exceeded["payload"]["mission_id"]
            await websocket.send(
                command("mission.status", session_id=session_id, payload={"mission_id": mission_id})
            )
            status = await receive_until(websocket, "mission.status")
            self.assertEqual(status["payload"]["status"], "error")


if __name__ == "__main__":
    unittest.main()
