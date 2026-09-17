from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from .domain import Message
from .observability import log_record
from .permissions import PermissionService
from .protocol import new_id
from .providers import AgentProvider
from .thread_service import ThreadNotFoundError, ThreadService
from .tools import ToolRegistry


EmitEvent = Callable[[str, str, dict[str, Any]], Awaitable[None]]


@dataclass(slots=True)
class ActiveRun:
    session_id: str
    thread_id: str
    run_id: str
    message_id: str
    cancel_event: asyncio.Event
    task: asyncio.Task[None] | None = None


@dataclass(slots=True)
class PendingApproval:
    approval_id: str
    session_id: str
    thread_id: str
    run_id: str
    tool_id: str
    tool_input: dict[str, Any]
    emit: EmitEvent


class AgentCoordinator:
    def __init__(
        self,
        threads: ThreadService,
        provider: AgentProvider,
        tools: ToolRegistry,
        permissions: PermissionService,
    ) -> None:
        self.threads = threads
        self.provider = provider
        self.tools = tools
        self.permissions = permissions
        self._runs: dict[str, ActiveRun] = {}
        self._approvals: dict[str, PendingApproval] = {}

    async def submit_message(
        self,
        *,
        session_id: str,
        thread_id: str,
        content: str,
        emit: EmitEvent,
    ) -> bool:
        if thread_id in self._runs:
            await emit(
                "error",
                thread_id,
                {"code": "run_active", "message": "A run is already active for this thread"},
            )
            return False
        try:
            user_message = await self.threads.add_message(thread_id, "user", content)
            thread = await self.threads.get_thread(thread_id)
        except ThreadNotFoundError:
            await emit("error", thread_id, {"code": "thread_not_found", "message": "Unknown thread"})
            return False
        await emit("thread.updated", thread_id, {"thread": thread.to_wire()})
        log_record(
            "message_received",
            session_id=session_id,
            thread_id=thread_id,
            message_id=user_message.id,
            provider=self.provider.name,
        )

        if content.strip().lower().startswith("/tool"):
            await self._request_tool(session_id, thread_id, content, emit)
            return True

        assistant_message = await self.threads.add_message(thread_id, "assistant", streaming=True)
        run = ActiveRun(
            session_id=session_id,
            thread_id=thread_id,
            run_id=new_id("run"),
            message_id=assistant_message.id,
            cancel_event=asyncio.Event(),
        )
        self._runs[thread_id] = run
        run.task = asyncio.create_task(self._drive_provider(run, emit), name=f"agent-run:{run.run_id}")
        return True

    async def cancel(self, *, session_id: str, thread_id: str) -> bool:
        run = self._runs.get(thread_id)
        if run is None or run.session_id != session_id or run.task is None:
            return False
        run.cancel_event.set()
        run.task.cancel()
        try:
            await run.task
        except asyncio.CancelledError:
            pass
        return True

    async def respond_to_approval(self, *, session_id: str, approval_id: str, decision: str) -> bool:
        approval = self._approvals.get(approval_id)
        if approval is None or approval.session_id != session_id:
            return False
        self._approvals.pop(approval_id, None)
        tool = self.tools.get(approval.tool_id)
        if tool is None:
            await approval.emit(
                "tool.failed",
                approval.thread_id,
                {
                    "approval_id": approval_id,
                    "run_id": approval.run_id,
                    "tool_id": approval.tool_id,
                    "message": "Tool is unavailable",
                },
            )
            return False
        if decision == "deny":
            await self.threads.add_message(
                approval.thread_id,
                "tool",
                f"User denied {tool.tool_id}.",
            )
            thread = await self.threads.set_status(approval.thread_id, "idle")
            await approval.emit(
                "tool.failed",
                approval.thread_id,
                {
                    "approval_id": approval_id,
                    "run_id": approval.run_id,
                    "tool_id": tool.tool_id,
                    "message": "Denied by user",
                },
            )
            await approval.emit("thread.updated", approval.thread_id, {"thread": thread.to_wire()})
            await approval.emit("agent.status", approval.thread_id, {"status": "idle", "run_id": approval.run_id})
            log_record("approval_denied", session_id=session_id, thread_id=approval.thread_id, run_id=approval.run_id)
            return True

        thread = await self.threads.set_status(approval.thread_id, "working")
        await approval.emit("agent.status", approval.thread_id, {"status": "working", "run_id": approval.run_id})
        await approval.emit(
            "tool.running",
            approval.thread_id,
            {
                "approval_id": approval_id,
                "run_id": approval.run_id,
                "tool_id": tool.tool_id,
            },
        )
        try:
            result = await asyncio.wait_for(tool.handler(approval.tool_input), timeout=tool.timeout_seconds)
            await self.threads.add_message(
                approval.thread_id,
                "tool",
                str(result.get("message", "Tool completed")),
            )
            thread = await self.threads.set_status(approval.thread_id, "complete")
            await approval.emit(
                "tool.completed",
                approval.thread_id,
                {
                    "approval_id": approval_id,
                    "run_id": approval.run_id,
                    "tool_id": tool.tool_id,
                    "output": result,
                },
            )
            await approval.emit("thread.updated", approval.thread_id, {"thread": thread.to_wire()})
            await approval.emit("agent.status", approval.thread_id, {"status": "complete", "run_id": approval.run_id})
            await approval.emit("run.completed", approval.thread_id, {"run_id": approval.run_id})
            log_record("tool_completed", session_id=session_id, thread_id=approval.thread_id, run_id=approval.run_id)
            return True
        except Exception as error:
            thread = await self.threads.set_status(approval.thread_id, "error")
            await approval.emit(
                "tool.failed",
                approval.thread_id,
                {
                    "approval_id": approval_id,
                    "run_id": approval.run_id,
                    "tool_id": tool.tool_id,
                    "message": str(error),
                },
            )
            await approval.emit("agent.status", approval.thread_id, {"status": "error", "run_id": approval.run_id})
            await approval.emit("run.failed", approval.thread_id, {"run_id": approval.run_id, "message": str(error)})
            await self.threads.persist_thread(thread.id)
            return False

    async def cancel_session(self, session_id: str) -> None:
        thread_ids = [thread_id for thread_id, run in self._runs.items() if run.session_id == session_id]
        for thread_id in thread_ids:
            await self.cancel(session_id=session_id, thread_id=thread_id)
        approval_ids = [
            approval_id
            for approval_id, approval in self._approvals.items()
            if approval.session_id == session_id
        ]
        for approval_id in approval_ids:
            self._approvals.pop(approval_id, None)

    async def _drive_provider(self, run: ActiveRun, emit: EmitEvent) -> None:
        sequence = 0
        first_delta_at: float | None = None
        loop = asyncio.get_running_loop()
        started_at = loop.time()
        try:
            thread = await self.threads.set_status(run.thread_id, "working")
            await emit("agent.status", run.thread_id, {"status": "working", "run_id": run.run_id})
            await emit(
                "agent.message.started",
                run.thread_id,
                {"message_id": run.message_id, "role": "assistant", "run_id": run.run_id},
            )
            async for delta in self.provider.stream_reply(thread.messages, run.cancel_event):
                if run.cancel_event.is_set():
                    break
                if first_delta_at is None:
                    first_delta_at = loop.time()
                    log_record(
                        "first_token",
                        session_id=run.session_id,
                        thread_id=run.thread_id,
                        run_id=run.run_id,
                        latency_ms=round((first_delta_at - started_at) * 1000),
                    )
                sequence += 1
                await self.threads.append_delta(run.thread_id, run.message_id, delta)
                await emit(
                    "agent.message.delta",
                    run.thread_id,
                    {
                        "message_id": run.message_id,
                        "delta": delta,
                        "sequence": sequence,
                        "run_id": run.run_id,
                    },
                )
            if run.cancel_event.is_set():
                await self._finish_cancelled(run, emit)
                return
            await self.threads.complete_message(run.thread_id, run.message_id)
            await self.threads.set_status(run.thread_id, "complete")
            await emit(
                "agent.message.completed",
                run.thread_id,
                {"message_id": run.message_id, "run_id": run.run_id},
            )
            await emit("agent.status", run.thread_id, {"status": "complete", "run_id": run.run_id})
            await emit("run.completed", run.thread_id, {"run_id": run.run_id})
            log_record("run_completed", session_id=run.session_id, thread_id=run.thread_id, run_id=run.run_id)
        except asyncio.CancelledError:
            await self._finish_cancelled(run, emit)
        except Exception as error:
            await self.threads.complete_message(run.thread_id, run.message_id)
            await self.threads.set_status(run.thread_id, "error")
            await emit(
                "agent.message.completed",
                run.thread_id,
                {"message_id": run.message_id, "run_id": run.run_id},
            )
            await emit("agent.status", run.thread_id, {"status": "error", "run_id": run.run_id})
            await emit("run.failed", run.thread_id, {"run_id": run.run_id, "message": str(error)})
            log_record(
                "run_failed",
                session_id=run.session_id,
                thread_id=run.thread_id,
                run_id=run.run_id,
                error_type=type(error).__name__,
            )
        finally:
            if self._runs.get(run.thread_id) is run:
                self._runs.pop(run.thread_id, None)

    async def _finish_cancelled(self, run: ActiveRun, emit: EmitEvent) -> None:
        await self.threads.complete_message(run.thread_id, run.message_id, cancelled=True)
        await self.threads.set_status(run.thread_id, "idle")
        await emit(
            "agent.message.completed",
            run.thread_id,
            {"message_id": run.message_id, "run_id": run.run_id, "cancelled": True},
        )
        await emit("agent.status", run.thread_id, {"status": "idle", "run_id": run.run_id})
        await emit("run.completed", run.thread_id, {"run_id": run.run_id, "cancelled": True})
        log_record("run_cancelled", session_id=run.session_id, thread_id=run.thread_id, run_id=run.run_id)

    async def _request_tool(
        self,
        session_id: str,
        thread_id: str,
        content: str,
        emit: EmitEvent,
    ) -> None:
        request = content.strip()[len("/tool") :].strip()
        tool_name, _, argument = request.partition(" ")
        tool_aliases = {
            "clock": "system.clock",
            "status": "system.diagnostics",
            "diagnostics": "system.diagnostics",
            "note": "demo.write_note",
        }
        tool_id = tool_aliases.get(tool_name.lower(), "demo.write_note")
        tool_input: dict[str, Any] = {}
        if tool_id == "demo.write_note":
            note_text = argument if tool_name.lower() == "note" else request
            tool_input = {"text": note_text or "Demonstration note"}
        tool = self.tools.get(tool_id)
        if tool is None or not self.permissions.may_execute(tool):
            await emit("error", thread_id, {"code": "tool_forbidden", "message": "Tool is unavailable"})
            return
        if not self.permissions.requires_approval(tool):
            await self._execute_safe_tool(session_id, thread_id, tool, tool_input, emit)
            return

        run_id = new_id("run")
        approval_id = new_id("approval")
        await self.threads.set_status(thread_id, "waiting_user")
        self._approvals[approval_id] = PendingApproval(
            approval_id=approval_id,
            session_id=session_id,
            thread_id=thread_id,
            run_id=run_id,
            tool_id=tool.tool_id,
            tool_input=tool_input,
            emit=emit,
        )
        await emit("agent.status", thread_id, {"status": "waiting_user", "run_id": run_id})
        await emit(
            "approval.required",
            thread_id,
            {
                "approval_id": approval_id,
                "run_id": run_id,
                "tool_id": tool.tool_id,
                "tool_name": "Simulated note write",
                "summary": (
                    "Allow one in-memory simulated note action "
                    f"({len(str(tool_input.get('text', '')))} characters)?"
                ),
                "permission_level": tool.permission_level.value,
                # This deliberately describes the action class, never its arguments.
                "impact_preview": dict(tool.impact_preview),
            },
        )
        log_record("approval_required", session_id=session_id, thread_id=thread_id, run_id=run_id)

    async def _execute_safe_tool(
        self,
        session_id: str,
        thread_id: str,
        tool: Any,
        tool_input: dict[str, Any],
        emit: EmitEvent,
    ) -> None:
        run_id = new_id("run")
        await self.threads.set_status(thread_id, "working")
        await emit("agent.status", thread_id, {"status": "working", "run_id": run_id})
        await emit(
            "tool.running",
            thread_id,
            {"run_id": run_id, "tool_id": tool.tool_id, "permission_level": tool.permission_level.value},
        )
        try:
            result = await asyncio.wait_for(tool.handler(tool_input), timeout=tool.timeout_seconds)
            await self.threads.add_message(thread_id, "tool", str(result.get("message", "Tool completed")))
            thread = await self.threads.set_status(thread_id, "complete")
            await emit(
                "tool.completed",
                thread_id,
                {"run_id": run_id, "tool_id": tool.tool_id, "output": result},
            )
            await emit("thread.updated", thread_id, {"thread": thread.to_wire()})
            await emit("agent.status", thread_id, {"status": "complete", "run_id": run_id})
            await emit("run.completed", thread_id, {"run_id": run_id})
            log_record(
                "safe_tool_completed",
                session_id=session_id,
                thread_id=thread_id,
                run_id=run_id,
                tool_id=tool.tool_id,
            )
        except Exception as error:
            await self.threads.set_status(thread_id, "error")
            await emit(
                "tool.failed",
                thread_id,
                {"run_id": run_id, "tool_id": tool.tool_id, "message": str(error)},
            )
            await emit("agent.status", thread_id, {"status": "error", "run_id": run_id})
            await emit("run.failed", thread_id, {"run_id": run_id, "message": str(error)})
