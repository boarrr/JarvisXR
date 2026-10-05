from __future__ import annotations

import asyncio
import contextlib
import json
from urllib.parse import parse_qs, urlparse
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from spatial_agent_backend.opencode_bridge import (
    OpencodeClient,
    OpencodeError,
    permission_from_event,
    translate_event,
)

AUTH = "Basic b3BlbmNvZGU6c2VjcmV0"  # opencode:secret


class _FakeOpencodeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "fake-opencode/1"

    # Silence per-request logging.
    def log_message(self, _format: str, *_args) -> None:  # noqa: A003
        return

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == AUTH

    def _send_json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode() or "{}")
        except json.JSONDecodeError:
            return {}

    def _emit(self, event_type: str, properties: dict | None = None) -> None:
        payload = {"type": event_type, "properties": properties or {}}
        chunk = f"data: {json.dumps(payload)}\n\n".encode()
        self.wfile.write(chunk)
        self.wfile.flush()

    def _route(self) -> tuple[str, dict]:
        parsed = urlparse(self.path)
        self.server.state.last_directory = (  # type: ignore[attr-defined]
            parse_qs(parsed.query).get("directory", [""])[0]
        )
        return parsed.path, parse_qs(parsed.query)

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        route, _query = self._route()
        state = self.server.state  # type: ignore[attr-defined]
        if route == "/global/health":
            self._send_json(200, {"healthy": True, "version": "test"})
            return
        if route == "/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self._emit("server.connected")
            if not state.prompt_sent.wait(timeout=10):
                return
            self._emit("session.status", {"sessionID": state.session_id, "status": {"type": "busy"}})
            self._emit(
                "message.part.delta",
                {"messageID": "msg_1", "partID": "prt_1", "field": "text", "delta": "Hel"},
            )
            self._emit(
                "message.part.delta",
                {"messageID": "msg_1", "partID": "prt_1", "field": "text", "delta": "lo"},
            )
            self._emit(
                "message.part.updated",
                {
                    "part": {
                        "type": "tool",
                        "tool": "bash",
                        "callID": "call_1",
                        "state": {"status": "running"},
                    }
                },
            )
            self._emit(
                "permission.asked",
                {
                    "id": "per_test",
                    "sessionID": state.session_id,
                    "permission": "bash",
                    "patterns": ["echo hello"],
                    "always": ["echo *"],
                    "metadata": {"command": "echo hello"},
                },
            )
            state.permission_waited.set()
            if not state.permission_replied.wait(timeout=10):
                return
            self._emit(
                "permission.replied",
                {"sessionID": state.session_id, "requestID": "per_test", "reply": "once"},
            )
            self._emit("file.edited", {"file": "/tmp/worktree/seed.txt"})
            self._emit("session.status", {"sessionID": state.session_id, "status": {"type": "idle"}})
            self._emit("session.idle", {"sessionID": state.session_id})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        route, _query = self._route()
        state = self.server.state  # type: ignore[attr-defined]
        if route == "/session":
            state.session_permission = self._read_body().get("permission")
            self._send_json(200, {"id": state.session_id})
            return
        if route == f"/session/{state.session_id}/prompt_async":
            self._read_body()
            state.prompt_sent.set()
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route == f"/session/{state.session_id}/permissions/per_test":
            body = self._read_body()
            state.permission_reply = body.get("response", "")
            state.permission_replied.set()
            self._send_json(200, True)
            return
        if route == f"/session/{state.session_id}/abort":
            self._send_json(200, True)
            return
        self._send_json(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        self._send_json(200, True)


class _State:
    def __init__(self) -> None:
        self.session_id = "ses_test"
        self.prompt_sent = threading.Event()
        self.permission_waited = threading.Event()
        self.permission_replied = threading.Event()
        self.permission_reply = ""
        self.session_permission = None
        self.last_directory = ""


def start_fake_server() -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeOpencodeHandler)
    server.state = _State()  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    return server, f"http://{host}:{port}"


class OpencodeBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.server, self.base_url = start_fake_server()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.client = OpencodeClient(self.base_url, password="secret")

    async def test_auth_is_required(self) -> None:
        unauthorized = OpencodeClient(self.base_url, password="wrong")
        with self.assertRaises(OpencodeError):
            await unauthorized.health()

    async def test_directory_and_permission_ruleset_are_scoped(self) -> None:
        scoped = OpencodeClient(
            self.base_url,
            password="secret",
            directory="/tmp/worktree/run-1",
        )
        session_id = await scoped.create_session(
            permission={"*": "allow", "edit": "allow", "bash": "ask"}
        )
        self.assertEqual(session_id, "ses_test")
        state = self.server.state  # type: ignore[attr-defined]
        self.assertEqual(state.last_directory, "/tmp/worktree/run-1")
        self.assertEqual(
            state.session_permission,
            {"*": "allow", "edit": "allow", "bash": "ask"},
        )

    async def test_session_lifecycle_streams_events_and_permissions(self) -> None:
        health = await self.client.health()
        self.assertTrue(health["healthy"])
        session_id = await self.client.create_session()
        self.assertEqual(session_id, "ses_test")

        collected: list[dict] = []
        approvals: list = []
        deltas: list[str] = []

        async def consume() -> None:
            async for event in self.client.events():
                if event.get("type") == "__stream_error__":
                    self.fail(f"stream error: {event}")
                request = permission_from_event(event)
                if request is not None:
                    approvals.append(request)
                    await self.client.reply_permission(
                        request.session_id, request.approval_id, "once"
                    )
                    continue
                translated = translate_event(event)
                if translated is None:
                    continue
                collected.append(translated)
                if translated["type"] == "message.delta":
                    deltas.append(translated["text"])

        consumer = asyncio.create_task(consume())
        await asyncio.sleep(0.2)
        await self.client.prompt(session_id, "do the thing")

        deadline = time.time() + 10
        while time.time() < deadline and not any(
            event["type"] == "run.completed" for event in collected
        ):
            await asyncio.sleep(0.05)

        if not consumer.done():
            consumer.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await consumer

        self.assertEqual("".join(deltas), "Hello")
        self.assertTrue(any(event["type"] == "tool.activity" for event in collected))
        self.assertTrue(any(event["type"] == "file.edited" for event in collected))
        self.assertTrue(any(event["type"] == "run.completed" for event in collected))

        self.assertEqual(len(approvals), 1)
        request = approvals[0]
        self.assertEqual(request.permission, "bash")
        self.assertEqual(request.patterns, ["echo hello"])
        self.assertEqual(request.always, ["echo *"])
        self.assertEqual(request.metadata, {"command": "echo hello"})
        self.assertTrue(
            any(event["type"] == "approval.resolved" for event in collected),
            "permission reply should surface as approval.resolved",
        )
        self.assertEqual(
            self.server.state.permission_reply,  # type: ignore[attr-defined]
            "once",
        )


class PermissionParsingTests(unittest.TestCase):
    def test_reads_pattern_title_and_command(self) -> None:
        event = {
            "type": "permission.asked",
            "properties": {
                "id": "perm_1",
                "sessionID": "ses_1",
                "permission": "bash",
                "title": "Run the tests",
                "pattern": "pytest -q",
                "metadata": {"command": "pytest -q"},
            },
        }
        request = permission_from_event(event)
        assert request is not None
        self.assertEqual(request.permission, "bash")
        self.assertEqual(request.title, "Run the tests")
        self.assertEqual(request.patterns, ["pytest -q"])
        self.assertEqual(request.command(), "pytest -q")

    def test_falls_back_to_legacy_shapes(self) -> None:
        event = {
            "type": "permission.asked",
            "properties": {
                "id": "perm_2",
                "sessionID": "ses_1",
                "type": "bash",
                "patterns": ["git status", "git diff"],
                "metadata": {},
            },
        }
        request = permission_from_event(event)
        assert request is not None
        self.assertEqual(request.permission, "bash")
        self.assertEqual(request.patterns, ["git status", "git diff"])
        self.assertEqual(request.command(), "git status")

    def test_ignores_non_permission_events(self) -> None:
        self.assertIsNone(permission_from_event({"type": "message.part.updated"}))


if __name__ == "__main__":
    unittest.main()
