from __future__ import annotations

import asyncio
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from uuid import uuid4

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer


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


async def receive_event(websocket) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=5.0))


async def receive_until(websocket, event_type: str) -> dict:
    for _ in range(500):
        event = await receive_event(websocket)
        if event["type"] == event_type:
            return event
    raise AssertionError(f"Did not receive {event_type}")


def run_git(*arguments: str, cwd: Path) -> None:
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True)


class MissionFlowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        run_git("init", "-b", "main", cwd=self.repo)
        run_git("config", "user.name", "Test", cwd=self.repo)
        run_git("config", "user.email", "test@example.com", cwd=self.repo)
        (self.repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
        run_git("add", "-A", cwd=self.repo)
        run_git("commit", "-m", "initial", cwd=self.repo)

        settings = Settings(
            database_path=Path(self.temporary_directory.name) / "mission.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
            fake_chunk_delay_seconds=0.001,
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.workspace = self.application.workspaces.register("Demo", self.repo)
        self.websocket_server = await serve(self.application.handle_connection, "127.0.0.1", 0)
        self.port = self.websocket_server.sockets[0].getsockname()[1]
        self.websocket = await connect(f"ws://127.0.0.1:{self.port}/ws")
        await self.websocket.send(
            command("session.hello", payload={"client": "mission-test", "protocol_version": 2})
        )
        ready = await receive_event(self.websocket)
        self.session_id = ready["session_id"]

    async def asyncTearDown(self) -> None:
        await self.websocket.close()
        self.websocket_server.close()
        await self.websocket_server.wait_closed()

    async def _await_mission_status(self, mission_id: str, target: str) -> dict:
        for _ in range(100):
            await self.websocket.send(
                command("mission.status", session_id=self.session_id, payload={"mission_id": mission_id})
            )
            event = await receive_until(self.websocket, "mission.status")
            if event["payload"].get("status") == target:
                return event["payload"]
            await asyncio.sleep(0.05)
        raise AssertionError(f"mission never reached {target}")

    async def test_fan_out_compare_and_pick_one(self) -> None:
        await self.websocket.send(
            command(
                "mission.create",
                session_id=self.session_id,
                payload={"goal": "Add a hello world", "agent_count": 2},
            )
        )
        created = await receive_until(self.websocket, "mission.created")
        mission_id = created["payload"]["id"]
        self.assertTrue(mission_id.startswith("mission_"))

        spawn_status = await receive_until(self.websocket, "mission.status")
        self.assertEqual(len(spawn_status["payload"]["agents"]), 2)

        # Wait for both agents' runs to finish.
        payload = await self._await_mission_status(mission_id, "awaiting_merge")
        self.assertEqual(payload["status"], "awaiting_merge")
        self.assertEqual(len(payload["agents"]), 2)

        # Compare: each agent exposes a run_id from its own worktree.
        await self.websocket.send(
            command("agent.compare", session_id=self.session_id, payload={"mission_id": mission_id})
        )
        compare = await receive_until(self.websocket, "mission.compare")
        agents = compare["payload"]["agents"]
        self.assertEqual(len(agents), 2)
        run_ids = [a["run_id"] for a in agents if a.get("run_id")]
        self.assertTrue(run_ids, "agents should expose worktree run ids")

        # Pick the first agent, merge it to base, discard the rest.
        await self.websocket.send(
            command(
                "mission.merge",
                session_id=self.session_id,
                payload={"mission_id": mission_id, "run_id": run_ids[0]},
            )
        )
        merged = await receive_until(self.websocket, "mission.merged")
        self.assertTrue(merged["payload"]["merged"])

        final = await self._await_mission_status(mission_id, "merged")
        self.assertEqual(final["status"], "merged")


if __name__ == "__main__":
    unittest.main()
