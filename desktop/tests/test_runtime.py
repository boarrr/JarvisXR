from __future__ import annotations

import dataclasses
import socket
import tempfile
import time
import unittest
from pathlib import Path

from spatial_agent_backend.config import Settings

from spatial_agent_desktop.runtime import DaemonRuntime


def _free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()
    return port


def _settings(tmp: Path) -> Settings:
    base = Settings.from_environment()
    return dataclasses.replace(
        base,
        host="127.0.0.1",
        port=_free_port(),
        provider="fake",
        discovery_enabled=False,
        auth_required=False,
        database_path=tmp / "spatial_agent.db",
        workspaces_file=tmp / "workspaces.json",
        mcp_config_path=tmp / "mcp.json",
    )


class DaemonRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.runtime = DaemonRuntime(_settings(Path(self._tmpdir.name)))
        self.runtime.start()
        self.assertTrue(self.runtime.wait_ready(), "daemon runtime should become ready")

    def tearDown(self) -> None:
        self.runtime.stop()
        self._tmpdir.cleanup()

    def test_status_and_link_info(self) -> None:
        status = self.runtime.status()
        self.assertTrue(status["running"])
        self.assertFalse(status["paused"])
        self.assertEqual(status["provider"], "fake")
        link = self.runtime.link_info()
        self.assertIn("ws_urls", link)
        self.assertTrue(link["ws_urls"])
        self.assertTrue(link["ws_urls"][0].startswith("ws://"))
        self.assertEqual(link["discovery_enabled"], False)

    def test_create_send_and_transcript(self) -> None:
        created = self.runtime.create_thread("Office test")
        self.assertTrue(created.get("id"))
        thread_id = created["id"]
        titles = [t["title"] for t in self.runtime.threads()]
        self.assertIn("Office test", titles)

        self.assertTrue(self.runtime.send_message(thread_id, "hello office"))
        deadline = time.time() + 10
        found = False
        while time.time() < deadline:
            thread = next((t for t in self.runtime.threads() if t["id"] == thread_id), None)
            roles = [m.get("role") for m in (thread or {}).get("messages", [])]
            if "assistant" in roles:
                found = True
                break
            time.sleep(0.1)
        self.assertTrue(found, "assistant reply should land in the transcript")

    def test_pause_blocks_new_runs(self) -> None:
        thread_id = self.runtime.create_thread("Paused test").get("id")
        paused = self.runtime.set_paused(True)
        self.assertTrue(paused["paused"])
        self.assertFalse(self.runtime.send_message(thread_id, "should not run"))
        resumed = self.runtime.set_paused(False)
        self.assertFalse(resumed["paused"])
        self.assertTrue(self.runtime.send_message(thread_id, "runs again"))


if __name__ == "__main__":
    unittest.main()
