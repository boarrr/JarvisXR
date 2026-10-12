from __future__ import annotations

import asyncio
import hashlib
import http.client
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer
from spatial_agent_backend.update_service import UpdateError, parse_byte_range


class ParseByteRangeTests(unittest.TestCase):
    def test_no_header(self) -> None:
        self.assertIsNone(parse_byte_range(None, 100))
        self.assertIsNone(parse_byte_range("", 100))

    def test_closed_range(self) -> None:
        self.assertEqual(parse_byte_range("bytes=10-19", 100), (10, 19))

    def test_open_range(self) -> None:
        self.assertEqual(parse_byte_range("bytes=90-", 100), (90, 99))

    def test_suffix_range(self) -> None:
        self.assertEqual(parse_byte_range("bytes=-10", 100), (90, 99))

    def test_end_clamped(self) -> None:
        self.assertEqual(parse_byte_range("bytes=90-500", 100), (90, 99))

    def test_unsatisfiable(self) -> None:
        with self.assertRaises(UpdateError):
            parse_byte_range("bytes=200-300", 100)


class UpdateHttpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        root = Path(self.temporary_directory.name)
        self.apk_bytes = bytes(range(256)) * 40  # 10240 bytes
        self.sha = hashlib.sha256(self.apk_bytes).hexdigest()
        updates = root / "updates"
        updates.mkdir()
        apk_name = f"spatial-agent-{self.sha[:12]}.apk"
        (updates / apk_name).write_bytes(self.apk_bytes)
        self.manifest_path = root / "manifest.json"
        self.manifest_path.write_text(
            json.dumps(
                {
                    "app": "spatial-agent",
                    "version": "9.9.9",
                    "sha256": self.sha,
                    "size_bytes": len(self.apk_bytes),
                    "built_at": "2026-10-12T00:00:00Z",
                    "apk": apk_name,
                }
            ),
            encoding="utf-8",
        )
        settings = Settings(
            provider="fake",
            fake_chunk_delay_seconds=0.001,
            database_path=root / "b.db",
            workspaces_file=root / "workspaces.json",
            mcp_config_path=root / "mcp.json",
            update_manifest_path=self.manifest_path,
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.server = await serve(
            self.application.handle_connection,
            "127.0.0.1",
            0,
            process_request=self.application._process_http_request,
        )
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.server.close()
        await self.server.wait_closed()

    def _get_blocking(self, path: str, headers: dict[str, str] | None = None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", path, headers=headers or {})
        response = conn.getresponse()
        body = response.read()
        status = response.status
        result = {key.lower(): value for key, value in response.getheaders()}
        conn.close()
        return status, result, body

    async def _get(self, path: str, headers: dict[str, str] | None = None):
        # Run the blocking HTTP client off the loop that is serving the request.
        return await asyncio.to_thread(self._get_blocking, path, headers)

    async def test_health(self) -> None:
        status, _, body = await self._get("/health")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["update"]["version"], "9.9.9")

    async def test_full_download(self) -> None:
        status, headers, body = await self._get(f"/update/{self.sha}.apk")
        self.assertEqual(status, 200)
        self.assertEqual(body, self.apk_bytes)
        self.assertEqual(headers["accept-ranges"], "bytes")
        self.assertEqual(headers["etag"], f'"{self.sha}"')

    async def test_range_download(self) -> None:
        status, headers, body = await self._get(
            f"/update/{self.sha}.apk", {"Range": "bytes=1000-1999"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(body, self.apk_bytes[1000:2000])
        self.assertEqual(headers["content-range"], f"bytes 1000-1999/{len(self.apk_bytes)}")

    async def test_resume_from_offset(self) -> None:
        start = 5000
        status, _, body = await self._get(
            f"/update/{self.sha}.apk", {"Range": f"bytes={start}-"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(body, self.apk_bytes[start:])

    async def test_stale_sha_conflict(self) -> None:
        status, _, _ = await self._get("/update/deadbeef.apk")
        self.assertEqual(status, 409)

    async def test_unsatisfiable_range(self) -> None:
        status, headers, _ = await self._get(
            f"/update/{self.sha}.apk", {"Range": "bytes=999999-"}
        )
        self.assertEqual(status, 416)
        self.assertEqual(headers["content-range"], f"bytes */{len(self.apk_bytes)}")


if __name__ == "__main__":
    unittest.main()
