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
            "v": 1,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": session_id,
            "thread_id": thread_id,
            "timestamp": "2026-09-15T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(websocket) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=2.0))


async def receive_until(websocket, event_type: str) -> tuple[list[dict], dict]:
    events: list[dict] = []
    for _ in range(100):
        event = await receive_event(websocket)
        events.append(event)
        if event["type"] == event_type:
            return events, event
    raise AssertionError(f"Did not receive {event_type}")


class ServerIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        settings = Settings(
            database_path=Path(self.temporary_directory.name) / "server.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
            fake_chunk_delay_seconds=0.001,
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.websocket_server = await serve(
            self.application.handle_connection,
            "127.0.0.1",
            0,
            max_size=settings.max_packet_bytes,
        )
        self.port = self.websocket_server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.websocket_server.close()
        await self.websocket_server.wait_closed()
        self.temporary_directory.cleanup()

    async def open_session(self):
        websocket = await connect(f"ws://127.0.0.1:{self.port}/ws")
        await websocket.send(
            command("session.hello", payload={"client": "test", "protocol_version": 1})
        )
        ready = await receive_event(websocket)
        self.assertEqual(ready["type"], "session.ready")
        self.assertEqual(ready["payload"]["provider"], "fake")
        self.assertEqual(ready["payload"]["model"], "local-deterministic")
        self.assertEqual(
            {tool["id"] for tool in ready["payload"]["tools"]},
            {"system.clock", "system.diagnostics", "demo.write_note"},
        )
        return websocket, ready["session_id"]

    async def test_thread_message_stream_and_persistence(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(command("thread.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            self.assertEqual(snapshot["type"], "thread.snapshot")
            thread_id = snapshot["payload"]["threads"][0]["id"]

            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "Hello through the real backend"},
                )
            )
            events, completed = await receive_until(websocket, "run.completed")
            event_types = [event["type"] for event in events]
            self.assertIn("agent.message.started", event_types)
            self.assertIn("agent.message.delta", event_types)
            self.assertIn("agent.message.completed", event_types)
            self.assertEqual(completed["thread_id"], thread_id)

            restored = await self.application.threads.get_thread(thread_id)
            self.assertEqual(restored.status, "complete")
            self.assertIn("real backend", restored.messages[-1].content)

    async def test_cancel_and_approval_gate(self) -> None:
        self.application.provider.chunk_delay_seconds = 0.05
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(command("thread.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            thread_id = snapshot["payload"]["threads"][0]["id"]

            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "Cancel this response"},
                )
            )
            await receive_until(websocket, "agent.message.started")
            await websocket.send(command("run.cancel", session_id=session_id, thread_id=thread_id))
            events, completed = await receive_until(websocket, "run.completed")
            self.assertTrue(completed["payload"].get("cancelled"))
            self.assertIn("agent.message.completed", [event["type"] for event in events])

            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "/tool remember milk"},
                )
            )
            _, approval = await receive_until(websocket, "approval.required")
            self.assertEqual(approval["payload"]["permission_level"], "write_reversible")
            self.assertNotIn("remember milk", approval["payload"]["summary"])
            self.assertEqual(
                approval["payload"]["impact_preview"]["route"],
                ["gesture", "local backend", "simulation buffer"],
            )
            self.assertFalse(approval["payload"]["impact_preview"]["external"])
            await websocket.send(
                command(
                    "approval.respond",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={
                        "approval_id": approval["payload"]["approval_id"],
                        "decision": "approve",
                    },
                )
            )
            events, _ = await receive_until(websocket, "run.completed")
            self.assertIn("tool.running", [event["type"] for event in events])
            self.assertIn("tool.completed", [event["type"] for event in events])

    async def test_thread_crud_and_focused_voice_routing(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(
                command(
                    "thread.create",
                    session_id=session_id,
                    payload={"title": "Voice workspace"},
                )
            )
            created = await receive_event(websocket)
            self.assertEqual(created["type"], "thread.created")
            thread_id = created["thread_id"]

            await websocket.send(
                command(
                    "thread.rename",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"title": "Private voice workspace"},
                )
            )
            renamed = await receive_event(websocket)
            self.assertEqual(renamed["payload"]["thread"]["title"], "Private voice workspace")

            await websocket.send(
                command("thread.focus", session_id=session_id, thread_id=thread_id)
            )
            await websocket.send(
                command(
                    "voice.transcript.final",
                    session_id=session_id,
                    payload={"transcript": "Route this local transcript"},
                )
            )
            await receive_until(websocket, "run.completed")
            restored = await self.application.threads.get_thread(thread_id)
            self.assertEqual(restored.messages[-2].role, "user")
            self.assertEqual(restored.messages[-2].content, "Route this local transcript")

            await websocket.send(
                command("thread.archive", session_id=session_id, thread_id=thread_id)
            )
            archived = await receive_event(websocket)
            self.assertEqual(archived["type"], "thread.archived")
            await websocket.send(command("thread.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            self.assertNotIn(thread_id, [item["id"] for item in snapshot["payload"]["threads"]])

    async def test_safe_telemetry_tool_runs_without_approval(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(command("thread.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            thread_id = snapshot["payload"]["threads"][0]["id"]
            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "/tool status"},
                )
            )
            events, _ = await receive_until(websocket, "run.completed")
            self.assertNotIn("approval.required", [event["type"] for event in events])
            completed = next(event for event in events if event["type"] == "tool.completed")
            self.assertEqual(completed["payload"]["tool_id"], "system.diagnostics")
            self.assertFalse(completed["payload"]["output"]["external_side_effect"])
            restored = await self.application.threads.get_thread(thread_id)
            self.assertEqual(restored.messages[-1].role, "tool")
            self.assertIn("nominal", restored.messages[-1].content.lower())


if __name__ == "__main__":
    unittest.main()
