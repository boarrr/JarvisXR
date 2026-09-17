#!/usr/bin/env python3
"""Minimal stdio MCP server used by backend tests."""
from __future__ import annotations

import json
import sys


def _send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main() -> None:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = message.get("method", "")
        request_id = message.get("id")
        if method == "initialize":
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {"tools": {}, "resources": {}},
                        "serverInfo": {"name": "fixture", "version": "1.0"},
                    },
                }
            )
        elif method in {"notifications/initialized", "notifications/cancelled"}:
            continue
        elif method == "tools/list":
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "tools": [
                            {
                                "name": "echo",
                                "description": "Echo text back",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {"text": {"type": "string"}},
                                    "additionalProperties": False,
                                },
                                "annotations": {"readOnlyHint": True},
                            },
                            {
                                "name": "write_note",
                                "description": "Record a note in the fixture process",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {"text": {"type": "string"}},
                                    "additionalProperties": False,
                                },
                                "annotations": {"destructiveHint": False},
                            },
                            {
                                "name": "explode",
                                "description": "Always fails",
                                "inputSchema": {"type": "object", "properties": {}},
                                "annotations": {},
                            },
                        ]
                    },
                }
            )
        elif method == "tools/call":
            params = message.get("params", {})
            name = params.get("name")
            arguments = params.get("arguments", {})
            if name == "echo":
                _send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "content": [
                                {"type": "text", "text": f"echo: {arguments.get('text', '')}"}
                            ],
                            "isError": False,
                        },
                    }
                )
            elif name == "write_note":
                _send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "content": [
                                {
                                    "type": "text",
                                    "text": f"note stored: {str(arguments.get('text', ''))[:40]}",
                                }
                            ],
                            "isError": False,
                        },
                    }
                )
            elif name == "explode":
                _send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "content": [{"type": "text", "text": "fixture failure"}],
                            "isError": True,
                        },
                    }
                )
            else:
                _send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32601, "message": f"unknown tool {name}"},
                    }
                )
        elif method == "resources/list":
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "resources": [{"uri": "fixture://greeting", "name": "greeting"}]
                    },
                }
            )
        elif method == "resources/read":
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "contents": [
                            {"uri": "fixture://greeting", "text": "hello from fixture"}
                        ]
                    },
                }
            )
        elif request_id is not None:
            _send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown method {method}"},
                }
            )


if __name__ == "__main__":
    main()
