from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any

from .domain import Message
from .observability import log_record
from .opencode_bridge import OpencodeClient, permission_from_event
from .permissions import PermissionService, ToolDefinition
from .protocol import new_id
from .providers import AgentProvider
from .providers.base import ToolCall
from .thread_service import ThreadNotFoundError, ThreadService
from .tools import ToolRegistry
from .workspace import (
    FileDiff,
    WorkspaceError,
    WorkspaceManager,
    Worktree,
    list_directory,
    read_file_bounded,
)


EmitEvent = Callable[[str, str, dict[str, Any]], Awaitable[None]]

MAX_TOOL_ITERATIONS = 6

# Permission policy for opencode-driven runs: edits proceed, shell asks.
# The server expects an array of rules (config files use an object; the
# HTTP API uses PermissionRuleset = list[PermissionRule]).
OPENCODE_PERMISSION = [
    {"permission": "*", "pattern": "*", "action": "allow"},
    {"permission": "edit", "pattern": "*", "action": "allow"},
    {"permission": "bash", "pattern": "*", "action": "ask"},
]


@dataclass(slots=True)
class ActiveRun:
    session_id: str
    thread_id: str
    run_id: str
    message_id: str
    cancel_event: asyncio.Event
    task: asyncio.Task[None] | None = None
    worktree: Worktree | None = None


@dataclass(slots=True)
class PendingOpencodePermission:
    approval_id: str
    session_id: str
    thread_id: str
    run_id: str
    decision: asyncio.Future[str] | None = None


@dataclass(slots=True)
class PendingApproval:
    approval_id: str
    session_id: str
    thread_id: str
    run_id: str
    tool_id: str
    tool_input: dict[str, Any]
    emit: EmitEvent
    decision: asyncio.Future[str] | None = None
    call_id: str = ""
    source: str = "native"
    server_id: str = ""


