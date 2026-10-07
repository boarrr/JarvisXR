from __future__ import annotations

"""Codex CLI harness: drives `codex exec` as a subprocess.

Output is parsed as JSONL when possible (one JSON object per line) and as plain
text otherwise, normalized into AgentEvent. Optionally override the binary and
leading arguments with SPATIAL_AGENT_CODEX_COMMAND.
"""

import asyncio
import json
import os
import shlex
from typing import AsyncIterator

from .agent_harness import AgentEvent, HarnessCapabilities


class _Session:
    def __init__(self, directory: str, title: str) -> None:
        self.directory = directory
        self.title = title
        self.queue: asyncio.Queue[AgentEvent | None] = asyncio.Queue()
        self.process: asyncio.subprocess.Process | None = None
        self.reader: asyncio.Task | None = None


class CodexCliHarness:
    name = "codex"
    capabilities = HarnessCapabilities(
        streaming=True,
        tools=True,
        permission_requests=False,  # CLI runs non-interactive; no per-call consent
        directory_scoping=True,
        resume=False,
        cost_reporting=False,
    )

    def __init__(self, command: str | None = None) -> None:
        raw = command or os.getenv("SPATIAL_AGENT_CODEX_COMMAND", "codex exec")
        self._command = shlex.split(raw)
        self._sessions: dict[str, _Session] = {}

    async def create_session(self, *, directory: str, title: str) -> str:
        from uuid import uuid4

        session_id = f"codex_{uuid4().hex[:12]}"
        self._sessions[session_id] = _Session(directory, title)
        return session_id

    async def prompt(self, session_id: str, text: str) -> None:
        session = self._sessions[session_id]
        if session.process is not None:
            raise RuntimeError("codex session already running")
        session.process = await asyncio.create_subprocess_exec(
            *self._command,
            text,
            cwd=session.directory,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        session.reader = asyncio.create_task(self._read(session))

    async def _read(self, session: _Session) -> None:
        process = session.process
        assert process is not None and process.stdout is not None
        async for raw_line in process.stdout:
            line = raw_line.decode("utf-8", errors="replace").rstrip("\n")
            event = self._parse(line)
            await session.queue.put(event)
            if event.status in {"idle", "complete"}:
                break
        await process.wait()
        session.process = None
        await session.queue.put(AgentEvent("status", status="idle"))

    @staticmethod
    def _parse(line: str) -> AgentEvent:
        stripped = line.strip()
        if not stripped:
            return AgentEvent("delta", text="")
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError:
            return AgentEvent("delta", text=stripped)
        if not isinstance(payload, dict):
            return AgentEvent("delta", text=stripped)
        kind = str(payload.get("type", "delta"))
        if kind in {"text", "message", "delta", "assistant"}:
            return AgentEvent("delta", text=str(payload.get("text", payload.get("content", ""))))
        if kind == "thinking":
            return AgentEvent("thinking_delta", text=str(payload.get("text", "")))
        if kind == "tool":
            return AgentEvent("tool", tool=str(payload.get("name", "")), detail=payload)
        if kind == "file":
            return AgentEvent("file_edited", path=str(payload.get("path", "")))
        if kind in {"done", "result", "idle", "complete"}:
            return AgentEvent("status", status="idle")
        if kind == "error":
            return AgentEvent("error", text=str(payload.get("message", "")))
        return AgentEvent("delta", text=stripped)

    async def events(self, session_id: str) -> AsyncIterator[AgentEvent]:
        session = self._sessions[session_id]
        while True:
            event = await session.queue.get()
            if event is None:
                return
            yield event
            if event.kind == "status" and event.status in {"idle", "complete"}:
                return

    async def reply_permission(
        self, session_id: str, approval_id: str, decision: str
    ) -> bool:
        # Codex CLI runs non-interactive; it cannot pause for a per-call answer.
        return False

    async def abort(self, session_id: str) -> bool:
        session = self._sessions.get(session_id)
        if session is None or session.process is None:
            return False
        session.process.terminate()
        return True

    async def close(self, session_id: str) -> None:
        session = self._sessions.pop(session_id, None)
        if session is not None and session.process is not None:
            session.process.terminate()
