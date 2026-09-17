from __future__ import annotations

from abc import ABC, abstractmethod
import asyncio
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request
import uuid
from typing import Any

from .observability import log_record

MCP_PROTOCOL_VERSION = "2025-06-18"
DEFAULT_REQUEST_TIMEOUT_SECONDS = 20.0
DEFAULT_TOOL_TIMEOUT_SECONDS = 120.0
MAX_SERVERS = 16
MAX_TOOL_RESULT_BYTES = 96 * 1024
MAX_CONTENT_ITEMS = 32
VALID_SERVER_ID = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
VALID_TRANSPORTS = {"stdio", "http"}


class McpError(RuntimeError):
    pass


class McpConfigError(McpError):
    pass


class McpConnectionError(McpError):
    pass


class McpToolError(McpError):
    pass


@dataclass(slots=True)
class McpServerConfig:
    id: str
    transport: str
    command: list[str] = field(default_factory=list)
    url: str = ""
    env: dict[str, str] = field(default_factory=dict)
    cwd: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    enabled: bool = True
    request_timeout_seconds: float = DEFAULT_REQUEST_TIMEOUT_SECONDS
    tool_timeout_seconds: float = DEFAULT_TOOL_TIMEOUT_SECONDS
    server_default_level: str | None = None
    tool_levels: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class McpTool:
    server_id: str
    name: str
    description: str
    input_schema: dict[str, Any]
    annotations: dict[str, Any]


@dataclass(frozen=True, slots=True)
class McpCallResult:
    text: str
    is_error: bool
    truncated: bool = False


class McpConnection(ABC):
    def __init__(self, config: McpServerConfig) -> None:
        self.config = config
        self.server_info: dict[str, Any] = {}

    async def start(self) -> None:
        await self.request(
            "initialize",
            {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "spatial-agent", "version": "0.5.0"},
            },
        )
        await self.notify("notifications/initialized", {})

    @abstractmethod
    async def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        return None

    @abstractmethod
    async def close(self) -> None:
        raise NotImplementedError