class AgentCoordinator:
    def __init__(
        self,
        threads: ThreadService,
        provider: AgentProvider,
        tools: ToolRegistry,
        permissions: PermissionService,
        workspaces: WorkspaceManager | None = None,
        opencode: OpencodeClient | None = None,
        opencode_directory: str = "",
        test_command: str = "",
    ) -> None:
        self.threads = threads
        self.provider = provider
        self.tools = tools
        self.permissions = permissions
        self.workspaces = workspaces
        self.opencode = opencode
        self.opencode_directory = opencode_directory
        self.test_command = test_command
        self._opencode_permissions: dict[str, PendingOpencodePermission] = {}
        self._opencode_sessions: dict[str, str] = {}
        self._runs: dict[str, ActiveRun] = {}
        self._approvals: dict[str, PendingApproval] = {}
        self._worktrees_by_run: dict[str, Worktree] = {}
        self._latest_run_by_thread: dict[str, str] = {}

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
        opencode_permission = self._opencode_permissions.get(approval_id)
        if opencode_permission is not None:
            if opencode_permission.session_id != session_id:
                return False
            self._opencode_permissions.pop(approval_id, None)
            if opencode_permission.decision is not None and not opencode_permission.decision.done():
                opencode_permission.decision.set_result(decision)
            return True
        approval = self._approvals.get(approval_id)
        if approval is None or approval.session_id != session_id:
            return False
        if approval.decision is not None:
            self._approvals.pop(approval_id, None)
            if not approval.decision.done():
                approval.decision.set_result(decision)
            return True
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
            approval = self._approvals.pop(approval_id, None)
            if approval is not None and approval.decision is not None and not approval.decision.done():
                approval.decision.cancel()
        opencode_ids = [
            approval_id
            for approval_id, permission in self._opencode_permissions.items()
            if permission.session_id == session_id
        ]
        for approval_id in opencode_ids:
            permission = self._opencode_permissions.pop(approval_id, None)
            if permission is not None and permission.decision is not None and not permission.decision.done():
                permission.decision.cancel()

    async def _drive_provider(self, run: ActiveRun, emit: EmitEvent) -> None:
        if self.opencode is not None:
            await self._drive_opencode(run, emit)
            return
        sequence = 0
        first_delta_at: float | None = None
        loop = asyncio.get_running_loop()
        started_at = loop.time()
        try:
            thread = await self.threads.set_status(run.thread_id, "working")
            await emit("agent.status", run.thread_id, {"status": "working", "run_id": run.run_id})
            await self._prepare_worktree(run, thread, emit)
            await emit(
                "agent.message.started",
                run.thread_id,
                {"message_id": run.message_id, "role": "assistant", "run_id": run.run_id},
            )
            tool_specs = self.tools.list_tool_specs() if self.provider.supports_tools else []
            iterations = 0
            while True:
                iterations += 1
                if iterations > MAX_TOOL_ITERATIONS:
                    await emit(
                        "error",
                        run.thread_id,
                        {
                            "code": "tool_loop_limit",
                            "message": "Tool iteration limit reached for this run",
                        },
                    )
                    break
                pending_calls: list[ToolCall] = []
                async for event in self.provider.stream_turn(thread.messages, tool_specs, run.cancel_event):
                    if run.cancel_event.is_set():
                        break
                    if event.kind == "delta" and event.text:
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
                        await self.threads.append_delta(run.thread_id, run.message_id, event.text)
                        await emit(
                            "agent.message.delta",
                            run.thread_id,
                            {
                                "message_id": run.message_id,
                                "delta": event.text,
                                "sequence": sequence,
                                "run_id": run.run_id,
                            },
                        )
                    elif event.kind == "tool_call" and event.tool_call is not None:
                        pending_calls.append(event.tool_call)
                if run.cancel_event.is_set():
                    await self._finish_cancelled(run, emit)
                    return
                if not pending_calls:
                    break
                await self.threads.record_tool_calls(
                    run.thread_id,
                    run.message_id,
                    [call.to_wire() for call in pending_calls],
                )
                for call in pending_calls:
                    await self._handle_tool_call(run, call, emit)
                thread = await self.threads.get_thread(run.thread_id)

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

    async def _opencode_session_for(
        self,
        run: ActiveRun,
        thread: Any,
        client: OpencodeClient,
    ) -> str:
        existing = self._opencode_sessions.get(run.thread_id)
        if existing:
            return existing
        session_id = await client.create_session(
            title=str(getattr(thread, "title", run.thread_id)),
            permission=[dict(rule) for rule in OPENCODE_PERMISSION],
        )
        self._opencode_sessions[run.thread_id] = session_id
        return session_id

    async def _request_opencode_permission(
        self,
        run: ActiveRun,
        request: Any,
        emit: EmitEvent,
    ) -> str:
        approval_id = request.approval_id
        decision: asyncio.Future[str] = asyncio.get_running_loop().create_future()
        self._opencode_permissions[approval_id] = PendingOpencodePermission(
            approval_id=approval_id,
            session_id=run.session_id,
            thread_id=run.thread_id,
            run_id=run.run_id,
            decision=decision,
        )
        with suppress(Exception):
            await self.threads.set_status(run.thread_id, "waiting_user")
        await emit("agent.status", run.thread_id, {"status": "waiting_user", "run_id": run.run_id})
        summary = f"Allow opencode {request.permission}?"
        if request.patterns:
            summary += " " + ", ".join(request.patterns)
        details = str(request.metadata.get("command", "")) or ", ".join(request.patterns)
        await emit(
            "approval.required",
            run.thread_id,
            {
                "approval_id": approval_id,
                "run_id": run.run_id,
                "tool_id": f"opencode.{request.permission}",
                "tool_name": f"opencode {request.permission}",
                "summary": summary,
                "permission_level": "explicit approval",
                "source": "opencode",
                "impact_preview": {
                    "route": ["gesture", "opencode", request.permission],
                    "scope": details or "opencode tool call",
                    "side_effect": "may change files or run commands",
                    "reversibility": "depends on the command",
                    "external": False,
                },
            },
        )
        log_record(
            "approval_required",
            session_id=run.session_id,
            thread_id=run.thread_id,
            run_id=run.run_id,
            tool_id=f"opencode.{request.permission}",
            source="opencode",
        )
        resolved = await decision
        self._opencode_permissions.pop(approval_id, None)
        with suppress(Exception):
            await self.threads.set_status(run.thread_id, "working")
        await emit("agent.status", run.thread_id, {"status": "working", "run_id": run.run_id})
        return resolved

    async def _drive_opencode(self, run: ActiveRun, emit: EmitEvent) -> None:
        assert self.opencode is not None
        sequence = 0
        try:
            thread = await self.threads.set_status(run.thread_id, "working")
            await emit("agent.status", run.thread_id, {"status": "working", "run_id": run.run_id})
            await self._prepare_worktree(run, thread, emit)
            directory = str(run.worktree.path) if run.worktree is not None else self.opencode_directory
            client = self.opencode.with_directory(directory) if directory else self.opencode
            opencode_session = await self._opencode_session_for(run, thread, client)
            prompt_text = ""
            for message in reversed(thread.messages):
                if message.role == "user" and message.content.strip():
                    prompt_text = message.content
                    break
            await emit(
                "agent.message.started",
                run.thread_id,
                {"message_id": run.message_id, "role": "assistant", "run_id": run.run_id},
            )
            await client.prompt(opencode_session, prompt_text)
            async for event in client.events():
                if run.cancel_event.is_set():
                    with suppress(Exception):
                        await client.abort(opencode_session)
                    break
                props = event.get("properties", {}) if isinstance(event, dict) else {}
                session_id = str(props.get("sessionID", ""))
                if session_id and session_id != opencode_session:
                    continue
                event_type = str(event.get("type", ""))
                if event_type == "message.part.delta":
                    if props.get("field") != "text":
                        continue
                    delta = str(props.get("delta", ""))
                    if not delta:
                        continue
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
                elif event_type == "permission.asked":
                    request = permission_from_event(event)
                    if request is None:
                        continue
                    resolved = await self._request_opencode_permission(run, request, emit)
                    response = "once" if resolved == "approve" else "reject"
                    with suppress(Exception):
                        await client.reply_permission(request.session_id, request.approval_id, response)
                elif event_type == "file.edited":
                    await emit(
                        "file.edited",
                        run.thread_id,
                        {"path": str(props.get("file", "")), "run_id": run.run_id},
                    )
                elif event_type == "session.idle":
                    break
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
        except Exception as error:  # noqa: BLE001
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

    async def _handle_tool_call(self, run: ActiveRun, call: ToolCall, emit: EmitEvent) -> None:
        tool = self.tools.get(call.tool_name)
        if tool is None:
            message = f"Unknown tool: {call.tool_name}"
            await self.threads.add_message(
                run.thread_id,
                "tool",
                message,
                metadata={"tool_call_id": call.call_id, "tool_name": call.tool_name},
            )
            await emit(
                "tool.failed",
                run.thread_id,
                {"run_id": run.run_id, "tool_id": call.tool_name, "call_id": call.call_id, "message": message},
            )
            return
        if not self.permissions.may_execute(tool):
            message = f"Tool is not available: {tool.tool_id}"
            await self.threads.add_message(
                run.thread_id,
                "tool",
                message,
                metadata={"tool_call_id": call.call_id, "tool_name": tool.tool_id},
            )
            await emit(
                "tool.failed",
                run.thread_id,
                {"run_id": run.run_id, "tool_id": tool.tool_id, "call_id": call.call_id, "message": message},
            )
            return

        approval_id = ""
        if self.permissions.requires_approval(tool):
            approval_id, decision = await self._request_call_approval(run, call, tool, emit)
            if decision != "approve":
                message = f"User denied {tool.tool_id}."
                await self.threads.add_message(
                    run.thread_id,
                    "tool",
                    message,
                    metadata={"tool_call_id": call.call_id, "tool_name": tool.tool_id},
                )
                await self.threads.set_status(run.thread_id, "working")
                await emit("agent.status", run.thread_id, {"status": "working", "run_id": run.run_id})
                await emit(
                    "tool.failed",
                    run.thread_id,
                    {
                        "approval_id": approval_id,
                        "run_id": run.run_id,
                        "tool_id": tool.tool_id,
                        "call_id": call.call_id,
                        "message": "Denied by user",
                    },
                )
                self._audit("tool_denied", run, tool_id=tool.tool_id, approval_id=approval_id)
                return
        else:
            await self.threads.set_status(run.thread_id, "working")

        await emit(
            "tool.running",
            run.thread_id,
            {"run_id": run.run_id, "tool_id": tool.tool_id, "call_id": call.call_id},
        )
        try:
            result = await asyncio.wait_for(
                tool.handler(call.arguments), timeout=tool.timeout_seconds
            )
        except Exception as error:
            message = str(error) or "Tool failed"
            await self.threads.add_message(
                run.thread_id,
                "tool",
                message,
                metadata={"tool_call_id": call.call_id, "tool_name": tool.tool_id},
            )
            await emit(
                "tool.failed",
                run.thread_id,
                {
                    "approval_id": approval_id,
                    "run_id": run.run_id,
                    "tool_id": tool.tool_id,
                    "call_id": call.call_id,
                    "message": message,
                },
            )
            self._audit("tool_failed", run, tool_id=tool.tool_id, approval_id=approval_id)
            return

        text = str(result.get("message", "Tool completed"))
        await self.threads.add_message(
            run.thread_id,
            "tool",
            text,
            metadata={"tool_call_id": call.call_id, "tool_name": tool.tool_id},
        )
        await emit(
            "tool.completed",
            run.thread_id,
            {
                "approval_id": approval_id,
                "run_id": run.run_id,
                "tool_id": tool.tool_id,
                "call_id": call.call_id,
                "output": result,
            },
        )
        self._audit("tool_completed", run, tool_id=tool.tool_id, approval_id=approval_id)

    async def _request_call_approval(
        self, run: ActiveRun, call: ToolCall, tool: ToolDefinition, emit: EmitEvent
    ) -> tuple[str, str]:
        approval_id = new_id("approval")
        decision: asyncio.Future[str] = asyncio.get_running_loop().create_future()
        self._approvals[approval_id] = PendingApproval(
            approval_id=approval_id,
            session_id=run.session_id,
            thread_id=run.thread_id,
            run_id=run.run_id,
            tool_id=tool.tool_id,
            tool_input=call.arguments,
            emit=emit,
            decision=decision,
            call_id=call.call_id,
            source=tool.source,
            server_id=tool.server_id,
        )
        await self.threads.set_status(run.thread_id, "waiting_user")
        await emit("agent.status", run.thread_id, {"status": "waiting_user", "run_id": run.run_id})
        await emit(
            "approval.required",
            run.thread_id,
            {
                "approval_id": approval_id,
                "run_id": run.run_id,
                "tool_id": tool.tool_id,
                "tool_name": tool.description,
                "summary": f"Allow {tool.description or tool.tool_id}?",
                "permission_level": tool.permission_level.value,
                "source": tool.source,
                "server_id": tool.server_id,
                "call_id": call.call_id,
                "impact_preview": dict(tool.impact_preview),
            },
        )
        log_record(
            "approval_required",
            session_id=run.session_id,
            thread_id=run.thread_id,
            run_id=run.run_id,
            tool_id=tool.tool_id,
            source=tool.source,
        )
        try:
            decision_value = await decision
        except asyncio.CancelledError:
            self._approvals.pop(approval_id, None)
            raise
        return approval_id, decision_value

    def _audit(self, event_type: str, run: ActiveRun, **fields: Any) -> None:
        store = getattr(self.threads, "store", None)
        record = getattr(store, "record_audit", None)
        if record is None:
            return
        record(
            event_type,
            session_id=run.session_id,
            thread_id=run.thread_id,
            run_id=run.run_id,
            detail=fields,
        )

    async def _prepare_worktree(self, run: ActiveRun, thread: Any, emit: EmitEvent) -> None:
        if self.workspaces is None:
            return
        workspace_id = str((thread.metadata or {}).get("workspace_id", ""))
        if not workspace_id:
            return
        if self.workspaces.get(workspace_id) is None:
            await emit(
                "error",
                run.thread_id,
                {
                    "code": "workspace_not_found",
                    "message": f"Workspace '{workspace_id}' is not registered",
                },
            )
            return
        try:
            worktree = await self.workspaces.create_worktree(workspace_id, run.run_id)
        except WorkspaceError as error:
            await emit(
                "error",
                run.thread_id,
                {"code": "workspace_error", "message": str(error)},
            )
            return
        run.worktree = worktree
        self._worktrees_by_run[run.run_id] = worktree
        self._latest_run_by_thread[run.thread_id] = run.run_id
        store = getattr(self.threads, "store", None)
        record = getattr(store, "record_run", None)
        if record is not None:
            record(
                run.run_id,
                session_id=run.session_id,
                thread_id=run.thread_id,
                workspace_id=workspace_id,
                worktree_path=str(worktree.path),
                branch=worktree.branch,
                base_commit=worktree.base_commit,
                status="active",
            )
        self._audit("worktree_created", run, workspace_id=workspace_id, branch=worktree.branch)
        await emit(
            "run.workspace",
            run.thread_id,
            {"run_id": run.run_id, **worktree.to_wire()},
        )

    def worktree_for_run(self, run_id: str) -> Worktree | None:
        return self._worktrees_by_run.get(run_id)

    def latest_worktree(self, thread_id: str) -> Worktree | None:
        run_id = self._latest_run_by_thread.get(thread_id)
        return self._worktrees_by_run.get(run_id) if run_id else None

    async def _thread_root(self, thread_id: str):
        worktree = self.latest_worktree(thread_id)
        if worktree is not None:
            return worktree.path
        if self.workspaces is None:
            raise WorkspaceError("No workspace manager is configured")
        thread = await self.threads.get_thread(thread_id)
        workspace_id = str((thread.metadata or {}).get("workspace_id", ""))
        workspace = self.workspaces.get(workspace_id) if workspace_id else None
        if workspace is None:
            raise WorkspaceError("No workspace is bound to this thread")
        return workspace.path

    async def list_thread_files(self, thread_id: str, relative_path: str = "") -> list[dict[str, Any]]:
        root = await self._thread_root(thread_id)
        return await asyncio.to_thread(list_directory, root, relative_path)

    async def read_thread_file(self, thread_id: str, relative_path: str) -> dict[str, Any]:
        root = await self._thread_root(thread_id)
        return await asyncio.to_thread(read_file_bounded, root, relative_path)

    async def diff_for_thread(self, thread_id: str) -> tuple[list[FileDiff], bool, str]:
        worktree = self.latest_worktree(thread_id)
        if worktree is None or self.workspaces is None:
            raise WorkspaceError("No agent worktree is available for this thread")
        files, truncated = await self.workspaces.diff(worktree)
        return files, truncated, worktree.run_id

    async def decide_diff(self, run_id: str, decision: str) -> dict[str, Any]:
        worktree = self._worktrees_by_run.get(run_id)
        if worktree is None or self.workspaces is None:
            raise WorkspaceError("Unknown diff run")
        if decision == "apply":
            tests_result = "skipped"
            if self.test_command.strip():
                passed, output = await self.workspaces.run_tests(worktree, self.test_command)
                if not passed:
                    raise WorkspaceError(
                        "Tests failed; the change was not applied.\n" + output[-1500:]
                    )
                tests_result = "passed"
            commit = await self.workspaces.commit(
                worktree, f"spatial agent run {run_id}"
            )
            await self.workspaces.remove_worktree_directory(worktree)
            result: dict[str, Any] = {
                "run_id": run_id,
                "decision": "apply",
                "branch": worktree.branch,
                "commit": commit,
                "tests": tests_result,
            }
        else:
            await self.workspaces.remove_worktree(worktree)
            result = {
                "run_id": run_id,
                "decision": "reject",
                "branch": worktree.branch,
            }
        self._worktrees_by_run.pop(run_id, None)
        for thread_id, latest_run_id in list(self._latest_run_by_thread.items()):
            if latest_run_id == run_id:
                self._latest_run_by_thread.pop(thread_id, None)
        store = getattr(self.threads, "store", None)
        update = getattr(store, "update_run_status", None)
        if update is not None:
            update(run_id, "applied" if decision == "apply" else "rejected")
        record = getattr(store, "record_audit", None)
        if record is not None:
            record(
                "diff_applied" if decision == "apply" else "diff_rejected",
                run_id=run_id,
                detail=dict(result),
            )
        return result

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
        tool_id = tool_aliases.get(tool_name.lower(), "")
        if not tool_id and self.tools.get(tool_name):
            tool_id = tool_name
        if not tool_id:
            tool_id = "demo.write_note"
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
            source=tool.source,
            server_id=tool.server_id,
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
                "source": tool.source,
                "server_id": tool.server_id,
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
