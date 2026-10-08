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


def command(command_type: str, *, session_id: str = "", thread_id: str = "", payload: dict | None = None) -> str:
    return json.dumps(
        {
            "v": 2,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": session_id,
            "thread_id": thread_id,
            "timestamp": "2026-10-08T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(ws) -> dict:
    return json.loads(await asyncio.wait_for(ws.recv(), timeout=5.0))


async def receive_until(ws, event_type: str) -> dict:
    for _ in range(300):
        event = await receive_event(ws)
        if event["type"] == event_type:
            return event
    raise AssertionError(f"Did not receive {event_type}")


def run_git(*arguments: str, cwd: Path) -> None:
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True)


class BroadcastTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        repo = Path(self.temporary_directory.name) / "repo"
        repo.mkdir()
        run_git("init", "-b", "main", cwd=repo)
        run_git("config", "user.name", "Test", cwd=repo)
        run_git("config", "user.email", "test@example.com", cwd=repo)
        (repo / "app.py").write_text("print('hi')\n", encoding="utf-8")
        run_git("add", "-A", cwd=repo)
        run_git("commit", "-m", "init", cwd=repo)

        settings = Settings(
            provider="fake",
            fake_chunk_delay_seconds=0.001,
            database_path=Path(self.temporary_directory.name) / "b.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.workspace = self.application.workspaces.register("Demo", repo)
        self.server = await serve(self.application.handle_connection, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.server.close()
        await self.server.wait_closed()

    async def _join(self) -> tuple[object, str]:
        ws = await connect(f"ws://127.0.0.1:{self.port}/ws")
        await ws.send(command("session.hello", payload={"client": "t", "protocol_version": 2}))
        ready = await receive_event(ws)
        return ws, ready["session_id"]

    async def test_agent_events_reach_all_sessions(self) -> None:
        ws_a, sid_a = await self._join()
        ws_b, sid_b = await self._join()
        async with ws_a, ws_b:
            await ws_b.send(command("thread.list", session_id=sid_b))
            snapshot = await receive_event(ws_b)
            thread_id = snapshot["payload"]["threads"][0]["id"]
            await ws_b.send(
                command(
                    "message.send",
                    session_id=sid_b,
                    thread_id=thread_id,
                    payload={"content": "hello from B"},
                )
            )
            # Session A (a different client) must also see B's run stream.
            completed = await receive_until(ws_a, "agent.message.completed")
            self.assertEqual(completed["thread_id"], thread_id)


if __name__ == "__main__":
    unittest.main()
