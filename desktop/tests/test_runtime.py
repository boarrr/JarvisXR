from __future__ import annotations

import dataclasses
import socket
import subprocess
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
        # Mission fan-out needs a registered git workspace for worktrees.
        repo = Path(self._tmpdir.name) / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "t@e.com"], cwd=repo, check=True, capture_output=True)
        (repo / "app.py").write_text("print('hi')\n", encoding="utf-8")
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=repo, check=True, capture_output=True)
        self.runtime._server.workspaces.register("Demo", repo)

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

    def test_mission_fan_out_and_pick_one(self) -> None:
        mission = self.runtime.create_mission("Add a feature", agent_count=2)
        mission_id = str(mission.get("id", ""))
        self.assertTrue(mission_id)
        self.assertEqual(len(mission.get("agents", [])), 2)

        status = mission
        for _ in range(100):
            status = self.runtime.mission_status(mission_id)
            if status.get("status") == "awaiting_merge":
                break
            time.sleep(0.05)
        self.assertEqual(status.get("status"), "awaiting_merge")

        agents = self.runtime.mission_compare(mission_id)
        run_ids = [a["run_id"] for a in agents if a.get("run_id")]
        self.assertTrue(run_ids, "agents should expose worktree run ids")

        result = self.runtime.mission_merge(mission_id, run_ids[0])
        self.assertTrue(result.get("merged"))
        self.assertEqual(self.runtime.mission_status(mission_id).get("status"), "merged")


if __name__ == "__main__":
    unittest.main()
