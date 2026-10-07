from __future__ import annotations

import argparse
import asyncio
import base64
from collections import deque
from contextlib import suppress
from dataclasses import dataclass, field, replace
import json
from pathlib import Path
import socket
import ssl
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from . import __version__
from .auth import PairingManager
from .config import Settings
from .coordinator import AgentCoordinator
from .mission_service import MissionService
from .discovery import DiscoveryAdvertiser, build_beacon, local_ipv4_addresses
from .mcp_host import McpHost
from .observability import configure_logging, log_record
from .permissions import PermissionService
from .protocol import (
    Envelope,
    ProtocolError,
    V2_COMMAND_TYPES,
    make_event,
    new_id,
    parse_client_message,
)
from .providers import (
    ClaudeProvider,
    CouncilProvider,
    DeepSeekProvider,
    FakeProvider,
    OpenAIProvider,
    ProviderConfigurationError,
)
from .storage import SQLiteStore
from .opencode_bridge import OpencodeClient
from .thread_service import ThreadNotFoundError, ThreadService
from .update_service import UpdateError, UpdateService
from .voice_service import Utterance, VoiceError, WhisperTranscriber
from .tools import ToolRegistry
from .workspace import WorkspaceError, WorkspaceManager


@dataclass(slots=True)
class Session:
    id: str
    connection: ServerConnection
    focused_thread_id: str = ""
    ready: bool = False
    protocol_version: int = 1
    device_id: str = ""
    device_name: str = ""
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
        self.workspaces = WorkspaceManager(settings.workspaces_file)
        self.workspaces.load()
        self.pairing = PairingManager(
            self.store, ttl_seconds=settings.pairing_code_ttl_seconds
        )
        self.mcp = McpHost(settings.mcp_config_path)
        self.updates = UpdateService(settings.update_manifest_path)
        self.voice = (
            WhisperTranscriber(settings.whisper_server_url)
            if settings.voice_enabled
            else None
        )
        self._utterances: dict[str, Utterance] = {}
        self.mcp.load()
        for error in self.mcp.load_errors:
            log_record("mcp_config_error", error=error)
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
        elif settings.provider == "deepseek":
            self.provider = DeepSeekProvider(
                model=settings.deepseek_model,
                max_output_tokens=settings.max_output_tokens,
            )
        elif settings.provider == "openai":
            self.provider = OpenAIProvider(
                model=settings.openai_model,
                max_output_tokens=settings.max_output_tokens,
            )
        elif settings.provider == "opencode":
            self.provider = FakeProvider(chunk_delay_seconds=settings.fake_chunk_delay_seconds)
        else:
            self.provider = FakeProvider(chunk_delay_seconds=settings.fake_chunk_delay_seconds)
        opencode_client = None
        if settings.provider == "opencode":
            opencode_client = OpencodeClient(
                base_url=settings.opencode_url,
                password=settings.opencode_password,
                username=settings.opencode_username,
            )
        # The cockpit should see the real brain, not the internal fallback stub.
        if settings.provider == "opencode":
            self.provider_label = "opencode"
            self.provider_model = "opencode"
        else:
            self.provider_label = self.provider.name
            self.provider_model = getattr(self.provider, "model", "local-deterministic")
        self.coordinator = AgentCoordinator(
            self.threads,
            self.provider,
            self.tools,
            self.permissions,
            self.workspaces,
            opencode=opencode_client,
            opencode_directory=settings.opencode_directory,
            test_command=settings.test_command,
            fs_root=settings.fs_root,
            harness=self._build_harness(settings),
        )
        self.missions = MissionService(self.threads, self.workspaces, self.coordinator)
        # Lifecycle handles for embedding (daemon desktop app).
        self._ssl_context: ssl.SSLContext | None = None
        self._advertiser = None
        self._serve_task: asyncio.Task | None = None
        self._websocket_server = None
        self._serve_ready: asyncio.Event | None = None
        self._stop_event: asyncio.Event | None = None

    @staticmethod
    def _build_harness(settings: Settings):
        if settings.harness == "codex":
            from .codex_cli_harness import CodexCliHarness

            return CodexCliHarness()
        return None

    async def initialize(self) -> None:
        await self.threads.initialize()
        self.missions.load()
        await self._configure_workspace_binding()
        if self.settings.auth_required:
            code = await asyncio.to_thread(self.pairing.issue_code)
            print(
                f"[spatial-agent] Pairing code: {code} "
                f"(valid {int(self.settings.pairing_code_ttl_seconds)} seconds)",
                flush=True,
            )
            log_record(
                "pairing_code_issued",
                ttl_seconds=int(self.settings.pairing_code_ttl_seconds),
            )
        failures = await self.mcp.start()
        for server_id, error in failures.items():
            log_record("mcp_server_unavailable", server_id=server_id, error=error)
        for server_id in self.mcp.connected_server_ids():
            registered = self.tools.register_mcp_server(
                self.mcp, server_id, self.mcp.cached_tools(server_id)
            )
            log_record("mcp_server_ready", server_id=server_id, tools=registered)

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
                try:
                    command = parse_client_message(raw, max_bytes=self.settings.max_packet_bytes)
                except ProtocolError as error:
                    await emit("error", "", {"code": error.code, "message": error.message})
                    continue
                # Bulk/streaming traffic (self-update chunks, live voice audio) is
                # not command spam and must not be rate limited.
                _rate_exempt = {
                    "update.fetch",
                    "update.check",
                    "voice.audio.start",
                    "voice.audio.chunk",
                    "voice.audio.end",
                    "voice.audio.cancel",
                }
                if (
                    command.type not in _rate_exempt
                    and not session.allow_command(self.settings.commands_per_minute)
                ):
                    await emit(
                        "error",
                        "",
                        {"code": "rate_limited", "message": "Command rate limit exceeded"},
                    )
                    continue
                try:
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
            if self.settings.auth_required:
                token = str(command.payload.get("auth_token", ""))
                device = await asyncio.to_thread(self.pairing.verify, token)
                if device is None:
                    await emit(
                        "error",
                        "",
                        {
                            "code": "auth_required",
                            "message": "Pair this device with session.pair before session.hello",
                        },
                    )
                    return
                session.device_id = device.id
                session.device_name = device.name
            session.protocol_version = int(command.payload.get("protocol_version", 1))
            session.ready = True
            await asyncio.to_thread(
                self.store.record_audit,
                "session_opened",
                session_id=session.id,
                device_id=session.device_id,
            )
            await emit(
                "session.ready",
                "",
                {
                    "protocol_version": session.protocol_version,
                    "provider": self.provider_label,
                    "model": self.provider_model,
                    "daemon_version": __version__,
                    "auth": (
                        "paired"
                        if session.device_id
                        else ("open-loopback" if not self.settings.auth_required else "required")
                    ),
                    "capabilities": [
                        "threads",
                        "streaming",
                        "cancel",
                        "approvals",
                        "provider_metadata",
                        "workspaces",
                        "diff_review",
                        "tool_catalog",
                        "pairing" if self.settings.auth_required else "open_loopback",
                        "missions",
                        *(["mcp"] if self.mcp.connected_server_ids() else []),
                        *(["dual_provider_council"] if self.provider.name == "council" else []),
                    ],
                    "workspaces": [
                        workspace.to_wire() for workspace in self.workspaces.list_workspaces()
                    ],
                    "mcp_servers": self.mcp.connected_server_ids(),
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

        if command.type == "session.pair":
            if not self.settings.auth_required:
                await emit(
                    "error",
                    "",
                    {
                        "code": "pairing_disabled",
                        "message": "This daemon does not require pairing",
                    },
                )
                return
            result = await asyncio.to_thread(
                self.pairing.redeem,
                str(command.payload.get("code", "")),
                str(command.payload.get("device_name", "")),
            )
            if result is None:
                await emit(
                    "error",
                    "",
                    {"code": "pairing_invalid", "message": "Pairing code is invalid or expired"},
                )
                return
            token, device = result
            await asyncio.to_thread(
                self.store.record_audit, "device_paired", device_id=device.id
            )
            log_record("device_paired", device_id=device.id, device_name=device.name)
            await emit(
                "session.paired",
                "",
                {"device_id": device.id, "device_name": device.name, "token": token},
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

        if command.type in V2_COMMAND_TYPES and session.protocol_version < 2:
            await emit(
                "error",
                command.thread_id,
                {
                    "code": "unsupported_version",
                    "message": f"{command.type} requires protocol version 2",
                },
            )
            return

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
        elif command.type == "voice.audio.start":
            if self.voice is None:
                await emit(
                    "voice.error",
                    command.thread_id,
                    {"code": "voice_disabled", "message": "Voice is not enabled on the daemon"},
                )
            else:
                self._utterances[session.id] = Utterance(
                    sample_rate=int(command.payload.get("sample_rate", 16000) or 16000),
                    channels=int(command.payload.get("channels", 1) or 1),
                    thread_id=command.thread_id or session.focused_thread_id,
                )
                await emit("voice.listening", command.thread_id, {"state": "listening"})
        elif command.type == "voice.audio.chunk":
            utterance = self._utterances.get(session.id)
            if utterance is None:
                await emit(
                    "voice.error",
                    command.thread_id,
                    {"code": "no_utterance", "message": "No active voice stream"},
                )
            else:
                try:
                    utterance.append(base64.b64decode(str(command.payload.get("data", ""))))
                except (ValueError, VoiceError) as error:
                    self._utterances.pop(session.id, None)
                    await emit(
                        "voice.error",
                        command.thread_id,
                        {"code": "bad_audio", "message": str(error)},
                    )
        elif command.type == "voice.audio.end":
            utterance = self._utterances.pop(session.id, None)
            if utterance is not None and self.voice is not None and utterance.pcm:
                try:
                    text = await asyncio.to_thread(self.voice.transcribe, utterance)
                except VoiceError as error:
                    await emit(
                        "voice.error",
                        command.thread_id,
                        {"code": error.code, "message": error.message},
                    )
                else:
                    await emit(
                        "voice.final",
                        command.thread_id,
                        {"transcript": text, "thread_id": utterance.thread_id},
                    )
        elif command.type == "voice.audio.cancel":
            self._utterances.pop(session.id, None)
            await emit("voice.cancelled", command.thread_id, {})
        elif command.type == "workspace.list":
            await emit(
                "workspace.snapshot",
                "",
                {
                    "workspaces": [
                        workspace.to_wire() for workspace in self.workspaces.list_workspaces()
                    ]
                },
            )
        elif command.type == "workspace.bind":
            thread = await self.threads.get_thread(command.thread_id)
            workspace_id = str(command.payload.get("workspace_id", "")).strip()
            if workspace_id and self.workspaces.get(workspace_id) is None:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "workspace_not_found", "message": "Unknown workspace"},
                )
                return
            metadata = dict(thread.metadata)
            metadata["workspace_id"] = workspace_id
            thread.metadata = metadata
            thread.touch()
            await self.threads.persist_thread(thread.id)
            await emit("thread.updated", command.thread_id, {"thread": thread.to_wire()})
        elif command.type == "file.list":
            path = str(command.payload.get("path", ""))
            try:
                entries = await self.coordinator.list_thread_files(command.thread_id, path)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "workspace_unavailable", "message": str(error)},
                )
                return
            await emit("file.tree", command.thread_id, {"path": path, "entries": entries})
        elif command.type == "file.read":
            path = str(command.payload.get("path", ""))
            try:
                content = await self.coordinator.read_thread_file(command.thread_id, path)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "workspace_unavailable", "message": str(error)},
                )
                return
            await emit("file.content", command.thread_id, content)
        elif command.type == "fs.list":
            path = str(command.payload.get("path", ""))
            try:
                entries = await self.coordinator.list_host_files(path)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "fs_unavailable", "message": str(error)},
                )
                return
            await emit(
                "file.tree",
                command.thread_id,
                {"path": path, "entries": entries, "scope": "host"},
            )
        elif command.type == "fs.read":
            path = str(command.payload.get("path", ""))
            try:
                content = await self.coordinator.read_host_file(path)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "fs_unavailable", "message": str(error)},
                )
                return
            content = dict(content)
            content["scope"] = "host"
            await emit("file.content", command.thread_id, content)
        elif command.type == "diff.get":
            try:
                files, truncated, run_id = await self.coordinator.diff_for_thread(command.thread_id)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "workspace_unavailable", "message": str(error)},
                )
                return
            await emit(
                "diff.proposed",
                command.thread_id,
                {
                    "run_id": run_id,
                    "truncated": truncated,
                    "files": [file_diff.to_wire() for file_diff in files],
                },
            )
        elif command.type == "diff.decision":
            run_id = str(command.payload["run_id"])
            decision = str(command.payload["decision"])
            run = await asyncio.to_thread(self.store.get_run, run_id)
            if run is None or run["session_id"] != session.id:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "diff_not_found", "message": "Unknown diff run"},
                )
                return
            try:
                result = await self.coordinator.decide_diff(run_id, decision)
            except WorkspaceError as error:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "diff_not_found", "message": str(error)},
                )
                return
            await emit(
                "diff.applied" if decision == "apply" else "diff.rejected",
                command.thread_id,
                result,
            )
            thread = await self.threads.get_thread(command.thread_id)
            await emit("thread.updated", command.thread_id, {"thread": thread.to_wire()})
        elif command.type == "tool.catalog":
            await emit("tool.catalog", "", self._tool_catalog_payload())
        elif command.type == "thread.combine":
            try:
                combined = await self.threads.combine_threads(
                    [str(item) for item in command.payload["thread_ids"]]
                )
            except ThreadNotFoundError:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "thread_not_found", "message": "Unknown source thread"},
                )
                return
            log_record(
                "threads_combined",
                session_id=session.id,
                thread_id=combined.id,
                sources=len(command.payload["thread_ids"]),
            )
            # Sources are absorbed into the combined agent.
            for source_id in command.payload["thread_ids"]:
                await emit("thread.archived", str(source_id), {})
            await emit("thread.created", combined.id, {"thread": combined.to_wire()})
        elif command.type == "mission.create":
            workspace_id = str(command.payload.get("workspace_id") or "")
            if not workspace_id and self.workspaces is not None:
                registered = self.workspaces.list_workspaces()
                if registered:
                    workspace_id = registered[0].id
            mission = await self.missions.create(
                session_id=session.id,
                workspace_id=workspace_id,
                goal=str(command.payload.get("goal", "")),
                agent_count=int(command.payload.get("agent_count", 3)),
                harness=str(command.payload.get("harness", self.settings.harness)),
                budget_seconds=int(command.payload.get("budget_seconds", 0)),
            )
            log_record("mission_created", session_id=session.id, mission_id=mission["id"])
            await emit("mission.created", "", mission)
            await self.missions.spawn(mission["id"], emit)
        elif command.type == "mission.status":
            await emit("mission.status", "", await self.missions.status(str(command.payload["mission_id"])))
        elif command.type == "mission.cancel":
            await self.missions.cancel(
                str(command.payload["mission_id"]), str(command.payload.get("agent_id", ""))
            )
            await emit("mission.status", "", await self.missions.status(str(command.payload["mission_id"])))
        elif command.type == "agent.compare":
            agents = await self.missions.compare(str(command.payload["mission_id"]))
            await emit("mission.compare", "", {"agents": agents})
        elif command.type == "agent.status":
            await emit("mission.status", "", await self.missions.status(str(command.payload["mission_id"])))
        elif command.type == "mission.merge":
            result = await self.missions.merge(
                str(command.payload["mission_id"]), str(command.payload["run_id"])
            )
            await emit("mission.merged", "", result)
        elif command.type == "thread.separate":
            try:
                restored = await self.threads.separate_thread(command.thread_id)
            except ThreadNotFoundError:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "thread_not_found", "message": "Unknown combined thread"},
                )
                return
            log_record(
                "threads_separated",
                session_id=session.id,
                thread_id=command.thread_id,
                restored=len(restored),
            )
            if session.focused_thread_id == command.thread_id:
                session.focused_thread_id = ""
            await emit("thread.archived", command.thread_id, {})
            for source in restored:
                await emit("thread.created", source.id, {"thread": source.to_wire()})
        elif command.type == "update.apply":
            package = self.updates.current()
            if package is None:
                await emit("error", "", {"code": "no_update", "message": "No update is published"})
                return
            result = await self._adb_install(str(package.apk_path), emit)
            if result.get("ok"):
                log_record("update_applied", session_id=session.id, version=package.version)
                await emit("update.applied", "", {"version": package.version})
            else:
                log_record("update_apply_failed", session_id=session.id, code=result.get("code", ""))
                # No usable adb link (or the install failed): hand the transfer
                # back to the cockpit so it can download and install the APK
                # itself via its PackageInstaller plugin - no USB required.
                await emit(
                    "update.fallback",
                    "",
                    {"reason": result.get("code", "install_failed"), "message": result.get("message", "")},
                )
                # Also send the legacy error shape: older clients only trigger
                # their in-app installer from this error code.
                await emit(
                    "error",
                    "",
                    {"code": result.get("code", "install_failed"), "message": result.get("message", "")},
                )
        elif command.type == "update.check":
            payload = self.updates.manifest_payload()
            log_record(
                "update_check",
                session_id=session.id,
                version=payload.get("version", ""),
                available=bool(payload),
            )
            if payload:
                await emit("update.available", "", payload)
            else:
                await emit("update.none", "", {})
        elif command.type == "update.fetch":
            offset = int(command.payload.get("offset", 0))
            length = int(command.payload.get("length", self.updates.chunk_bytes))
            log_record("update_fetch", session_id=session.id, offset=offset, length=length)
            try:
                data, eof = self.updates.read_chunk(offset, length)
            except UpdateError as error:
                await emit("error", "", {"code": error.code, "message": error.message})
                return
            import base64 as _base64
            if eof or offset == 0:
                log_record(
                    "update_transfer",
                    session_id=session.id,
                    offset=offset,
                    bytes=len(data),
                    eof=eof,
                )
            await emit(
                "update.chunk",
                "",
                {
                    "offset": offset,
                    "data": _base64.b64encode(data).decode("ascii"),
                    "eof": eof,
                },
            )
        elif command.type == "thread.restore":
            try:
                restored = await self.threads.restore_thread(command.thread_id)
            except ThreadNotFoundError:
                await emit(
                    "error",
                    command.thread_id,
                    {"code": "thread_not_found", "message": "Unknown thread"},
                )
                return
            log_record(
                "thread_restored",
                session_id=session.id,
                thread_id=restored.id,
            )
            await emit("thread.created", restored.id, {"thread": restored.to_wire()})
        else:
            await emit("error", command.thread_id, {"code": "unknown_command", "message": "Unknown command"})

    async def _adb_install(self, apk_path: str, emit: Any) -> dict[str, Any]:
        """Install the published APK over adb, streaming progress to the client.

        We push then `pm install` (instead of `adb install`) so we can report
        transfer percentage, and we start the server, prefer USB, reconnect the
        cached wireless address, and retry the whole thing a few times.
        """
        import re as _re
        import shutil as _shutil

        adb = _shutil.which("adb") or str(
            Path.home() / "Library/Android/sdk/platform-tools/adb"
        )
        if not Path(adb).exists():
            return {"ok": False, "code": "no_adb", "message": "adb not found on the daemon host"}

        ip_file = self.settings.update_manifest_path.parent / "wifi-ip"
        cached_ip = ip_file.read_text().strip() if ip_file.exists() else ""

        async def run(args: list[str], timeout: float = 30.0) -> tuple[int, str]:
            proc = await asyncio.create_subprocess_exec(
                adb, *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            try:
                out, _ = await asyncio.wait_for(proc.communicate(), timeout)
            except asyncio.TimeoutError:
                with suppress(Exception):
                    proc.kill()
                return 1, "timeout"
            return proc.returncode, (out or b"").decode("utf-8", errors="replace")

        def parse_devices(text: str) -> list[tuple[str, str]]:
            rows = [line.split("\t") for line in text.splitlines()[1:] if "\t" in line]
            return [(row[0].strip(), row[1].strip()) for row in rows if len(row) >= 2]

        async def pick() -> str:
            _rc, out = await run(["devices"], 10)
            devs = parse_devices(out)
            usb = [name for name, state in devs if ":" not in name and state == "device"]
            if usb:
                return usb[0]
            wifi = [name for name, state in devs if ":" in name and state == "device"]
            return wifi[0] if wifi else ""

        with suppress(Exception):
            await run(["start-server"], 20)

        last_code, last_message = "no_adb_device", "No adb device connected"
        remote = "/data/local/tmp/spatial-agent-update.apk"
        for _attempt in range(4):
            serial = await pick()
            if not serial and cached_ip:
                with suppress(Exception):
                    await run(["disconnect", f"{cached_ip}:5555"], 10)
                    await run(["connect", f"{cached_ip}:5555"], 10)
                await asyncio.sleep(2)
                serial = await pick()
            if not serial:
                last_code, last_message = "no_adb_device", "No adb device connected"
                await asyncio.sleep(3)
                continue

            await emit("update.progress", "", {"stage": "transferring", "percent": 0})
            # adb suppresses its progress bar when piped, so we push the APK in
            # slices and report real progress from the bytes sent.
            import os as _os
            import tempfile as _tempfile

            remote_dir = "/data/local/tmp/spatial-agent-update"
            with suppress(Exception):
                await run(["-s", serial, "shell", "rm", "-rf", remote_dir], 20)
                await run(["-s", serial, "shell", "mkdir", "-p", remote_dir], 20)
            file_size = _os.path.getsize(apk_path) or 1
            part_size = 4 * 1024 * 1024
            sent = 0
            push_ok = True
            temp_dir = _tempfile.mkdtemp(prefix="sa-update-")
            try:
                with open(apk_path, "rb") as handle:
                    index = 0
                    while True:
                        chunk = handle.read(part_size)
                        if not chunk:
                            break
                        index += 1
                        part_path = _os.path.join(temp_dir, f"part{index:04d}")
                        with open(part_path, "wb") as part_file:
                            part_file.write(chunk)
                        rc, _out = await run(
                            ["-s", serial, "push", part_path, f"{remote_dir}/part{index:04d}"],
                            180,
                        )
                        if rc != 0:
                            push_ok = False
                            break
                        sent += len(chunk)
                        await emit(
                            "update.progress",
                            "",
                            {"stage": "transferring", "percent": min(99, int(sent * 100 / file_size))},
                        )
            finally:
                with suppress(Exception):
                    _os.remove(part_path)
                with suppress(Exception):
                    _os.rmdir(temp_dir)
            if not push_ok:
                last_code, last_message = "transfer_failed", "adb push failed"
                if ":" in serial:
                    with suppress(Exception):
                        await run(["disconnect", serial], 10)
                await asyncio.sleep(2)
                continue
            with suppress(Exception):
                await run(
                    ["-s", serial, "shell", f"cat {remote_dir}/part* > {remote}"],
                    120,
                )
                await run(["-s", serial, "shell", "rm", "-rf", remote_dir], 20)
            await emit("update.progress", "", {"stage": "installing", "percent": 100})
            _rc, out = await run(["-s", serial, "shell", "pm", "install", "-r", remote], 900)
            if "Success" in out:
                with suppress(Exception):
                    await run(["-s", serial, "shell", "rm", "-f", remote], 20)
                await emit("update.progress", "", {"stage": "relaunching"})
                with suppress(Exception):
                    await run(
                        ["-s", serial, "shell", "monkey", "-p", "com.spatialagent.xr",
                         "-c", "android.intent.category.LAUNCHER", "1"],
                        30,
                    )
                return {"ok": True}
            last_code, last_message = "install_failed", out[-400:]
            if ":" in serial:
                with suppress(Exception):
                    await run(["disconnect", serial], 10)
            await asyncio.sleep(2)

        return {"ok": False, "code": last_code, "message": last_message}

    async def _configure_workspace_binding(self) -> None:
        path_value = self.settings.workspace_path.strip()
        if not path_value:
            return
        path = Path(path_value).expanduser().resolve()
        if not path.is_dir():
            log_record("workspace_binding_skipped", path=str(path), reason="not_a_directory")
            return
        workspace = next(
            (w for w in self.workspaces.list_workspaces() if w.path == path), None
        )
        if workspace is None:
            try:
                workspace = self.workspaces.register(
                    self.settings.workspace_name or path.name,
                    path,
                    self.settings.workspace_branch or "main",
                )
            except WorkspaceError as error:
                log_record("workspace_binding_skipped", path=str(path), reason=str(error))
                return
        bound = 0
        for thread in await self.threads.list_threads():
            metadata = dict(thread.metadata)
            if metadata.get("workspace_id") == workspace.id:
                continue
            metadata["workspace_id"] = workspace.id
            thread.metadata = metadata
            thread.touch()
            await self.threads.persist_thread(thread.id)
            bound += 1
        log_record("workspace_bound", workspace_id=workspace.id, threads=bound)

    def _tool_catalog_payload(self) -> dict[str, Any]:
        return {
            "tools": [
                {
                    "id": tool.tool_id,
                    "description": tool.description,
                    "permission_level": tool.permission_level.value,
                    "source": tool.source,
                    "server_id": tool.server_id,
                    "annotations": dict(tool.annotations),
                }
                for tool in self.tools.list_tools()
            ],
            "mcp_servers": self.mcp.connected_server_ids(),
        }

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

    def _build_ssl_context(self) -> ssl.SSLContext | None:
        if not (self.settings.tls_certificate_path and self.settings.tls_private_key_path):
            return None
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(
            str(self.settings.tls_certificate_path),
            str(self.settings.tls_private_key_path),
        )
        return context

    async def start(self) -> None:
        """Bring the daemon up without blocking (for an embedding app)."""
        await self.initialize()
        self._ssl_context = self._build_ssl_context()
        log_record(
            "server_started",
            host=self.settings.host,
            port=self.settings.port,
            provider=self.provider.name,
            database=str(self.settings.database_path),
            auth_required=self.settings.auth_required,
            tls=bool(self._ssl_context),
            workspaces=len(self.workspaces.list_workspaces()),
        )
        self._advertiser = DiscoveryAdvertiser(
            payload=build_beacon(
                ws_port=self.settings.port,
                discovery_port=self.settings.discovery_port,
                host_name=_mdns_name(),
                cert_path=_ca_certificate_path(self.settings),
                version=_update_version(self.settings),
            ),
            port=self.settings.discovery_port,
            enabled=self.settings.discovery_enabled,
        )
        self._advertiser.start()
        if self.settings.discovery_enabled:
            log_record(
                "discovery_started",
                port=self.settings.discovery_port,
                ips=local_ipv4_addresses(),
            )
        self._serve_ready = asyncio.Event()
        self._stop_event = asyncio.Event()
        self._serve_task = asyncio.create_task(self._serve())

    async def _serve(self) -> None:
        async with serve(
            self.handle_connection,
            self.settings.host,
            self.settings.port,
            max_size=self.settings.max_packet_bytes,
            max_queue=32,
            ping_interval=20,
            ping_timeout=20,
            ssl=self._ssl_context,
        ) as websocket_server:
            self._websocket_server = websocket_server
            assert self._serve_ready is not None
            self._serve_ready.set()
            assert self._stop_event is not None
            await self._stop_event.wait()

    async def wait_until_ready(self) -> None:
        if self._serve_ready is not None:
            await self._serve_ready.wait()

    def bound_port(self) -> int:
        server = self._websocket_server
        if server is not None:
            for sock in getattr(server, "sockets", []) or []:
                try:
                    return int(sock.getsockname()[1])
                except (OSError, IndexError, TypeError):
                    continue
        return self.settings.port

    async def stop(self) -> None:
        if self._stop_event is not None:
            self._stop_event.set()
        if self._serve_task is not None:
            try:
                await asyncio.wait_for(asyncio.shield(self._serve_task), timeout=5.0)
            except asyncio.TimeoutError:
                self._serve_task.cancel()
        await self.mcp.stop()
        if self._advertiser is not None:
            self._advertiser.stop()
        log_record("server_stopped")

    async def serve_forever(self) -> None:
        await self.start()
        await self.wait_until_ready()
        if self._serve_task is not None:
            await self._serve_task


def _mdns_name() -> str:
    name = socket.gethostname().strip()
    if not name:
        return ""
    return name if name.endswith(".local") else "%s.local" % name


def _ca_certificate_path(settings: Settings) -> Path | None:
    cert = settings.tls_certificate_path
    if cert is None:
        return None
    sibling = cert.parent / "ca.crt"
    return sibling if sibling.is_file() else cert


def _update_version(settings: Settings) -> str:
    manifest = settings.update_manifest_path
    if not manifest.is_file():
        return ""
    try:
        return str(json.loads(manifest.read_text(encoding="utf-8")).get("version", ""))
    except (OSError, ValueError):
        return ""


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Spatial Agent local WebSocket backend")
    parser.add_argument("--host", help="Override SPATIAL_AGENT_HOST")
    parser.add_argument("--port", type=int, help="Override SPATIAL_AGENT_PORT")
    parser.add_argument("--database", type=Path, help="Override SPATIAL_AGENT_DB")
    parser.add_argument(
        "--provider",
        choices=("fake", "claude", "openai", "deepseek", "council"),
        help="Override SPATIAL_AGENT_PROVIDER",
    )
    return parser


def main() -> None:
    configure_logging()
    arguments = build_argument_parser().parse_args()
    environment = Settings.from_environment()
    settings = replace(
        environment,
        host=arguments.host or environment.host,
        port=arguments.port or environment.port,
        database_path=arguments.database or environment.database_path,
        provider=arguments.provider or environment.provider,
    )
    try:
        asyncio.run(SpatialAgentServer(settings).serve_forever())
    except ProviderConfigurationError as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
