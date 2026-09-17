from __future__ import annotations

import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.mcp_host import McpError, McpHost, parse_sse_messages

FIXTURE_SERVER = Path(__file__).parent / "fixtures" / "mcp_echo_server.py"


def write_config(path: Path, servers: list[dict]) -> None:
    path.write_text(json.dumps({"servers": servers}), encoding="utf-8")


class McpHostTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.config_path = Path(self.temporary_directory.name) / "mcp.json"
        write_config(
            self.config_path,
            [
                {
                    "id": "fixture",
                    "transport": "stdio",
                    "command": [sys.executable, str(FIXTURE_SERVER)],
                    "tool_timeout_seconds": 10,
                }
            ],
        )
        self.host = McpHost(self.config_path)
        self.host.load()

    async def asyncTearDown(self) -> None:
        await self.host.stop()

    async def test_lists_and_calls_stdio_tools(self) -> None:
        failures = await self.host.start()
        self.assertEqual(failures, {})
        tools = await self.host.list_tools("fixture")
        self.assertEqual(
            {tool.name for tool in tools}, {"echo", "write_note", "explode"}
        )
        echo = next(tool for tool in tools if tool.name == "echo")
        self.assertTrue(echo.annotations.get("readOnlyHint"))

        result = await self.host.call_tool("fixture", "echo", {"text": "hi"})
        self.assertFalse(result.is_error)
        self.assertEqual(result.text, "echo: hi")

        failing = await self.host.call_tool("fixture", "explode", {})
        self.assertTrue(failing.is_error)
        self.assertIn("fixture failure", failing.text)

    async def test_unknown_tool_reports_error(self) -> None:
        await self.host.start()
        with self.assertRaises(McpError):
            await self.host.call_tool("fixture", "missing_tool", {})

    async def test_reads_resources(self) -> None:
        await self.host.start()
        resources = await self.host.list_resources("fixture")
        self.assertEqual(resources[0]["uri"], "fixture://greeting")
        result = await self.host.read_resource("fixture", "fixture://greeting")
        self.assertIn("hello from fixture", result.text)

    async def test_unreachable_server_is_reported_not_fatal(self) -> None:
        write_config(
            self.config_path,
            [
                {
                    "id": "broken",
                    "transport": "stdio",
                    "command": [sys.executable, "-c", "import sys; sys.exit(3)"],
                }
            ],
        )
        host = McpHost(self.config_path)
        host.load()
        failures = await host.start()
        self.assertIn("broken", failures)
        await host.stop()

    async def test_policy_levels_are_exposed(self) -> None:
        write_config(
            self.config_path,
            [
                {
                    "id": "fixture",
                    "transport": "stdio",
                    "command": [sys.executable, str(FIXTURE_SERVER)],
                    "policy": {"default": "write_reversible", "tools": {"echo": "safe_read"}},
                }
            ],
        )
        host = McpHost(self.config_path)
        host.load()
        self.assertEqual(host.server_default_level("fixture"), "write_reversible")
        self.assertEqual(host.tool_levels("fixture"), {"echo": "safe_read"})

    def test_config_validation_rejects_bad_entries(self) -> None:
        cases = [
            [{"id": "bad id!", "transport": "stdio", "command": ["x"]}],
            [{"id": "x", "transport": "carrier-pigeon", "command": ["x"]}],
            [{"id": "x", "transport": "stdio", "command": []}],
            [{"id": "x", "transport": "http"}],
            [
                {
                    "id": "x",
                    "transport": "stdio",
                    "command": ["x"],
                    "policy": {"default": "banana"},
                }
            ],
            [
                {"id": "x", "transport": "stdio", "command": ["x"]},
                {"id": "x", "transport": "stdio", "command": ["y"]},
            ],
        ]
        for servers in cases:
            write_config(self.config_path, servers)
            host = McpHost(self.config_path)
            host.load()
            self.assertTrue(host.load_errors, servers)

    def test_sse_parser_extracts_json_messages(self) -> None:
        body = (
            "event: message\n"
            'data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n'
            "\n"
            "data: [DONE]\n"
        )
        messages = parse_sse_messages(body)
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["result"], {"ok": True})


if __name__ == "__main__":
    unittest.main()
