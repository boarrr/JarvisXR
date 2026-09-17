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


def command(command_type: str, *, payload: dict | None = None) -> str:
    return json.dumps(
        {
            "v": 1,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": "",
            "thread_id": "",
            "timestamp": "2026-09-16T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(websocket) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=2.0))


class ServerAuthTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.settings = Settings(
            database_path=Path(self.temporary_directory.name) / "auth.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            auth_required=True,
            pairing_code_ttl_seconds=60.0,
            fake_chunk_delay_seconds=0.001,
        )
        self.application = SpatialAgentServer(self.settings)
        await self.application.initialize()
        self.websocket_server = await serve(
            self.application.handle_connection,
            "127.0.0.1",
            0,
            max_size=self.settings.max_packet_bytes,
        )
        self.port = self.websocket_server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.websocket_server.close()
        await self.websocket_server.wait_closed()
        self.temporary_directory.cleanup()

    async def open_socket(self):
        return await connect(f"ws://127.0.0.1:{self.port}/ws")

    async def test_pairing_flow_and_token_hello(self) -> None:
        websocket = await self.open_socket()
        async with websocket:
            await websocket.send(
                command("session.hello", payload={"protocol_version": 1})
            )
            event = await receive_event(websocket)
            self.assertEqual(event["type"], "error")
            self.assertEqual(event["payload"]["code"], "auth_required")

            await websocket.send(
                command("session.pair", payload={"code": "ZZZZZZZZ", "device_name": "Quest"})
            )
            event = await receive_event(websocket)
            self.assertEqual(event["payload"]["code"], "pairing_invalid")

            code = self.application.pairing.issue_code()
            await websocket.send(
                command(
                    "session.pair",
                    payload={"code": code.lower(), "device_name": "Quest 3S"},
                )
            )
            paired = await receive_event(websocket)
            self.assertEqual(paired["type"], "session.paired")
            self.assertTrue(paired["payload"]["token"])
            self.assertTrue(paired["payload"]["device_id"])

            await websocket.send(
                command("session.pair", payload={"code": code, "device_name": "Replay"})
            )
            event = await receive_event(websocket)
            self.assertEqual(event["payload"]["code"], "pairing_invalid")

            await websocket.send(
                command(
                    "session.hello",
                    payload={"protocol_version": 1, "auth_token": paired["payload"]["token"]},
                )
            )
            ready = await receive_event(websocket)
            self.assertEqual(ready["type"], "session.ready")
            self.assertEqual(ready["payload"]["auth"], "paired")
            self.assertIn("pairing", ready["payload"]["capabilities"])
            self.assertEqual(ready["payload"]["workspaces"], [])

    async def test_token_survives_reconnect_until_revoked(self) -> None:
        code = self.application.pairing.issue_code()
        websocket = await self.open_socket()
        async with websocket:
            await websocket.send(
                command("session.pair", payload={"code": code, "device_name": "Quest"})
            )
            paired = await receive_event(websocket)
            token = paired["payload"]["token"]
            device_id = paired["payload"]["device_id"]

        second = await self.open_socket()
        async with second:
            await second.send(
                command("session.hello", payload={"protocol_version": 1, "auth_token": token})
            )
            ready = await receive_event(second)
            self.assertEqual(ready["type"], "session.ready")
            self.assertEqual(ready["payload"]["auth"], "paired")

        self.assertTrue(self.application.pairing.revoke(device_id))
        third = await self.open_socket()
        async with third:
            await third.send(
                command("session.hello", payload={"protocol_version": 1, "auth_token": token})
            )
            event = await receive_event(third)
            self.assertEqual(event["payload"]["code"], "auth_required")

    async def test_open_loopback_daemon_rejects_pairing_and_allows_hello(self) -> None:
        temporary_directory = TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        settings = Settings(
            database_path=Path(temporary_directory.name) / "open.db",
            workspaces_file=Path(temporary_directory.name) / "workspaces.json",
        )
        application = SpatialAgentServer(settings)
        await application.initialize()
        server = await serve(application.handle_connection, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            websocket = await connect(f"ws://127.0.0.1:{port}/ws")
            async with websocket:
                await websocket.send(
                    command("session.pair", payload={"code": "AAAAAAAA", "device_name": "x"})
                )
                event = await receive_event(websocket)
                self.assertEqual(event["payload"]["code"], "pairing_disabled")

                await websocket.send(command("session.hello", payload={"protocol_version": 1}))
                ready = await receive_event(websocket)
                self.assertEqual(ready["type"], "session.ready")
                self.assertEqual(ready["payload"]["auth"], "open-loopback")
        finally:
            server.close()
            await server.wait_closed()


if __name__ == "__main__":
    unittest.main()
