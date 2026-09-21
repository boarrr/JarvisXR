from __future__ import annotations

import json
import unittest

from spatial_agent_backend.protocol import ProtocolError, parse_client_message


def command(command_type: str, *, thread_id: str = "", payload: dict | None = None) -> str:
    return json.dumps(
        {
            "v": 1,
            "type": command_type,
            "event_id": "cmd_test",
            "session_id": "sess_test",
            "thread_id": thread_id,
            "timestamp": "2026-09-15T12:00:00Z",
            "payload": payload or {},
        }
    )


class ProtocolTests(unittest.TestCase):
    def test_valid_message_command(self) -> None:
        parsed = parse_client_message(
            command("message.send", thread_id="thread_1", payload={"content": "Hello"}),
            max_bytes=4096,
        )
        self.assertEqual(parsed.type, "message.send")
        self.assertEqual(parsed.payload["content"], "Hello")

    def test_rejects_unknown_fields(self) -> None:
        value = json.loads(command("thread.list"))
        value["unexpected"] = True
        with self.assertRaisesRegex(ProtocolError, "fields"):
            parse_client_message(json.dumps(value), max_bytes=4096)

    def test_rejects_unknown_command(self) -> None:
        with self.assertRaises(ProtocolError) as raised:
            parse_client_message(command("system.shell"), max_bytes=4096)
        self.assertEqual(raised.exception.code, "unknown_command")

    def test_rejects_empty_message(self) -> None:
        with self.assertRaises(ProtocolError) as raised:
            parse_client_message(
                command("message.send", thread_id="thread_1", payload={"content": " "}),
                max_bytes=4096,
            )
        self.assertEqual(raised.exception.code, "invalid_payload")

    def test_focus_may_clear_the_server_focus(self) -> None:
        parsed = parse_client_message(command("thread.focus"), max_bytes=4096)
        self.assertEqual(parsed.thread_id, "")

    def test_rejects_unexpected_payload_fields(self) -> None:
        with self.assertRaises(ProtocolError) as raised:
            parse_client_message(
                command("thread.list", payload={"secret": "must-not-cross"}),
                max_bytes=4096,
            )
        self.assertEqual(raised.exception.code, "invalid_payload")

    def test_rejects_oversized_packet(self) -> None:
        with self.assertRaises(ProtocolError) as raised:
            parse_client_message(command("thread.list"), max_bytes=8)
        self.assertEqual(raised.exception.code, "packet_too_large")

    def test_accepts_v2_envelope_and_negotiation(self) -> None:
        value = json.loads(command("session.hello", payload={"protocol_version": 2}))
        value["v"] = 2
        parsed = parse_client_message(json.dumps(value), max_bytes=4096)
        self.assertEqual(parsed.v, 2)
        self.assertEqual(parsed.payload["protocol_version"], 2)
        with self.assertRaises(ProtocolError):
            parse_client_message(
                command("session.hello", payload={"protocol_version": 3}), max_bytes=4096
            )

    def test_v2_commands_validate_payloads(self) -> None:
        parsed = parse_client_message(
            command(
                "workspace.bind",
                thread_id="thread_1",
                payload={"workspace_id": "ws_abc"},
            ),
            max_bytes=4096,
        )
        self.assertEqual(parsed.payload["workspace_id"], "ws_abc")

        with self.assertRaises(ProtocolError):
            parse_client_message(
                command("workspace.bind", payload={"workspace_id": "ws_abc"}),
                max_bytes=4096,
            )
        with self.assertRaises(ProtocolError) as raised:
            parse_client_message(
                command(
                    "diff.decision",
                    thread_id="thread_1",
                    payload={"run_id": "run_1", "decision": "maybe"},
                ),
                max_bytes=4096,
            )
        self.assertEqual(raised.exception.code, "invalid_payload")
        with self.assertRaises(ProtocolError):
            parse_client_message(
                command(
                    "file.read",
                    thread_id="thread_1",
                    payload={"path": "a", "extra": True},
                ),
                max_bytes=4096,
            )

    def test_combine_command_validates_thread_ids(self) -> None:
        parsed = parse_client_message(
            command("thread.combine", payload={"thread_ids": ["thread_1", "thread_2"]}),
            max_bytes=4096,
        )
        self.assertEqual(len(parsed.payload["thread_ids"]), 2)
        for invalid in (
            {"thread_ids": ["thread_1"]},
            {"thread_ids": ["thread_1", "thread_1"]},
            {"thread_ids": ["thread_1", ""]},
            {"thread_ids": "thread_1"},
        ):
            with self.assertRaises(ProtocolError):
                parse_client_message(command("thread.combine", payload=invalid), max_bytes=4096)


if __name__ == "__main__":
    unittest.main()
