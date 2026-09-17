from __future__ import annotations

import argparse
import asyncio
from collections import deque
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from .config import Settings
from .coordinator import AgentCoordinator
from .observability import configure_logging, log_record
from .permissions import PermissionService
from .protocol import Envelope, ProtocolError, make_event, new_id, parse_client_message
from .providers import (
    ClaudeProvider,
    CouncilProvider,
    FakeProvider,
    OpenAIProvider,
    ProviderConfigurationError,
)
from .storage import SQLiteStore
from .thread_service import ThreadNotFoundError, ThreadService
from .tools import ToolRegistry


@dataclass(slots=True)
class Session:
    id: str
    connection: ServerConnection
    focused_thread_id: str = ""
    ready: bool = False
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    command_times: deque[float] = field(default_factory=deque)

    def allow_command(self, limit_per_minute: int) -> bool:
        now = asyncio.get_running_loop().time()
        cutoff = now - 60.0
        while self.command_times and self.command_times[0] < cutoff:
            self.command_times.popleft()
        if len(self.command_times) >= limit_per_minute:
            return False
        self.command_times.append(now)
        return True


class SpatialAgentServer:
    def __init__(self, settings: Settings) -> None:
        settings.validate()
        self.settings = settings
        self.store = SQLiteStore(settings.database_path)
        self.threads = ThreadService(self.store)
        self.tools = ToolRegistry()
        self.permissions = PermissionService()
        if settings.provider == "council":
            self.provider = CouncilProvider(
                OpenAIProvider(
                    model=settings.openai_model,
                    max_output_tokens=settings.max_output_tokens,
                ),
                ClaudeProvider(
                    model=settings.anthropic_model,
                    max_output_tokens=settings.max_output_tokens,
                ),
            )
        elif settings.provider == "claude":
            self.provider = ClaudeProvider(
                model=settings.anthropic_model,
                max_output_tokens=settings.max_output_tokens,
            )
        elif settings.provider == "openai":
            self.provider = OpenAIProvider(
                model=settings.openai_model,
                max_output_tokens=settings.max_output_tokens,
            )
        else:
            self.provider = FakeProvider(chunk_delay_seconds=settings.fake_chunk_delay_seconds)
        self.coordinator = AgentCoordinator(self.threads, self.provider, self.tools, self.permissions)

    async def initialize(self) -> None:
        await self.threads.initialize()

    async def handle_connection(self, connection: ServerConnection) -> None:
        session = Session(new_id("sess"), connection)
        log_record("connection_opened", session_id=session.id, remote=str(connection.remote_address))

        async def emit(event_type: str, thread_id: str, payload: dict[str, Any]) -> None:
            event = make_event(
                event_type,
                session_id=session.id,
                thread_id=thread_id,
                payload=payload,
            )
            await self._send(session, event)

        try:
            async for raw in connection:
                if not isinstance(raw, str):
                    await emit(
                        "error",
                        "",
                        {"code": "binary_packet", "message": "Binary commands are not supported"},
                    )
                    await connection.close(code=1003, reason="Text frames required")
                    break
                if not session.allow_command(self.settings.commands_per_minute):
                    await emit(
                        "error",
                        "",
                        {"code": "rate_limited", "message": "Command rate limit exceeded"},
                    )
                    continue
                try:
                    command = parse_client_message(raw, max_bytes=self.settings.max_packet_bytes)
                    await self._dispatch(session, command, emit)
                except ProtocolError as error:
                    await emit("error", "", {"code": error.code, "message": error.message})
                except ThreadNotFoundError:
                    await emit("error", "", {"code": "thread_not_found", "message": "Unknown thread"})
                except Exception as error:
                    log_record(
                        "command_failed",
                        session_id=session.id,
                        error_type=type(error).__name__,
                    )
                    await emit(
                        "error",
                        "",
                        {"code": "internal_error", "message": "The command could not be completed"},
                    )
        except ConnectionClosed:
            pass
        finally:
            await self.coordinator.cancel_session(session.id)
            log_record("connection_closed", session_id=session.id)

    async def _dispatch(self, session: Session, command: Envelope, emit: Any) -> None:
        if command.type == "session.hello":
            if session.ready:
                await emit("error", "", {"code": "session_exists", "message": "Session is already ready"})
                return
            session.ready = True
            await emit(
                "session.ready",
                "",
                {
                    "protocol_version": 1,
                    "provider": self.provider.name,
                    "model": getattr(self.provider, "model", "local-deterministic"),
                    "capabilities": [
                        "threads",
                        "streaming",
                        "cancel",
                        "approvals",
                        "provider_metadata",
                        *(["dual_provider_council"] if self.provider.name == "council" else []),
                    ],
                    "tools": [
                        {
                            "id": tool.tool_id,
                            "description": tool.description,
                            "permission_level": tool.permission_level.value,
                        }
                        for tool in self.tools.list_tools()
                    ],
                },
            )
            return

        if not session.ready:
            await emit("error", "", {"code": "session_required", "message": "Send session.hello first"})
            return
        if command.session_id != session.id:
            await emit("error", command.thread_id, {"code": "session_mismatch", "message": "Invalid session_id"})
            return

        log_record(
            "command_received",
            session_id=session.id,
            thread_id=command.thread_id,
            event_id=command.event_id,
            command_type=command.type,
        )

        if command.type == "thread.list":
            threads = await self.threads.list_threads()
            await emit("thread.snapshot", "", {"threads": [thread.to_wire() for thread in threads]})
        elif command.type == "thread.create":
            thread = await self.threads.create_thread(str(command.payload.get("title", "New thread")))
            await emit("thread.created", thread.id, {"thread": thread.to_wire()})
        elif command.type == "thread.focus":
            if command.thread_id:
                await self.threads.get_thread(command.thread_id)
            session.focused_thread_id = command.thread_id
        elif command.type == "thread.rename":
            thread = await self.threads.rename_thread(command.thread_id, str(command.payload["title"]))
            await emit("thread.updated", thread.id, {"thread": thread.to_wire()})
        elif command.type == "thread.archive":
            with suppress(Exception):
                await self.coordinator.cancel(session_id=session.id, thread_id=command.thread_id)
            await self.threads.archive_thread(command.thread_id)
            if session.focused_thread_id == command.thread_id:
                session.focused_thread_id = ""
            await emit("thread.archived", command.thread_id, {})
        elif command.type == "message.send":
            await self.coordinator.submit_message(
                session_id=session.id,
                thread_id=command.thread_id,
                content=str(command.payload["content"]),
                emit=emit,
            )
        elif command.type == "run.cancel":
            if not await self.coordinator.cancel(session_id=session.id, thread_id=command.thread_id):
                await emit("error", command.thread_id, {"code": "run_not_found", "message": "No active run"})
        elif command.type == "approval.respond":
            if not await self.coordinator.respond_to_approval(
                session_id=session.id,
                approval_id=str(command.payload["approval_id"]),
                decision=str(command.payload["decision"]),
            ):
                await emit("error", command.thread_id, {"code": "approval_not_found", "message": "Unknown approval"})
        elif command.type == "voice.transcript.final":
            target_thread_id = command.thread_id or session.focused_thread_id
            if not target_thread_id:
                await emit("error", "", {"code": "focus_required", "message": "Voice transcript has no target thread"})
                return
            await self.coordinator.submit_message(
                session_id=session.id,
                thread_id=target_thread_id,
                content=str(command.payload["transcript"]),
                emit=emit,
            )
        else:
            await emit("error", command.thread_id, {"code": "unknown_command", "message": "Unknown command"})

    async def _send(self, session: Session, event: Envelope) -> None:
        try:
            async with session.send_lock:
                await session.connection.send(event.to_json())
            log_record(
                "event_sent",
                session_id=session.id,
                thread_id=event.thread_id,
                event_id=event.event_id,
                event_type=event.type,
            )
        except ConnectionClosed:
            return

    async def serve_forever(self) -> None:
        await self.initialize()
        log_record(
            "server_started",
            host=self.settings.host,
            port=self.settings.port,
            provider=self.provider.name,
            database=str(self.settings.database_path),
        )
        async with serve(
            self.handle_connection,
            self.settings.host,
            self.settings.port,
            max_size=self.settings.max_packet_bytes,
            max_queue=32,
            ping_interval=20,
            ping_timeout=20,
        ) as websocket_server:
            await websocket_server.serve_forever()


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Spatial Agent local WebSocket backend")
    parser.add_argument("--host", help="Override SPATIAL_AGENT_HOST")
    parser.add_argument("--port", type=int, help="Override SPATIAL_AGENT_PORT")
    parser.add_argument("--database", type=Path, help="Override SPATIAL_AGENT_DB")
    parser.add_argument(
        "--provider",
        choices=("fake", "claude", "openai", "council"),
        help="Override SPATIAL_AGENT_PROVIDER",
    )
    return parser


def main() -> None:
    configure_logging()
    arguments = build_argument_parser().parse_args()
    environment = Settings.from_environment()
    settings = Settings(
        host=arguments.host or environment.host,
        port=arguments.port or environment.port,
        database_path=arguments.database or environment.database_path,
        provider=arguments.provider or environment.provider,
        anthropic_model=environment.anthropic_model,
        openai_model=environment.openai_model,
        max_output_tokens=environment.max_output_tokens,
        max_packet_bytes=environment.max_packet_bytes,
        commands_per_minute=environment.commands_per_minute,
        fake_chunk_delay_seconds=environment.fake_chunk_delay_seconds,
    )
    try:
        asyncio.run(SpatialAgentServer(settings).serve_forever())
    except ProviderConfigurationError as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
