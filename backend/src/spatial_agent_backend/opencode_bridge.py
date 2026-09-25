from __future__ import annotations

import asyncio
import base64
import json
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

DEFAULT_TIMEOUT_SECONDS = 30.0
MAX_ERROR_BODY_CHARS = 800


class OpencodeError(RuntimeError):
    """Raised when the opencode server rejects or fails a request."""


@dataclass(slots=True)
class PermissionRequest:
    """A tool approval opencode is waiting on."""

    approval_id: str
    session_id: str
    permission: str
    patterns: list[str] = field(default_factory=list)
    always: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_wire(self) -> dict[str, Any]:
        return {
            "approval_id": self.approval_id,
            "session_id": self.session_id,
            "permission": self.permission,
            "patterns": list(self.patterns),
            "always": list(self.always),
            "metadata": dict(self.metadata),
        }


class OpencodeClient:
    """Minimal async client for a local ``opencode serve`` instance.

    Only the endpoints the cockpit needs are wrapped: sessions, prompts,
    server-sent events, permission replies, abort, and status. The client is
    dependency-free; blocking urllib calls run in worker threads.
    """

    def __init__(
        self,
        base_url: str = "http://127.0.0.1:4096",
        password: str = "",
        username: str = "opencode",
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        directory: str = "",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self._username = username
        self._password = password
        # The server is multi-directory: scoping every call to a directory lets
        # one server drive an isolated git worktree per run.
        self.directory = directory
        credentials = f"{username}:{password}".encode()
        self._auth_header = "Basic " + base64.b64encode(credentials).decode()

    def with_directory(self, directory: str) -> "OpencodeClient":
        return OpencodeClient(
            self.base_url,
            password=self._password,
            username=self._username,
            timeout_seconds=self.timeout_seconds,
            directory=directory,
        )

    def _scoped(self, path: str) -> str:
        if not self.directory:
            return path
        separator = "&" if "?" in path else "?"
        return f"{path}{separator}directory={urllib.parse.quote(self.directory, safe='')}"

    # -- blocking transport -------------------------------------------------
    def _blocking_request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            self.base_url + self._scoped(path), data=data, method=method
        )
        request.add_header("Authorization", self._auth_header)
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(
                request, timeout=timeout if timeout is not None else self.timeout_seconds
            ) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")[:MAX_ERROR_BODY_CHARS]
            raise OpencodeError(f"{method} {path} failed: HTTP {error.code} {detail}") from error
        except urllib.error.URLError as error:
            raise OpencodeError(f"{method} {path} unreachable: {error.reason}") from error
        if not raw.strip():
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError as error:
            raise OpencodeError(f"{method} {path} returned invalid JSON") from error

    async def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        return await asyncio.to_thread(self._blocking_request, method, path, body, timeout=timeout)

    # -- typed API ----------------------------------------------------------
    async def health(self) -> dict[str, Any]:
        return await self._request("GET", "/global/health")

    async def create_session(
        self,
        title: str = "",
        permission: dict[str, Any] | None = None,
    ) -> str:
        body: dict[str, Any] = {}
        if title:
            body["title"] = title
        if permission:
            body["permission"] = permission
        session = await self._request("POST", "/session", body)
        session_id = str(session.get("id", "")) if isinstance(session, dict) else ""
        if not session_id:
            raise OpencodeError("session creation returned no id")
        return session_id

    async def delete_session(self, session_id: str) -> bool:
        return bool(await self._request("DELETE", f"/session/{session_id}"))

    async def prompt(self, session_id: str, text: str) -> None:
        """Send a prompt without waiting for the reply (events carry it)."""
        await self._request(
            "POST",
            f"/session/{session_id}/prompt_async",
            {"parts": [{"type": "text", "text": text}]},
        )

    async def abort(self, session_id: str) -> bool:
        return bool(await self._request("POST", f"/session/{session_id}/abort", {}))

    async def status(self) -> dict[str, Any]:
        return await self._request("GET", "/session/status")

    async def messages(self, session_id: str) -> list[dict[str, Any]]:
        result = await self._request("GET", f"/session/{session_id}/message")
        return result if isinstance(result, list) else []

    async def reply_permission(
        self,
        session_id: str,
        approval_id: str,
        response: str,
        *,
        remember: list[str] | None = None,
    ) -> bool:
        body: dict[str, Any] = {"response": response}
        if remember:
            body["remember"] = remember
        result = await self._request(
            "POST", f"/session/{session_id}/permissions/{approval_id}", body
        )
        return bool(result)

    # -- events -------------------------------------------------------------
    async def events(self) -> AsyncIterator[dict[str, Any]]:
        """Yield decoded SSE events from ``GET /event`` until the stream ends."""
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        stop = threading.Event()

        def pump() -> None:
            try:
                request = urllib.request.Request(self.base_url + self._scoped("/event"))
                request.add_header("Authorization", self._auth_header)
                request.add_header("Accept", "text/event-stream")
                with urllib.request.urlopen(request, timeout=None) as response:
                    for raw_line in response:
                        if stop.is_set():
                            return
                        line = raw_line.decode("utf-8", errors="replace").strip()
                        if not line.startswith("data:"):
                            continue
                        payload = line[5:].strip()
                        if not payload:
                            continue
                        try:
                            event = json.loads(payload)
                        except json.JSONDecodeError:
                            continue
                        loop.call_soon_threadsafe(queue.put_nowait, event)
            except Exception as error:  # noqa: BLE001 - surfaced to the consumer
                loop.call_soon_threadsafe(
                    queue.put_nowait, {"type": "__stream_error__", "error": str(error)}
                )
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, None)

        thread = threading.Thread(target=pump, name="opencode-events", daemon=True)
        thread.start()
        try:
            while True:
                event = await queue.get()
                if event is None:
                    return
                yield event
        finally:
            stop.set()


