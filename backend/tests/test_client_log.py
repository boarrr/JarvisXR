from __future__ import annotations

import asyncio
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from uuid import uuid4

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer


def command(
    command_type: str,
    *,
    session_id: str = "",
    thread_id: str = "",
    payload: dict | None = None,
) -> str:
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


class ClientLogRelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.log_path = Path(self.temporary_directory.name) / "client.log"
        settings = Settings(
            provider="fake",
            fake_chunk_delay_seconds=0.001,
            database_path=Path(self.temporary_directory.name) / "b.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
            client_log_path=self.log_path,
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.server = await serve(self.application.handle_connection, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.server.close()
        await self.server.wait_closed()

    async def test_client_log_is_written_to_disk(self) -> None:
        ws = await connect(f"ws://127.0.0.1:{self.port}/ws")
        async with ws:
            await ws.send(
                command("session.hello", payload={"client": "t", "protocol_version": 2})
            )
            ready = await receive_event(ws)
            session_id = ready["session_id"]
            await ws.send(
                command(
                    "client.log",
                    session_id=session_id,
                    payload={
                        "level": "error",
                        "source": "headset",
                        "message": "boom: updater stalled",
                    },
                )
            )
            for _ in range(60):
                if self.log_path.exists() and "boom: updater stalled" in self.log_path.read_text(
                    encoding="utf-8"
                ):
                    break
                await asyncio.sleep(0.05)
        self.assertIn("boom: updater stalled", self.log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
