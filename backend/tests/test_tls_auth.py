from __future__ import annotations

import asyncio
import json
from pathlib import Path
import shutil
import ssl
import subprocess
from tempfile import TemporaryDirectory
import unittest
from uuid import uuid4

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer


def command(command_type: str, *, session_id: str = "", payload: dict | None = None) -> str:
    return json.dumps(
        {
            "v": 2,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": session_id,
            "thread_id": "",
            "timestamp": "2026-09-21T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(websocket) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=10.0))


@unittest.skipUnless(shutil.which("openssl"), "openssl is required for TLS tests")
class TlsAuthTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.cert_dir = Path(self.temporary_directory.name) / "certs"
        self.cert_dir.mkdir()
        self._generate_certificates()
        self.settings = Settings(
            database_path=Path(self.temporary_directory.name) / "tls.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
            auth_required=True,
            tls_certificate_path=self.cert_dir / "server.crt",
            tls_private_key_path=self.cert_dir / "server.key",
            pairing_code_ttl_seconds=60.0,
            fake_chunk_delay_seconds=0.001,
        )
        self.application = SpatialAgentServer(self.settings)
        await self.application.initialize()
        self.websocket_server = await serve(
            self.application.handle_connection,
            "127.0.0.1",
            0,
            ssl=self.application._build_ssl_context(),
        )
        self.port = self.websocket_server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.websocket_server.close()
        await self.websocket_server.wait_closed()

    def _generate_certificates(self) -> None:
        directory = self.cert_dir
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-days", "2", "-subj", "/CN=Spatial Agent Test CA",
                "-keyout", str(directory / "ca.key"), "-out", str(directory / "ca.crt"),
            ],
            check=True,
            capture_output=True,
        )
        extension = directory / "server.ext"
        extension.write_text(
            "basicConstraints=CA:FALSE\n"
            "keyUsage=digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            "subjectAltName=DNS:localhost,IP:127.0.0.1\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                "openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-subj", "/CN=localhost",
                "-keyout", str(directory / "server.key"), "-out", str(directory / "server.csr"),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl", "x509", "-req", "-in", str(directory / "server.csr"),
                "-CA", str(directory / "ca.crt"), "-CAkey", str(directory / "ca.key"),
                "-CAcreateserial", "-days", "2", "-sha256",
                "-extfile", str(extension), "-out", str(directory / "server.crt"),
            ],
            check=True,
            capture_output=True,
        )

    def _trusting_context(self) -> ssl.SSLContext:
        return ssl.create_default_context(cafile=str(self.cert_dir / "ca.crt"))

    async def test_wss_pairing_and_authenticated_session(self) -> None:
        code = self.application.pairing.issue_code()
        websocket = await connect(
            f"wss://127.0.0.1:{self.port}/ws", ssl=self._trusting_context()
        )
        async with websocket:
            await websocket.send(
                command("session.pair", payload={"code": code, "device_name": "Quest 3S"})
            )
            paired = await receive_event(websocket)
            self.assertEqual(paired["type"], "session.paired")
            token = paired["payload"]["token"]
            self.assertTrue(token)

            await websocket.send(
                command("session.hello", payload={"protocol_version": 2, "auth_token": token})
            )
            ready = await receive_event(websocket)
            self.assertEqual(ready["type"], "session.ready")
            self.assertEqual(ready["payload"]["auth"], "paired")

            await websocket.send(command("thread.list", session_id=ready["session_id"]))
            snapshot = await receive_event(websocket)
            self.assertEqual(snapshot["type"], "thread.snapshot")
            self.assertTrue(snapshot["session_id"].startswith("sess_"))

    async def test_untrusted_certificate_is_rejected(self) -> None:
        with self.assertRaises(ssl.SSLError):
            await connect(
                f"wss://127.0.0.1:{self.port}/ws",
                ssl=ssl.create_default_context(),
            )

    async def test_plain_websocket_cannot_skip_tls(self) -> None:
        with self.assertRaises(Exception):
            await connect(f"ws://127.0.0.1:{self.port}/ws", open_timeout=3)


if __name__ == "__main__":
    unittest.main()
