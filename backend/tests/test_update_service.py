from __future__ import annotations

import base64
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.update_service import UpdateError, UpdateService


class UpdateServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.manifest_path = self.root / "manifest.json"

    def _publish(self, payload: bytes, **fields) -> None:
        updates = self.root / "updates"
        updates.mkdir(exist_ok=True)
        apk = updates / "spatial-agent-test.apk"
        apk.write_bytes(payload)
        manifest = {
            "app": "spatial-agent",
            "package": "com.spatialagent.xr",
            "version": fields.get("version", "abc123"),
            "sha256": fields.get("sha256", "deadbeef"),
            "size_bytes": len(payload),
            "built_at": "2026-09-23T00:00:00Z",
            "apk": apk.name,
        }
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_missing_manifest_reports_no_update(self) -> None:
        service = UpdateService(self.manifest_path)
        self.assertIsNone(service.current())
        self.assertEqual(service.manifest_payload(), {})
        with self.assertRaises(UpdateError):
            service.read_chunk(0, 16)

    def test_manifest_and_chunked_download(self) -> None:
        payload = bytes(range(256)) * 1000  # 256,000 bytes
        self._publish(payload, version="rev42")
        service = UpdateService(self.manifest_path, chunk_bytes=64 * 1024)
        manifest = service.manifest_payload()
        self.assertEqual(manifest["version"], "rev42")
        self.assertEqual(manifest["size_bytes"], len(payload))
        self.assertEqual(manifest["chunk_bytes"], 64 * 1024)

        assembled = bytearray()
        offset = 0
        while True:
            data, eof = service.read_chunk(offset, 1_000_000)
            self.assertLessEqual(len(data), 64 * 1024)
            assembled.extend(data)
            offset += len(data)
            if eof:
                break
        self.assertEqual(bytes(assembled), payload)

    def test_chunk_is_base64_transport_ready(self) -> None:
        self._publish(b"hello-update")
        service = UpdateService(self.manifest_path)
        data, eof = service.read_chunk(0, 64)
        self.assertTrue(eof)
        self.assertEqual(base64.b64decode(base64.b64encode(data)), b"hello-update")

    def test_manifest_without_apk_is_ignored(self) -> None:
        self.manifest_path.write_text(
            json.dumps({"apk": "missing.apk", "sha256": "x"}), encoding="utf-8"
        )
        self.assertIsNone(UpdateService(self.manifest_path).current())


if __name__ == "__main__":
    unittest.main()
