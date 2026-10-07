from __future__ import annotations

import sys
import unittest
from pathlib import Path

from spatial_agent_backend.codex_cli_harness import CodexCliHarness

FIXTURE = Path(__file__).parent / "fixtures" / "fake_codex_cli.py"


class CodexHarnessTests(unittest.IsolatedAsyncioTestCase):
    async def test_streams_normalized_events(self) -> None:
        harness = CodexCliHarness(command=f"{sys.executable} {FIXTURE}")
        session_id = await harness.create_session(
            directory=str(Path(__file__).parent), title="probe"
        )
        await harness.prompt(session_id, "hello codex")
        events = [event async for event in harness.events(session_id)]

        kinds = [event.kind for event in events]
        self.assertIn("delta", kinds)
        self.assertIn("tool", kinds)
        self.assertEqual(events[-1].kind, "status")
        self.assertEqual(events[-1].status, "idle")

        text = "".join(event.text for event in events if event.kind == "delta")
        self.assertIn("hello codex", text)
        self.assertIn("done.", text)

        tool_names = [event.tool for event in events if event.kind == "tool"]
        self.assertIn("shell", tool_names)

    async def test_close_terminates_session(self) -> None:
        harness = CodexCliHarness(command=f"{sys.executable} {FIXTURE}")
        session_id = await harness.create_session(directory=".", title="x")
        await harness.close(session_id)
        with self.assertRaises(KeyError):
            await harness.prompt(session_id, "after close")


if __name__ == "__main__":
    unittest.main()