class StdioConnection(McpConnection):
    def __init__(self, config: McpServerConfig) -> None:
        super().__init__(config)
        self._process: asyncio.subprocess.Process | None = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self._reader_task: asyncio.Task[None] | None = None
        self._stderr_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if not self.config.command:
            raise McpConfigError(f"Server '{self.config.id}' has no stdio command")
        environment = {**os.environ, **self.config.env}
        self._process = await asyncio.create_subprocess_exec(
            *self.config.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.config.cwd or None,
            env=environment,
        )
        self._reader_task = asyncio.create_task(self._read_loop())
        self._stderr_task = asyncio.create_task(self._drain_stderr())
        response = await self.request(
            "initialize",
            {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "spatial-agent", "version": "0.5.0"},
            },
        )
        self.server_info = response.get("serverInfo", {})
        await self.notify("notifications/initialized", {})

    async def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        process = self._process
        if process is None or process.stdin is None:
            raise McpConnectionError(f"Server '{self.config.id}' is not running")
        self._next_id += 1
        request_id = self._next_id
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )
        try:
            process.stdin.write(payload.encode("utf-8") + b"\n")
            await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as error:
            self._pending.pop(request_id, None)
            raise McpConnectionError(f"Server '{self.config.id}' pipe closed") from error
        try:
            return await asyncio.wait_for(
                future, timeout=self.config.request_timeout_seconds
            )
        except asyncio.TimeoutError as error:
            self._pending.pop(request_id, None)
            raise McpConnectionError(
                f"Server '{self.config.id}' timed out on {method}"
            ) from error

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        process = self._process
        if process is None or process.stdin is None:
            return
        payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params})
        try:
            process.stdin.write(payload.encode("utf-8") + b"\n")
            await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass

    async def _read_loop(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        while True:
            try:
                line = await process.stdout.readline()
            except (ValueError, ConnectionResetError):
                break
            if not line:
                break
            try:
                message = json.loads(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if not isinstance(message, dict):
                continue
            request_id = message.get("id")
            if request_id is None or request_id not in self._pending:
                continue
            future = self._pending.pop(request_id)
            if future.done():
                continue
            if "error" in message:
                error = message.get("error") or {}
                future.set_exception(
                    McpToolError(str(error.get("message", "MCP request failed")))
                )
            else:
                result = message.get("result")
                future.set_result(result if isinstance(result, dict) else {})
        for future in self._pending.values():
            if not future.done():
                future.set_exception(
                    McpConnectionError(f"Server '{self.config.id}' exited")
                )
        self._pending.clear()

    async def _drain_stderr(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        while True:
            try:
                line = await process.stderr.readline()
            except (ValueError, ConnectionResetError):
                break
            if not line:
                break
            text = line.decode("utf-8", errors="replace").strip()
            if text:
                log_record("mcp_server_stderr", server_id=self.config.id, line=text[:200])

    async def close(self) -> None:
        if self._reader_task is not None:
            self._reader_task.cancel()
        if self._stderr_task is not None:
            self._stderr_task.cancel()
        process = self._process
        self._process = None
        if process is not None:
            if process.stdin is not None:
                try:
                    process.stdin.close()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            try:
                await asyncio.wait_for(process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()


def parse_sse_messages(body: str) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    for line in body.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[len("data:") :].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            decoded = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, dict):
            messages.append(decoded)
    return messages


class HttpConnection(McpConnection):
    def __init__(self, config: McpServerConfig) -> None:
        super().__init__(config)
        self._session_id = ""

    async def start(self) -> None:
        response = await self._post(
            {
                "jsonrpc": "2.0",
                "id": str(uuid.uuid4()),
                "method": "initialize",
                "params": {
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "spatial-agent", "version": "0.5.0"},
                },
            }
        )
        self.server_info = response.get("serverInfo", {})
        await self.notify("notifications/initialized", {})

    async def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        return await self._post(
            {
                "jsonrpc": "2.0",
                "id": str(uuid.uuid4()),
                "method": method,
                "params": params,
            }
        )

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self._post(
            {"jsonrpc": "2.0", "method": method, "params": params}, expect_response=False
        )

    async def _post(
        self, payload: dict[str, Any], *, expect_response: bool = True
    ) -> dict[str, Any]:
        return await asyncio.to_thread(self._post_sync, payload, expect_response)

    def _post_sync(self, payload: dict[str, Any], expect_response: bool) -> dict[str, Any]:
        request = urllib.request.Request(
            self.config.url,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
        )
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "application/json, text/event-stream")
        if self._session_id:
            request.add_header("Mcp-Session-Id", self._session_id)
        for key, value in self.config.headers.items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(
                request, timeout=self.config.request_timeout_seconds
            ) as response:
                session_id = response.headers.get("Mcp-Session-Id", "")
                if session_id:
                    self._session_id = session_id
                body = response.read(MAX_TOOL_RESULT_BYTES * 2).decode(
                    "utf-8", errors="replace"
                )
                content_type = response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as error:
            raise McpConnectionError(
                f"Server '{self.config.id}' returned HTTP {error.code}"
            ) from error
        except OSError as error:
            raise McpConnectionError(
                f"Server '{self.config.id}' is unreachable: {error}"
            ) from error
        if not expect_response:
            return {}
        messages = (
            parse_sse_messages(body)
            if "text/event-stream" in content_type
            else [json.loads(body)] if body.strip() else []
        )
        request_id = payload.get("id")
        for message in messages:
            if message.get("id") == request_id:
                if "error" in message:
                    raise McpToolError(
                        str((message.get("error") or {}).get("message", "MCP error"))
                    )
                result = message.get("result")
                return result if isinstance(result, dict) else {}
        raise McpConnectionError(
            f"Server '{self.config.id}' returned no response for {payload.get('method')}"
        )

    async def close(self) -> None:
        return None


class McpHost:
    """Loads mcp.json, owns one connection per enabled server, and lists/calls tools."""

    def __init__(self, config_path: Path) -> None:
        self.config_path = config_path
        self._configs: dict[str, McpServerConfig] = {}
        self._connections: dict[str, McpConnection] = {}
        self._tools: dict[str, list[McpTool]] = {}
        self.load_errors: list[str] = []

    def load(self) -> None:
        self.load_errors = []
        self._configs = {}
        if not self.config_path.is_file():
            return
        try:
            payload = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            self.load_errors.append(f"mcp config is unreadable: {error}")
            return
        servers = payload.get("servers", [])
        if not isinstance(servers, list):
            self.load_errors.append("mcp config 'servers' must be a list")
            return
        for entry in servers:
            try:
                config = self._parse_server(entry)
            except McpConfigError as error:
                self.load_errors.append(str(error))
                continue
            if config.id in self._configs:
                self.load_errors.append(f"duplicate MCP server id: {config.id}")
                continue
            if len(self._configs) >= MAX_SERVERS:
                self.load_errors.append(f"too many MCP servers (max {MAX_SERVERS})")
                break
            self._configs[config.id] = config

    def _parse_server(self, entry: Any) -> McpServerConfig:
        if not isinstance(entry, dict):
            raise McpConfigError("each MCP server entry must be an object")
        server_id = str(entry.get("id", ""))
        if not VALID_SERVER_ID.fullmatch(server_id):
            raise McpConfigError(f"invalid MCP server id: {server_id!r}")
        transport = str(entry.get("transport", "stdio"))
        if transport not in VALID_TRANSPORTS:
            raise McpConfigError(
                f"server '{server_id}' transport must be one of {sorted(VALID_TRANSPORTS)}"
            )
        command = entry.get("command", [])
        if transport == "stdio" and (
            not isinstance(command, list)
            or not command
            or not all(isinstance(item, str) and item for item in command)
        ):
            raise McpConfigError(f"server '{server_id}' requires a non-empty command list")
        url = str(entry.get("url", ""))
        if transport == "http" and not url.startswith(("http://", "https://")):
            raise McpConfigError(f"server '{server_id}' requires an http(s) url")
        policy = entry.get("policy", {})
        if not isinstance(policy, dict):
            raise McpConfigError(f"server '{server_id}' policy must be an object")
        tool_levels = policy.get("tools", {})
        if not isinstance(tool_levels, dict):
            raise McpConfigError(f"server '{server_id}' policy.tools must be an object")
        valid_levels = {
            "safe_read",
            "sensitive_read",
            "write_reversible",
            "write_external",
            "destructive",
            "forbidden",
        }
        for level in [policy.get("default"), *tool_levels.values()]:
            if level is not None and str(level) not in valid_levels:
                raise McpConfigError(
                    f"server '{server_id}' has invalid policy level: {level!r}"
                )
        return McpServerConfig(
            id=server_id,
            transport=transport,
            command=[str(item) for item in command],
            url=url,
            env={str(k): str(v) for k, v in (entry.get("env") or {}).items()},
            cwd=str(entry.get("cwd", "")),
            headers={str(k): str(v) for k, v in (entry.get("headers") or {}).items()},
            enabled=bool(entry.get("enabled", True)),
            request_timeout_seconds=float(
                entry.get("request_timeout_seconds", DEFAULT_REQUEST_TIMEOUT_SECONDS)
            ),
            tool_timeout_seconds=float(
                entry.get("tool_timeout_seconds", DEFAULT_TOOL_TIMEOUT_SECONDS)
            ),
            server_default_level=(
                str(policy["default"]) if policy.get("default") else None
            ),
            tool_levels={str(k): str(v) for k, v in tool_levels.items()},
        )

    def configured_server_ids(self) -> list[str]:
        return [server_id for server_id, config in self._configs.items() if config.enabled]

    def connected_server_ids(self) -> list[str]:
        return list(self._connections.keys())

    async def start(self) -> dict[str, str]:
        failures: dict[str, str] = {}
        for server_id in self.configured_server_ids():
            config = self._configs[server_id]
            connection: McpConnection = (
                StdioConnection(config)
                if config.transport == "stdio"
                else HttpConnection(config)
            )
            try:
                await connection.start()
            except Exception as error:
                failures[server_id] = str(error)
                await connection.close()
                continue
            self._connections[server_id] = connection
            try:
                self._tools[server_id] = await self.list_tools(server_id)
            except McpError as error:
                failures[server_id] = str(error)
                self._tools[server_id] = []
        return failures

    async def stop(self) -> None:
        for connection in self._connections.values():
            try:
                await connection.close()
            except Exception:
                pass
        self._connections.clear()
        self._tools.clear()

    def server_default_level(self, server_id: str) -> str | None:
        config = self._configs.get(server_id)
        return config.server_default_level if config else None

    def tool_levels(self, server_id: str) -> dict[str, str]:
        config = self._configs.get(server_id)
        return dict(config.tool_levels) if config else {}

    def cached_tools(self, server_id: str) -> list[McpTool]:
        return list(self._tools.get(server_id, []))

    def tool_timeout_seconds(self, server_id: str) -> float:
        config = self._configs.get(server_id)
        return config.tool_timeout_seconds if config else DEFAULT_TOOL_TIMEOUT_SECONDS

    async def list_tools(self, server_id: str) -> list[McpTool]:
        connection = self._connections.get(server_id)
        if connection is None:
            raise McpConnectionError(f"Server '{server_id}' is not connected")
        result = await connection.request("tools/list", {})
        tools: list[McpTool] = []
        for entry in result.get("tools", [])[:100]:
            if not isinstance(entry, dict):
                continue
            name = str(entry.get("name", "")).strip()
            if not name:
                continue
            schema = entry.get("inputSchema", {"type": "object", "properties": {}})
            annotations = entry.get("annotations", {})
            tools.append(
                McpTool(
                    server_id=server_id,
                    name=name,
                    description=str(entry.get("description", "")),
                    input_schema=schema if isinstance(schema, dict) else {"type": "object"},
                    annotations=annotations if isinstance(annotations, dict) else {},
                )
            )
        return tools

    async def call_tool(
        self, server_id: str, tool_name: str, arguments: dict[str, Any]
    ) -> McpCallResult:
        connection = self._connections.get(server_id)
        if connection is None:
            raise McpConnectionError(f"Server '{server_id}' is not connected")
        result = await connection.request(
            "tools/call", {"name": tool_name, "arguments": arguments}
        )
        is_error = bool(result.get("isError", False))
        parts: list[str] = []
        truncated = False
        for item in (result.get("content") or [])[:MAX_CONTENT_ITEMS]:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text":
                parts.append(str(item.get("text", "")))
            else:
                parts.append(f"[{item.get('type', 'content')}]")
        text = "\n".join(part for part in parts if part)
        if len(text.encode("utf-8")) > MAX_TOOL_RESULT_BYTES:
            text = text[:MAX_TOOL_RESULT_BYTES]
            truncated = True
        return McpCallResult(text=text, is_error=is_error, truncated=truncated)

    async def list_resources(self, server_id: str) -> list[dict[str, Any]]:
        connection = self._connections.get(server_id)
        if connection is None:
            raise McpConnectionError(f"Server '{server_id}' is not connected")
        result = await connection.request("resources/list", {})
        resources = result.get("resources", [])
        return [item for item in resources[:200] if isinstance(item, dict)]

    async def read_resource(self, server_id: str, uri: str) -> McpCallResult:
        connection = self._connections.get(server_id)
        if connection is None:
            raise McpConnectionError(f"Server '{server_id}' is not connected")
        result = await connection.request("resources/read", {"uri": uri})
        contents = result.get("contents", [])
        parts: list[str] = []
        for item in contents[:MAX_CONTENT_ITEMS]:
            if not isinstance(item, dict):
                continue
            parts.append(str(item.get("text", item.get("uri", ""))))
        text = "\n".join(part for part in parts if part)
        truncated = len(text.encode("utf-8")) > MAX_TOOL_RESULT_BYTES
        if truncated:
            text = text[:MAX_TOOL_RESULT_BYTES]
        return McpCallResult(text=text, is_error=False, truncated=truncated)