def permission_from_event(event: dict[str, Any]) -> PermissionRequest | None:
    if event.get("type") != "permission.asked":
        return None
    props = event.get("properties", {})
    approval_id = str(props.get("id", ""))
    if not approval_id:
        return None
    return PermissionRequest(
        approval_id=approval_id,
        session_id=str(props.get("sessionID", "")),
        permission=str(props.get("permission", "")),
        patterns=[str(pattern) for pattern in props.get("patterns", [])],
        always=[str(pattern) for pattern in props.get("always", [])],
        metadata=dict(props.get("metadata", {})),
    )


def translate_event(event: dict[str, Any]) -> dict[str, Any] | None:
    """Map an opencode SSE event to a daemon-facing event dict.

    The daemon emits these over the existing websocket so the cockpit reuses
    its message, tool, approval, and status surfaces.
    """
    event_type = event.get("type", "")
    props = event.get("properties", {})
    if event_type == "message.part.delta":
        if props.get("field") != "text":
            return None
        delta = str(props.get("delta", ""))
        return {"type": "message.delta", "text": delta} if delta else None
    if event_type == "message.part.updated":
        part = props.get("part", {})
        if part.get("type") == "tool":
            state = part.get("state", {})
            return {
                "type": "tool.activity",
                "tool": str(part.get("tool", "")),
                "status": str(state.get("status", "")),
                "call_id": str(part.get("callID", part.get("id", ""))),
            }
        return None
    if event_type == "session.status":
        status = props.get("status", {})
        status_type = str(status.get("type", "")) if isinstance(status, dict) else ""
        if status_type == "busy":
            return {"type": "agent.status", "status": "working"}
        if status_type == "idle":
            return {"type": "agent.status", "status": "idle"}
        return None
    if event_type == "session.idle":
        return {"type": "run.completed"}
    if event_type == "file.edited":
        return {"type": "file.edited", "path": str(props.get("file", ""))}
    if event_type == "permission.replied":
        return {
            "type": "approval.resolved",
            "approval_id": str(props.get("requestID", "")),
            "reply": str(props.get("reply", "")),
        }
    return None
