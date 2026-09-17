from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Sequence
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.coordinator import AgentCoordinator
from spatial_agent_backend.domain import Message
from spatial_agent_backend.mcp_host import McpCallResult, McpTool
from spatial_agent_backend.permissions import (
    PermissionLevel,
    PermissionService,
    map_mcp_permission,
)
from spatial_agent_backend.providers.base import (
    AgentProvider,
    ProviderStreamEvent,
    ToolCall,
    ToolSpec,
)
from spatial_agent_backend.storage import SQLiteStore
from spatial_agent_backend.thread_service import ThreadService
from spatial_agent_backend.tools import ToolRegistry


class ScriptedProvider(AgentProvider):
    supports_tools = True

    def __init__(self, tool_name: str = "mcp.fixture.echo", arguments: dict | None = None) -> None:
        self.tool_name = tool_name
        self.arguments = arguments or {"text": "agent"}
        self.turns = 0
        self.seen_tool_messages: list[str] = []

    @property
    def name(self) -> str:
        return "scripted"

    async def stream_reply(
        self, messages: Sequence[Message], cancel_event: asyncio.Event
    ) -> AsyncIterator[str]:
        async for event in self.stream_turn(messages, [], cancel_event):
            if event.kind == "delta":
                yield event.text

    async def stream_turn(
        self,
        messages: Sequence[Message],
        tools: Sequence[ToolSpec],
        cancel_event: asyncio.Event,
    ) -> AsyncIterator[ProviderStreamEvent]:
        self.turns += 1
        for message in messages:
            if message.role == "tool":
                self.seen_tool_messages.append(message.content)
        if self.turns == 1:
            yield ProviderStreamEvent(kind="delta", text="Checking the fixture. ")
            yield ProviderStreamEvent(
                kind="tool_call",
                tool_call=ToolCall(
                    call_id="call_1",
                    tool_name=self.tool_name,
                    arguments=dict(self.arguments),
                ),
            )
            yield ProviderStreamEvent(kind="done")
            return
        yield ProviderStreamEvent(kind="delta", text="All done.")
        yield ProviderStreamEvent(kind="done")


class StubMcpHost:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict]] = []

    async def call_tool(self, server_id: str, tool_name: str, arguments: dict) -> McpCallResult:
        self.calls.append((server_id, tool_name, arguments))
        return McpCallResult(
            text=f"echo: {arguments.get('text', '')}", is_error=False
        )

    def tool_levels(self, server_id: str) -> dict[str, str]:
        return {}

    def server_default_level(self, server_id: str) -> str | None:
        return None

    def tool_timeout_seconds(self, server_id: str) -> float:
        return 5.0


class ToolLoopTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.store = SQLiteStore(Path(self.temporary_directory.name) / "loop.db")
        self.threads = ThreadService(self.store)
        await self.threads.initialize()
        self.thread_id = (await self.threads.list_threads())[0].id
        self.session_id = "sess_tool_loop"
        self.events: list[tuple[str, str, dict]] = []
        self.tools = ToolRegistry()
        self.host = StubMcpHost()
        self.tools.register_mcp_server(
            self.host,
            "fixture",
            [
                McpTool(
                    server_id="fixture",
                    name="echo",
                    description="Echo text back",
                    input_schema={"type": "object", "properties": {"text": {"type": "string"}}},
                    annotations={"readOnlyHint": True},
                ),
                McpTool(
                    server_id="fixture",
                    name="write_note",
                    description="Write a note",
                    input_schema={"type": "object", "properties": {"text": {"type": "string"}}},
                    annotations={},
                ),
            ],
        )

    def build_coordinator(self, provider: ScriptedProvider) -> AgentCoordinator:
        return AgentCoordinator(
            self.threads, provider, self.tools, PermissionService()
        )

    async def emit(self, event_type: str, thread_id: str, payload: dict) -> None:
        self.events.append((event_type, thread_id, payload))

    def event_types(self) -> list[str]:
        return [event_type for event_type, _thread, _payload in self.events]

    def first_payload(self, event_type: str) -> dict:
        for recorded_type, _thread, payload in self.events:
            if recorded_type == event_type:
                return payload
        raise AssertionError(f"event not observed: {event_type}")

    async def wait_for_event(self, event_type: str, timeout: float = 2.0) -> dict:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            for recorded_type, _thread, payload in self.events:
                if recorded_type == event_type:
                    return payload
            await asyncio.sleep(0.01)
        raise AssertionError(f"event not observed: {event_type}")

    async def test_safe_tool_loop_completes_without_approval(self) -> None:
        provider = ScriptedProvider()
        coordinator = self.build_coordinator(provider)
        await coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="echo something",
            emit=self.emit,
        )
        task = coordinator._runs[self.thread_id].task
        await task

        self.assertNotIn("approval.required", self.event_types())
        self.assertIn("tool.completed", self.event_types())
        self.assertIn("run.completed", self.event_types())
        self.assertEqual(self.host.calls, [("fixture", "echo", {"text": "agent"})])
        self.assertEqual(provider.turns, 2)
        self.assertIn("echo: agent", provider.seen_tool_messages)

        thread = await self.threads.get_thread(self.thread_id)
        assistant = next(message for message in thread.messages if message.role == "assistant")
        self.assertEqual(assistant.content, "Checking the fixture. All done.")
        self.assertEqual(assistant.metadata["tool_calls"][0]["call_id"], "call_1")
        tool_message = next(message for message in thread.messages if message.role == "tool")
        self.assertEqual(tool_message.metadata["tool_call_id"], "call_1")
        self.assertEqual(thread.status, "complete")

        delta_sequences = [
            payload["sequence"]
            for event_type, _thread, payload in self.events
            if event_type == "agent.message.delta"
        ]
        self.assertEqual(delta_sequences, [1, 2])

        audit_types = {entry["event_type"] for entry in self.store.list_audit()}
        self.assertIn("tool_completed", audit_types)

    async def test_approval_gated_tool_runs_after_approve(self) -> None:
        provider = ScriptedProvider(
            tool_name="mcp.fixture.write_note", arguments={"text": "secret note"}
        )
        coordinator = self.build_coordinator(provider)
        await coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="write the note",
            emit=self.emit,
        )
        approval = await self.wait_for_event("approval.required")
        self.assertEqual(approval["permission_level"], "write_reversible")
        self.assertEqual(approval["source"], "mcp")
        self.assertEqual(approval["server_id"], "fixture")
        self.assertNotIn("secret note", json.dumps(approval))

        task = coordinator._runs[self.thread_id].task
        accepted = await coordinator.respond_to_approval(
            session_id=self.session_id,
            approval_id=approval["approval_id"],
            decision="approve",
        )
        self.assertTrue(accepted)
        await task

        self.assertIn("tool.completed", self.event_types())
        self.assertEqual(self.host.calls, [("fixture", "write_note", {"text": "secret note"})])
        self.assertIn("waiting_user", [payload["status"] for event_type, _thread, payload in self.events if event_type == "agent.status"])

    async def test_denied_tool_reports_denial_and_run_continues(self) -> None:
        provider = ScriptedProvider(
            tool_name="mcp.fixture.write_note", arguments={"text": "denied note"}
        )
        coordinator = self.build_coordinator(provider)
        await coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="write the note",
            emit=self.emit,
        )
        approval = await self.wait_for_event("approval.required")
        task = coordinator._runs[self.thread_id].task
        await coordinator.respond_to_approval(
            session_id=self.session_id,
            approval_id=approval["approval_id"],
            decision="deny",
        )
        await task

        failed = self.first_payload("tool.failed")
        self.assertEqual(failed["message"], "Denied by user")
        self.assertEqual(self.host.calls, [])
        self.assertTrue(
            any("denied" in message.lower() for message in provider.seen_tool_messages)
        )
        thread = await self.threads.get_thread(self.thread_id)
        assistant = next(message for message in thread.messages if message.role == "assistant")
        self.assertEqual(assistant.content, "Checking the fixture. All done.")

    async def test_cancel_while_waiting_for_approval(self) -> None:
        provider = ScriptedProvider(
            tool_name="mcp.fixture.write_note", arguments={"text": "cancel note"}
        )
        coordinator = self.build_coordinator(provider)
        await coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="write the note",
            emit=self.emit,
        )
        approval = await self.wait_for_event("approval.required")
        cancelled = await coordinator.cancel(
            session_id=self.session_id, thread_id=self.thread_id
        )
        self.assertTrue(cancelled)
        self.assertIn("run.completed", self.event_types())
        completion = self.first_payload("run.completed")
        self.assertTrue(completion.get("cancelled"))
        self.assertFalse(
            await coordinator.respond_to_approval(
                session_id=self.session_id,
                approval_id=approval["approval_id"],
                decision="approve",
            )
        )
        thread = await self.threads.get_thread(self.thread_id)
        self.assertEqual(thread.status, "idle")

    async def test_unknown_tool_is_reported_and_loop_continues(self) -> None:
        provider = ScriptedProvider(tool_name="mcp.fixture.missing")
        coordinator = self.build_coordinator(provider)
        await coordinator.submit_message(
            session_id=self.session_id,
            thread_id=self.thread_id,
            content="call a missing tool",
            emit=self.emit,
        )
        task = coordinator._runs[self.thread_id].task
        await task
        failed = self.first_payload("tool.failed")
        self.assertIn("Unknown tool", failed["message"])


class PermissionMappingTests(unittest.TestCase):
    def test_annotations_map_to_permission_levels(self) -> None:
        self.assertEqual(
            map_mcp_permission({"readOnlyHint": True}), PermissionLevel.SAFE_READ
        )
        self.assertEqual(map_mcp_permission({}), PermissionLevel.WRITE_REVERSIBLE)
        self.assertEqual(
            map_mcp_permission({"openWorldHint": True}), PermissionLevel.WRITE_EXTERNAL
        )
        self.assertEqual(
            map_mcp_permission({"destructiveHint": True}), PermissionLevel.DESTRUCTIVE
        )

    def test_explicit_configuration_wins(self) -> None:
        self.assertEqual(
            map_mcp_permission({"readOnlyHint": True}, configured="forbidden"),
            PermissionLevel.FORBIDDEN,
        )
        self.assertEqual(
            map_mcp_permission({}, server_default="sensitive_read"),
            PermissionLevel.SENSITIVE_READ,
        )


if __name__ == "__main__":
    unittest.main()
