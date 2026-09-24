from __future__ import annotations

import argparse
import asyncio
from collections import deque
from contextlib import suppress
from dataclasses import dataclass, field, replace
from pathlib import Path
import ssl
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from . import __version__
from .auth import PairingManager
from .config import Settings
from .coordinator import AgentCoordinator
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
from .thread_service import ThreadNotFoundError, ThreadService
from .update_service import UpdateError, UpdateService
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
        else:
            self.provider = FakeProvider(chunk_delay_seconds=settings.fake_chunk_delay_seconds)
        self.coordinator = AgentCoordinator(
            self.threads, self.provider, self.tools, self.permissions, self.workspaces
        )

    async def initialize(self) -> None:
        await self.threads.initialize()
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
                # The chunked self-update transfer is bulk data, not commands.
                if (
                    command.type not in {"update.fetch", "update.check"}
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
                    "provider": self.provider.name,
                    "model": getattr(self.provider, "model", "local-deterministic"),
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
            proc = await asyncio.create_subprocess_exec(
                adb, "-s", serial, "push", apk_path, remote,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            buffer = b""
            last_percent = -1
            while True:
                chunk = await proc.stdout.read(256)
                if not chunk:
                    break
                buffer += chunk
                found = _re.findall(rb"(\d{1,3})%", buffer)
                if found:
                    percent = min(100, int(found[-1]))
                    if percent != last_percent:
                        last_percent = percent
                        await emit("update.progress", "", {"stage": "transferring", "percent": percent})
                    buffer = buffer[-64:]
            push_rc = await proc.wait()
            if push_rc != 0:
                last_code, last_message = "transfer_failed", "adb push failed"
                if ":" in serial:
                    with suppress(Exception):
                        await run(["disconnect", serial], 10)
                await asyncio.sleep(2)
                continue

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

    async def serve_forever(self) -> None:
        await self.initialize()
        ssl_context = self._build_ssl_context()
        log_record(
            "server_started",
            host=self.settings.host,
            port=self.settings.port,
            provider=self.provider.name,
            database=str(self.settings.database_path),
            auth_required=self.settings.auth_required,
            tls=bool(ssl_context),
            workspaces=len(self.workspaces.list_workspaces()),
        )
        async with serve(
            self.handle_connection,
            self.settings.host,
            self.settings.port,
            max_size=self.settings.max_packet_bytes,
            max_queue=32,
            ping_interval=20,
            ping_timeout=20,
            ssl=ssl_context,
        ) as websocket_server:
            try:
                await websocket_server.serve_forever()
            finally:
                await self.mcp.stop()


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
